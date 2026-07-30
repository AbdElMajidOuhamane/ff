const std = @import("std");
const xev = @import("xev");
const c = @import("../c.zig").c;
const microtasks =@import("./microtasks.zig");

const MAX_TIMERS = 128;

const TimerSlot = struct {
    completion: xev.Completion,
    active: bool,
    persistent: c.Global,
    isolate: ?*c.Isolate,
   
};


fn timerCallback(
    ud: ?*TimerSlot,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch return .disarm;

    const slot = ud orelse return .disarm;
    if (!slot.active) return .disarm;

    if (slot.isolate) |isolate| {
        var handle_scope: c.HandleScope = undefined;
        c.v8__HandleScope__CONSTRUCT(&handle_scope, isolate);
        defer c.v8__HandleScope__DESTRUCT(&handle_scope);

        const context = c.v8__Isolate__GetCurrentContext(isolate);
        const fn_val = c.v8__Global__Get(&slot.persistent, isolate);
        if (fn_val) |val| {
            const recv = c.v8__Undefined(isolate);
            _ = c.v8__Function__Call(
                @ptrCast(val),
                context,
                @ptrCast(recv),
                0,
                null,
            );
        }
        microtasks.pumpMicrotasks(isolate);
    }

    slot.active = false;
    c.v8__Global__Reset(&slot.persistent);

    return .disarm;
}
pub const TimerManager = struct {
    loop: *xev.Loop,
    timer: xev.Timer,
    slots: [MAX_TIMERS]TimerSlot,

    pub fn init(loop: *xev.Loop) TimerManager {
        var slots: [MAX_TIMERS]TimerSlot = undefined;
        for (&slots) |*s| {
            s.* = .{
                .completion = .{},
                .active = false,
                .persistent = undefined,
                .isolate = null,
                           };
        }
        return .{
            .loop = loop,
            .timer = xev.Timer.init() catch unreachable,
            .slots = slots,
        };
    }

    pub fn setTimeout(
        self: *TimerManager,
        isolate: ?*c.Isolate,
       
        callback: ?*const c.Value,
        ms: u64,
    ) !usize {
        var idx: ?usize = null;
        for (&self.slots, 0..) |*s, i| {
            if (!s.active) {
                idx = i;
                break;
            }
        }
        const i = idx orelse return error.NoSlotsAvailable;
        const slot = &self.slots[i];

        slot.active = true;
        slot.isolate = isolate;
        slot.completion = .{};
        c.v8__Global__New(isolate, @ptrCast(callback), &slot.persistent);

        self.timer.run(self.loop, &slot.completion, ms, TimerSlot, slot, timerCallback);
        return i;
    }

    pub fn cancelAll(self: *TimerManager) void {
        for (&self.slots) |*s| {
            if (s.active) {
                s.active = false;
                c.v8__Global__Reset(&s.persistent);
            }
        }
    }
};
