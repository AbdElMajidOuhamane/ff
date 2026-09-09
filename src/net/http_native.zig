const std = @import("std");
const simd = std.simd;
const xev = @import("xev");
const c = @import("../c.zig").c;
const microtasks = @import("../event/microtasks.zig");
const ws = @import("ws_native.zig");
const api_ws = @import("../api/websocket.zig");
const builtin = @import("builtin");
const tls_mod = @import("tls_server.zig");
const tls_on = tls_mod.available;
const response_mod = @import("../types/response.zig"); // NEW
const headers_mod = @import("../types/headers.zig"); // NEW

// F3: the Debug req_counter (CountingAllocator) that used to wrap this
// file's allocator is deleted. Nothing in this file allocates through it
// (zero `gpa.` call sites) and the real per-request heap traffic — QuickJS
// values plus types/response.zig via raw smp_allocator — bypasses it, so
// `balanced=true` was vacuous false assurance. The meaningful per-job
// counter lives in net/async_fetch.zig.

pub const MAX_CONN = 512;
const READ_BUF_SIZE = 4096;
const WRITE_BUF_SIZE = 16384;
const ACCEPT_BATCH = 8;

const ConnState = enum(u8) { idle, reading, writing, closing };
const ConnFlags = packed struct(u16) {
    keep_alive: bool = false,
    ws_open: bool = false,
    ws_writing: bool = false,
    ws_close_after_write: bool = false,
    ws_read_armed: bool = false,
    ws_pending_open: bool = false,
    tls: bool = false,
    tls_close_after_write: bool = false,
    handler_parked: bool = false,   // NEW
    _pad: u7 = 0,                   // u8 -> u7
};
comptime {
    assert(@sizeOf(ConnFlags) == 2);
    assert(@alignOf(ConnFlags) == 2);
    assert(@sizeOf(Method) == 1);
    assert(@alignOf(Method) == 1);
    assert(@sizeOf(ParsedRequest) <= 64);
    assert(@alignOf(ParsedRequest) <= 8);
    assert(@sizeOf(ConnState) == 1);
}
const assert = std.debug.assert;

const Method = enum(u8) { get, post, put, delete, head, options, patch, none };
var states: [MAX_CONN]ConnState = [_]ConnState{.idle} ** MAX_CONN;
var cflags: [MAX_CONN]ConnFlags = [_]ConnFlags{.{}} ** MAX_CONN;
// DOD-FIX 11: removed unused `read_bytes` column.
var write_lens: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
var write_offsets: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
var methods: [MAX_CONN]Method = [_]Method{.none} ** MAX_CONN;
var read_comps: [MAX_CONN]xev.Completion = [_]xev.Completion{.{}} ** MAX_CONN;
var write_comps: [MAX_CONN]xev.Completion = [_]xev.Completion{.{}} ** MAX_CONN;
var close_comps: [MAX_CONN]xev.Completion = [_]xev.Completion{.{}} ** MAX_CONN;
var hdr_scan_off: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
var fds: [MAX_CONN]xev.TCP = undefined;
var buf_lens: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
// F4: bytes of read_bufs[0..buf_lens] consumed by the current request
// (headers_end + content_length). Keep-alive re-arms use it to preserve
// pipelined bytes instead of discarding them.
var req_consumed: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
var ws_partial_len: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
// DOD §3: 512B bool column → 64B bitset (8×u64). Set only on fragment start,
// read only on fragment completion — never scanned linearly with buf_lens.
var ws_partial_binary_bits: [MAX_CONN / 64]u64 = [_]u64{0} ** (MAX_CONN / 64);
inline fn wsPartialBinary(id: usize) bool {
    return (ws_partial_binary_bits[id >> 6] >> @intCast(id & 63)) & 1 == 1;
}
inline fn wsSetPartialBinary(id: usize, is_bin: bool) void {
    const w = &ws_partial_binary_bits[id >> 6];
    const bit: u64 = @as(u64, 1) << @intCast(id & 63);
    if (is_bin) w.* |= bit else w.* &= ~bit;
}
var ws_sockets: [MAX_CONN]?c.Value = [_]?c.Value{null} ** MAX_CONN;
var ws_batch: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
var read_bufs: [MAX_CONN][READ_BUF_SIZE]u8 = undefined;
var write_bufs: [MAX_CONN][WRITE_BUF_SIZE]u8 = undefined;
// DOD-FIX 4: static per-slot WS partial buffer (no more heap pointer).
var ws_partial: [MAX_CONN][ws.WS_MSG_SIZE]u8 = undefined;
// DOD-FIX 3: chunked-write state for large response bodies.
var body_remaining: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
var body_source_off: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
// body_bufs holds one fully-staged large response body per slot. Static
// allocation: MAX_CONN × BODY_BUF_SIZE. Bodies larger than BODY_BUF_SIZE
// get a 500 (JS body pointers are freed when callHandler returns, so the
// whole body must be staged before the write pipeline starts).
const BODY_BUF_SIZE = 64 * 1024;
var body_bufs: [MAX_CONN][BODY_BUF_SIZE]u8 = undefined;
var body_lens: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
// ── TLS (https/wss): per-slot BearSSL engine + bidirectional iobuf ──
var tls_ctxs: [MAX_CONN]tls_mod.Ctx = undefined;
var tls_iobufs: [MAX_CONN][tls_mod.IOBUF_LEN]u8 = undefined;
var tls_active: bool = false; // runtime switch (cert/key given), set before accept starts
var free_list: [MAX_CONN]u16 = undefined;
var free_count: usize = 0;
var slot_ids: [MAX_CONN]u16 = undefined;

// ── Parked async handlers (one flat column per slot) ── // NEW
// Generation counter guards late promise reactions against slot reuse.
var slot_gen: [MAX_CONN]u16 = [_]u16{0} ** MAX_CONN;
var parked_since_ms: [MAX_CONN]u64 = [_]u64{0} ** MAX_CONN;
var promise_class_id: c.ClassID = 0;

const HDR_MAX = 2048;
const HANDLER_TIMEOUT_MS: u64 = 30_000;
const WATCHDOG_INTERVAL_MS: u64 = 1000;
var watchdog_timer: xev.Timer = undefined;
var watchdog_comp: xev.Completion = .{};
var watchdog_started = false;

pub var handler_fn: ?c.Value = null;
pub var handler_ctx: ?*c.Context = null;
pub var ws_enabled: bool = false;
pub var ws_on_open: ?c.Value = null;
pub var ws_on_message: ?c.Value = null;
pub var ws_on_close: ?c.Value = null;
var native_echo: bool = false;
var listener_tcp: xev.TCP = undefined;
var accept_comp: xev.Completion = .{};
var g_loop: ?*xev.Loop = null;
var initialized: bool = false;

// Gap-7 fix: largest→smallest field order (56B → 48B, still ≤64 assert).
// The single construction site (parseRequest) uses named fields, so the
// reorder is safe. Stack transient only — never stored in a large array.
pub const ParsedRequest = struct {
    method: []const u8,
    url: []const u8,
    content_length: usize,
    method_tag: Method,
    keep_alive: bool,
};

// ---- SIMD/CI helpers (unchanged) ----

