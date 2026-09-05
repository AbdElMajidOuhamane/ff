const std = @import("std");
const xev = @import("xev");
const c = @import("../c.zig").c;
const microtasks = @import("./microtasks.zig");
const http_api = @import("../net/http.zig");
const async_fetch = @import("../net/async_fetch.zig");
const ws_client = @import("../net/ws_client.zig");
const timers_mod = @import("timers.zig");

var g_thread_pool: xev.ThreadPool = undefined;

// Set once by Runtime.init (engine owns both ends). Null-safe: no timers yet.
pub var timer_mgr: ?*timers_mod.TimerManager = null;

fn timersAlive() bool {
    const tm = timer_mgr orelse return false;
    return tm.hasReferencedTimers();
}

pub const EventLoop = struct {
    loop: xev.Loop,

    pub fn init() !EventLoop {
        g_thread_pool = xev.ThreadPool.init(.{ .max_threads = 4 });
        return .{ .loop = try xev.Loop.init(.{ .thread_pool = &g_thread_pool }) };
    }
    pub fn initInto(self: *EventLoop) void {
        g_thread_pool = xev.ThreadPool.init(.{ .max_threads = 4 });
        self.* = .{ .loop = xev.Loop.init(.{ .thread_pool = &g_thread_pool }) catch unreachable };
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

    // ── hot inline predicates: single-bit / empty checks, predictable ──
    inline fn hasPendingCompletions(loop: *const xev.Loop) bool {
        if (@hasField(@TypeOf(loop.*), "completions")) {
            return !loop.completions.empty();
        }
        return false;
    }
    inline fn hasWork(loop: *const xev.Loop) bool {
        return loop.active > 0 or
            !loop.submissions.empty() or
            hasPendingCompletions(loop);
    }

    // Cold tuning knobs — kept out of the per-iteration working set.
    const GC_POLICE = (1 << 13);
    const GC_MIN_HEAP = 8 * 1024 * 1024;
    const IDLE_MIN_NS: u64 = 100_000;
    const IDLE_MAX_NS: u64 = 8_000_000;

    pub fn runWithMicrotasks(self: *EventLoop, ctx: *c.Context) void {
        var gc_ticks: usize = 0;
        var next_gc_check: usize = GC_POLICE;
        var idle_delay_ns: u64 = IDLE_MIN_NS;

        while (true) {
            var did_work = false;
            if (hasWork(&self.loop)) {
                self.loop.run(.once) catch {};
                did_work = true;
            }
            // Batched completion drains: contiguous, reusable slot storage,
            // zero allocations per drain. Order is fixed for predictability.
            if (async_fetch.pending.load(.acquire) > 0) {
                async_fetch.arm(&self.loop);
            }
            async_fetch.drainCompleted(ctx);
            if (ws_client.pending.load(.acquire) > 0) {
                ws_client.arm(&self.loop);
            }
            ws_client.drainCompleted(ctx);
            microtasks.pumpMicrotasks(ctx);
            if (gc_ticks >= next_gc_check) {
                next_gc_check += GC_POLICE;
                const rt = c.getRuntime(ctx);
                var stats: c.MemoryUsage = undefined;
                c.computeMemoryUsage(rt, &stats);
                if (stats.memory_used_size > GC_MIN_HEAP) {
                    c.runGC(rt);
                }
            }
            gc_ticks +%= 1;
            if (self.loop.stopped()) break;
            const work_left = hasWork(&self.loop);
            if (!http_api.server_running.load(.acquire) and
                !work_left and
                async_fetch.pending.load(.acquire) == 0 and
                ws_client.pending.load(.acquire) == 0 and
                !timersAlive()) break;
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
