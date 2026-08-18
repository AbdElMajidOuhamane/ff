const std = @import("std");
const xev = @import("xev");
const c = @import("../c.zig").c;
const microtasks = @import("./microtasks.zig");
const http_api = @import("../net/http.zig");
const async_fetch = @import("../net/async_fetch.zig");
const immediates = @import("./immediates.zig");

var g_thread_pool: xev.ThreadPool = undefined;

const GC_POLICE = 1 << 13;
const GC_POLICE_MASK = GC_POLICE - 1; // power-of-two: tick test is a mask, no modulo
const GC_MIN_HEAP = 8 * 1024 * 1024;

// DOD: every cycle's decisions derive from one packed word of work sources.
// Lane layout (LSB first): io(0) immediates(1) fetch(2) http(3).
const Work = packed struct(u8) {
    io: bool = false,
    immediates: bool = false,
    fetch: bool = false,
    http: bool = false,
    _pad: u4 = 0,

    // any of io/immediates/fetch keeps the runtime awake; http alone doesn't.
    const IDLE_MASK: u8 = 0b0000_0111;

    inline fn bits(w: Work) u8 {
        return @as(u8, @bitCast(w));
    }
};

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

    fn hasIoWork(loop: *const xev.Loop) bool {
        return loop.active > 0 or
            !loop.submissions.empty() or
            hasPendingCompletions(loop);
    }

    // SIMD: the four source predicates land in a 4-lane bool vector; @select
    // widens them to u8 lanes (SIMD compare-select), then a weighted dot-product
    // packs them into one bitmask word. One branch on status per cycle.
    inline fn classifyWork(self: *EventLoop) Work {
        const lanes: @Vector(4, bool) = .{
            hasIoWork(&self.loop),
            immediates.pending(),
            async_fetch.pending.load(.acquire) > 0,
            http_api.server_running.load(.acquire),
        };
        const lanes_u8: @Vector(4, u8) = @select(u8, lanes, @as(@Vector(4, u8), @splat(1)), @as(@Vector(4, u8), @splat(0)));
        const weights: @Vector(4, u8) = .{ 1, 2, 4, 8 };
        const packed_bits: u8 = @reduce(.Add, lanes_u8 * weights);
        return @bitCast(packed_bits);
    }

    pub fn runWithMicrotasks(self: *EventLoop, isolate: ?*c.Isolate) void {
        var gc_ticks: usize = 0;
        while (true) {
            const work = classifyWork(self);

            // setImmediate: never block on .once while the in-process queue
            // is non-empty - .nowait processes any ready fds without parking,
            // then flush() below drains immediates (zero syscalls per item).
            if (work.immediates) {
                self.loop.run(.no_wait) catch {};
            } else if (work.io) {
                self.loop.run(.once) catch {};
            }

            // Async-fetch: keep the xev Async armed while jobs are in flight
            // (worker notify() wakes us promptly), drain finished jobs, then
            // pump microtasks so the awaited fetch continuation runs.
            if (work.fetch) {
                async_fetch.arm(&self.loop);
            }
            async_fetch.drainCompleted(isolate);

            microtasks.pumpMicrotasks(isolate);
            immediates.flush(isolate);

            // GC police: mask on a wrapping tick keeps the sampling branch-free.
            if (isolate != null and (gc_ticks & GC_POLICE_MASK) == 0) {
                var stats: c.HeapStatistics = undefined;
                c.v8__Isolate__GetHeapStatistics(isolate, &stats);
                if (stats.used_heap_size > GC_MIN_HEAP) {
                    c.v8__Isolate__LowMemoryNotification(isolate);
                }
            }
            gc_ticks +%= 1;

            if (self.loop.stopped()) break;

            const awake = Work.bits(work) & Work.IDLE_MASK;

            // Exit when the server is gone and no source holds a lane.
            if (!work.http and awake == 0) break;

            // Idle-but-alive (server up, nothing to do): nap rather than spin.
            if (awake == 0) {
                var ts: std.c.timespec = .{ .sec = 0, .nsec = 100_000 };
                _ = std.c.nanosleep(&ts, null);
            }
        }
    }
};
