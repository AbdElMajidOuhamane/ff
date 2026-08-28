const std = @import("std");
const xev = @import("xev");
const c = @import("../c.zig").c;
const tls = @import("./tls.zig");
const response_mod = @import("../types/response.zig");
const builtin = @import("builtin");

// Debug builds route job allocations through a counter: per-job reports
// prove the allocation budget and catch leaks mechanically (balanced()
// asserted at job end). ReleaseFast binds straight to smp_allocator.
var job_counter: counting.CountingAllocator = .{ .base = std.heap.smp_allocator };
const gpa = if (builtin.mode == .Debug)
    job_counter.allocator()
else
    std.heap.smp_allocator;

const counting = @import("../util/counting_allocator.zig");
const http = std.http;

// ============================================================
// Async fetch — DOD/SoA slot pool over a PERSISTENT WORKER POOL.
//
// No per-fetch heap structs. Every live fetch is an integer slot id into
// dense per-field arrays; slots come from an O(1) free-list. The pool
// doubles as the concurrency cap: at most MAX_FETCH jobs are in flight,
// so submit fails fast with error.NoConnectionAvailable.
//
// PHASE 4: threads are spawned ONCE at init() and consume slot ids from a
// preallocated MPSC ring. Workers PARK on a blocking read of a shared
// wakeup pipe (Zig 0.16 removed Thread.Mutex/Condition; the Io-bound ones
// don't fit raw pooled threads). submit() is enqueue-only — the
// per-request std.Thread.spawn (syscall + stack map + scheduler churn) is
// gone. `pending` counts IN-FLIGHT JOBS rather than live threads; the
// event loop's arm/drain gating semantics are unchanged.
//
// Worker completion is detected with a SIMD sweep over the state vector
// (doneMask), then each candidate is confirmed with a per-slot acquire
// CAS — vector front-end for cheap batching, atomics for correctness.
//
// Wakeup: a single xev.Async (mach port). Worker notify() wakes the loop;
// the callback re-arms while pending > 0 and disarms at 0. drainCompleted()
// also runs every tick as a safety net against a coalesced/missed notify.
//
// v8 is touched ONLY on the main thread (drainCompleted/completeJob).
// ============================================================

pub const MAX_FETCH = 16; // matches tls.MAX_CONN; == u64 mask lanes

const JOB_FREE: u8 = 0;
const JOB_BUSY: u8 = 1;
const JOB_DONE: u8 = 2;
const JOB_CLAIMED: u8 = 3;

// ---- Hot state (touched every tick: state machine + V8 resolvers) ----
var states:    [MAX_FETCH]std.atomic.Value(u8) = [_]std.atomic.Value(u8){.{ .raw = JOB_FREE }} ** MAX_FETCH;
var resolvers: [MAX_FETCH]c.Global = undefined;
var results:   [MAX_FETCH]?*response_mod.ResponseData = [_]?*response_mod.ResponseData{null} ** MAX_FETCH;
var errs:      [MAX_FETCH]?[]const u8 = [_]?[]const u8{null} ** MAX_FETCH;
// ---- Cold data (touched only on submit/complete, not every tick) ----
var url_bufs:  [MAX_FETCH][:0]const u8 = undefined;
var uris:      [MAX_FETCH]std.Uri = undefined;
var methods:   [MAX_FETCH]http.Method = undefined;
var headers:   [MAX_FETCH]std.ArrayList(http.Header) = undefined;
var bodies:    [MAX_FETCH]?[:0]const u8 = [_]?[:0]const u8{null} ** MAX_FETCH;

// ---- O(1) slot allocator (spinlock-guarded) ----
var free_list: [MAX_FETCH]u16 = undefined;
var free_count: usize = MAX_FETCH;
var pool_lock: std.atomic.Mutex = .unlocked;

// ---- persistent worker pool: MPSC job ring (spinlock + wakeup pipe) ----
const RING_CAP = MAX_FETCH; // >= slot count: enqueue cannot overflow
var job_ring: [RING_CAP]u16 = undefined;
var ring_head: usize = 0; // consumer index (workers)
var ring_tail: usize = 0; // producer index (main thread)
var ring_lock: std.atomic.Mutex = .unlocked;
var shutdown_requested = false;
var pool_started = false;
var worker_threads: [MAX_FETCH]?std.Thread = [_]?std.Thread{null} ** MAX_FETCH;
// Wakeup pipe: workers block on read(job_pipe[0]); each enqueued job /
// shutdown broadcast writes one byte.
var job_pipe: [2]std.posix.fd_t = .{ -1, -1 };