fn freePop() ?usize {
    if (free_count == 0) return null;
    free_count -= 1;
    return free_list[free_count];
}
fn freePush(id: usize) void {
    free_list[free_count] = @intCast(id);
    free_count += 1;
}
fn findTokenCIScalar(haystack: []const u8, needle: []const u8) ?usize {
    outer: for (0..haystack.len - needle.len + 1) |i| {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) continue :outer;
        }
        return i;
    }
    return null;
}
fn matchCI(haystack: []const u8, pos: usize, needle: []const u8) bool {
    var j: usize = 0;
    while (j < needle.len) : (j += 1) {
        if (std.ascii.toLower(haystack[pos + j]) != std.ascii.toLower(needle[j])) return false;
    }
    return true;
}
fn ciStartsWith(s: []const u8, comptime prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    inline for (prefix, 0..) |ch, k| {
        if (std.ascii.toLower(s[k]) != ch) return false;
    }
    return true;
}
fn ciListHas(value: []const u8, token: []const u8) bool {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        var s: usize = 0;
        var e: usize = raw.len;
        while (s < e and (raw[s] == ' ' or raw[s] == '\t')) s += 1;
        while (e > s and (raw[e - 1] == ' ' or raw[e - 1] == '\t')) e -= 1;
        const member = raw[s..e];
        if (member.len == token.len and matchCI(member, 0, token)) return true;
    }
    return false;
}
fn findTokenCISimd(haystack: []const u8, needle: []const u8) ?usize {
    const n = needle.len;
    const window_end = haystack.len - n + 1;
    const first = std.ascii.toLower(needle[0]);
    const N = simd.suggestVectorLength(u8) orelse 16;
    const V = @Vector(N, u8);
    const M = std.meta.Int(.unsigned, N);
    const spl_first: V = @splat(first);
    const spl_lower: V = @splat(@as(u8, 0x20));
    var i: usize = 0;
    while (i < window_end and window_end - i >= N) : (i += N) {
        const v: V = haystack[i..][0..N].*;
        var bits: M = @bitCast((v | spl_lower) == spl_first);
        while (bits != 0) {
            const j: usize = @ctz(bits);
            if (matchCI(haystack, i + j, needle)) return i + j;
            bits &= bits - 1;
        }
    }
    while (i < window_end) : (i += 1) {
        if (matchCI(haystack, i, needle)) return i;
    }
    return null;
}
fn findTokenCI(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    if (haystack.len - needle.len + 1 >= 16) return findTokenCISimd(haystack, needle);
    return findTokenCIScalar(haystack, needle);
}
fn findHeaderEnd(h: []const u8, from: usize) ?usize {
    if (h.len < 4 or from + 4 > h.len) return null;
    const N = simd.suggestVectorLength(u8) orelse 16;
    const V = @Vector(N, u8);
    const M = std.meta.Int(.unsigned, N);
    const spl_lf: V = @splat('\n');
    var i: usize = @max(from + 3, 3);
    while (i < h.len) {
        const chunk_end = @min(i + N, h.len);
        if (chunk_end - i >= N) {
            const v: V = h[i..][0..N].*;
            var bits: M = @bitCast(v == spl_lf);
            while (bits != 0) {
                const off: usize = @ctz(bits);
                bits &= bits - 1;
                const p = i + off;
                if (p >= 3 and h[p - 3] == '\r' and h[p - 2] == '\n' and h[p - 1] == '\r') return p - 3;
            }
            i += N;
        } else {
            while (i < chunk_end) : (i += 1) {
                if (h[i] == '\n' and h[i - 3] == '\r' and h[i - 2] == '\n' and h[i - 1] == '\r') return i - 3;
            }
        }
    }
    return null;
}
fn classifyMethod(s: []const u8) Method {
    if (s.len == 3) {
        if (s[0] == 'G' and s[1] == 'E' and s[2] == 'T') return .get;
        if (s[0] == 'P' and s[1] == 'U' and s[2] == 'T') return .put;
    } else if (s.len == 4) {
        if (s[0] == 'P' and s[1] == 'O' and s[2] == 'S' and s[3] == 'T') return .post;
        if (s[0] == 'H' and s[1] == 'E' and s[2] == 'A' and s[3] == 'D') return .head;
    } else if (s.len == 5) {
        if (s[0] == 'P' and s[1] == 'A' and s[2] == 'T' and s[3] == 'C' and s[4] == 'H') return .patch;
    } else if (s.len == 6) {
        // FIX: "DELETE" is exactly 6 bytes (indices 0..5) — the old code read
        // s[6] here (OOB: panics in safe builds, silent `.none` in ReleaseFast).
        if (s[0] == 'D' and s[1] == 'E' and s[2] == 'L' and s[3] == 'E' and s[4] == 'T' and s[5] == 'E') return .delete;
    } else if (s.len == 7) {
        if (s[0] == 'O' and s[1] == 'P' and s[2] == 'T' and s[3] == 'I' and s[4] == 'O' and s[5] == 'N' and s[6] == 'S') return .options;
    }
    return .none;
}
fn parseRequest(buf: []const u8, headers_end: usize) ParsedRequest {
    var pr = ParsedRequest{ .method = "", .method_tag = .none, .url = "", .content_length = 0, .keep_alive = true };
    const region = buf[0..headers_end];
    if (region.len < 10) return pr;
    const sp1 = std.mem.indexOfScalar(u8, region, ' ') orelse return pr;
    if (sp1 + 1 >= region.len) return pr;
    const sp2 = std.mem.indexOfScalarPos(u8, region, sp1 + 1, ' ') orelse return pr;
    pr.method = region[0..sp1];
    pr.method_tag = classifyMethod(pr.method);
    pr.url = region[sp1 + 1 .. sp2];
    const proto_full = region[sp2 + 1 ..];
    var plen: usize = 0;
    while (plen < proto_full.len and proto_full[plen] != '\r' and proto_full[plen] != '\n') plen += 1;
    const proto = proto_full[0..plen];
    const is_11 = std.mem.endsWith(u8, proto, "HTTP/1.1");
    var has_close = false;
    var has_keepalive = false;
    var i: usize = sp2 + 1;
    while (i < region.len) {
        while (i < region.len and (region[i] == '\r' or region[i] == '\n')) : (i += 1) {}
        if (i >= region.len) break;
        const line_start = i;
        while (i < region.len and region[i] != '\r' and region[i] != '\n') : (i += 1) {}
        const hline = region[line_start..i];
        if (ciStartsWith(hline, "connection:")) {
            const val = hline["connection:".len..];
            if (!has_close and ciListHas(val, "close")) has_close = true;
            if (!has_keepalive and ciListHas(val, "keep-alive")) has_keepalive = true;
        } else if (pr.content_length == 0 and ciStartsWith(hline, "content-length:")) {
            const val = hline["content-length:".len..];
            var s: usize = 0;
            while (s < val.len and (val[s] == ' ' or val[s] == '\t')) s += 1;
            var e = s;
            while (e < val.len and val[e] >= '0' and val[e] <= '9') e += 1;
            if (e > s) pr.content_length = std.fmt.parseInt(usize, val[s..e], 10) catch 0;
        }
    }
    pr.keep_alive = if (is_11) !has_close else has_keepalive;
    return pr;
}
fn statusReason(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        301 => "Moved Permanently",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Payload Too Large",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        else => "Unknown",
    };
}
fn pushStr(w: []u8, pos: *usize, s: []const u8) void {
    @memcpy(w[pos.*..][0..s.len], s);
    pos.* += s.len;
}
fn appendUInt(w: []u8, pos: *usize, value: usize) void {
    var buf: [20]u8 = undefined;
    var n: usize = 0;
    var v = value;
    if (v == 0) {
        buf[0] = '0';
        n = 1;
    } else {
        while (v > 0) : (v /= 10) {
            buf[n] = @as(u8, @intCast('0' + v % 10));
            n += 1;
        }
        std.mem.reverse(u8, buf[0..n]);
    }
    @memcpy(w[pos.* ..][0..n], buf[0..n]);
    pos.* += n;
}
fn wantsBodyBytes(id: usize, status: u16) bool {
    return methods[id] != .head and status != 204 and status != 304;
}
fn formatResponseHeader(w: []u8, status: u16, content_length: ?usize, keep_alive: bool) usize {
    var pos: usize = 0;
    pushStr(w, &pos, "HTTP/1.1 ");
    appendUInt(w, &pos, status);
    pushStr(w, &pos, " ");
    pushStr(w, &pos, statusReason(status));
    pushStr(w, &pos, "\r\n");
    pushStr(w, &pos, "Content-Type: text/plain\r\n");
    if (content_length) |n| {
        pushStr(w, &pos, "Content-Length: ");
        appendUInt(w, &pos, n);
        pushStr(w, &pos, "\r\n");
    }
    if (keep_alive) pushStr(w, &pos, "Connection: keep-alive\r\n");
    pushStr(w, &pos, "\r\n");
    return pos;
}
fn buildResponse(id: usize, status: u16, body: []const u8) void {
    const suppress = !wantsBodyBytes(id, status);
    const cl: ?usize = if (status == 204 or status == 304) null else body.len;
    const w: *[WRITE_BUF_SIZE]u8 = &write_bufs[id];
    var pos = formatResponseHeader(w[0..], status, cl, cflags[id].keep_alive);
    if (!suppress and body.len > 0 and pos + body.len <= WRITE_BUF_SIZE) {
        @memcpy(w[pos..][0..body.len], body);
        pos += body.len;
    }
    write_lens[id] = pos;
}

