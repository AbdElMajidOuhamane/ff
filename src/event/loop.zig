const std =@import("std");
const xev =@import("xev");

pub const EventLoop = struct {
    loop: xev.Loop,

    pub fn init() !EventLoop {
        return .{
            .loop = try xev.Loop.init(.{}),
        };
    }

    pub fn deinit(self: *EventLoop) void {
        self.loop.deinit();
    }

    pub fn run(self: *EventLoop) !void {
        try self.loop.run(.until_done);
    }
};