// ---- cross-thread wakeup ----
const AsyncT = xev.Async;
var async_h: AsyncT = undefined;
var async_comp: xev.Completion = .{};
var async_armed = false;

// main-thread/pump-visible wip counter; 0 => all jobs done
pub var pending: std.atomic.Value(u64) = .{ .raw = 0 };

fn poolLock() void {
    while (!pool_lock.tryLock()) std.atomic.spinLoopHint();
}

fn poolUnlock() void {
    pool_lock.unlock();
}

fn ringLock() void {
    while (!ring_lock.tryLock()) std.atomic.spinLoopHint();
}

fn ringUnlock() void {
    ring_lock.unlock();
}

fn poolInit() void {
    for (0..MAX_FETCH) |i| free_list[i] = @intCast(MAX_FETCH - 1 - i);
    free_count = MAX_FETCH;
}

fn acquireSlot() ?usize {
    if (free_count == 0) return null;
    free_count -= 1;
    const s: usize = free_list[free_count];
    states[s].store(JOB_BUSY, .release);
    return s;
}

fn releaseSlot(s: usize) void {
    states[s].store(JOB_FREE, .release);
    url_bufs[s] = undefined;
    uris[s] = undefined;
    methods[s] = undefined;
    headers[s] = undefined;
    bodies[s] = null;
    resolvers[s] = undefined;
    results[s] = null;
    errs[s] = null;
    free_list[free_count] = @intCast(s);
    free_count += 1;
}

// ---- lifecycle ----

fn makeJobPipe() !void {
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeCreateFailed;
    job_pipe = fds;
}

/// Wakes every parked worker: one byte each so all of them re-check state.
fn wakeAllWorkers() void {
    if (job_pipe[1] < 0) return;
    var b: [MAX_FETCH]u8 = [_]u8{1} ** MAX_FETCH;
    _ = std.c.write(job_pipe[1], &b, b.len);
}

pub fn init() void {
    poolInit();
    async_h = AsyncT.init() catch unreachable;
    async_armed = false;
    ring_head = 0;
    ring_tail = 0;
    shutdown_requested = false;
    makeJobPipe() catch {
        async_h.deinit();
        return;
    };
    // Best-effort spawn: a partial pool is fine — excess jobs simply wait
    // in the ring until a worker frees up.
    for (&worker_threads) |*t| {
            t.* = std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, workerLoop, .{}) catch {
            t.* = null;
            break;
        };
    }
    pool_started = true;
}

pub fn deinit() void {
    if (pool_started) {
        ringLock();
        shutdown_requested = true;
        ringUnlock();
        wakeAllWorkers(); // one byte per parked worker
        for (&worker_threads) |*t| {
            if (t.*) |*tt| {
                tt.join();
                t.* = null;
            }
        }
        pool_started = false;
    }
    if (job_pipe[0] >= 0) _ = c.close(job_pipe[0]);
    if (job_pipe[1] >= 0) _ = c.close(job_pipe[1]);
    job_pipe = .{ -1, -1 };
    async_h.deinit();
    // Loop only exits once pending==0 and everything is drained, so slots
    // should all be free. Safety: reclaim anything that leaked regardless.
    for (0..MAX_FETCH) |s| {
        if (states[s].load(.acquire) != JOB_FREE) {
            c.v8__Global__Reset(&resolvers[s]);
            freeOwned(s);
        }
    }
}

fn freeOwned(s: usize) void {
    gpa.free(url_bufs[s]);
    for (headers[s].items) |h| {
        gpa.free(h.name);
        gpa.free(h.value);
    }
    headers[s].deinit(gpa);
    if (bodies[s]) |b| gpa.free(b);
}

// ---- persistent worker loop ----

fn workerLoop() void {
    while (true) {
        // Park until a job byte arrives (blocking read — zero idle CPU).
        var wake: [1]u8 = undefined;
        const n = std.c.read(job_pipe[0], &wake, 1);
        if (n <= 0) return; // pipe closed => hard shutdown

        var got: ?u16 = null;
        ringLock();
        if (ring_head != ring_tail) {
            got = job_ring[ring_head % RING_CAP];
            ring_head +%= 1;
        }
        const stop = shutdown_requested and ring_head == ring_tail;
        ringUnlock();

        // Always run a claimed job first — even during shutdown — then exit
        // if the ring drained under a shutdown request.
        if (got) |slot_id| runJob(slot_id);
        if (stop) return;
    }
}

