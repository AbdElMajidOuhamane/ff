const std = @import("std");
const xev = @import("xev");
const c = @import("../c.zig").c;
const microtasks = @import("./microtasks.zig");

const MAX_TIMERS = 128;
const MS_ONESHOT: u64 = 0;

// Hot state (touched every set/clear/fire): active bits + repeat + completions.
// Cold state (touched only on alloc/free/fire): ctx + callbacks + timers.
// Split ordering keeps the hot working set in fewer cache lines.
pub const TimerManager = struct {
    loop: *xev.Loop,
    // ── hot ──
    active_bits: [2]u64 = [_]u64{0} ** 2,
    repeat_ms: [MAX_TIMERS]u64 = [_]u64{MS_ONESHOT} ** MAX_TIMERS,
    completion: [MAX_TIMERS]xev.Completion = [_]xev.Completion{.{}} ** MAX_TIMERS,
    c_cancel: [MAX_TIMERS]xev.Completion = [_]xev.Completion{.{}} ** MAX_TIMERS,
    free_head: u8 = 0,
    next_free: [MAX_TIMERS]u8 = undefined,
    // ── cold ──
    timers: [MAX_TIMERS]xev.Timer = undefined,
    ctx: [MAX_TIMERS]?*c.Context = [_]?*c.Context{null} ** MAX_TIMERS,
    callbacks: [MAX_TIMERS]?c.Value = [_]?c.Value{null} ** MAX_TIMERS,

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
        return (self.active_bits[idx >> 6] >> @intCast(idx & 63)) & 1 == 1;
    }
    inline fn setActive(self: *TimerManager, idx: u8) void {
        self.active_bits[idx >> 6] |= (@as(u64, 1) << @intCast(idx & 63));
    }
    inline fn clearActive(self: *TimerManager, idx: u8) void {
        self.active_bits[idx >> 6] &= ~(@as(u64, 1) << @intCast(idx & 63));
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
    fn allocSlot(self: *TimerManager, ctx: *c.Context, callback: c.Value) !u8 {
        const idx = self.popFree() orelse return error.NoSlotsAvailable;
        self.setActive(idx);
        self.ctx[idx] = ctx;
        self.callbacks[idx] = c.dupValue(ctx, callback);
        return idx;
    }
    fn freeSlot(self: *TimerManager, idx: u8) void {
        self.clearActive(idx);
        self.repeat_ms[idx] = MS_ONESHOT;
        if (self.callbacks[idx]) |v| {
            c.freeValue(self.ctx[idx].?, v);
        }
        self.callbacks[idx] = null;
        self.ctx[idx] = null;
        self.pushFree(idx);
    }
    pub fn setTimeout(
        self: *TimerManager,
        ctx: *c.Context,
        callback: c.Value,
        ms: u64,
    ) !usize {
        const idx = try self.allocSlot(ctx, callback);
        self.repeat_ms[idx] = MS_ONESHOT;
        self.timers[idx].run(self.loop, &self.completion[idx], ms, TimerManager, self, timerCallback);
        return idx;
    }
    pub fn setInterval(
        self: *TimerManager,
        ctx: *c.Context,
        callback: c.Value,
        ms: u64,
    ) !usize {
        const idx = try self.allocSlot(ctx, callback);
        self.repeat_ms[idx] = ms;
        self.timers[idx].run(self.loop, &self.completion[idx], ms, TimerManager, self, timerCallback);
        return idx;
    }
    pub fn clear(self: *TimerManager, id: usize) void {
        if (id >= MAX_TIMERS) return;
        const idx: u8 = @intCast(id);
        if (!self.isActive(idx)) return;
        self.clearActive(idx);
        if (self.callbacks[idx]) |v| {
            c.freeValue(self.ctx[idx].?, v);
        }
        self.callbacks[idx] = null;
        self.ctx[idx] = null;
        self.timers[idx].cancel(self.loop, &self.completion[idx], &self.c_cancel[idx], TimerManager, self, cancelCb);
    }
    pub fn cancelAll(self: *TimerManager) void {
        for (0..MAX_TIMERS) |i| {
            const idx: u8 = @intCast(i);
            if (self.isActive(idx)) {
                self.clearActive(idx);
                if (self.callbacks[i]) |v| {
                    c.freeValue(self.ctx[i].?, v);
                }
                self.callbacks[i] = null;
                self.ctx[i] = null;
            }
        }
    }
};

fn timerCallback(
    ud: ?*TimerManager,
    l: *xev.Loop,
    cpl: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    const tm = ud orelse return .disarm;
    const idx: u8 = @intCast(tm.indexOfCompletion(cpl));
    _ = r catch |err| {
        if (err != error.Canceled and tm.isActive(idx)) tm.freeSlot(idx);
        return .disarm;
    };
    if (!tm.isActive(idx)) return .disarm;
    if (tm.ctx[idx]) |ctx| {
        if (tm.callbacks[idx]) |fn_val| {
            _ = c.call(ctx, fn_val, c.JS_UNDEFINED, 0, null);
        }
        microtasks.pumpMicrotasks(ctx);
    }
    if (tm.repeat_ms[idx] != MS_ONESHOT) {
        if (tm.isActive(idx)) {
            tm.timers[idx].run(l, &tm.completion[idx], tm.repeat_ms[idx], TimerManager, tm, timerCallback);
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
