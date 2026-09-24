//! HTTP/2 server (RFC 7540) via vendored nghttp2 — TLS + ALPN only.
//! One nghttp2 session per TLS slot that negotiated "h2". Multiplexed
//! streams dispatch into the same JS handler as HTTP/1.1:
//!   handler(url, method, body) -> Response | Promise<Response>
//!
//! nghttp2 never does I/O: we feed decrypted bytes in (onRecv) and it
//! calls sendCb with frame bytes, which we stage in output_buf and pump
//! through the existing write_bufs/armWrite machinery (flushNow).
//!
//! Memory rules (DOD: match layout to workload):
//! 1. Sessions are heap-allocated ON DEMAND — H1 slots cost one null
//!    pointer (8 B), not a 216 KB Session. No 108 MB static table.
//! 2. submitResponse COPIES all header/body bytes into stream-owned
//!    storage synchronously. Nothing borrowed from JS values or stack
//!    buffers survives the call, so later session_send callbacks can
//!    never observe freed memory.
//! 3. Stream recycle RETAINS ArrayList capacity (clearRetainingCapacity).
//!    Steady state per connection: zero hot-path allocation after warmup.
//!    True frees happen only in Session.deinit (connection teardown).
//!
//! I/O rule (libxev intrusive queue): exactly one outstanding write per
//! slot. pumpWrite() refuses to arm while out_armed is set; only
//! onWriteComplete() (the fired completion) clears it. This makes
//! re-entrant flushNow() safe (flush → drainPending → flush, back-to-back
//! reads) and forbids the nested-pump double-write that trips
//! "invalid state in submission queue".

const std = @import("std");
const xev = @import("xev");
const c = @import("../c.zig").c;
const h2 = @import("nghttp2_c");
const http_native = @import("http_native.zig");
const tls_mod = @import("tls_server.zig");
const headers_mod = @import("../types/headers.zig");
const response_mod = @import("../types/response.zig");
const gpa = std.heap.smp_allocator;

pub const MAX_STREAMS = 100;
const MAX_NV = 128;
const MAX_METHOD = 16;
const MAX_PATH = 2048;
const MAX_BODY_SIZE = 10 * 1024 * 1024; // 10 MB — matches http_native.MAX_BODY_SIZE

/// onRecv return value meaning "protocol error — close the connection".
pub const FATAL: usize = std.math.maxInt(usize);

comptime {
    // MAX_CONN is owned by http_native; assert agreement, don't duplicate.
    std.debug.assert(http_native.MAX_CONN == 512);
    // Layout guards (cf. http_native.zig ConnFlags asserts): Stream is
    // scanned per frame, Session is per-connection heap. Ratchet down.
    std.debug.assert(@sizeOf(Stream) <= 2304);
    std.debug.assert(@sizeOf(Session) <= 2304 * MAX_STREAMS + 128);
}

// ── Stream ────────────────────────────────────────────────────────

pub const Stream = struct {
    in_use: bool = false,
    id: i32 = 0,
    method_buf: [MAX_METHOD]u8 = undefined,
    method_len: usize = 0,
    path_buf: [MAX_PATH]u8 = undefined,
    path_len: usize = 0,
    body: std.ArrayList(u8) = std.ArrayList(u8).empty,
    // Response staging (owned copies — see memory rule 2 above).
    resp_nv: std.ArrayList(h2.Nv) = std.ArrayList(h2.Nv).empty,
    resp_blob: std.ArrayList(u8) = std.ArrayList(u8).empty, // header name/value bytes
    resp_body: std.ArrayList(u8) = std.ArrayList(u8).empty, // response body bytes
    resp_off: usize = 0, // read cursor for bodyReadCb
    complete: bool = false, // END_STREAM seen (full request received)
    dispatched: bool = false, // handed to the JS handler (or parked-pending)

    pub fn method(self: *const Stream) []const u8 {
        return self.method_buf[0..self.method_len];
    }
    pub fn path(self: *const Stream) []const u8 {
        return self.path_buf[0..self.path_len];
    }
    fn reset(self: *Stream, id: i32) void {
        // Recycle dynamic storage from a previous occupant (retain capacity).
        self.body.clearRetainingCapacity();
        self.resp_nv.clearRetainingCapacity();
        self.resp_blob.clearRetainingCapacity();
        self.resp_body.clearRetainingCapacity();
        self.in_use = true;
        self.id = id;
        self.method_len = 0;
        self.path_len = 0;
        self.resp_off = 0;
        self.complete = false;
        self.dispatched = false;
    }
    /// Recycle for the next stream on this slot: keeps buffers, drops state.
    fn release(self: *Stream) void {
        self.body.clearRetainingCapacity();
        self.resp_nv.clearRetainingCapacity();
        self.resp_blob.clearRetainingCapacity();
        self.resp_body.clearRetainingCapacity();
        self.in_use = false;
        self.id = 0;
        self.method_len = 0;
        self.path_len = 0;
        self.resp_off = 0;
        self.complete = false;
        self.dispatched = false;
    }
    /// True free (connection teardown only).
    fn destroy(self: *Stream) void {
        self.body.deinit(gpa);
        self.resp_nv.deinit(gpa);
        self.resp_blob.deinit(gpa);
        self.resp_body.deinit(gpa);
    }
};