// ── TLS (https/wss) helpers ─────────────────────────────────────────
// Plain path: kernel reads/writes hit read_bufs/write_bufs directly.
// TLS path:   kernel <-> BearSSL engine; plaintext flows via read_bufs/write_bufs.

pub fn enableTls() void {
    if (tls_on) tls_active = tls_mod.ready();
}

fn armRead(id: usize, l: *xev.Loop) void {
    if (tls_on and cflags[id].tls) {
        // Kernel may write ciphertext straight into the engine's landing buffer.
        const sp = tls_mod.recvRecSpace(&tls_ctxs[id]);
        if (sp.len == 0) return;
        states[id] = .reading;
        fds[id].read(l, &read_comps[id], .{ .slice = sp }, u16, &slot_ids[id], readCb);
        return;
    }
    states[id] = .reading;
    fds[id].read(l, &read_comps[id], .{ .slice = read_bufs[id][buf_lens[id]..] }, u16, &slot_ids[id], readCb);
}

fn armWrite(id: usize, l: *xev.Loop) void {
    if (tls_on and cflags[id].tls) {
        // Feed staged plaintext into the engine, then write ciphertext.
        var fed: usize = 0;
        while (write_lens[id] > fed) {
            const got = tls_mod.sendAppFeed(&tls_ctxs[id], write_bufs[id][fed..write_lens[id]]);
            if (got == 0) break;
            fed += got;
        }
        if (fed < write_lens[id]) {
            const rem = write_lens[id] - fed;
            @memmove(write_bufs[id][0..rem], write_bufs[id][fed..write_lens[id]]);
            write_lens[id] = rem;
        } else {
            write_lens[id] = 0;
        }
        write_offsets[id] = 0;
        tls_mod.flush(&tls_ctxs[id]);
        const out = tls_mod.sendRecReady(&tls_ctxs[id]);

        if (out.len == 0) return;
        states[id] = .writing;
        fds[id].write(l, &write_comps[id], .{ .slice = out }, u16, &slot_ids[id], writeCb);
        return;
    }
    states[id] = .writing;
    fds[id].write(l, &write_comps[id], .{ .slice = write_bufs[id][write_offsets[id]..write_lens[id]] }, u16, &slot_ids[id], writeCb);
}

/// Drive the BearSSL engine. br_ssl_engine_current_state() returns a BITMASK
/// (flags combine; verified in bearssl_ssl.h), so check every applicable flag
/// each pass, in BearSSL's documented priority: SENDREC > RECVAPP > SENDAPP > RECVREC.
/// Called from readCb (after recvRecAck) and from writeCb (after ciphertext drained).
fn tlsPump(id: usize, l: *xev.Loop) void {
    var spins: u8 = 0;
    while (spins < 32) : (spins += 1) {
        const st = tls_mod.curState(&tls_ctxs[id]);
        if (st & tls_mod.ST_CLOSED != 0) {
            closeConn(id);
            return;
        }
        // 1) Ciphertext ready for the kernel: write it (writeCb acks + re-pumps).
        if (st & tls_mod.ST_SENDREC != 0) {
            const out = tls_mod.sendRecReady(&tls_ctxs[id]);
            if (out.len > 0) {
                states[id] = .writing;
                fds[id].write(l, &write_comps[id], .{ .slice = out }, u16, &slot_ids[id], writeCb);
                return;
            }
        }
        // 2) Decrypted app data: stage into read_bufs, keep looping.
        if (st & tls_mod.ST_RECVAPP != 0) {
            const app = tls_mod.recvAppReady(&tls_ctxs[id]);
            if (app.len > 0) {
                if (buf_lens[id] + app.len > READ_BUF_SIZE) {
                    closeConn(id);
                    return;
                }
                @memcpy(read_bufs[id][buf_lens[id]..][0..app.len], app);
                buf_lens[id] += app.len;
                tls_mod.recvAppAck(&tls_ctxs[id], app.len);
                continue;
            }
        }
        // 3) Engine accepts plaintext: feed staged response data.
        if (st & tls_mod.ST_SENDAPP != 0 and write_lens[id] > 0) {
            armWrite(id, l);
            return;
        }
        // 4) Engine wants ciphertext: process buffered plaintext first, else read.
        if (st & tls_mod.ST_RECVREC != 0 and tls_mod.recvRecSpace(&tls_ctxs[id]).len > 0) {
            if (buf_lens[id] > 0) {
                processPlaintext(id, l);
                return;
            }
            if (cflags[id].ws_open) armReadId(id, l) else armRead(id, l);
            return;
        }
        return; // nothing actionable — wait for a kernel op to complete
    }
}

fn hardClose(id: usize) void {
    states[id] = .closing;
    const loop = g_loop orelse {
        states[id] = .idle;
        freePush(id);
        return;
    };
    fds[id].close(loop, &close_comps[id], u16, &slot_ids[id], closeCb);
}

fn extractInt(ctx: ?*c.Context, val: c.Value, default: u16) u16 {
    if (c.isUndefined(val) != 0 or c.isNull(val) != 0) return default;
    var out: i32 = 0;
    if (c.toInt32(ctx, &out, val) == -1) return default;
    return @intCast(out);
}




fn nowMs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @intCast(@as(i64, ts.sec) * std.time.ms_per_s + @divTrunc(ts.nsec, std.time.ns_per_ms));
}

fn isManagedHeader(name: []const u8) bool {
    // Length/hop-by-hop framing is computed by the server, never taken from JS.
    return std.ascii.eqlIgnoreCase(name, "content-length") or
        std.ascii.eqlIgnoreCase(name, "transfer-encoding") or
        std.ascii.eqlIgnoreCase(name, "connection");
}

fn printException(ctx: ?*c.Context, exc: c.Value) void {
    if (ctx == null) return;
    const msg = c.toCString(ctx, exc) orelse return;
    defer c.freeCString(ctx, msg);
    std.debug.print("[http] handler error: {s}\n", .{msg});
}

// DOD-FIX 3: chunked large-body write helper. The caller has already
// formatted the header block into write_bufs[id] (write_lens[id] = header
// length); writeCb drains WRITE_BUF_SIZE chunks from body_bufs afterwards.
fn stageLargeResponse(id: usize, header_len: usize, body_ptr: [*]const u8, blen: usize) void { // CHANGED signature
    write_lens[id] = header_len;
    write_offsets[id] = 0;
    @memcpy(body_bufs[id][0..blen], body_ptr[0..blen]);
    body_lens[id] = blen; // total staged body size
    body_remaining[id] = blen; // bytes not yet copied into write_bufs
    body_source_off[id] = 0; // read cursor into body_bufs
}

