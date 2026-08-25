const std = @import("std");
const xev = @import("xev");
const c = @import("../c.zig").c;
const microtasks = @import("./microtasks.zig");
const http_api = @import("../net/http.zig");
const async_fetch = @import("../net/async_fetch.zig");
const ws_client = @import("../net/ws_client.zig");
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
    const IDLE_MIN_NS: u64 = 100_000; // 100µs
    const IDLE_MAX_NS: u64 = 8_000_000; // 8ms
    pub fn runWithMicrotasks(self: *EventLoop, isolate: ?*c.Isolate) void {
        var gc_ticks: usize = 0;
        var next_gc_check: usize = GC_POLICE;
        var idle_delay_ns: u64 = IDLE_MIN_NS;
        while (true) {
            var did_work = false;
            if (hasWork(&self.loop)) {
                self.loop.run(.once) catch {};
                did_work = true;
            }
            // Async-fetch: keep the xev Async armed while jobs are in flight
            // (worker notify() wakes us promptly), drain finished jobs, then
            // pump microtasks so the awaited fetch continuation runs.
            if (async_fetch.pending.load(.acquire) > 0) {
                async_fetch.arm(&self.loop);
            }
            async_fetch.drainCompleted(isolate);
            // WS clients: same pump idiom — armed Async while live workers
            // exist, SIMD done-sweep + claim + dispatch each tick. The
            // worker-side strict handshake (JOB_DONE -> JOB_BUSY) relies on
            // this being called regularly.
            if (ws_client.pending.load(.acquire) > 0) {
                ws_client.arm(&self.loop);
            }
            ws_client.drainCompleted(isolate);
            microtasks.pumpMicrotasks(isolate);
            if (isolate != null and gc_ticks >= next_gc_check) {
                next_gc_check += GC_POLICE;
                var stats: c.HeapStatistics = undefined;
                c.v8__Isolate__GetHeapStatistics(isolate, &stats);
                if (stats.used_heap_size > GC_MIN_HEAP) {
                    c.v8__Isolate__LowMemoryNotification(isolate);
                }
            }
            gc_ticks +%= 1;
            if (self.loop.stopped()) break;
            const work_left = hasWork(&self.loop);
            if (!http_api.server_running.load(.acquire) and
                !work_left and
                async_fetch.pending.load(.acquire) == 0 and
                ws_client.pending.load(.acquire) == 0) break;
            if (!work_left and !did_work) {
                const ts: std.c.timespec = .{
                    .sec = @intCast(idle_delay_ns / std.time.ns_per_s),
                    .nsec = @intCast(idle_delay_ns % std.time.ns_per_s),
                };
                _ = std.c.nanosleep(&ts, null);
                idle_delay_ns = @min(idle_delay_ns * 2, IDLE_MAX_NS);
            } else {
                idle_delay_ns = IDLE_MIN_NS;
            }
        }
    }
};