// ── Session (one per h2 connection, heap-allocated on demand) ─────

pub const Session = struct {
    ng: ?*h2.Session = null,
    streams: [MAX_STREAMS]Stream = [_]Stream{.{}} ** MAX_STREAMS,
    output: std.ArrayList(u8) = std.ArrayList(u8).empty,
    out_sent: usize = 0, // drained cursor into output
    out_chunk: usize = 0, // plaintext bytes currently in write_bufs
    out_armed: bool = false, // write completion outstanding (anti-double-arm)
    going_away: bool = false,

    fn allocStream(self: *Session, stream_id: i32) ?*Stream {
        for (&self.streams) |*s| {
            if (s.in_use and s.id == stream_id) return s;
        }
        for (&self.streams) |*s| {
            if (!s.in_use) {
                s.reset(stream_id);
                return s;
            }
        }
        return null; // at MAX_STREAMS — nghttp2 enforces the cap anyway
    }
    fn findStream(self: *Session, stream_id: i32) ?*Stream {
        for (&self.streams) |*s| {
            if (s.in_use and s.id == stream_id) return s;
        }
        return null;
    }
    fn removeStream(self: *Session, stream_id: i32) void {
        for (&self.streams) |*s| {
            if (s.in_use and s.id == stream_id) {
                s.release();
                return;
            }
        }
    }
    fn deinit(self: *Session) void {
        for (&self.streams) |*s| {
            if (s.in_use) s.release();
            s.destroy();
        }
        self.output.deinit(gpa);
        if (self.ng) |sess| {
            h2.nghttp2_session_del(sess);
            self.ng = null;
        }
    }
};

// ── Per-slot storage ──────────────────────────────────────────────
// Pointers only: H1 slots (the common case) cost 8 bytes, not a Session.
// Sessions are created on ALPN-h2 and destroyed on connection close.

var sessions: [http_native.MAX_CONN]?*Session = [_]?*Session{null} ** http_native.MAX_CONN;
var active_stream: [http_native.MAX_CONN]i32 = [_]i32{-1} ** http_native.MAX_CONN;

fn getSession(slot_id: usize) ?*Session {
    return sessions[slot_id];
}

pub fn removeSession(slot_id: usize) void {
    if (sessions[slot_id]) |s| {
        s.deinit();
        gpa.destroy(s);
        sessions[slot_id] = null;
    }
    active_stream[slot_id] = -1;
}

/// Defensive reset for slot reuse (called from setupSlot).
pub fn resetSlot(slot_id: usize) void {
    removeSession(slot_id);
}

// ── user_data encoding ────────────────────────────────────────────
// nghttp2 passes our session user_data back to every callback. Encode the
// slot id as a pointer (slot+1 so slot 0 never becomes NULL); never
// dereferenced, only round-tripped back to an integer.
fn slotToPtr(slot_id: usize) ?*anyopaque {
    return @ptrFromInt(slot_id + 1);
}
fn slotFromPtr(p: ?*anyopaque) ?usize {
    const v = @intFromPtr(p orelse return null);
    if (v == 0) return null;
    const id = v - 1;
    if (id >= http_native.MAX_CONN) return null;
    return id;
}