// NEW: shared response staging — used by the sync path and the parked
// continuation. Reads Response objects natively (opaque pointer, no JS
// property lookups), plain objects via properties (back-compat). User
// headers serialize straight into write_bufs — zero dynamic allocations.
fn stageHandlerResponse(id: usize, result: c.Value) void {
    const ctx = handler_ctx orelse {
        buildResponse(id, 500, "Internal Server Error");
        return;
    };

    var status: u16 = 200;
    var status_text: []const u8 = "";
    var body_bytes: []const u8 = "";
    var has_body = false;
    var hdrs: ?*headers_mod.HeadersData = null;

    if (c.isObject(result) != 0) {
        if (response_mod.dataFromJS(ctx, result)) |rd| {
            status = rd.status;
            status_text = rd.statusText();
            if (rd.body()) |b| {
                body_bytes = b;
                has_body = true;
            }
            hdrs = rd.headers;
        } else {
            // Plain JS object fallback: { status, body }.
            const status_val = c.getPropertyStr(ctx, result, "status");
            defer c.freeValue(ctx, status_val);
            status = extractInt(ctx, status_val, 200);
            const body_out_val = c.getPropertyStr(ctx, result, "body");
            defer c.freeValue(ctx, body_out_val);
            if (c.isString(body_out_val) != 0) {
                if (c.toCString(ctx, body_out_val)) |cstr| {
                    defer c.freeCString(ctx, cstr);
                    const n = std.mem.len(cstr);
                    if (n > 0) {
                        body_bytes = cstr[0..n];
                        has_body = true;
                    }
                }
            } else if (c.isObject(body_out_val) != 0) {
                var size: usize = 0;
                const p = c.getArrayBuffer(ctx, &size, body_out_val);
                if (p != null and size > 0) {
                    body_bytes = p[0..size];   // was: p.?[0..size]
                    has_body = true;
                }
            }        }
    }

    const suppress = !wantsBodyBytes(id, status);
    if (has_body and !suppress and body_bytes.len > BODY_BUF_SIZE) {
        buildResponse(id, 500, "response body too large");
        return;
    }

    const w: *[WRITE_BUF_SIZE]u8 = &write_bufs[id];
    var pos: usize = 0;

    // Status line.
    pushStr(w, &pos, "HTTP/1.1 ");
    appendUInt(w, &pos, status);
    pushStr(w, &pos, " ");
    if (status_text.len > 0 and std.mem.indexOfAny(u8, status_text, "\r\n") == null) {
        pushStr(w, &pos, status_text);
    } else {
        pushStr(w, &pos, statusReason(status));
    }
    pushStr(w, &pos, "\r\n");

    // User headers from the Response's HeadersData (already lowercased).
    // Drop CR/LF-bearing pairs (header-injection guard).
    var seen_ct = false;
    if (hdrs) |h| {
        for (0..h.len()) |i| {
            const p = h.getPair(i);
            if (isManagedHeader(p.name)) continue;
            if (std.mem.indexOfAny(u8, p.name, "\r\n") != null or
                std.mem.indexOfAny(u8, p.value, "\r\n") != null) continue;
            if (std.ascii.eqlIgnoreCase(p.name, "content-type")) seen_ct = true;
            if (pos + p.name.len + p.value.len + 4 > HDR_MAX) break; // budget: drop the rest
            pushStr(w, &pos, p.name);
            pushStr(w, &pos, ": ");
            pushStr(w, &pos, p.value);
            pushStr(w, &pos, "\r\n");
        }
    }
    // Back-compat default content type only when JS gave none.
    if (!seen_ct and has_body and !suppress) {
        pushStr(w, &pos, "Content-Type: text/plain\r\n");
    }
    if (status != 204 and status != 304) {
        pushStr(w, &pos, "Content-Length: ");
        appendUInt(w, &pos, body_bytes.len);
        pushStr(w, &pos, "\r\n");
    }
    if (cflags[id].keep_alive) pushStr(w, &pos, "Connection: keep-alive\r\n");
    pushStr(w, &pos, "\r\n");

    write_lens[id] = pos;
    write_offsets[id] = 0;
    body_lens[id] = 0;
    body_remaining[id] = 0;
    body_source_off[id] = 0;

    if (suppress or !has_body or body_bytes.len == 0) return;

    if (pos + body_bytes.len <= WRITE_BUF_SIZE) {
        @memcpy(w[pos..][0..body_bytes.len], body_bytes);
        write_lens[id] = pos + body_bytes.len;
    } else {
        stageLargeResponse(id, pos, body_bytes.ptr, body_bytes.len);
    }
}

// NEW: park-and-resume machinery ─────────────────────────────────────

/// Claim a parked slot from a reaction's packed magic. Returns null when the
/// connection was closed or the slot was reused (generation mismatch).
fn claimParkedSlot(magic: c_int) ?usize {
    const m: u32 = @bitCast(magic);
    const id: usize = @intCast(m & 0x1FF);
    const gen: u16 = @intCast((m >> 9) & 0x3F);
    if (id >= MAX_CONN) return null;
    if (slot_gen[id] & 0x3F != gen) return null;
    if (!cflags[id].handler_parked) return null;
    return id;
}

fn completeParked(magic: c_int, argc: c_int, argv: [*c]c.Value, rejected: bool) c.Value {
    const id = claimParkedSlot(magic) orelse return c.JS_UNDEFINED;
    cflags[id].handler_parked = false;
    parked_since_ms[id] = 0;

    const val: c.Value = if (argc > 0) argv[0] else c.JS_UNDEFINED;
    if (rejected) {
        printException(handler_ctx, val);
        buildResponse(id, 500, "Internal Server Error");
    } else {
        stageHandlerResponse(id, val);
    }
    if (g_loop) |l| {
        states[id] = .writing;
        armWrite(id, l);
    } else {
        closeConn(id);
    }
    return c.JS_UNDEFINED;
}

fn handlerFulfilledCb(
    _: ?*c.Context,
    _: c.Value,
    argc: c_int,
    argv: [*c]c.Value,
    magic: c_int,
) callconv(.c) c.Value {
    return completeParked(magic, argc, argv, false);
}

fn handlerRejectedCb(
    _: ?*c.Context,
    _: c.Value,
    argc: c_int,
    argv: [*c]c.Value,
    magic: c_int,
) callconv(.c) c.Value {
    return completeParked(magic, argc, argv, true);
}

/// Attach onFulfilled/onRejected to a pending handler promise. Zero
/// allocations on the Zig side: the slot id + generation travel in the
/// C-function magic (i32), continuations live in the slot columns.
fn parkHandler(id: usize, ctx: ?*c.Context, promise: c.Value) bool {
    // QuickJS stores C-function magic in int16_t — keep the packed value
    // within 15 bits: slot (9 bits, MAX_CONN=512) | generation (6 bits).
    const magic: i32 = @bitCast(@as(u32, @intCast(id & 0x1FF)) |
        (@as(u32, slot_gen[id] & 0x3F) << 9));
    const ok_fn = c.newCFunctionMagic(ctx, &handlerFulfilledCb, "", 1, c.JS_CFUNC_generic_magic, magic);
    const err_fn = c.newCFunctionMagic(ctx, &handlerRejectedCb, "", 1, c.JS_CFUNC_generic_magic, magic);
    defer c.freeValue(ctx, ok_fn);
    defer c.freeValue(ctx, err_fn);
    if (c.isException(ok_fn) != 0 or c.isException(err_fn) != 0) {
        const exc = c.getException(ctx);
        printException(ctx, exc);
        c.freeValue(ctx, exc);
        return false;
    }
    const then_atom = c.newAtomLen(ctx, "then", 4);
    defer c.freeAtom(ctx, then_atom);
    var then_argv = [_]c.Value{ ok_fn, err_fn };
    const then_result = c.invoke(ctx, promise, then_atom, 2, &then_argv);
    defer c.freeValue(ctx, then_result);
    if (c.isException(then_result) != 0) {
        const exc = c.getException(ctx);
        printException(ctx, exc);
        c.freeValue(ctx, exc);
        return false;
    }
    cflags[id].handler_parked = true;
    parked_since_ms[id] = nowMs();
    return true;
}
// CHANGED: callHandler — removes the dead tag==7 spin; detects promises via
// the one-time class-id probe; parks pending promises; unwraps settled ones.
fn callHandler(id: usize, parsed: *const ParsedRequest, body: []const u8) void {
    const ctx = handler_ctx orelse {
        buildResponse(id, 500, "");
        return;
    };
    const handler = handler_fn orelse {
        buildResponse(id, 500, "");
        return;
    };
    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);

    const url_val = c.newStringLen(ctx, parsed.url.ptr, @intCast(parsed.url.len));
    const method_val = c.newStringLen(ctx, parsed.method.ptr, @intCast(parsed.method.len));
    const body_val = if (body.len > 0)
        c.newStringLen(ctx, body.ptr, @intCast(body.len))
    else
        c.newStringLen(ctx, "", 0);
    defer c.freeValue(ctx, url_val);
    defer c.freeValue(ctx, method_val);
    defer c.freeValue(ctx, body_val);

    var argv = [_]c.Value{ url_val, method_val, body_val };
    var result = c.call(ctx, handler, global, 3, &argv);
    defer c.freeValue(ctx, result);

    if (c.isException(result) != 0) {
        const exc = c.getException(ctx);
        printException(ctx, exc);
        c.freeValue(ctx, exc);
        buildResponse(id, 500, "Internal Server Error");
        return;
    }

    if (promise_class_id != 0 and c.isObject(result) != 0 and
        c.getClassID(result) == promise_class_id)
    {
        const ps = c.promiseState(ctx, result);

        if (ps == 0) {
            // Pending: park the connection; the promise's `then` reactions
            // resume staging + writing from the event loop (or watchdog).
            if (parkHandler(id, ctx, result)) {
                if (builtin.mode == .Debug)
                    std.debug.print("[allocs] req id={d}: parked\n", .{id});
                return;
            }
            buildResponse(id, 500, "Internal Server Error");
            return;
        }
        if (ps == 2) {
            // Rejected.
            const pr = c.promiseResult(ctx, result);
            c.freeValue(ctx, result);
            result = pr;
            printException(ctx, pr);
            buildResponse(id, 500, "Internal Server Error");
            return;
        }
        // Fulfilled synchronously: unwrap and stage without an event-loop
        // roundtrip (keeps the hot path allocation-free and fast).
        const pr = c.promiseResult(ctx, result);
        c.freeValue(ctx, result);
        result = pr;
    }

    stageHandlerResponse(id, result);
}