// ---- submission (main thread, from fetchCallback) ----
// Takes ownership of url_buf/headers/body on success; frees them on failure.
// ENQUEUE-ONLY: hands the slot id to the persistent pool — no thread spawn.

pub fn submit(
    isolate: ?*c.Isolate,
    resolver: *const c.PromiseResolver,
    url_buf: [:0]const u8,
    uri: std.Uri,
    method: http.Method,
    header_list: std.ArrayList(http.Header),
    body: ?[:0]const u8,
) !void {
    var hl = header_list; // deinit()/items take *Self — the param is const
    poolLock();
    defer poolUnlock();
        const s = acquireSlot() orelse {
        // we own the pieces — free them before reporting capacity exhaustion
        if (builtin.mode == .Debug)
            std.debug.print("[submit] rejected: pool full\n", .{}); // DIAGNOSTIC (W4)
        gpa.free(url_buf);        for (hl.items) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        hl.deinit(gpa);
        if (body) |b| gpa.free(b);
        return error.NoConnectionAvailable;
    };

    url_bufs[s] = url_buf;
    uris[s] = uri;
    methods[s] = method;
    headers[s] = hl;
    bodies[s] = body;
    results[s] = null;
    errs[s] = null;
    c.v8__Global__New(isolate, @ptrCast(resolver), &resolvers[s]);

    // Count the job BEFORE signaling so the worker's completion decrement
    // can never race ahead of our increment.
    _ = pending.fetchAdd(1, .acq_rel);

    // Enqueue for the persistent pool, then poke one parked worker.
    ringLock();
    if (shutdown_requested) {
        ringUnlock();
        _ = pending.fetchSub(1, .acq_rel);
        c.v8__Global__Reset(&resolvers[s]);
        freeOwned(s);
        releaseSlot(s);
        return error.NoConnectionAvailable;
    }
    job_ring[ring_tail % RING_CAP] = @intCast(s);
    ring_tail +%= 1;
    ringUnlock();
    _ = std.c.write(job_pipe[1], &[_]u8{1}, 1);
}

// ---- job execution (worker threads, never touches v8) ----