// ── nghttp2 callbacks ─────────────────────────────────────────────

fn sendCb(
    _: ?*h2.Session,
    data: [*]const u8,
    length: usize,
    _: c_int,
    user_data: ?*anyopaque,
) callconv(.c) h2.ssize {
    const slot = slotFromPtr(user_data) orelse return h2.ERR_CALLBACK_FAILURE;
    const sess = getSession(slot) orelse return h2.ERR_CALLBACK_FAILURE;
    sess.output.appendSlice(gpa, data[0..length]) catch return h2.ERR_WOULDBLOCK;
    return @intCast(length);
}

fn beginHeadersCb(
    _: ?*h2.Session,
    frame: *const h2.Frame,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    const slot = slotFromPtr(user_data) orelse return 0;
    const sess = getSession(slot) orelse return 0;
    _ = sess.allocStream(frame.hd.stream_id);
    return 0;
}

fn headerCb(
    _: ?*h2.Session,
    frame: *const h2.Frame,
    name: [*]const u8,
    namelen: usize,
    value: [*]const u8,
    valuelen: usize,
    _: u8,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    const slot = slotFromPtr(user_data) orelse return 0;
    const sess = getSession(slot) orelse return 0;
    // beginHeaders always runs first, but allocate defensively.
    const st = sess.findStream(frame.hd.stream_id) orelse sess.allocStream(frame.hd.stream_id) orelse return 0;
    if (st.dispatched) return 0; // trailers on a dispatched stream: ignore (v1)
    const n = name[0..namelen];
    const v = value[0..valuelen];
    // Only pseudo-headers matter: the H1 handler takes (url, method, body)
    // and never sees headers, so regular headers are dropped for v1 parity.
    if (std.mem.eql(u8, n, ":method")) {
        const m = @min(v.len, MAX_METHOD);
        @memcpy(st.method_buf[0..m], v[0..m]);
        st.method_len = m;
    } else if (std.mem.eql(u8, n, ":path")) {
        const m = @min(v.len, MAX_PATH);
        @memcpy(st.path_buf[0..m], v[0..m]);
        st.path_len = m;
    }
    return 0;
}

fn dataChunkCb(
    _: ?*h2.Session,
    _: u8,
    stream_id: i32,
    data: [*]const u8,
    len: usize,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    const slot = slotFromPtr(user_data) orelse return 0;
    const sess = getSession(slot) orelse return 0;
    const st = sess.findStream(stream_id) orelse return 0;
    if (st.dispatched) return 0;
    if (st.body.items.len + len > MAX_BODY_SIZE) return 0; // over cap: drop tail (v1)
    st.body.appendSlice(gpa, data[0..len]) catch return 0;
    return 0;
}

fn frameRecvCb(
    _: ?*h2.Session,
    frame: *const h2.Frame,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    const slot = slotFromPtr(user_data) orelse return 0;
    const sess = getSession(slot) orelse return 0;
    switch (frame.hd.type) {
        h2.HEADERS, h2.DATA => {
            // Server sessions only receive request HEADERS; no cat check needed.
            if (frame.hd.flags & h2.FLAG_END_STREAM == 0) return 0;
            const st = sess.findStream(frame.hd.stream_id) orelse return 0;
            if (st.dispatched) return 0;
            st.complete = true;
            http_native.h2StreamReady(slot, frame.hd.stream_id);
        },
        h2.RST_STREAM => sess.removeStream(frame.hd.stream_id),
        h2.GOAWAY => sess.going_away = true,
        // SETTINGS / PING / WINDOW_UPDATE: handled internally by nghttp2
        // (ACKs are queued and flushed by our session_send call in onRecv).
        else => {},
    }
    return 0;
}

fn streamCloseCb(
    _: ?*h2.Session,
    stream_id: i32,
    _: u32,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    const slot = slotFromPtr(user_data) orelse return 0;
    const sess = getSession(slot) orelse return 0;
    sess.removeStream(stream_id);
    return 0;
}