pub const ws_class_id_val: c.ClassID = 0;

fn wsSocket(id: usize, ctx: ?*c.Context) ?c.Value {
    if (ws_sockets[id]) |v| return v;
    const obj = api_ws.makeSocket(ctx, @intCast(id)) orelse return null;
    ws_sockets[id] = obj;
    return obj;
}

fn wsNotify(id: usize, which: ?c.Value, argc: u32) void {
    const ctx = handler_ctx orelse return;
    const cb = which orelse return;
    if (c.isFunction(ctx, cb) == 0) return;
    const sock = wsSocket(id, ctx) orelse return;
    if (argc == 1) {
        var argv = [_]c.Value{sock};
        _ = c.call(ctx, cb, c.JS_UNDEFINED, 1, &argv);
    } else if (argc == 2) {
        var argv = [_]c.Value{ sock, sock };
        _ = c.call(ctx, cb, c.JS_UNDEFINED, 2, &argv);
    }
}

/// Copy `bytes` into a fresh JS Uint8Array view (binary WS messages arrive
/// as Uint8Array — matches every example in examples/ and Node's ws).
fn u8ArrayFromBytes(ctx: ?*c.Context, bytes: []const u8) c.Value {
    const ab = c.newArrayBufferCopy(ctx, bytes.ptr, bytes.len);
    if (c.getTag(ab) == c.TAG_EXCEPTION) return ab;
    defer c.freeValue(ctx, ab);
    // JS_NewTypedArray implements the 3-arg constructor form: with an
    // ArrayBuffer as argv[0] it unconditionally reads argv[1] (offset) and
    // argv[2] (length) — passing argc=1 reads out of bounds and yields a
    // zero-length view. Pass all three args explicitly.
    var argv = [_]c.Value{
        ab,
        c.newInt32(ctx, 0),
        c.newInt32(ctx, @intCast(bytes.len)),
    };
    return c.newTypedArray(ctx, 3, &argv, c.JS_TYPED_ARRAY_UINT8);
}

fn wsNotifyMessage(id: usize, msg: []const u8, binary: bool) void {
    const ctx = handler_ctx orelse return;
    const cb = ws_on_message orelse return;
    if (c.isFunction(ctx, cb) == 0) return;
    const sock = wsSocket(id, ctx) orelse return;
    const data_val = if (binary)
        u8ArrayFromBytes(ctx, msg)
    else
        c.newStringLen(ctx, msg.ptr, @intCast(msg.len));
    defer c.freeValue(ctx, data_val);
    var argv = [_]c.Value{ sock, data_val };
    _ = c.call(ctx, cb, c.JS_UNDEFINED, 2, &argv);
}

pub fn wsSendTextUtf8(id: usize, str_val: c.Value, ctx: ?*c.Context) void {
    const s = str_val;
    if (!cflags[id].ws_open or states[id] == .closing) return;
    const cstr = c.toCString(ctx, s) orelse return;
    defer c.freeCString(ctx, cstr);
    const ulen = std.mem.len(cstr);
    if (ulen == 0) return;
    if (ulen > ws.WS_MSG_SIZE) {
        wsSendClose(id, 1009);
        return;
    }
    if (!cflags[id].ws_writing) {
        write_lens[id] = 0;
        write_offsets[id] = 0;
        ws_batch[id] = 0;
    }
    const tail = write_lens[id];
    const need = @as(usize, ws.MAX_HDR) + ulen;
    if (tail + need > WRITE_BUF_SIZE) return;
    const buf = write_bufs[id][tail..];
    @memcpy(buf[ws.MAX_HDR..][0..ulen], cstr[0..ulen]);
    const hlen = ws.buildHeader(buf, ws.OP_TEXT, true, ulen);
    if (hlen != ws.MAX_HDR) @memmove(buf[hlen..][0..ulen], buf[ws.MAX_HDR..][0..ulen]);
    write_lens[id] = tail + hlen + ulen;
    if (!cflags[id].ws_writing) wsKick(id);
}

pub fn wsSendBinary(id: usize, bytes: []const u8) void {
    if (!cflags[id].ws_open or states[id] == .closing) return;
    if (bytes.len > ws.WS_MSG_SIZE) {
        wsSendClose(id, 1009);
        return;
    }
    if (!cflags[id].ws_writing) {
        write_lens[id] = 0;
        write_offsets[id] = 0;
        ws_batch[id] = 0;
    }
    const tail = write_lens[id];
    const need = @as(usize, ws.MAX_HDR) + bytes.len;
    if (tail + need > WRITE_BUF_SIZE) return;
    const buf = write_bufs[id][tail..];
    @memcpy(buf[ws.MAX_HDR..][0..bytes.len], bytes);
    const hlen = ws.buildHeader(buf, ws.OP_BINARY, true, bytes.len);
    if (hlen != ws.MAX_HDR) @memmove(buf[hlen..][0..bytes.len], buf[ws.MAX_HDR..][0..bytes.len]);
    write_lens[id] = tail + hlen + bytes.len;
    if (!cflags[id].ws_writing) wsKick(id);
}

pub fn wsSendClose(id: usize, code: u16) void {
    if (states[id] == .closing) return;
    if (!cflags[id].ws_open) {
        closeConn(id);
        return;
    }
    if (!cflags[id].ws_writing) {
        write_lens[id] = 0;
        write_offsets[id] = 0;
        ws_batch[id] = 0;
    }
    var payload: [2]u8 = undefined;
    payload[0] = @intCast(code >> 8);
    payload[1] = @intCast(code & 0xff);
    const tail = write_lens[id];
    const buf = write_bufs[id][tail..];
    @memcpy(buf[ws.MAX_HDR..][0..2], &payload);
    const hlen = ws.buildHeader(buf, ws.OP_CLOSE, true, 2);
    if (hlen != ws.MAX_HDR) @memmove(buf[hlen..][0..2], buf[ws.MAX_HDR..][0..2]);
    write_lens[id] = tail + hlen + 2;
    cflags[id].ws_close_after_write = true;
    if (!cflags[id].ws_writing) wsKick(id);
}

fn wsSendCloseEcho(id: usize, payload: []const u8) void {
    if (states[id] == .closing) return;
    if (!cflags[id].ws_writing) {
        write_lens[id] = 0;
        write_offsets[id] = 0;
        ws_batch[id] = 0;
    }
    const plen = @min(payload.len, @as(usize, 2));
    const tail = write_lens[id];
    const buf = write_bufs[id][tail..];
    @memcpy(buf[ws.MAX_HDR..][0..plen], payload[0..plen]);
    const hlen = ws.buildHeader(buf, ws.OP_CLOSE, true, plen);
    if (hlen != ws.MAX_HDR) @memmove(buf[hlen..][0..plen], buf[ws.MAX_HDR..][0..plen]);
    write_lens[id] = tail + hlen + plen;
    cflags[id].ws_close_after_write = true;
    if (!cflags[id].ws_writing) wsKick(id);
}