fn runJob(slot_id: u16) void {
    const s: usize = slot_id;
    if (builtin.mode == .Debug) job_counter.reset(); // DIAGNOSTIC (W3)

    var req = tls.client().request(methods[s], uris[s], .{
        .extra_headers = headers[s].items,
    }) catch {
        failSlot(s, "Network error");
        return;
    };
    defer req.deinit();

    // Register the connection in the transport pool (records fd + TLS flag,
    // applies TCP_NODELAY). TLS handshake runs lazily on first read/write,
    // so NODELAY covers ClientHello -> Finished -> request.
    var slot: ?usize = null;
    if (req.connection) |cn| slot = tls.attach(cn);
    defer if (slot) |sl| tls.detach(sl);

    if (bodies[s]) |payload| {
        req.transfer_encoding = .{ .content_length = payload.len };
        var body_writer = req.sendBodyUnflushed(&.{}) catch {
            failSlot(s, "Failed to send request body");
            return;
        };
        body_writer.writer.writeAll(payload) catch {
            failSlot(s, "Failed to write request body");
            return;
        };
        body_writer.end() catch {};
        req.connection.?.flush() catch {};
    } else {
        req.sendBodiless() catch {
            failSlot(s, "Failed to send request");
            return;
        };
    }

    var redirect_buf: [8000]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch {
        failSlot(s, "Failed to receive response");
        return;
    };

    var owned_body: ?[]u8 = null;
    defer if (owned_body) |b| gpa.free(b);

    const status_code = @intFromEnum(response.head.status);
    const status_class = status_code / 100;
    const has_body = switch (status_class) {
        1 => false,
        2 => response.head.status != .no_content and response.head.status != .not_modified,
        3 => false,
        else => true,
    };

    if (!has_body) {
        req.connection.?.closing = true;
    }

    // ---- Build ResponseData + copy headers FIRST (pristine head).
    // Creating response.reader() below mutates head/buffering state, so
    // iterateHeaders must run before it (else it spins on stale offsets). ----
    const resp_data = gpa.create(response_mod.ResponseData) catch {
        failSlot(s, "Out of memory");
        return;
    };
    resp_data.* = response_mod.ResponseData.init();

    resp_data.status = status_code;
    resp_data.setStatusText(response.head.status.phrase() orelse "OK");

    var header_it = response.head.iterateHeaders();
    while (header_it.next()) |h| {
        resp_data.headers.appendEntry(h.name, h.value);
    }

    // ---- Stream the body AFTER headers are captured ----
    if (has_body) {
        var transfer_buf: [8192]u8 = undefined;
        const content_encoding = response.head.content_encoding;
        const compressed = content_encoding != .identity;
        var decompress_buf: ?[]u8 = null;
        defer if (decompress_buf) |d| gpa.free(d);
        var decompress: std.http.Decompress = undefined;

        const reader = if (!compressed)
            response.reader(&transfer_buf)
        else dec: {
            const window_len: usize = switch (content_encoding) {
                .gzip, .deflate => std.compress.flate.max_window_len,
                .zstd => std.compress.zstd.default_window_len,
                else => 0,
            };
            if (window_len == 0) {
                std.debug.print("[fetch] unsupported content-encoding: {s}\n", .{@tagName(content_encoding)});
                break :dec response.reader(&transfer_buf);
            }
            const d = gpa.alloc(u8, window_len) catch break :dec response.reader(&transfer_buf);
            decompress_buf = d;
            break :dec response.readerDecompressing(&transfer_buf, &decompress, d);
        };

        // Tracks whether a Content-Length'd body under-delivered — such a
        // connection's framing state is unreliable and must never be reused.
        var body_incomplete = false;
        const wire_cl = if (content_encoding == .identity) response.head.content_length else null;

        if (wire_cl) |cl| {
            if (cl > 0) {
                const len: usize = @intCast(cl);
                const buf = gpa.alloc(u8, len) catch |err| alloc_b: {
                    std.debug.print("[fetch] body alloc error: {s}\n", .{@errorName(err)});
                    break :alloc_b null;
                };
                if (buf) |b| {
                    const n = reader.readSliceShort(b) catch |err| read_b: {
                        std.debug.print("[fetch] body read error: {s}\n", .{@errorName(err)});
                        break :read_b 0;
                    };
                    if (n == 0) {
                        gpa.free(b);
                        body_incomplete = true;
                    } else if (n == len) {
                        owned_body = b;
                    } else {
                        owned_body = gpa.realloc(b, n) catch null;
                        if (owned_body == null) gpa.free(b);
                        body_incomplete = true; // promised bytes never arrived
                    }
                }
            }
        } else {
            var acc: std.ArrayList(u8) = .empty;
            defer acc.deinit(gpa);
            var chunk: [16 * 1024]u8 = undefined;
            var total: usize = 0;
            while (true) {
                const n = reader.readSliceShort(chunk[0..]) catch |err| acc_b: {
                    std.debug.print("[fetch] body read error: {s} after {d} bytes\n", .{ @errorName(err), total });
                    break :acc_b 0;
                };
                if (n == 0) break;
                acc.appendSlice(gpa, chunk[0..n]) catch |err| {
                    std.debug.print("[fetch] body accumulate error: {s}\n", .{@errorName(err)});
                    break;
                };
                total += n;
            }
            if (total > 0) {
                owned_body = acc.toOwnedSlice(gpa) catch |err| fin_b: {
                    std.debug.print("[fetch] body finalize error: {s}\n", .{@errorName(err)});
                    break :fin_b null;
                };
            }
        }

        if (compressed) {
            // readerDecompressing stops at the gzip EOF; for te=chunked the
            // final chunk terminator is left unread. Draining the framing
            // reader to its deterministic end-of-message (no extra RTT) keeps
            // the connection reusable.
            var plain_reader = response.reader(&transfer_buf);
            var drain: [2048]u8 = undefined;
            while (true) {
                const n = plain_reader.readSliceShort(drain[0..]) catch break;
                if (n == 0) break;
            }
        }

        if (body_incomplete) {
            // Content-Length unmet: this connection's framing state is
            // unreliable — never hand it back to the keep-alive pool.
            req.connection.?.closing = true;
        }
    }

    if (owned_body) |b| {
        resp_data.setBodyOwned(b);
        owned_body = null; // transferred; the Response owns it now
    } else if (response.head.content_length != null and has_body) {
        resp_data.setBody("");
    }

    if (builtin.mode == .Debug) { // DIAGNOSTIC (W3): budget proof + leak assert
        std.debug.print(
            "[allocs] job {d}: allocs={d} frees={d} +{d}B -{d}B balanced={}\n",
            .{
                slot_id,
                job_counter.alloc_count,
                job_counter.free_count,
                job_counter.bytes_allocated,
                job_counter.bytes_freed,
                job_counter.balanced(),
            },
        );
        std.debug.assert(job_counter.balanced()); // leak => loud failure
    }

    okSlot(s, resp_data);
}

