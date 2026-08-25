const std = @import("std");
const xev = @import("xev");
const c = @import("../c.zig").c;
const tls = @import("./tls.zig");
const response_mod = @import("../types/response.zig");

const gpa = std.heap.smp_allocator;
const http = std.http;

// ============================================================
// Async fetch — DOD/SoA slot pool, same idiom as net/tls.zig.
//
// No per-fetch heap structs. Every live fetch is an integer slot id into
// dense per-field arrays; slots come from an O(1) free-list. The pool
// doubles as the concurrency cap: at most MAX_FETCH workers exist, so
// spawns are bounded and "submit" fails fast with error.NoConnectionAvailable.
//
// Worker completion is detected with a SIMD sweep over the state vector
// (a doneBitmap), then each candidate is confirmed with a per-slot acquire
// CAS — vector front-end for cheap batching, atomics for correctness
// (the same vector-then-scalar hybrid as findCrLf in tls.zig).
//
// Wakeup: a single xev.Async (mach port). Worker notify() wakes the loop;
// the callback re-arms while pending > 0 and disarms at 0. drainCompleted()
// also runs every tick as a safety net against a coalesced/missed notify.
//
// v8 is touched ONLY on the main thread (drainCompleted/completeJob).
// ============================================================

pub const MAX_FETCH = 64; // matches tls.MAX_CONN; == u64 mask lanes

const JOB_FREE: u8 = 0;
const JOB_BUSY: u8 = 1;
const JOB_DONE: u8 = 2;
const JOB_CLAIMED: u8 = 3;

// ---- SoA hot state (one contiguous block per field) ----
var states:    [MAX_FETCH]std.atomic.Value(u8) = [_]std.atomic.Value(u8){.{ .raw = JOB_FREE }} ** MAX_FETCH;
var url_bufs:  [MAX_FETCH][:0]const u8 = undefined;
var uris:      [MAX_FETCH]std.Uri = undefined;
var methods:   [MAX_FETCH]http.Method = undefined;
var headers:   [MAX_FETCH]std.ArrayList(http.Header) = undefined;
var bodies:    [MAX_FETCH]?[:0]const u8 = [_]?[:0]const u8{null} ** MAX_FETCH;
var resolvers: [MAX_FETCH]c.Global = undefined;
var results:   [MAX_FETCH]?*response_mod.ResponseData = [_]?*response_mod.ResponseData{null} ** MAX_FETCH;
var errs:      [MAX_FETCH]?[]const u8 = [_]?[]const u8{null} ** MAX_FETCH;

// ---- O(1) slot allocator (spinlock-guarded) ----
var free_list: [MAX_FETCH]u16 = undefined;
var free_count: usize = MAX_FETCH;
var pool_lock: std.atomic.Mutex = .unlocked;

// ---- cross-thread wakeup ----
const AsyncT = xev.Async;
var async_h: AsyncT = undefined;
var async_comp: xev.Completion = .{};
var async_armed = false;

// main-thread/pump-visible wip counter; 0 => all workers done
pub var pending: std.atomic.Value(u64) = .{ .raw = 0 };

fn poolLock() void {
    while (!pool_lock.tryLock()) std.atomic.spinLoopHint();
}

fn poolUnlock() void {
    pool_lock.unlock();
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

pub fn init() void {
    poolInit();
    async_h = AsyncT.init() catch unreachable;
    async_armed = false;
}

pub fn deinit() void {
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

// ---- submission (main thread, from fetchCallback) ----
// Takes ownership of url_buf/headers/body on success; frees them on failure.

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
        gpa.free(url_buf);
        for (hl.items) |h| {
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

    _ = pending.fetchAdd(1, .acq_rel);
    const s16: u16 = @intCast(s);
    const th = std.Thread.spawn(.{}, workerMain, .{s16}) catch {
        _ = pending.fetchSub(1, .acq_rel);
        c.v8__Global__Reset(&resolvers[s]);
        freeOwned(s);
        releaseSlot(s);
        return error.SpawnFailed;
    };
    th.detach();
}

// ---- worker (never touches v8) ----

fn workerMain(slot_id: u16) void {
    const s: usize = slot_id;

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
                    } else if (n == len) {
                        owned_body = b;
                    } else {
                        owned_body = gpa.dupe(u8, b[0..n]) catch b[0..n];
                        if (owned_body.?.len == n) gpa.free(b);
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
    }

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

    if (owned_body) |b| {
        resp_data.setBodyOwned(b);
        owned_body = null; // transferred; the Response owns it now
    } else if (response.head.content_length != null and has_body) {
        resp_data.setBody("");
    }

    okSlot(s, resp_data);
}

fn failSlot(s: usize, comptime msg: []const u8) void {
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
    var raw: [MAX_FETCH]u8 = undefined;
    for (0..MAX_FETCH) |i| raw[i] = states[i].raw; // scalar gather; ordering not needed (hint only)
    const v: @Vector(MAX_FETCH, u8) = @bitCast(raw);
    const eq = v == @as(@Vector(MAX_FETCH, u8), @splat(JOB_DONE));
    return @bitCast(eq); // 64 x u1 lanes -> u64 bitmask
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