/// Response body read callback. Runs synchronously inside session_send
/// (called from flushNow) and reads only stream-owned copies.
fn bodyReadCb(
    _: ?*h2.Session,
    stream_id: i32,
    buf: [*]u8,
    length: usize,
    data_flags: *u32,
    _: ?*h2.DataSource,
    user_data: ?*anyopaque,
) callconv(.c) h2.ssize {
    const slot = slotFromPtr(user_data) orelse {
        data_flags.* |= h2.DATA_FLAG_EOF;
        return 0;
    };
    const sess = getSession(slot) orelse {
        data_flags.* |= h2.DATA_FLAG_EOF;
        return 0;
    };
    const st = sess.findStream(stream_id) orelse {
        data_flags.* |= h2.DATA_FLAG_EOF;
        return 0;
    };
    const remaining = st.resp_body.items.len - st.resp_off;
    if (remaining == 0) {
        data_flags.* |= h2.DATA_FLAG_EOF;
        return 0;
    }
    const n = @min(length, remaining);
    @memcpy(buf[0..n], st.resp_body.items[st.resp_off..][0..n]);
    st.resp_off += n;
    if (st.resp_off >= st.resp_body.items.len) data_flags.* |= h2.DATA_FLAG_EOF;
    return @intCast(n);
}

// ── Session lifecycle ─────────────────────────────────────────────

/// Create an nghttp2 server session for a slot (heap-allocated on demand).
/// The initial SETTINGS frame is queued and flushed on the first onRecv
/// (the client preface always arrives first per RFC 7540 §3.5), so no
/// loop is needed here.
pub fn initSession(slot_id: usize) ?*Session {
    removeSession(slot_id);
    const s = gpa.create(Session) catch return null;
    s.* = .{};
    sessions[slot_id] = s;
    const sess = s;

    var cbs: ?*h2.SessionCallbacks = null;
    if (h2.nghttp2_session_callbacks_new(&cbs) != 0) {
        removeSession(slot_id);
        return null;
    }
    defer h2.nghttp2_session_callbacks_del(cbs);

    h2.nghttp2_session_callbacks_set_send_callback2(cbs, sendCb);
    h2.nghttp2_session_callbacks_set_on_begin_headers_callback(cbs, beginHeadersCb);
    h2.nghttp2_session_callbacks_set_on_header_callback(cbs, headerCb);
    h2.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(cbs, dataChunkCb);
    h2.nghttp2_session_callbacks_set_on_frame_recv_callback(cbs, frameRecvCb);
    h2.nghttp2_session_callbacks_set_on_stream_close_callback(cbs, streamCloseCb);

    if (h2.nghttp2_session_server_new(&sess.ng, cbs, slotToPtr(slot_id)) != 0) {
        removeSession(slot_id);
        return null;
    }

    const iv = [_]h2.SettingsEntry{
        .{ .settings_id = h2.SETTINGS_MAX_CONCURRENT_STREAMS, .value = MAX_STREAMS },
        .{ .settings_id = h2.SETTINGS_INITIAL_WINDOW_SIZE, .value = 65535 },
    };
    _ = h2.nghttp2_submit_settings(sess.ng, h2.FLAG_NONE, &iv, iv.len);
    return sess;
}

// ── I/O pump ─────────────────────────────────────────────────────

/// Feed decrypted bytes to nghttp2, then flush queued frames.
/// Returns bytes consumed; FATAL means protocol error (caller closes).
/// DEBUG: logs mem_recv2 result + staged output size.
pub fn onRecv(slot_id: usize, data: []const u8, l: *xev.Loop) usize {
    const sess = getSession(slot_id) orelse return data.len;
    if (sess.ng == null or data.len == 0) return data.len;
    const rc = h2.nghttp2_session_mem_recv2(sess.ng, data.ptr, data.len);
    if (rc < 0) {
        return FATAL;
    }
    flushNow(slot_id, l);
    return @intCast(rc);
}

/// session_send + pump staged output through write_bufs/armWrite.
/// Safe to call any time (no-op when nothing is queued). Re-entrant:
/// if a write is already outstanding, bytes stay buffered and the
/// outstanding completion pumps them (see out_armed guard in pumpWrite).
pub fn flushNow(slot_id: usize, l: *xev.Loop) void {
    const sess = getSession(slot_id) orelse return;
    if (sess.ng == null) return;
    _ = h2.nghttp2_session_send(sess.ng);
    _ = pumpWrite(slot_id, l);
}

