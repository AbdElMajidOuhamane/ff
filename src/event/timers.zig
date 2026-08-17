const std = @import("std");
const xev = @import("xev");
const c = @import("../c.zig").c;
const microtasks = @import("./microtasks.zig");

const MAX_TIMERS = 128;
const MS_ONESHOT: u64 = 0;

pub const TimerManager = struct {
    loop: *xev.Loop,
    timer: xev.Timer,

    // Singleton free-list: next_free[i] = next slot index, MAX_TIMERS = end.
    free_head: u8,
    next_free: [MAX_TIMERS]u8,

    // SoA hot state (everything a callback touches, one contiguous block).
    active:     [MAX_TIMERS]bool,
    repeat_ms:  [MAX_TIMERS]u64, // 0 == one-shot
    isolate:    [MAX_TIMERS]?*c.Isolate,
    persistent: [MAX_TIMERS]c.Global,
    completion: [MAX_TIMERS]xev.Completion,
    c_cancel:   [MAX_TIMERS]xev.Completion,

    pub fn init(loop: *xev.Loop) TimerManager {
        var tm: TimerManager = .{
            .loop = loop,
            .timer = xev.Timer.init() catch unreachable,
            .free_head = 0,
            .next_free = undefined,
            .active = [_]bool{false} ** MAX_TIMERS,
            .repeat_ms = [_]u64{MS_ONESHOT} ** MAX_TIMERS,
            .isolate = [_]?*c.Isolate{null} ** MAX_TIMERS,
            .persistent = undefined,
            .completion = [_]xev.Completion{.{}} ** MAX_TIMERS,
            .c_cancel = [_]xev.Completion{.{}} ** MAX_TIMERS,
        };
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

    fn allocSlot(self: *TimerManager, isolate: ?*c.Isolate, callback: ?*const c.Value) !u8 {
        const idx = self.popFree() orelse return error.NoSlotsAvailable;
        self.active[idx] = true;
        self.isolate[idx] = isolate;
        c.v8__Global__New(isolate, @ptrCast(callback), &self.persistent[idx]);
        return idx;
    }

    fn freeSlot(self: *TimerManager, idx: u8) void {
        self.active[idx] = false;
        self.repeat_ms[idx] = MS_ONESHOT;
        self.isolate[idx] = null;
        c.v8__Global__Reset(&self.persistent[idx]);
        self.pushFree(idx);
    }

    pub fn setTimeout(
        self: *TimerManager,
        isolate: ?*c.Isolate,
        callback: ?*const c.Value,
        ms: u64,
    ) !usize {
        const idx = try self.allocSlot(isolate, callback);
        self.repeat_ms[idx] = MS_ONESHOT;
        self.timer.run(self.loop, &self.completion[idx], ms, TimerManager, self, timerCallback);
        return idx;
    }

    pub fn setInterval(
        self: *TimerManager,
        isolate: ?*c.Isolate,
        callback: ?*const c.Value,
        ms: u64,
    ) !usize {
        const idx = try self.allocSlot(isolate, callback);
        self.repeat_ms[idx] = ms;
        self.timer.run(self.loop, &self.completion[idx], ms, TimerManager, self, timerCallback);
        return idx;
    }

    pub fn clear(self: *TimerManager, id: usize) void {
        if (id >= MAX_TIMERS) return;
        const idx: u8 = @intCast(id);
        if (!self.active[idx]) return;
        self.active[idx] = false;
        c.v8__Global__Reset(&self.persistent[idx]);
        self.timer.cancel(self.loop, &self.completion[idx], &self.c_cancel[idx], TimerManager, self, cancelCb);
    }

    pub fn cancelAll(self: *TimerManager) void {
        for (0..MAX_TIMERS) |i| {
            if (self.active[i]) {
                self.active[i] = false;
                c.v8__Global__Reset(&self.persistent[i]);
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
    _ = r catch return .disarm; // Canceled or Unexpected: nothing to do
    const tm = ud orelse return .disarm;
    const idx: u8 = @intCast(tm.indexOfCompletion(cpl));
    if (!tm.active[idx]) return .disarm;

    if (tm.isolate[idx]) |isolate| {
        var handle_scope: c.HandleScope = undefined;
        c.v8__HandleScope__CONSTRUCT(&handle_scope, isolate);
        defer c.v8__HandleScope__DESTRUCT(&handle_scope);

        const context = c.v8__Isolate__GetCurrentContext(isolate);
        const fn_val = c.v8__Global__Get(&tm.persistent[idx], isolate);
        if (fn_val) |val| {
            const recv = c.v8__Undefined(isolate);
            _ = c.v8__Function__Call(@ptrCast(val), context, @ptrCast(recv), 0, null);
        }
            }

    if (tm.repeat_ms[idx] != MS_ONESHOT) {
        if (tm.active[idx]) {
            tm.timer.run(l, &tm.completion[idx], tm.repeat_ms[idx], TimerManager, tm, timerCallback);
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
    tm.freeSlot(idx); // slot already inactive; reclaims Global + free-list slot
    return .disarm;
}
