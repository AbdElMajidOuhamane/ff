const std = @import("std");
const xev = @import("xev");
const c = @import("../c.zig").c;
const microtasks = @import("./microtasks.zig");
const http_api = @import("../net/http.zig");

var g_thread_pool: xev.ThreadPool = undefined;

pub const EventLoop = struct {
    loop: xev.Loop,

    pub fn init() !EventLoop {
        g_thread_pool = xev.ThreadPool.init(.{ .max_threads = 4 });
        return .{ .loop = try xev.Loop.init(.{ .thread_pool = &g_thread_pool }) };
    }

    pub fn initHeap(allocator: std.mem.Allocator) !*EventLoop {
        const ptr = try allocator.create(EventLoop);
        g_thread_pool = xev.ThreadPool.init(.{ .max_threads = 4 });
        ptr.* = .{ .loop = try xev.Loop.init(.{ .thread_pool = &g_thread_pool }) };
        return ptr;
    }

    pub fn deinit(self: *EventLoop) void {
        self.loop.deinit();
    }

    pub fn run(self: *EventLoop) !void {
        try self.loop.run(.until_done);
    }

    const GC_POLICE = (1 << 13);
    const GC_MIN_HEAP = 8 * 1024 * 1024;

    pub fn runWithMicrotasks(self: *EventLoop, isolate: ?*c.Isolate) void {
        var gc_ticks: usize = 0;
        while (true) {
            if (self.loop.active > 0 or !self.loop.submissions.empty() or !self.loop.completions.empty()) {
                self.loop.run(.once) catch {};
            }

            microtasks.pumpMicrotasks(isolate);

            if (isolate != null and (gc_ticks % GC_POLICE == 0)) {
                var stats: c.HeapStatistics = undefined;
                c.v8__Isolate__GetHeapStatistics(isolate, &stats);
                if (stats.used_heap_size > GC_MIN_HEAP) {
                    c.v8__Isolate__LowMemoryNotification(isolate);
                }
            }
            gc_ticks +%= 1;

            if (self.loop.stopped()) break;
            if (!http_api.server_running.load(.acquire)) break;

            if (self.loop.active == 0 and self.loop.submissions.empty() and self.loop.completions.empty()) {
                var ts: c.timespec = .{ .tv_sec = 0, .tv_nsec = 100_000 };
                _ = c.nanosleep(&ts, null);
            }
        }
    }
};