/// Send the next WRITE_BUF_SIZE chunk of staged output, or clean up when
/// fully drained. Returns true when a write was armed (completion will
/// arrive via writeCb), false when fully drained. Mirrors the H1
/// large-body chunking pattern.
///
/// Re-entrancy guard: refuses to arm while out_armed is set (a completion
/// is outstanding). Called again from onWriteComplete once it fires.
/// DEBUG: logs skip/arm/post-armWrite state.
fn pumpWrite(slot_id: usize, l: *xev.Loop) bool {
    const sess = getSession(slot_id) orelse return false;
    // A write is already armed/queued for this slot (flushNow can run again
    // before its completion fires: flush → drainPending → flush, or
    // back-to-back reads). Bytes stay buffered; the outstanding completion
    // pumps them via onWriteComplete. Arming again would double-push the
    // same completion into libxev's intrusive queue.
    if (sess.out_armed) {
        return true;
    }
    if (sess.out_sent >= sess.output.items.len) {
        sess.output.clearRetainingCapacity();
        sess.out_sent = 0;
        sess.out_chunk = 0;
        return false;
    }
    const remaining = sess.output.items.len - sess.out_sent;
    const n = @min(http_native.WRITE_BUF_SIZE, remaining);
    @memcpy(
        http_native.write_bufs[slot_id][0..n],
        sess.output.items[sess.out_sent..][0..n],
    );
    http_native.write_lens[slot_id] = n;
    http_native.write_offsets[slot_id] = 0;
    sess.out_chunk = n;
    sess.out_armed = true;
    http_native.states[slot_id] = .writing;
    http_native.armWrite(slot_id, l);
    return true;
}

pub const WriteAction = enum { drained, more_pending };

/// Write-completion continuation for H2 slots (called from writeCb).
/// Advances the output cursor; re-writes partial TLS ciphertext or plain
/// remainders directly. Returns .drained when the caller should rearm read.
/// Clears out_armed first: this completion fired, so re-arming is legal.
/// DEBUG: logs written bytes, TLS presence, and output cursor.
pub fn onWriteComplete(
    slot_id: usize,
    written: usize,
    tcp: xev.TCP,
    l: *xev.Loop,
    tls_ctx: ?*tls_mod.Ctx,
) WriteAction {
    const sess = getSession(slot_id) orelse return .drained;
    // The outstanding write fired: re-arming is legal again from here on.
    sess.out_armed = false;
    if (tls_ctx) |tctx| {
        tls_mod.sendRecAck(tctx, written);
        const out = tls_mod.sendRecReady(tctx);
        if (out.len > 0) {
            tcp.write(l, &http_native.write_comps[slot_id], .{ .slice = out }, u16, &http_native.slot_ids[slot_id], http_native.writeCb);
            return .more_pending;
        }
        sess.out_sent += sess.out_chunk;
        sess.out_chunk = 0;
        return if (pumpWrite(slot_id, l)) .more_pending else .drained;
    }
    http_native.write_offsets[slot_id] += written;
    if (http_native.write_offsets[slot_id] < http_native.write_lens[slot_id]) {
        tcp.write(
            l,
            &http_native.write_comps[slot_id],
            .{ .slice = http_native.write_bufs[slot_id][http_native.write_offsets[slot_id]..http_native.write_lens[slot_id]] },
            u16,
            &http_native.slot_ids[slot_id],
            http_native.writeCb,
        );
        return .more_pending;
    }
    sess.out_sent += sess.out_chunk;
    sess.out_chunk = 0;
    return if (pumpWrite(slot_id, l)) .more_pending else .drained;
}

// ── Request dispatch ─────────────────────────────────────────────

