const std = @import("std");
const xev = @import("xev");
const c = @import("../c.zig").c;
const microtasks = @import("./microtasks.zig");

pub const MAX_TIMERS = 128;
const MAX_TIMER_ARGS = 8;
const MS_ONESHOT: u64 = 0;

// Hot state (touched every set/clear/fire): active/ref/sched/zombie bits +
// delays + completions. Cold state (touched only on alloc/free/fire): ctx +
// callbacks + args + timers.
//
// Design note: OUR code never reuses a completion across a cancel boundary.
// Cancel flows only through cancel+cancelCb (clear path, proven); restart
// flows only through run-from-fire (interval, proven) and reset() (refresh,
// libxev-owned). unref/ref touch NOTHING but bits — loop exit for unref'd
// timers comes from the loop predicate consulting hasReferencedTimers().
//
// Reentrancy note: clear() called from inside a firing callback (directly,
// or via anything the callback runs, including the microtask pump) frees
// synchronously while the epilogue below would free a second time.
// The zombie bit marks "already freed by reentrant clear"; the epilogue
// consumes it instead of freeing. Ownership: clear-sync sets, epilogue
// consumes, allocSlot resets. No other writer exists.
pub const TimerManager = struct {
    loop: *xev.Loop,
    // ── hot ──
    active_bits: [2]u64 = [_]u64{0} ** 2,
    ref_bits: [2]u64 = [_]u64{0} ** 2,
    sched_bits: [2]u64 = [_]u64{0} ** 2,
    zombie_bits: [2]u64 = [_]u64{0} ** 2,
    repeat_ms: [MAX_TIMERS]u64 = [_]u64{MS_ONESHOT} ** MAX_TIMERS,
    delay_ms: [MAX_TIMERS]u64 = [_]u64{0} ** MAX_TIMERS,
    completion: [MAX_TIMERS]xev.Completion = [_]xev.Completion{.{}} ** MAX_TIMERS,
    c_cancel: [MAX_TIMERS]xev.Completion = [_]xev.Completion{.{}} ** MAX_TIMERS,
    free_head: u8 = 0,
    next_free: [MAX_TIMERS]u8 = undefined,
    // ── cold ──
    timers: [MAX_TIMERS]xev.Timer = undefined,
    ctx: [MAX_TIMERS]?*c.Context = [_]?*c.Context{null} ** MAX_TIMERS,
    callbacks: [MAX_TIMERS]?c.Value = [_]?c.Value{null} ** MAX_TIMERS,
    nargs: [MAX_TIMERS]u8 = [_]u8{0} ** MAX_TIMERS,
    args: [MAX_TIMERS][MAX_TIMER_ARGS]c.Value = [_][MAX_TIMER_ARGS]c.Value{[_]c.Value{c.JS_UNDEFINED} ** MAX_TIMER_ARGS} ** MAX_TIMERS,

    comptime {
        // 128 active flags must fit in 16 bytes, not 128.
        std.debug.assert(@sizeOf([2]u64) == 16);
        std.debug.assert(MAX_TIMERS == 128);
    }

    pub fn init(loop: *xev.Loop) TimerManager {
        var tm: TimerManager = .{
            .loop = loop,
        };
        for (&tm.timers) |*t| t.* = xev.Timer.init() catch unreachable;
        for (0..MAX_TIMERS) |i| tm.next_free[i] = @intCast(i + 1);
        tm.next_free[MAX_TIMERS - 1] = MAX_TIMERS;
        return tm;
    }

    inline fn isActive(self: *const TimerManager, idx: u8) bool {
        return bitGet(&self.active_bits, idx);
    }
    inline fn setActive(self: *TimerManager, idx: u8) void {
        bitOp(&self.active_bits, idx, true);
    }
    inline fn clearActive(self: *TimerManager, idx: u8) void {
        bitOp(&self.active_bits, idx, false);
    }
    pub inline fn isReferenced(self: *const TimerManager, idx: u8) bool {
        return bitGet(&self.ref_bits, idx);
    }
    inline fn isScheduled(self: *const TimerManager, idx: u8) bool {
        return bitGet(&self.sched_bits, idx);
    }

    pub fn hasReferencedTimers(self: *const TimerManager) bool {
        // Load-bearing for loop exit: unref'd timers stay armed (with live
        // xev completions), so the loop predicate — not unscheduling —
        // decides process lifetime. See runWithMicrotasks break condition.
        for (0..2) |w| {
            if (self.active_bits[w] & self.ref_bits[w] != 0) return true;
        }
        return false;
    }

    fn popFree(self: *TimerManager) ?u8 {
        const head = self.free_head;
        if (head == MAX_TIMERS) return null;
        self.free_head = self.next_free[head];
        return head;
    }
    fn pushFree(self: *TimerManager, i: u8) void {
        self.next_free[i] = self.free_head;
        self.free_head = i;
    }
    fn indexOfCompletion(self: *const TimerManager, cpl: *const xev.Completion) usize {
        return (@intFromPtr(cpl) - @intFromPtr(&self.completion[0])) / @sizeOf(xev.Completion);
    }
    fn indexOfCancel(self: *const TimerManager, cpl: *const xev.Completion) usize {
        return (@intFromPtr(cpl) - @intFromPtr(&self.c_cancel[0])) / @sizeOf(xev.Completion);
    }
    fn freeJsValues(self: *TimerManager, idx: u8) void {
        if (self.callbacks[idx]) |v| {
            c.freeValue(self.ctx[idx].?, v);
            self.callbacks[idx] = null;
        }
        for (self.args[idx][0..self.nargs[idx]]) |v| {
            c.freeValue(self.ctx[idx].?, v);
        }
        self.nargs[idx] = 0;
    }
    fn allocSlot(self: *TimerManager, ctx: *c.Context, callback: c.Value, args: []const c.Value) !u8 {
        const idx = self.popFree() orelse return error.NoSlotsAvailable;
        self.setActive(idx);
        bitOp(&self.ref_bits, idx, true); // referenced by default (Node parity)
        bitOp(&self.zombie_bits, idx, false); // reset: stale marks must not leak across lifecycles
        self.ctx[idx] = ctx;
        self.callbacks[idx] = c.dupValue(ctx, callback);
        self.nargs[idx] = @intCast(args.len);
        for (args, 0..) |a, i| self.args[idx][i] = c.dupValue(ctx, a);
        return idx;
    }
    fn freeSlot(self: *TimerManager, idx: u8) void {
        self.clearActive(idx);
        bitOp(&self.ref_bits, idx, false);
        bitOp(&self.sched_bits, idx, false);
        self.repeat_ms[idx] = MS_ONESHOT;
        self.delay_ms[idx] = 0;
        if (self.ctx[idx] != null) self.freeJsValues(idx);
        self.ctx[idx] = null;
        self.pushFree(idx);
    }
    pub fn setTimeout(
        self: *TimerManager,
        ctx: *c.Context,
        callback: c.Value,
        ms: u64,
        args: []const c.Value,
    ) !usize {
        const idx = try self.allocSlot(ctx, callback, args);
        self.repeat_ms[idx] = MS_ONESHOT;
        self.delay_ms[idx] = ms;
        self.timers[idx].run(self.loop, &self.completion[idx], ms, TimerManager, self, timerCallback);
        bitOp(&self.sched_bits, idx, true);
        return idx;
    }
    pub fn setInterval(
        self: *TimerManager,
        ctx: *c.Context,
        callback: c.Value,
        ms: u64,
        args: []const c.Value,
    ) !usize {
        const idx = try self.allocSlot(ctx, callback, args);
        self.repeat_ms[idx] = ms;
        self.delay_ms[idx] = ms;
        self.timers[idx].run(self.loop, &self.completion[idx], ms, TimerManager, self, timerCallback);
        bitOp(&self.sched_bits, idx, true);
        return idx;
    }
    pub fn clear(self: *TimerManager, id: usize) void {
        if (id >= MAX_TIMERS) return;
        const idx: u8 = @intCast(id);
        if (!self.isActive(idx)) return;
        self.clearActive(idx);
        if (self.ctx[idx] != null) self.freeJsValues(idx);
        self.ctx[idx] = null;
        if (self.isScheduled(idx)) {
            // Completion pending: cancelCb finishes the free.
            self.timers[idx].cancel(self.loop, &self.completion[idx], &self.c_cancel[idx], TimerManager, self, cancelCb);
        } else {
            // Nothing pending: free synchronously (avoids canceling a dead
            // completion). When reached reentrantly from inside a firing
            // callback, mark zombie so the epilogue below skips its own free.
            self.freeSlot(idx);
            bitOp(&self.zombie_bits, idx, true);
        }
    }
    pub fn unrefSlot(self: *TimerManager, idx: u8) void {
        if (idx >= MAX_TIMERS or !self.isActive(idx)) return;
        // Bits only — deliberately no xev interaction. The timer stays
        // armed and fires normally if the loop outlives it (Node parity);
        // process exit is the loop predicate's job (hasReferencedTimers).
        bitOp(&self.ref_bits, idx, false);
    }
    pub fn refSlot(self: *TimerManager, idx: u8) void {
        if (idx >= MAX_TIMERS or !self.isActive(idx)) return;
        bitOp(&self.ref_bits, idx, true);
    }
    pub fn refreshSlot(self: *TimerManager, idx: u8) void {
        if (idx >= MAX_TIMERS or !self.isActive(idx)) return;
        // Native stop+restart: owns any pending-fire overlap internally,
        // reusing the existing completion pair. No hand-rolled cancel/run.
        self.timers[idx].reset(self.loop, &self.completion[idx], &self.c_cancel[idx], self.delay_ms[idx], TimerManager, self, timerCallback);
        bitOp(&self.sched_bits, idx, true);
    }
    pub fn cancelAll(self: *TimerManager) void {
        for (0..MAX_TIMERS) |i| {
            const idx: u8 = @intCast(i);
            if (self.isActive(idx)) {
                self.clearActive(idx);
                bitOp(&self.ref_bits, idx, false);
                bitOp(&self.sched_bits, idx, false);
                bitOp(&self.zombie_bits, idx, false);
                if (self.ctx[i] != null) self.freeJsValues(idx);
                self.callbacks[i] = null;
                self.ctx[i] = null;
            }
        }
    }
};

