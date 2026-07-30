const std =@import("std");
const xev =@import("xev");

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
};