fn wsSendPong(id: usize, payload: []const u8) void {
    if (!cflags[id].ws_writing) {
        write_lens[id] = 0;
        write_offsets[id] = 0;
        ws_batch[id] = 0;
    }
    const plen = @min(payload.len, @as(usize, ws.WS_MSG_SIZE));
    const tail = write_lens[id];
    if (tail + @as(usize, ws.MAX_HDR) + plen > WRITE_BUF_SIZE) return;
    const buf = write_bufs[id][tail..];
    @memcpy(buf[ws.MAX_HDR..][0..plen], payload[0..plen]);
    const hlen = ws.buildHeader(buf, ws.OP_PONG, true, plen);
    if (hlen != ws.MAX_HDR) @memmove(buf[hlen..][0..plen], buf[ws.MAX_HDR..][0..plen]);
    write_lens[id] = tail + hlen + plen;
    if (!cflags[id].ws_writing) wsKick(id);
}

// DOD-FIX 4: ws_partial is now a static per-slot byte array (no heap pointer).
fn wsHandleData(id: usize, hdr: ws.FrameHdr, payload: []const u8) bool {
    if (ws.isData(hdr.opcode)) {
        if (ws_partial_len[id] != 0) {
            wsSendClose(id, 1002);
            return false;
        }
        if (hdr.fin) {
            wsNotifyMessage(id, payload, hdr.opcode == ws.OP_BINARY);
            return true;
        }
        if (payload.len > ws.WS_MSG_SIZE) {
            wsSendClose(id, 1009);
            return false;
        }
    wsSetPartialBinary(id, hdr.opcode == ws.OP_BINARY);
        @memcpy(ws_partial[id][0..payload.len], payload);
        ws_partial_len[id] = payload.len;
        return true;
    }
    if (ws_partial_len[id] == 0) {
        wsSendClose(id, 1002);
        return false;
    }
    if (ws_partial_len[id] + payload.len > ws.WS_MSG_SIZE) {
        wsSendClose(id, 1009);
        return false;
    }
    @memcpy(ws_partial[id][ws_partial_len[id]..][0..payload.len], payload);
    ws_partial_len[id] += payload.len;
    if (hdr.fin) {
        wsNotifyMessage(id, ws_partial[id][0..ws_partial_len[id]], wsPartialBinary(id));
        ws_partial_len[id] = 0;
    }
    return true;
}

fn wsConsume(id: usize, l: *xev.Loop) void {

    var leftover = read_bufs[id][0..buf_lens[id]];
    while (leftover.len > 0) {
        const hdr = ws.parseHeader(leftover) orelse break;
        if (hdr.payload_len > ws.WS_MSG_SIZE and !ws.isControl(hdr.opcode)) {
            wsSendClose(id, 1009);
            return;
        }
        const total = @as(usize, hdr.header_len) + hdr.payload_len;
        if (leftover.len < total) break;
        const payload = leftover[hdr.header_len..total];
        ws.unmask(payload, hdr.mask);
        switch (hdr.opcode) {
            ws.OP_PING => wsSendPong(id, payload),
            ws.OP_PONG => {},
            ws.OP_CLOSE => {
                wsSendCloseEcho(id, payload);
                return;
            },
            else => {
                if (!wsHandleData(id, hdr, payload)) return;
            },
        }
        leftover = leftover[total..];
    }
    buf_lens[id] = leftover.len;
    if (leftover.len > 0) {
        @memmove(read_bufs[id][0..leftover.len], leftover);
    }
    if (states[id] == .reading and !cflags[id].ws_writing) armReadId(id, l);
}

fn wsNotifyOpen(id: usize) void {
    wsNotify(id, ws_on_open, 1);
}

fn wsNotifyClose(id: usize) void {
    wsNotify(id, ws_on_close, 1);
}

fn wsShutdown(id: usize) void {
    if (!cflags[id].ws_open) return;
    wsNotifyClose(id);            // <-- add the id argument
    if (ws_sockets[id]) |v| {
        c.freeValue(handler_ctx, v);
        ws_sockets[id] = null;
    }
    cflags[id].ws_open = false;
    ws_partial_len[id] = 0;
   wsSetPartialBinary(id, false);
    cflags[id].ws_close_after_write = false;
    cflags[id].ws_writing = false;
}

fn tryUpgrade(id: usize, l: *xev.Loop, kpos: usize, headers_end: usize, pr: *const ParsedRequest) void {
    const total = buf_lens[id];
    var start = kpos + "sec-websocket-key:".len;
    while (start < total and (read_bufs[id][start] == ' ' or read_bufs[id][start] == '\t')) start += 1;
    var end = start;
    while (end < total and read_bufs[id][end] != '\r' and read_bufs[id][end] != '\n') end += 1;
    if (end == start) {
        buildResponse(id, 400, "Bad Request");
        states[id] = .writing;
        armWrite(id, l);
        return;
    }
    const key = read_bufs[id][start..end];
    var accept: [28]u8 = undefined;
    ws.computeAccept(key, &accept);
    const w: *[WRITE_BUF_SIZE]u8 = &write_bufs[id];
    var pos: usize = 0;
    pushStr(w, &pos, "HTTP/1.1 101 Switching Protocols\r\n");
    pushStr(w, &pos, "Upgrade: websocket\r\n");
    pushStr(w, &pos, "Connection: Upgrade\r\n");
    pushStr(w, &pos, "Sec-WebSocket-Accept: ");
    @memcpy(w[pos..][0..28], &accept);
    pos += 28;
    pushStr(w, &pos, "\r\n\r\n");
    write_lens[id] = pos;
    const consumed = headers_end + pr.content_length;
    const rest = buf_lens[id] - consumed;
    if (rest > 0) @memmove(read_bufs[id][0..rest], read_bufs[id][consumed..buf_lens[id]]);
    buf_lens[id] = rest;
    hdr_scan_off[id] = 0;
    cflags[id].ws_open = true;
    cflags[id].ws_writing = true;
    cflags[id].ws_close_after_write = false;
    cflags[id].ws_pending_open = true;
    ws_partial_len[id] = 0;
    wsSetPartialBinary(id, false);
    states[id] = .writing;
    write_offsets[id] = 0;
    ws_batch[id] = write_lens[id];
    armWrite(id, l);
}

// CHANGED: clears parked state so a late continuation no-ops.
fn closeConn(id: usize) void {
    body_remaining[id] = 0;
    body_source_off[id] = 0;
    body_lens[id] = 0;
    cflags[id].handler_parked = false; // NEW
    parked_since_ms[id] = 0; // NEW
    wsShutdown(id);
    if (states[id] == .closing) return;
    if (tls_on and cflags[id].tls) {
        tls_mod.shutdown(&tls_ctxs[id]); // close_notify
        tls_mod.flush(&tls_ctxs[id]);
        const out = tls_mod.sendRecReady(&tls_ctxs[id]);
        if (out.len > 0) {
            states[id] = .closing;
            cflags[id].tls_close_after_write = true;
            const l = g_loop orelse {
                hardClose(id);
                return;
            };
            fds[id].write(l, &write_comps[id], .{ .slice = out }, u16, &slot_ids[id], writeCb);
            return;
        }
    }
    hardClose(id);
}

fn closeCb(
    ud: ?*u16,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    r: xev.CloseError!void,
) xev.CallbackAction {
    _ = r catch {};
    const raw = ud orelse return .disarm;
    const id: usize = @intCast(raw.*);
    states[id] = .idle;
    freePush(id);
    return .disarm;
}

// NEW: watchdog — one repeating timer (not from the 128-slot JS timer
// pool): scans parked slots and fails hung handlers with 504.
fn watchdogCb(
    _: ?*void,
    l: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch return .disarm;
    const now = nowMs();
    for (0..MAX_CONN) |id| {
        if (!cflags[id].handler_parked) continue;
        if (now -% parked_since_ms[id] < HANDLER_TIMEOUT_MS) continue;
        cflags[id].handler_parked = false;
        parked_since_ms[id] = 0;
        buildResponse(id, 504, "Gateway Timeout");
        states[id] = .writing;
        armWrite(id, l);
    }
    watchdog_timer.run(l, &watchdog_comp, WATCHDOG_INTERVAL_MS, void, null, watchdogCb);
    return .disarm;
}

