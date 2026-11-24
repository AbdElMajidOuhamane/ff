const std = @import("std");
const qjs = @import("../engine/quickjs_shim.zig");
const limits = @import("../util/limits.zig");

// Maximum runtimes supported: 1 main + 8 workers
pub const RT_COUNT = 9;

// Structure of Arrays (SoA) aligned for cache-line safety
var trip: [RT_COUNT]std.atomic.Value(u8) align(64) = [_]std.atomic.Value(u8){.{ .raw = 0 }} ** RT_COUNT;
var entered_ms: [RT_COUNT]std.atomic.Value(u64) align(64) = [_]std.atomic.Value(u64){.{ .raw = 0 }} ** RT_COUNT;
var budget_ms: [RT_COUNT]std.atomic.Value(u32) align(64) = [_]std.atomic.Value(u32){.{ .raw = 0 }} ** RT_COUNT;
var depth: [RT_COUNT]std.atomic.Value(u32) align(64) = [_]std.atomic.Value(u32){.{ .raw = 0 }} ** RT_COUNT;
var rt_ptrs: [RT_COUNT]?*anyopaque = [_]?*anyopaque{null} ** RT_COUNT;
var wall_deadline_ms: std.atomic.Value(u64) align(64) = .{ .raw = 0 };

pub const Mutex = struct {
    state: std.atomic.Value(u8) = .init(0),

    pub fn lock(self: *Mutex) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
            std.Thread.yield() catch {};
        }
    }

    pub fn tryLock(self: *Mutex) bool {
        return self.state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null;
    }

    pub fn unlock(self: *Mutex) void {
        self.state.store(0, .release);
    }
};

var monitor_running = std.atomic.Value(bool).init(false);
var monitor_thread: ?std.Thread = null;
var thread_mutex: Mutex = .{};

pub fn monotonicNowMs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @intCast(@as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000));
}

/// Fast interrupt callback called by QuickJS periodically
pub fn interruptCb(_: ?*qjs.Runtime, opaque_: ?*anyopaque) callconv(.c) c_int {
    const idx = @intFromPtr(opaque_);
    if (idx >= RT_COUNT) return 0;
    return trip[idx].load(.monotonic);
}

threadlocal var current_runtime_idx: ?usize = null;

pub fn getRuntimeIdx(rt: ?*anyopaque) ?usize {
    if (current_runtime_idx) |idx| return idx;
    if (rt == null) return null;
    for (0..RT_COUNT) |i| {
        if (rt_ptrs[i] == rt) return i;
    }
    return null;
}

pub inline fn isBudgetEnabled(runtime_idx: usize) bool {
    if (runtime_idx >= RT_COUNT) return false;
    return budget_ms[runtime_idx].load(.monotonic) > 0;
}

/// Mark when JS execution enters a macrotask/handler/microtask pump
pub inline fn enterJs(runtime_idx: usize, now_ms: u64) void {
    if (runtime_idx >= RT_COUNT) return;
    const prev = depth[runtime_idx].fetchAdd(1, .acq_rel);
    if (prev == 0) {
        trip[runtime_idx].store(0, .monotonic);
        entered_ms[runtime_idx].store(now_ms, .release);
    }
}

/// Mark when JS execution enters, fetching monotonic clock only when budget is enabled
pub inline fn enterJsAuto(runtime_idx: usize) void {
    if (!isBudgetEnabled(runtime_idx)) return;
    enterJs(runtime_idx, monotonicNowMs());
}

/// Mark when JS execution returns to the event loop
pub inline fn leaveJs(runtime_idx: usize) void {
    if (runtime_idx >= RT_COUNT) return;
    const prev = depth[runtime_idx].fetchSub(1, .acq_rel);
    if (prev <= 1) {
        depth[runtime_idx].store(0, .release);
        entered_ms[runtime_idx].store(0, .release);
        trip[runtime_idx].store(0, .monotonic);
    }
}