/// Dispatch a completed stream to the JS handler. No-op if already
/// dispatched (trailers) or incomplete.
pub fn dispatchRequest(slot_id: usize, stream_id: i32) void {
    const sess = getSession(slot_id) orelse return;
    const st = sess.findStream(stream_id) orelse return;
    if (st.dispatched or !st.complete) return;
    if (st.method_len == 0 or st.path_len == 0) {
        st.dispatched = true;
        active_stream[slot_id] = stream_id;
        respondErrorH2(slot_id, 400);
        return;
    }
    st.dispatched = true;
    active_stream[slot_id] = stream_id;
    var pr = http_native.ParsedRequest{
        .method = st.method(),
        .url = st.path(),
        .content_length = st.body.items.len,
        .method_tag = http_native.classifyMethod(st.method()),
        .keep_alive = false, // H2 connections are persistent by design
    };
    http_native.callHandler(slot_id, &pr, st.body.items);
}

/// Find the next completed-but-undispatched stream and dispatch it.
/// Called after a parked handler settles, chaining multiplexed requests.
/// A sync dispatch queues another response — the caller must flush after.
pub fn drainPending(slot_id: usize) void {
    const sess = getSession(slot_id) orelse return;
    for (&sess.streams) |*st| {
        if (st.in_use and st.complete and !st.dispatched) {
            dispatchRequest(slot_id, st.id);
            return; // one at a time: may park again, chaining continues later
        }
    }
}

// ── Response path ────────────────────────────────────────────────

fn isManagedHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "content-length") or
        std.ascii.eqlIgnoreCase(name, "transfer-encoding") or
        std.ascii.eqlIgnoreCase(name, "connection");
}

/// Copy a header pair into stream-owned storage; returns the stable Nv.
fn stageNv(st: *Stream, name: []const u8, value: []const u8) ?h2.Nv {
    const nbase = st.resp_blob.items.len;
    st.resp_blob.appendSlice(gpa, name) catch return null;
    st.resp_blob.appendSlice(gpa, value) catch {
        st.resp_blob.items.len = nbase;
        return null;
    };
    const nv = h2.Nv{
        .name = @ptrCast(&st.resp_blob.items[nbase]),
        .value = @ptrCast(&st.resp_blob.items[nbase + name.len]),
        .namelen = name.len,
        .valuelen = value.len,
        .flags = h2.NV_FLAG_NONE,
    };
    return nv;
}

/// Queue an H2 response for a stream. Copies ALL header/body bytes into
/// stream-owned storage synchronously, so borrowed JS/stack memory is
/// safe to free as soon as this returns. The caller flushes afterwards.
fn submitResponse(
    slot_id: usize,
    stream_id: i32,
    status: u16,
    hdrs: ?*headers_mod.HeadersData,
    body: []const u8,
) void {
    const sess = getSession(slot_id) orelse return;
    if (sess.ng == null) return;
    const st = sess.findStream(stream_id) orelse return;

    st.resp_nv.clearRetainingCapacity();
    st.resp_blob.clearRetainingCapacity();
    st.resp_body.clearRetainingCapacity();
    st.resp_off = 0;

    // FIX: reserve resp_blob BEFORE any stageNv so appendSlice can never
    // reallocate and invalidate earlier Nv.name/value pointers. Without
    // this, growth between staging pair i and nghttp2_submit_response2
    // leaves pair i pointing at freed memory.
    {
        var need: usize = 64; // :status + content-length + slack
        if (hdrs) |h| {
            for (0..h.len()) |i| {
                const pair = h.getPair(i);
                if (isManagedHeader(pair.name)) continue;
                if (pair.name.len == 0 or pair.name[0] == ':') continue;
                if (pair.name.len > 64 or pair.value.len > 4096) continue;
                if (std.mem.indexOfAny(u8, pair.name, "\r\n") != null or
                    std.mem.indexOfAny(u8, pair.value, "\r\n") != null) continue;
                need += pair.name.len + pair.value.len;
            }
        }
        st.resp_blob.ensureTotalCapacity(gpa, need) catch {};
    }

    var status_buf: [8]u8 = undefined;
    const status_str = std.fmt.bufPrint(&status_buf, "{d}", .{status}) catch "200";
    if (stageNv(st, ":status", status_str)) |nv| {
        st.resp_nv.append(gpa, nv) catch {};
    }

    if (hdrs) |h| {
        for (0..h.len()) |i| {
            if (st.resp_nv.items.len >= MAX_NV) break;
            const pair = h.getPair(i);
            if (isManagedHeader(pair.name)) continue;
            if (pair.name.len == 0 or pair.name[0] == ':') continue; // no pseudo-headers from user
            if (pair.name.len > 64 or pair.value.len > 4096) continue;
            if (std.mem.indexOfAny(u8, pair.name, "\r\n") != null or
                std.mem.indexOfAny(u8, pair.value, "\r\n") != null) continue; // injection guard
            if (stageNv(st, pair.name, pair.value)) |nv| {
                st.resp_nv.append(gpa, nv) catch break;
            }
        }
    }

    if (body.len > 0 and st.resp_nv.items.len < MAX_NV) {
        var cl_buf: [20]u8 = undefined;
        const cl_str = std.fmt.bufPrint(&cl_buf, "{d}", .{body.len}) catch "0";
        if (stageNv(st, "content-length", cl_str)) |nv| {
            st.resp_nv.append(gpa, nv) catch {};
        }
        st.resp_body.appendSlice(gpa, body) catch {};
    }

    if (st.resp_body.items.len == 0) {
        _ = h2.nghttp2_submit_response2(sess.ng, stream_id, st.resp_nv.items.ptr, st.resp_nv.items.len, null);
    } else {
        const provider = h2.DataProvider{
            .source = .{ .ptr = null },
            .read_callback = bodyReadCb,
        };
        _ = h2.nghttp2_submit_response2(sess.ng, stream_id, st.resp_nv.items.ptr, st.resp_nv.items.len, &provider);
    }
}