inline fn bitOp(bits: *[2]u64, idx: u8, set: bool) void {
    if (set) {
        bits[idx >> 6] |= (@as(u64, 1) << @intCast(idx & 63));
    } else {
        bits[idx >> 6] &= ~(@as(u64, 1) << @intCast(idx & 63));
    }
}
inline fn bitGet(bits: *const [2]u64, idx: u8) bool {
    return (bits[idx >> 6] >> @intCast(idx & 63)) & 1 == 1;
}

fn timerCallback(
    ud: ?*TimerManager,
    l: *xev.Loop,
    cpl: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    const tm = ud orelse return .disarm;
    const idx: u8 = @intCast(tm.indexOfCompletion(cpl));
    bitOp(&tm.sched_bits, idx, false); // completion consumed
    _ = r catch |err| {
        if (err != error.Canceled and tm.isActive(idx)) tm.freeSlot(idx);
        return .disarm;
    };
    if (!tm.isActive(idx)) return .disarm;
    if (tm.ctx[idx]) |ctx| {
        if (tm.callbacks[idx]) |fn_val| {
            // Lifetime hold: the callback may free itself mid-execution
            // (clearInterval(t) inside the callback frees the slot's dup),
            // and so may any argument. QuickJS requires func_obj and argv
            // values to stay alive for the duration of JS_Call, so dup
            // everything first; each dup is balanced by exactly one free.
            const fn_hold = c.dupValue(ctx, fn_val);
            defer c.freeValue(ctx, fn_hold);
            const n: usize = tm.nargs[idx];
            var arg_hold: [MAX_TIMER_ARGS]c.Value = undefined;
            for (tm.args[idx][0..n], 0..) |a, i| arg_hold[i] = c.dupValue(ctx, a);
            defer {
                for (arg_hold[0..n]) |a| c.freeValue(ctx, a);
            }
            const ret = c.call(ctx, fn_val, c.JS_UNDEFINED, @intCast(n), if (n > 0) &tm.args[idx][0] else null);
            // Surface timer exceptions like microtaskJob does; free the
            // (previously leaked) non-exception return value here.
            if (c.isException(ret) != 0) {
                const exc = c.getException(ctx);
                defer c.freeValue(ctx, exc);
                const msg = c.toCString(ctx, exc);
                if (msg) |m| {
                    defer c.freeCString(ctx, m);
                    std.debug.print("timer error: {s}\n", .{m});
                }
            } else {
                c.freeValue(ctx, ret);
            }
        }
        microtasks.pumpMicrotasks(ctx);
    }
    if (bitGet(&tm.zombie_bits, idx)) {
        // Reentrant clear() freed this slot during the call above (directly
        // or via the microtask pump): consume the mark, skip our own free.
        bitOp(&tm.zombie_bits, idx, false);
        return .disarm;
    }
    if (tm.repeat_ms[idx] != MS_ONESHOT) {
        if (tm.isActive(idx)) {
            tm.timers[idx].run(l, &tm.completion[idx], tm.repeat_ms[idx], TimerManager, tm, timerCallback);
            bitOp(&tm.sched_bits, idx, true);
        } else {
            tm.freeSlot(idx);
        }
        return .disarm;
    }
    tm.freeSlot(idx);
    return .disarm;
}

fn cancelCb(
    ud: ?*TimerManager,
    _: *xev.Loop,
    cpl: *xev.Completion,
    r: xev.Timer.CancelError!void,
) xev.CallbackAction {
    _ = r catch {};
    const tm = ud orelse return .disarm;
    const idx: u8 = @intCast(tm.indexOfCancel(cpl));
    tm.freeSlot(idx);
    return .disarm;
}
