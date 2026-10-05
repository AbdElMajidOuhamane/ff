const std = @import("std");
const xev = @import("xev");
const c = @import("../c.zig").c;
const microtasks = @import("./microtasks.zig");
const http_api = @import("../net/http.zig");
const async_fetch = @import("../net/async_fetch.zig");
const ws_client = @import("../net/ws_client.zig");
const timers_mod = @import("timers.zig");
const worker_mod = @import("../worker/worker.zig");
const pg_client = @import("../net/pg_client.zig");
const ffi_api = @import("../api/ffi.zig");
// C2: async FS completions drain here (Promise settlements on the JS thread).
const fs_mod = @import("../api/fs.zig");

var g_thread_pool: xev.ThreadPool = undefined;

// Set once by Runtime.init (engine owns both ends). Null-safe: no timers yet.
pub var timer_mgr: ?*timers_mod.TimerManager = null;

fn timersAlive() bool {
    const tm = timer_mgr orelse return false;
    return tm.hasReferencedTimers();
}

// Timer completions armed in the loop that JS has unref'd. Saturating
// subtract is required: sched_bits is set at setTimeout() time while
// loop.active only rises once the submission is processed, so sched can
// legitimately lead active by one.
inline fn unrefArmed() usize {
    const tm = timer_mgr orelse return 0;
    return tm.unrefScheduledCount();
}

pub const EventLoop = struct {
    loop: xev.Loop,

    pub fn init() !EventLoop {
        g_thread_pool = xev.ThreadPool.init(.{ .max_threads = 4 });
        return .{ .loop = try xev.Loop.init(.{ .thread_pool = &g_thread_pool }) };
    }
    pub fn initInto(self: *EventLoop) void {
        // Fail loud when the selected backend is unavailable (io_uring needs
        // Linux 5.1+ and must not be blocked by seccomp) instead of hitting
        // `catch unreachable` below with no message. Skipped unless io_uring
        // was selected: inner.available is always the io_uring probe on Linux
        // and must not gate the epoll path.
        if (xev.is_io_uring and !xev.available()) {
            std.debug.print("ff: I/O backend unavailable (io_uring requires Linux 5.1+ and must not be blocked by seccomp; rebuild with -Dio_uring=false for epoll)\n", .{});
            std.process.exit(1);
        }
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

    // Should the process stay alive / should we block on the loop?
    //
    // Identical to hasWork() except that armed-but-unref'd timers are
    // excluded. Those timers keep loop.active > 0, which is exactly why
    // the old break condition — `!work_left and ... and !timersAlive()` —
    // could never be satisfied: `!work_left` was already false whenever
    // any timer existed, so `timersAlive()` never got to decide anything.
    inline fn hasRelevantWork(loop: *xev.Loop) bool {
        if ((loop.active -| unrefArmed()) > 0) return true;
        if (timersAlive()) return true;
        if (http_api.server_running.load(.acquire)) return true;
        if (async_fetch.pending.load(.acquire) > 0) return true;
        if (ws_client.pending.load(.acquire) > 0) return true;
        if (pg_client.pending.load(.acquire) > 0) return true;
        if (ffi_api.pending.load(.acquire) > 0) return true;
        if (ffi_api.bridge_pending.load(.acquire) > 0) return true;
        // C2: in-flight async FS jobs keep the process alive (else
        // `await fs.readFileAsync()` would exit before settling).
        if (fs_mod.pending.load(.acquire) > 0) return true;
        if (worker_mod.liveCount() > 0) return true;
        // Queue entries only count as blocking when nothing is unref'd:
        // with an unref'd timer pending, an entry in submissions may be that
        // timer's own submission, and waiting on it is precisely the bug.
        // Every other producer (server / fetch / ws / pg / worker) is covered
        // by its own counter above, so skipping the queue here drops no work.
        if (unrefArmed() == 0) {
            if (!loop.submissions.empty()) return true;
            if (hasPendingCompletions(loop)) return true;
        }
        return false;
    }

    // Cold tuning knobs — kept out of the per-iteration working set.
    const GC_POLICE = (1 << 13);
    const GC_MIN_HEAP = 8 * 1024 * 1024;
    const IDLE_MIN_NS: u64 = 100_000;
    const IDLE_MAX_NS: u64 = 8_000_000;

    // A failing run() must never be swallowed: `catch {}` on the tick turns
    // submit errors and nested-run bugs into a silent stall that looks
    // exactly like a backend hang. Fail loud with the error name instead.
    // Plain catch-all (no named errors): Loop.run's error set differs per
    // backend, and naming a non-member error is a compile error.
    inline fn runOnce(self: *EventLoop) void {
        self.loop.run(.once) catch |err| {
            std.debug.print("ff: event loop error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
    }

    inline fn runNoWait(self: *EventLoop) void {
        self.loop.run(.no_wait) catch |err| {
            std.debug.print("ff: event loop error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
    }

    pub fn runWithMicrotasks(self: *EventLoop, ctx: *c.Context) void {
        var gc_ticks: usize = 0;
        var next_gc_check: usize = GC_POLICE;
        var idle_delay_ns: u64 = IDLE_MIN_NS;

        while (true) {
            var did_work = false;
            if ((self.loop.active -| unrefArmed()) > 0) {
                // Real work armed (referenced timers, sockets, fetch…):
                // block until at least one completion arrives.
                self.runOnce();
                did_work = true;
            } else if (!self.loop.submissions.empty() or hasPendingCompletions(&self.loop)) {
                // Only queued entries remain — possibly an unref'd timer's
                // own submission. Drain them without blocking, then decide;
                // blocking here is what made `t.unref()` wait out the timer.
                self.runNoWait();
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
            if (ffi_api.pending.load(.acquire) > 0 or ffi_api.bridge_pending.load(.acquire) > 0) {
                ffi_api.ensureArmed();
            }
            ffi_api.drainCompleted(ctx);
            // C2: async FS settlements (Promise resolve/reject on JS thread).
            if (fs_mod.pending.load(.acquire) > 0) {
                fs_mod.ensureArmed();
            }
            fs_mod.drainCompleted(ctx);
            worker_mod.drainCompleted(ctx);
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
            if (!hasRelevantWork(&self.loop)) break;
            if (!did_work) {
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
