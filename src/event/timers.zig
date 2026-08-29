const std = @import("std");
const xev = @import("xev");
const c = @import("../c.zig").c;
const microtasks = @import("./microtasks.zig");
const MAX_TIMERS = 128;
const MS_ONESHOT: u64 = 0;
pub const TimerManager = struct {
    loop: *xev.Loop,
    timers: [MAX_TIMERS]xev.Timer,
    free_head: u8,
    next_free: [MAX_TIMERS]u8,
    active:     [MAX_TIMERS]bool,
    repeat_ms:  [MAX_TIMERS]u64,
    ctx:        [MAX_TIMERS]?*c.Context,
    callbacks:  [MAX_TIMERS]?c.Value,
    completion: [MAX_TIMERS]xev.Completion,
    c_cancel:   [MAX_TIMERS]xev.Completion,
    pub fn init(loop: *xev.Loop) TimerManager {
        var tm: TimerManager = .{
            .loop = loop,
            .timers = undefined,
            .free_head = 0,
            .next_free = undefined,
            .active = [_]bool{false} ** MAX_TIMERS,
            .repeat_ms = [_]u64{MS_ONESHOT} ** MAX_TIMERS,
            .ctx = [_]?*c.Context{null} ** MAX_TIMERS,
            .callbacks = [_]?c.Value{null} ** MAX_TIMERS,
            .completion = [_]xev.Completion{.{}} ** MAX_TIMERS,
            .c_cancel = [_]xev.Completion{.{}} ** MAX_TIMERS,
        };
        for (&tm.timers) |*t| t.* = xev.Timer.init() catch unreachable;
        for (0..MAX_TIMERS) |i| tm.next_free[i] = @intCast(i + 1);
        tm.next_free[MAX_TIMERS - 1] = MAX_TIMERS;
        return tm;
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
        self.active[idx] = true;
        self.ctx[idx] = ctx;
        self.callbacks[idx] = c.dupValue(ctx, callback);
        return idx;
    }
    fn freeSlot(self: *TimerManager, idx: u8) void {
        self.active[idx] = false;
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
        if (!self.active[idx]) return;
        self.active[idx] = false;
        if (self.callbacks[idx]) |v| {
            c.freeValue(self.ctx[idx].?, v);
        }
        self.callbacks[idx] = null;
        self.ctx[idx] = null;
        self.timers[idx].cancel(self.loop, &self.completion[idx], &self.c_cancel[idx], TimerManager, self, cancelCb);
    }
    pub fn cancelAll(self: *TimerManager) void {
        for (0..MAX_TIMERS) |i| {
            if (self.active[i]) {
                self.active[i] = false;
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
        if (err != error.Canceled and tm.active[idx]) tm.freeSlot(idx);
        return .disarm;
    };
    if (!tm.active[idx]) return .disarm;
    if (tm.ctx[idx]) |ctx| {
        if (tm.callbacks[idx]) |fn_val| {
            _ = c.call(ctx, fn_val, c.JS_UNDEFINED, 0, null);
        }
        microtasks.pumpMicrotasks(ctx);
    }
    if (tm.repeat_ms[idx] != MS_ONESHOT) {
        if (tm.active[idx]) {
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