// CHANGED: bumps generation, resets parked state (cflags reset below also
// clears handler_parked).
fn setupSlot(l: *xev.Loop, tcp: xev.TCP) bool {
    const id = freePop() orelse {
        _ = std.c.close(tcp.fd);
        return false;
    };
    fds[id] = tcp;
    slot_gen[id] +%= 1; // NEW
    parked_since_ms[id] = 0; // NEW
    const nodelay: c_int = 1;
    std.posix.setsockopt(
        tcp.fd,
        std.posix.IPPROTO.TCP,
        std.posix.TCP.NODELAY,
        std.mem.asBytes(&nodelay),
    ) catch {};
    states[id] = .reading;
    methods[id] = Method.none;
    buf_lens[id] = 0;
    req_consumed[id] = 0; // F4
    hdr_scan_off[id] = 0;
    write_lens[id] = 0;
    write_offsets[id] = 0;
    body_remaining[id] = 0;
    body_source_off[id] = 0;
    body_lens[id] = 0;
    cflags[id] = .{ .keep_alive = true, .ws_read_armed = true, .tls = tls_active };
    ws_partial_len[id] = 0;
    wsSetPartialBinary(id, false);
    if (tls_on and tls_active) tls_mod.slotInit(&tls_ctxs[id], &tls_iobufs[id]);
    armRead(id, l);
    return true;
}

fn acceptCb(
    _: ?*void,
    l: *xev.Loop,
    _: *xev.Completion,
    r: xev.AcceptError!xev.TCP,
) xev.CallbackAction {
    const first = r catch {
        listener_tcp.accept(l, &accept_comp, void, null, acceptCb);
        return .disarm;
    };
    var budget: usize = ACCEPT_BATCH;
    if (setupSlot(l, first)) budget -= 1;
    while (budget > 0) : (budget -= 1) {
        const rc = std.c.accept(listener_tcp.fd, null, null);
        if (std.posix.errno(rc) != .SUCCESS) break;
        const fd: std.posix.socket_t = @intCast(rc);
        if (!setupSlot(l, xev.TCP.initFd(fd))) break;
    }
    listener_tcp.accept(l, &accept_comp, void, null, acceptCb);
    return .disarm;
}

fn readCb(
    ud: ?*u16,
    l: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    _: xev.ReadBuffer,
    r: xev.ReadError!usize,
) xev.CallbackAction {
    const raw = ud orelse return .disarm;
    const id: usize = @intCast(raw.*);
    cflags[id].ws_read_armed = false;
    const n = r catch {
        closeConn(id);
        return .disarm;
    };
    if (n == 0) {
        closeConn(id);
        return .disarm;
    }
    if (tls_on and cflags[id].tls) {
        // Ciphertext landed in the engine buffer; ack and drive the engine.
        tls_mod.recvRecAck(&tls_ctxs[id], n);
        tlsPump(id, l);
        return .disarm;
    }
    buf_lens[id] += n;
    processPlaintext(id, l);
    return .disarm;
}

/// HTTP/WS state machine over bytes in read_bufs[0..buf_lens]
/// (plaintext for plain HTTP, decrypted app-data when TLS is active).
fn processPlaintext(id: usize, l: *xev.Loop) void {
    if (cflags[id].handler_parked) {
        // Parked: no pipelining, and leave the read DISARMED — re-arming
        // here while the continuation later writes would double-arm the
        // completion. A vanished client is caught on write or by the
        // watchdog.
        return;
    }
    if (cflags[id].ws_open) {
        wsConsume(id, l);
        return;
    }
    const scan_from = if (hdr_scan_off[id] > 3) hdr_scan_off[id] - 3 else 0;
    const he_found = findHeaderEnd(read_bufs[id][0..buf_lens[id]], scan_from);
    if (he_found == null) {
        hdr_scan_off[id] = buf_lens[id];
        if (buf_lens[id] >= READ_BUF_SIZE) {
            closeConn(id);
            return;
        }
        armRead(id, l);
        return;
    }
    const headers_end = he_found.? + 4;
    hdr_scan_off[id] = 0;
    const pr = parseRequest(read_bufs[id][0..buf_lens[id]], headers_end);
    methods[id] = pr.method_tag;
    if (ws_enabled) {
        if (findTokenCI(read_bufs[id][0..buf_lens[id]], "sec-websocket-key:")) |kpos| {
            tryUpgrade(id, l, kpos, headers_end, &pr);
            return;
        }
    }
    if (pr.method.len == 0) {
        buildResponse(id, 400, "Bad Request");
        states[id] = .writing;
        armWrite(id, l);
        return;
    }
    const expect = headers_end + pr.content_length;
    if (expect > READ_BUF_SIZE) {
        buildResponse(id, 413, "Payload Too Large");
        states[id] = .writing;
        armWrite(id, l);
        return;
    }
    req_consumed[id] = expect; // F4: remember the consumed span for keep-alive
    if (buf_lens[id] < expect) {
        armRead(id, l);
        return;
    }
    cflags[id].keep_alive = pr.keep_alive;
    if (native_echo) {
        buildResponse(id, 200, "{\"message\":\"ok\"}");
    } else {
        const body = read_bufs[id][headers_end .. headers_end + pr.content_length];
        callHandler(id, &pr, body);
    }
    if (!cflags[id].handler_parked) {
        states[id] = .writing;
        armWrite(id, l);
    } else {
        // Parked: read stays disarmed; writeCb re-arms it after the
        // continuation's write completes.
        states[id] = .reading;
    }
}

// F4: keep-alive re-arm that preserves pipelined bytes. The finished request
// consumed read_bufs[0..req_consumed]; bytes beyond it belong to the next
// pipelined request and must survive (the old code zeroed buf_lens and
// re-read from offset 0, silently discarding them). Mirrors the WS leftover
// handling in wsConsume.
fn keepAlivePreserve(id: usize) void {
    const leftover = read_bufs[id][req_consumed[id]..buf_lens[id]];
    @memmove(read_bufs[id][0..leftover.len], leftover);
    buf_lens[id] = leftover.len;
    req_consumed[id] = 0;
    hdr_scan_off[id] = 0;
}

fn keepAliveRearm(id: usize, l: *xev.Loop) void {
    keepAlivePreserve(id);
    states[id] = .reading;
    if (buf_lens[id] > 0) {
        // A complete pipelined request may already be buffered: drive it now
        // with NO read armed (processPlaintext arms its own write). Falling
        // through to armRead here as well would double-arm the completion.
        if (findHeaderEnd(read_bufs[id][0..buf_lens[id]], 0)) |he| {
            const headers_end = he + 4;
            const pr = parseRequest(read_bufs[id][0..buf_lens[id]], headers_end);
            if (pr.method.len == 0 or buf_lens[id] >= headers_end + pr.content_length) {
                processPlaintext(id, l);
                return;
            }
        }
    }
    armRead(id, l);
}

