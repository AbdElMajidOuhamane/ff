const std = @import("std");
const xev = @import("xev");
const c = @import("../c.zig").c;
const microtasks = @import("./microtasks.zig");

pub const EventLoop = struct {
    loop: xev.Loop,

    pub fn init() !EventLoop {
        return .{
            .loop = try xev.Loop.init(.{}),
        };
    }

    pub fn initHeap(allocator: std.mem.Allocator) !*EventLoop {
        const ptr = try allocator.create(EventLoop);
        ptr.* = .{
            .loop = try xev.Loop.init(.{}),
        };
        return ptr;
    }

    pub fn deinit(self: *EventLoop) void {
        self.loop.deinit();
    }

    pub fn run(self: *EventLoop) !void {
        try self.loop.run(.until_done);
    }

    pub fn runWithMicrotasks(self: *EventLoop, isolate: ?*c.Isolate) void {
        while (true) {
            self.loop.run(.once) catch {};
            microtasks.pumpMicrotasks(isolate);
            if (self.loop.stopped()) break;
            if (self.loop.active == 0 and self.loop.submissions.empty() and self.loop.completions.empty()) break;
        }
    }
};