pub inline fn leaveJsAuto(runtime_idx: usize) void {
    if (!isBudgetEnabled(runtime_idx)) return;
    leaveJs(runtime_idx);
}

pub fn registerRuntime(rt: *qjs.Runtime, idx: usize, budget: u32) void {
    if (idx >= RT_COUNT) return;
    current_runtime_idx = idx;
    rt_ptrs[idx] = rt;
    budget_ms[idx].store(budget, .release);
    depth[idx].store(0, .release);
    trip[idx].store(0, .monotonic);
    entered_ms[idx].store(0, .release);

    if (budget > 0) {
        qjs.setInterruptHandler(rt, interruptCb, @ptrFromInt(idx));
        startMonitorIfNeeded();
    }
}

pub fn isWallExpired(now_ms: u64, deadline_ms: u64) bool {
    return deadline_ms != 0 and now_ms >= deadline_ms;
}

pub fn setWallTimeout(ms: u32) void {
    if (ms == 0) {
        wall_deadline_ms.store(0, .release);
        return;
    }
    const now = monotonicNowMs();
    wall_deadline_ms.store(now + @as(u64, ms), .release);
    startMonitorIfNeeded();
}

fn monitorLoop() void {
    const ts: std.c.timespec = .{ .sec = 0, .nsec = 20 * 1_000_000 };
    while (monitor_running.load(.acquire)) {
        _ = std.c.nanosleep(&ts, null);
        const now = monotonicNowMs();
        const deadline = wall_deadline_ms.load(.acquire);
        if (isWallExpired(now, deadline)) {
            const msg = "error: wall-clock timeout exceeded\n";
            _ = std.c.write(2, msg.ptr, msg.len);
            std.c._exit(124);
        }
        for (0..RT_COUNT) |i| {
            const b = budget_ms[i].load(.acquire);
            if (b == 0) continue;
            const start = entered_ms[i].load(.acquire);
            if (start != 0 and now >= start and (now - start) > b) {
                trip[i].store(1, .monotonic);
            }
        }
    }
}

fn startMonitorIfNeeded() void {
    thread_mutex.lock();
    defer thread_mutex.unlock();
    if (!monitor_running.load(.acquire)) {
        monitor_running.store(true, .release);
        monitor_thread = std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, monitorLoop, .{}) catch null;
    }
}

pub fn stopMonitor() void {
    thread_mutex.lock();
    defer thread_mutex.unlock();
    if (monitor_running.swap(false, .acq_rel)) {
        if (monitor_thread) |th| {
            th.join();
            monitor_thread = null;
        }
    }
}

test "isWallExpired checks disabled and active deadlines" {
    try std.testing.expect(!isWallExpired(1000, 0));
    try std.testing.expect(!isWallExpired(999, 1000));
    try std.testing.expect(isWallExpired(1000, 1000));
    try std.testing.expect(isWallExpired(1500, 1000));
}

test "enterJs and leaveJs nest and clear state" {
    const idx = RT_COUNT - 1;
    budget_ms[idx].store(100, .release);
    defer {
        budget_ms[idx].store(0, .release);
        depth[idx].store(0, .release);
        entered_ms[idx].store(0, .release);
        trip[idx].store(0, .monotonic);
    }

    enterJs(idx, 5000);
    try std.testing.expectEqual(@as(u32, 1), depth[idx].load(.acquire));
    try std.testing.expectEqual(@as(u64, 5000), entered_ms[idx].load(.acquire));

    enterJs(idx, 6000);
    try std.testing.expectEqual(@as(u32, 2), depth[idx].load(.acquire));
    try std.testing.expectEqual(@as(u64, 5000), entered_ms[idx].load(.acquire));

    leaveJs(idx);
    try std.testing.expectEqual(@as(u32, 1), depth[idx].load(.acquire));
    try std.testing.expectEqual(@as(u64, 5000), entered_ms[idx].load(.acquire));

    leaveJs(idx);
    try std.testing.expectEqual(@as(u32, 0), depth[idx].load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), entered_ms[idx].load(.acquire));
}