fn writeCb(
    ud: ?*u16,
    l: *xev.Loop,
    _: *xev.Completion,
    tcp: xev.TCP,
    _: xev.WriteBuffer,
    r: xev.WriteError!usize,
) xev.CallbackAction {
    const raw = ud orelse return .disarm;
    const id: usize = @intCast(raw.*);
    const written = r catch {
        closeConn(id);
        return .disarm;
    };

    if (tls_on and cflags[id].tls) {
        tls_mod.sendRecAck(&tls_ctxs[id], written);
        const out = tls_mod.sendRecReady(&tls_ctxs[id]);
        if (out.len > 0) {
            tcp.write(l, &write_comps[id], .{ .slice = out }, u16, &slot_ids[id], writeCb);
            return .disarm;
        }
        // All ciphertext drained — the staged plaintext "write" is complete.
        write_lens[id] = 0;
        write_offsets[id] = 0;
        if (cflags[id].tls_close_after_write) {
            hardClose(id);
            return .disarm;
        }
        if (cflags[id].ws_open) {
            ws_batch[id] = 0;
            cflags[id].ws_writing = false;
            if (cflags[id].ws_pending_open) {
                cflags[id].ws_pending_open = false;
                wsNotifyOpen(id);
            }
            if (cflags[id].ws_close_after_write) {
                wsShutdown(id);
                hardClose(id);
                return .disarm;
            }
        } else if (body_lens[id] > 0) {
            // Large-body chunked write: load the next chunk from body_bufs.
            if (write_lens[id] == 0) {
                const n = @min(WRITE_BUF_SIZE, body_remaining[id]);
                if (n > 0) {
                    @memcpy(write_bufs[id][0..n], body_bufs[id][body_source_off[id]..][0..n]);
                    write_lens[id] = n;
                    write_offsets[id] = 0;
                    body_source_off[id] += n;
                    body_remaining[id] -= n;
                } else {
                    body_lens[id] = 0;
                    body_remaining[id] = 0;
                    body_source_off[id] = 0;
                }
            }
            if (write_lens[id] > 0) {
                armWrite(id, l);
                return .disarm;
            }
            if (cflags[id].keep_alive) {
                states[id] = .reading;
                keepAlivePreserve(id); // F4 (TLS: tlsPump re-arms + scans)
                tlsPump(id, l);
            } else {
                closeConn(id);
            }
            return .disarm;
        }
        // Frames staged while ciphertext was in flight.
        if (write_lens[id] > 0) {
            armWrite(id, l);
            return .disarm;
        }
        if (cflags[id].ws_open) {
            if (!cflags[id].ws_read_armed) tlsPump(id, l);
            return .disarm;
        }
        if (cflags[id].keep_alive) {
            states[id] = .reading;
            keepAlivePreserve(id); // F4 (TLS: tlsPump re-arms + scans)
            tlsPump(id, l); // re-enter pump: arms read / feeds staged data
        } else {
            closeConn(id);
        }
        return .disarm;
    }

    if (cflags[id].ws_open) {
        write_offsets[id] += written;
        if (write_offsets[id] < ws_batch[id]) {
            ws_batch[id] = write_lens[id];
            tcp.write(l, &write_comps[id], .{ .slice = write_bufs[id][write_offsets[id]..write_lens[id]] }, u16, &slot_ids[id], writeCb);
            return .disarm;
        }
        const staged = write_lens[id] - ws_batch[id];
        if (staged > 0) {
            const src_end = write_lens[id];
            @memmove(write_bufs[id][0..staged], write_bufs[id][(src_end - staged)..src_end]);
            write_lens[id] = staged;
            wsKick(id);
            return .disarm;
        }
        write_lens[id] = 0;
        write_offsets[id] = 0;
        ws_batch[id] = 0;
        cflags[id].ws_writing = false;
        if (cflags[id].ws_pending_open) {
            cflags[id].ws_pending_open = false;
            wsNotifyOpen(id);
        }
        if (cflags[id].ws_close_after_write) {
            wsShutdown(id);
            closeConn(id);
            return .disarm;
        }
        if (!cflags[id].ws_read_armed) {
            states[id] = .reading;
            armReadId(id, l);
        }
        return .disarm;
    }

    write_offsets[id] += written;

    // DOD-FIX 3: drain large-body chunks via body_bufs with proper offsets.
    if (body_lens[id] > 0) {
        if (write_offsets[id] >= write_lens[id]) {
            // Current span (header or chunk) fully written; load the next chunk.
            const n = @min(WRITE_BUF_SIZE, body_remaining[id]);
            if (n == 0) {
                body_lens[id] = 0;
                body_remaining[id] = 0;
                body_source_off[id] = 0;
                write_lens[id] = 0;
                write_offsets[id] = 0;
                if (cflags[id].keep_alive) {
                    keepAliveRearm(id, l); // F4
                } else {
                    closeConn(id);
                }
                return .disarm;
            }
            @memcpy(write_bufs[id][0..n], body_bufs[id][body_source_off[id]..][0..n]);
            write_lens[id] = n;
            write_offsets[id] = 0;
            body_source_off[id] += n;
            body_remaining[id] -= n;
        }
        if (write_offsets[id] < write_lens[id]) {
            tcp.write(
                l,
                &write_comps[id],
                .{ .slice = write_bufs[id][write_offsets[id]..write_lens[id]] },
                u16,
                &slot_ids[id],
                writeCb,
            );
            return .disarm;
        }
        return .disarm;
    }

    if (write_offsets[id] < write_lens[id]) {
        tcp.write(l, &write_comps[id], .{ .slice = write_bufs[id][write_offsets[id]..write_lens[id]] }, u16, &slot_ids[id], writeCb);
        return .disarm;
    }

    write_offsets[id] = 0;
    if (cflags[id].keep_alive) {
        write_lens[id] = 0;
        keepAliveRearm(id, l); // F4
    } else {
        closeConn(id);
    }
    return .disarm;
}

fn wsKick(id: usize) void {
    const l = g_loop orelse return;
    states[id] = .writing;
    cflags[id].ws_writing = true;
    write_offsets[id] = 0;
    ws_batch[id] = write_lens[id];
    armWrite(id, l);
}

fn armReadId(id: usize, l: *xev.Loop) void {
    cflags[id].ws_read_armed = true;
    armRead(id, l);
}

pub fn init(loop: *xev.Loop, port: u16) !void {
    if (initialized) return;
    g_loop = loop;
    if (std.c.getenv("FF_ECHO") != null) native_echo = true;
    for (0..MAX_CONN) |i| {
        slot_ids[i] = @intCast(i);
        free_list[i] = @intCast(i);
    }
    free_count = MAX_CONN;
    const addr = std.Io.net.IpAddress.parseIp4("0.0.0.0", port) catch unreachable;
    listener_tcp = try xev.TCP.init(addr);
    try listener_tcp.bind(addr);
    try listener_tcp.listen(128);
    listener_tcp.accept(loop, &accept_comp, void, null, acceptCb);
    if (!watchdog_started) { // NEW
        watchdog_timer = xev.Timer.init() catch unreachable;
        watchdog_timer.run(loop, &watchdog_comp, WATCHDOG_INTERVAL_MS, void, null, watchdogCb);
        watchdog_started = true;
    }
    initialized = true;
    std.debug.print("[http] listening on 0.0.0.0:{d}\n", .{port});
    if (tls_active) std.debug.print("[http] TLS mode: https/wss active\n", .{});
}

pub fn deinit() void {
    if (!initialized) return;
    initialized = false;
    watchdog_started = false; // NEW
    for (&states, 0..) |*s, i| {
        if (s.* != .idle) {
            closeConn(i);
        }
    }
    if (handler_fn) |v| {
        c.freeValue(handler_ctx, v);
        handler_fn = null;
    }
    if (ws_on_open) |v| {
        c.freeValue(handler_ctx, v);
        ws_on_open = null;
    }
    if (ws_on_message) |v| {
        c.freeValue(handler_ctx, v);
        ws_on_message = null;
    }
    if (ws_on_close) |v| {
        c.freeValue(handler_ctx, v);
        ws_on_close = null;
    }
    for (&ws_sockets) |*s| {
        if (s.*) |v| {
            c.freeValue(handler_ctx, v);
            s.* = null;
        }
    }
    g_loop = null;
}

// CHANGED: one-time probe capturing QuickJS's internal Promise class id so
// callHandler detects promises with a single JS_GetClassID call.
pub fn setupStrings(ctx: ?*c.Context) void {
    if (promise_class_id != 0) return;
    var cap: [2]c.Value = undefined;
    const p = c.newPromiseCapability(ctx, &cap);
    defer c.freeValue(ctx, p);
    defer c.freeValue(ctx, cap[0]);
    defer c.freeValue(ctx, cap[1]);
    if (c.isObject(p) != 0) promise_class_id = c.getClassID(p);
}

// ── Regression test: classifyMethod must never read past the slice ──
// "DELETE" is exactly 6 bytes; the old code read s[6] in the len==6 branch
// (OOB: panics in Debug, silent misclassify as .none in ReleaseFast).
// Exact-length slices make any regression a hard panic under `zig build test`.
test "classifyMethod covers all methods with exact-length slices" {
    const cases = .{
        .{ "GET", Method.get },
        .{ "PUT", Method.put },
        .{ "POST", Method.post },
        .{ "HEAD", Method.head },
        .{ "PATCH", Method.patch },
        .{ "DELETE", Method.delete },
        .{ "OPTIONS", Method.options },
        .{ "", Method.none },
        .{ "TRACE", Method.none },
        .{ "get", Method.none },
    };
    inline for (cases) |case| {
        const s: []const u8 = case[0];
        try std.testing.expectEqual(case[1], classifyMethod(s));
    }
}