fn failSlot(s: usize, comptime msg: []const u8) void {
    if (builtin.mode == .Debug)
        std.debug.print("[fail] slot {d}: {s}\n", .{ s, msg }); // DIAGNOSTIC (W4)
    errs[s] = msg;
    finishSlot(s);
}

fn okSlot(s: usize, data: *response_mod.ResponseData) void {
    results[s] = data;
    finishSlot(s);
}

fn finishSlot(s: usize) void {
    states[s].store(JOB_DONE, .release);
    _ = pending.fetchSub(1, .release);
    async_h.notify() catch {};
}

// ---- event-loop integration (main thread only) ----

/// Arm the cross-thread wakeup if jobs are in flight. Called each tick.
pub fn arm(loop: *xev.Loop) void {
    if (async_armed) return;
    async_armed = true;
    async_h.wait(loop, &async_comp, void, null, asyncCb);
}

fn asyncCb(
    ud: ?*void,
    l: *xev.Loop,
    comp: *xev.Completion,
    r: AsyncT.WaitError!void,
) xev.CallbackAction {
    _ = ud;
    _ = comp;
    _ = r catch return .disarm;
    if (pending.load(.acquire) > 0) {
        async_armed = true;
        async_h.wait(l, &async_comp, void, null, asyncCb);
        return .disarm;
    }
    async_armed = false;
    return .disarm;
}

// ---- SIMD done-sweep ----
//
// Single vectorized pass builds a u64 bitmask of candidate DONE slots; each
// set bit is then confirmed with a per-slot acquire CAS. The vector load is
// only a cheap *detector* (may lag a tick), never the data hand-off — the
// per-slot CAS provides the memory ordering for the result arrays. Same
// "vector wide, then scalar per-element" hybrid as findCrLf in tls.zig.

fn doneMask() u64 {
    var mask: u64 = 0;
    inline for (0..MAX_FETCH) |i| {
        if (states[i].raw == JOB_DONE) mask |= @as(u64, 1) << @intCast(i);
    }
    return mask;
}

fn claimSlot(s: usize) bool {
    return states[s].cmpxchgStrong(JOB_DONE, JOB_CLAIMED, .acq_rel, .acquire) == null;
}

/// Resolve/reject every finished job. Call each loop tick (after loop.run,
/// before pumping microtasks) so the `await` continuation runs promptly.
pub fn drainCompleted(isolate: ?*c.Isolate) void {
    var mask = doneMask();
    while (mask != 0) {
        const s: usize = @ctz(mask);
        mask &= mask - 1;
        if (claimSlot(s)) completeJob(isolate, s);
    }
}

fn completeJob(isolate: ?*c.Isolate, s: usize) void {
    var hs: c.HandleScope = undefined;
    c.v8__HandleScope__CONSTRUCT(&hs, isolate);
    defer c.v8__HandleScope__DESTRUCT(&hs);

    const context = c.v8__Isolate__GetCurrentContext(isolate);

    const resolver: *const c.PromiseResolver = @ptrCast(
        c.v8__Global__Get(&resolvers[s], isolate) orelse {
            c.v8__Global__Reset(&resolvers[s]);
            freeOwned(s);
            releaseSlot(s);
            return;
        },
    );
    var out: c.MaybeBool = undefined;

    if (results[s]) |data| {
        if (response_mod.buildResponseJSObject(isolate, context, data)) |obj| {
            c.v8__Promise__Resolver__Resolve(resolver, context, @ptrCast(obj), &out);
        }
        // data is deliberately NOT freed: buildResponseJSObject stashed it as
        // the __d external on the JS Response, which owns it for its lifetime.
    } else {
        const msg = errs[s] orelse "fetch failed";
        const ev = c.v8__String__NewFromUtf8(isolate, @ptrCast(msg.ptr), 0, @intCast(msg.len));
        c.v8__Promise__Resolver__Reject(resolver, context, @ptrCast(ev), &out);
    }

    c.v8__Global__Reset(&resolvers[s]);
    freeOwned(s);
    releaseSlot(s);
}