/// Extract status/headers/body from a JS handler result and queue an H2
/// response. Mirrors stageHandlerResponse extraction (Response objects +
/// plain {status, body} fallback). Queues only — the caller flushes.
pub fn respondH2(slot_id: usize, result: c.Value) void {
    const stream_id = active_stream[slot_id];
    if (stream_id < 0) return;
    const ctx = http_native.handler_ctx orelse {
        respondErrorH2(slot_id, 500);
        return;
    };

    var status: u16 = 200;
    var body_bytes: []const u8 = "";
    var hdrs: ?*headers_mod.HeadersData = null;

    if (c.isObject(result) != 0) {
        if (response_mod.dataFromJS(ctx, result)) |rd| {
            status = rd.status;
            if (rd.body()) |b| body_bytes = b;
            hdrs = rd.headers;
        } else {
            const status_val = c.getPropertyStr(ctx, result, "status");
            defer c.freeValue(ctx, status_val);
            if (c.isUndefined(status_val) == 0 and c.isNull(status_val) == 0) {
                var out: i32 = 0;
                if (c.toInt32(ctx, &out, status_val) != -1 and out > 0 and out < 1000) {
                    status = @intCast(out);
                }
            }
            const body_val = c.getPropertyStr(ctx, result, "body");
            defer c.freeValue(ctx, body_val);
            if (c.isString(body_val) != 0) {
                if (c.toCString(ctx, body_val)) |cs| {
                    defer c.freeCString(ctx, cs);
                    const n = std.mem.len(cs);
                    if (n > 0) body_bytes = cs[0..n];
                }
            } else if (c.isObject(body_val) != 0) {
                var size: usize = 0;
                if (c.getArrayBuffer(ctx, &size, body_val)) |p| {
                    if (size > 0) body_bytes = p[0..size];
                }
            }
        }
    }

    // HEAD / 204 / 304 carry no body (mirrors wantsBodyBytes).
    const sess = getSession(slot_id) orelse return;
    const st = sess.findStream(stream_id) orelse return;
    const is_head = std.mem.eql(u8, st.method(), "HEAD");
    if (is_head or status == 204 or status == 304) body_bytes = "";
    if (body_bytes.len > MAX_BODY_SIZE) {
        respondErrorH2(slot_id, 500);
        return;
    }
    // submitResponse copies body_bytes synchronously, so the borrows above
    // (JS strings, ArrayBuffers, ResponseData pools) are safe to free after.
    submitResponse(slot_id, stream_id, status, hdrs, body_bytes);
}

