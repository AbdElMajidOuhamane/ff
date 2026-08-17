const std = @import("std");
const xev = @import("xev");
const c = @import("../c.zig").c;
const microtasks = @import("./microtasks.zig");
const http_api = @import("../net/http.zig");
const async_fetch = @import("../net/async_fetch.zig");
const immediates = @import("./immediates.zig");

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

    fn hasPendingCompletions(loop: *const xev.Loop) bool {
        if (@hasField(@TypeOf(loop.*), "completions")) {
            return !loop.completions.empty();
        }
        return false;
    }

    fn hasWork(loop: *const xev.Loop) bool {
        return loop.active > 0 or
            !loop.submissions.empty() or
            hasPendingCompletions(loop);
    }

    const GC_POLICE = (1 << 13);
    const GC_MIN_HEAP = 8 * 1024 * 1024;

        pub fn runWithMicrotasks(self: *EventLoop, isolate: ?*c.Isolate) void {
        var gc_ticks: usize = 0;
        while (true) {
            // setImmediate: never block on .once while the in-process queue
            // is non-empty - .nowait processes any ready fds without parking,
            // then flush() below drains immediates (zero syscalls per item).
             if (immediates.pending()) {
                self.loop.run(.no_wait) catch {};
            } else if (hasWork(&self.loop)) {
                self.loop.run(.once) catch {};
            }

            // Async-fetch: keep the xev Async armed while jobs are in flight
            // (worker notify() wakes us promptly), drain finished jobs, then
            // pump microtasks so the awaited fetch continuation runs.
            if (async_fetch.pending.load(.acquire) > 0) {
                async_fetch.arm(&self.loop);
            }
            async_fetch.drainCompleted(isolate);

            microtasks.pumpMicrotasks(isolate);
            immediates.flush(isolate);

            if (isolate != null and (gc_ticks % GC_POLICE == 0)) {
                var stats: c.HeapStatistics = undefined;
                c.v8__Isolate__GetHeapStatistics(isolate, &stats);
                if (stats.used_heap_size > GC_MIN_HEAP) {
                    c.v8__Isolate__LowMemoryNotification(isolate);
                }
            }
            gc_ticks +%= 1;

            if (self.loop.stopped()) break;
            if (!http_api.server_running.load(.acquire) and
                !hasWork(&self.loop) and
                !immediates.pending() and
                async_fetch.pending.load(.acquire) == 0) break;

            if (!hasWork(&self.loop) and !immediates.pending()) {
                var ts: std.c.timespec = .{ .sec = 0, .nsec = 100_000 };
                _ = std.c.nanosleep(&ts, null);
            }
        }
    }
};