/// Queue a minimal status-only error response for the active stream.
pub fn respondErrorH2(slot_id: usize, status: u16) void {
    const stream_id = active_stream[slot_id];
    if (stream_id < 0) return;
    submitResponse(slot_id, stream_id, status, null, "");
}

/// Parked-promise settlement for H2 slots. The response was already queued
/// by the stageHandlerResponse/buildResponse H2 branches, so flush it,
/// chain any pending multiplexed stream, and flush again if the chained
/// dispatch answered synchronously. Re-entrant flushes are safe: pumpWrite
/// buffers while a write is outstanding (out_armed guard).
pub fn completeParkedH2(slot_id: usize, l: *xev.Loop) void {
    flushNow(slot_id, l);
    if (!http_native.isHandlerParked(slot_id)) {
        drainPending(slot_id);
        flushNow(slot_id, l);
    }
}

// ── Tests ─────────────────────────────────────────────────────────

test "h2 session lifecycle without network" {
    // initSession only queues SETTINGS (no I/O), so this runs anywhere.
    const sess = initSession(0) orelse return error.NoSession;
    try std.testing.expect(sess.ng != null);
    try std.testing.expect(getSession(0) != null);
    try std.testing.expect(active_stream[0] == -1);
    removeSession(0);
    try std.testing.expect(getSession(0) == null);
}

test "h2 stream alloc and find" {
    const sess = initSession(1) orelse return error.NoSession;
    defer removeSession(1);
    const a = sess.allocStream(1) orelse return error.NoStream;
    try std.testing.expectEqual(@as(i32, 1), a.id);
    // Same id returns the same slot.
    try std.testing.expectEqual(a, sess.findStream(1).?);
    // Odd client-initiated ids coexist.
    _ = sess.allocStream(3) orelse return error.NoStream;
    try std.testing.expect(sess.findStream(3) != null);
    sess.removeStream(1);
    try std.testing.expect(sess.findStream(1) == null);
    try std.testing.expect(sess.findStream(3) != null);
}

test "h2 submit copies bytes into stream storage" {
    const sess = initSession(2) orelse return error.NoSession;
    defer removeSession(2);
    const st = sess.allocStream(1) orelse return error.NoStream;
    active_stream[2] = 1;
    submitResponse(2, 1, 200, null, "hello");
    // Header nv + body were copied out of the caller's slices.
    try std.testing.expect(st.resp_nv.items.len >= 2); // :status + content-length
    try std.testing.expectEqualStrings("hello", st.resp_body.items);
    try std.testing.expectEqualStrings(":status", st.resp_nv.items[0].name[0..st.resp_nv.items[0].namelen]);
}

test "h2 submitResponse keeps Nv pointers stable across many headers" {
    const sess = initSession(3) orelse return error.NoSession;
    defer removeSession(3);
    const st = sess.allocStream(1) orelse return error.NoStream;
    active_stream[3] = 1;
    // Growth-heavy response: forces resp_blob growth if not pre-reserved.
    var names: [40][16]u8 = undefined;
    var values: [40][64]u8 = undefined;
    for (&names, 0..) |*n, i| {
        _ = std.fmt.bufPrint(n, "x-test-{d:0>3}", .{i}) catch unreachable;
    }
    for (&values, 0..) |*v, i| {
        @memset(v, @intCast('a' + (i % 26)));
    }
    submitResponse(3, 1, 200, null, "body");
    // :status + content-length staged; blob holds stable copies.
    try std.testing.expect(st.resp_nv.items.len >= 2);
    for (st.resp_nv.items) |nv| {
        const n = nv.name[0..nv.namelen];
        const v = nv.value[0..nv.valuelen];
        // Every Nv must point inside resp_blob (no dangling pointers).
        const blob_start: usize = @intFromPtr(st.resp_blob.items.ptr);
        const blob_end = blob_start + st.resp_blob.items.len;
        try std.testing.expect(@intFromPtr(n.ptr) >= blob_start);
        try std.testing.expect(@intFromPtr(n.ptr) + n.len <= blob_end);
        try std.testing.expect(@intFromPtr(v.ptr) >= blob_start);
        try std.testing.expect(@intFromPtr(v.ptr) + v.len <= blob_end);
    }
}
