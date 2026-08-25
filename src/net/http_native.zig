const std = @import("std");
const simd = std.simd;
const xev = @import("xev");
const c = @import("../c.zig").c;
const microtasks = @import("../event/microtasks.zig");
const ws = @import("ws_native.zig");
const api_ws = @import("../api/websocket.zig");
const builtin = @import("builtin");

// Thread-safe general-purpose allocator (server main-thread writes only).
// Debug builds route response-staging allocations through a counter:
// proves the request-path budget (socket buffers are static, never alloc).
var req_counter: counting.CountingAllocator = .{ .base = std.heap.smp_allocator };
const gpa = if (builtin.mode == .Debug)
    req_counter.allocator()
else
    std.heap.smp_allocator;

const counting = @import("../util/counting_allocator.zig");

pub const MAX_CONN = 512;
const READ_BUF_SIZE = 16384;
const WRITE_BUF_SIZE = 16384;
const ACCEPT_BATCH = 8;

// ============================================================
// Response staging — two-tier (skill: zero-alloc hot path, cold exception):
//   ≤16KB  : static per-conn write_bufs[id]   — zero allocations, always
//   >16KB  : ONE smp allocation per response  — cold exceptional path,
//            freed when the write drains or the connection closes
// ============================================================
var big_write: [MAX_CONN]?[]u8 = [_]?[]u8{null} ** MAX_CONN;

/// Idempotent release of any spilled response buffer for slot `id`.
fn freeBigWrite(id: usize) void {
    if (big_write[id]) |p| {
        gpa.free(p);
        big_write[id] = null;
    }
}

const ConnState = enum(u8) { idle, reading, writing, closing };
// Packed per-connection flags (skill Practice #4): six booleans that were
// previously six parallel bool arrays now share one byte per slot, so flag
// checks in read/write completion touch a single cache line instead of up
// to four.
const ConnFlags = packed struct(u8) {
    keep_alive: bool = false,
    ws_open: bool = false,
    ws_writing: bool = false,
    ws_close_after_write: bool = false,
    ws_read_armed: bool = false,
    ws_pending_open: bool = false,
    _pad: u2 = 0,
};
comptime {
    assert(@sizeOf(ConnFlags) == 1); // skill: verify packed layout claims
}
const assert = std.debug.assert;

const Method = enum(u8) { get, post, put, delete, head, options, patch, none };
// ---- SoA hot state: compact + contiguous ----
var states: [MAX_CONN]ConnState = [_]ConnState{.idle} ** MAX_CONN;
var cflags: [MAX_CONN]ConnFlags = [_]ConnFlags{.{}} ** MAX_CONN;
var read_bytes: [MAX_CONN]usize = undefined;
var write_lens: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
var write_offsets: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
var methods: [MAX_CONN]Method = [_]Method{.none} ** MAX_CONN;
var read_comps: [MAX_CONN]xev.Completion = [_]xev.Completion{.{}} ** MAX_CONN;
var write_comps: [MAX_CONN]xev.Completion = [_]xev.Completion{.{}} ** MAX_CONN;
var close_comps: [MAX_CONN]xev.Completion = [_]xev.Completion{.{}} ** MAX_CONN;
// Per-slot watermark of header-terminator scan progress, so partial reads
// resume the "\r\n\r\n" search instead of rescanning from byte 0.
var hdr_scan_off: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
var fds: [MAX_CONN]xev.TCP = undefined;
var buf_lens: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
// ---- WebSocket SoA state ----
var ws_partial_len: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
// Type of the in-flight fragmented message (true == OP_BINARY). Dedicated
// flag so it can never collide with write-batch bookkeeping.
var ws_partial_binary: [MAX_CONN]bool = [_]bool{false} ** MAX_CONN;
var ws_sockets: [MAX_CONN]c.Global = [_]c.Global{.{ .data_ptr = 0 }} ** MAX_CONN;
var ws_batch: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
// ---- Cold bulk data: out-of-line so hot state stays dense ----
var read_bufs: [MAX_CONN][READ_BUF_SIZE]u8 = undefined;
var write_bufs: [MAX_CONN][WRITE_BUF_SIZE]u8 = undefined;
var ws_partial: [MAX_CONN][ws.WS_MSG_SIZE]u8 = undefined;
// ---- O(1) free-list slot allocator ----
var free_list: [MAX_CONN]u16 = undefined;
var free_count: usize = 0;
var slot_ids: [MAX_CONN]u16 = undefined;
pub var handler_fn_global: c.Global = .{ .data_ptr = 0 };
pub var handler_context_global: c.Global = .{ .data_ptr = 0 };
pub var handler_isolate: ?*c.Isolate = null;
var str_methods: [8]c.Global = [_]c.Global{.{ .data_ptr = 0 }} ** 8;
var str_status: c.Global = .{ .data_ptr = 0 };
var str_body: c.Global = .{ .data_ptr = 0 };
var str_empty: c.Global = .{ .data_ptr = 0 };
// ---- WebSocket V8 handler callbacks ----
pub var ws_enabled: bool = false;
pub var ws_on_open: c.Global = .{ .data_ptr = 0 };
pub var ws_on_message: c.Global = .{ .data_ptr = 0 };
pub var ws_on_close: c.Global = .{ .data_ptr = 0 };
// ---- DIAGNOSTIC: native echo (FF_ECHO=1 skips the V8 handler) ----
const ECHO_BODY = "{\"message\":\"ok\"}";
var native_echo: bool = false;
var listener_tcp: xev.TCP = undefined;
var accept_comp: xev.Completion = .{};
var g_loop: ?*xev.Loop = null;
var initialized: bool = false;
const ParsedRequest = struct {
    method: []const u8,
    method_tag: Method,
    url: []const u8,
    content_length: usize,
    keep_alive: bool,
};
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
// True when `value` contains `token` as a comma-separated member (trimmed,
// case-insensitive). Faithful replacement for whole-header substring scans
// like "Connection: close" that could false-match other headers or values.
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
// Wide scan for the lowercased first needle byte (OR 0x20 lowercases A-Z;
// exact for 'c'/'k'/'h' since only alpha bytes can map onto a lowercase
// letter), then scalar-confirm the remaining needle chars. First set lane is
// found via @ctz on the lane bitmask (TigerBeetle style), falling back to a
// scalar tail. Mirrors tls.zig:findCrLf / engine.zig:trimStartWidth.
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
// SIMD scan for "\r\n\r\n" beginning at or after `from`. Candidates are lanes
// equal to '\n' (@ctz over the lane bitmask), each confirmed by its three
// preceding bytes; scalar fallback for short spans and tails. Returns the
// index of the pattern start, mirroring std.mem.indexOf semantics.
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
        if (s[0] == 'D' and s[1] == 'E' and s[2] == 'L' and s[3] == 'E' and s[4] == 'T' and s[5] == 'E') return .delete;
    } else if (s.len == 7) {
        if (s[0] == 'O' and s[1] == 'P' and s[2] == 'T' and s[3] == 'I' and s[4] == 'O' and s[5] == 'N' and s[6] == 'S') return .options;
    }
    return .none;
}
// Single pass over the request line plus every header line: one CI prefix
// compare per header instead of up to five full-buffer token sweeps.
fn parseRequest(buf: []const u8, headers_end: usize) ParsedRequest {
    var pr = ParsedRequest{ .method = "", .method_tag = .none, .url = "", .content_length = 0, .keep_alive = true };
    const region = buf[0..headers_end];
    if (region.len < 10) return pr;
    // ---- Request line ----
    const sp1 = std.mem.indexOfScalar(u8, region, ' ') orelse return pr;
    if (sp1 + 1 >= region.len) return pr;
    const sp2 = std.mem.indexOfScalarPos(u8, region, sp1 + 1, ' ') orelse return pr;
    pr.method = region[0..sp1];
    pr.method_tag = classifyMethod(pr.method);
    pr.url = region[sp1 + 1 .. sp2];
    // HTTP version: compare against the protocol token only (strip CRLF so
    // the suffix check sees "HTTP/1.1", not "HTTP/1.1\r\n...").
    const proto_full = region[sp2 + 1 ..];
    var plen: usize = 0;
    while (plen < proto_full.len and proto_full[plen] != '\r' and proto_full[plen] != '\n') plen += 1;
    const proto = proto_full[0..plen];
    const is_11 = std.mem.endsWith(u8, proto, "HTTP/1.1");
    // ---- Header lines: exactly one pass ----
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
/// RFC-correct response semantics:
///   HEAD          -> Content-Length reflects what GET would return,
///                    but zero body bytes are staged.
///   204 / 304     -> no Content-Length header at all, no body.
///   everything el -> Content-Length + body staged by the caller.
fn wantsBodyBytes(id: usize, status: u16) bool {
    return methods[id] != .head and status != 204 and status != 304;
}
/// Pure header formatter: status line, Content-Type, optional
/// Content-Length, optional Connection. Returns bytes written. Operates on
/// ANY destination slice so both the static fast path and the spilled
/// large-response path share one wire-format implementation.
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
    // 204/304 MUST NOT carry Content-Length; HEAD carries GET's length.
    const cl: ?usize = if (status == 204 or status == 304) null else body.len;
    const w: *[WRITE_BUF_SIZE]u8 = &write_bufs[id];
    var pos = formatResponseHeader(w[0..], status, cl, cflags[id].keep_alive);
    if (!suppress and body.len > 0 and pos + body.len <= WRITE_BUF_SIZE) {
        @memcpy(w[pos..][0..body.len], body);
        pos += body.len;
    }
    write_lens[id] = pos;
}
fn extractInt(isolate: ?*c.Isolate, context: ?*c.Context, val: ?*const c.Value, default: u16) u16 {
    _ = isolate;
    const v = val orelse return default;
    if (c.v8__Value__IsUndefined(v) or c.v8__Value__IsNull(v)) return default;
    var out: c.MaybeI32 = undefined;
    c.v8__Value__Int32Value(v, context, &out);
    return @intCast(out.value);
}
fn callV8Handler(id: usize, parsed: *const ParsedRequest, body: []const u8) void {
    if (builtin.mode == .Debug) req_counter.reset(); // DIAGNOSTIC (W3)
    const isolate = handler_isolate orelse {
        buildResponse(id, 500, "");
        return;
    };
    const context_ptr = c.v8__Global__Get(&handler_context_global, isolate) orelse {
        buildResponse(id, 500, "");
        return;
    };
    const context: *c.Context = @ptrCast(@constCast(context_ptr));
    var hs: c.HandleScope = undefined;
    c.v8__HandleScope__CONSTRUCT(&hs, isolate);
    defer c.v8__HandleScope__DESTRUCT(&hs);
    c.v8__Context__Enter(context);
    defer c.v8__Context__Exit(context);
    const global = c.v8__Context__Global(context) orelse {
        buildResponse(id, 500, "");
        return;
    };
    const handler_fn_data = c.v8__Global__Get(&handler_fn_global, isolate) orelse {
        buildResponse(id, 500, "");
        return;
    };
    const handler_fn: *const c.Function = @ptrCast(handler_fn_data);
    const url_val = c.v8__String__NewFromUtf8(isolate, @ptrCast(parsed.url.ptr), 0, @intCast(parsed.url.len));
    if (url_val == null) {
        buildResponse(id, 500, "");
        return;
    }
    const method_val: ?*const c.Value = if (parsed.method_tag != .none)
        @ptrCast(c.v8__Global__Get(&str_methods[@intFromEnum(parsed.method_tag)], isolate))
    else
        c.v8__String__NewFromUtf8(isolate, @ptrCast(parsed.method.ptr), 0, @intCast(parsed.method.len));
    if (method_val == null) {
        buildResponse(id, 500, "");
        return;
    }
    var body_val: ?*const c.Value = null;
    if (body.len > 0) {
        body_val = c.v8__String__NewFromUtf8(isolate, @ptrCast(body.ptr), 0, @intCast(body.len));
        if (body_val == null) {
            buildResponse(id, 500, "");
            return;
        }
    } else {
        body_val = @ptrCast(c.v8__Global__Get(&str_empty, isolate));
    }
    var argv = [_]*const c.Value{ @ptrCast(url_val), @ptrCast(method_val.?), @ptrCast(body_val.?) };
    const result = c.v8__Function__Call(handler_fn, context, @ptrCast(global), 3, &argv);
    if (result == null) {
        buildResponse(id, 500, "");
        return;
    }
    var response_val = result;
    if (c.v8__Value__IsPromise(result)) {
        var pi: u32 = 0;
        while (pi < 1000) : (pi += 1) {
            if (c.v8__Promise__State(result) != 0) break;
            microtasks.pumpMicrotasks(isolate);
        }
        if (c.v8__Promise__State(result) == 1) {
            response_val = c.v8__Promise__Result(result);
        } else {
            buildResponse(id, 500, "");
            return;
        }
    }
    if (response_val == null or !c.v8__Value__IsObject(response_val)) {
        buildResponse(id, 500, "");
        return;
    }
    const status_val = c.v8__Object__Get(@ptrCast(response_val), context, @ptrCast(c.v8__Global__Get(&str_status, isolate)));
    const status = extractInt(isolate, context, status_val, 200);
    const body_out_val = c.v8__Object__Get(@ptrCast(response_val), context, @ptrCast(c.v8__Global__Get(&str_body, isolate)));

    const suppress = !wantsBodyBytes(id, status);
    const keep_alive = cflags[id].keep_alive;
    var done = false;
    body_pipeline: {
        const bv = body_out_val orelse break :body_pipeline;
        if (c.v8__Value__IsUndefined(bv) or c.v8__Value__IsNull(bv)) break :body_pipeline;
        const str_v: ?*const c.Value = if (c.v8__Value__IsString(bv)) bv else c.v8__Value__ToDetailString(bv, context);
        const s = str_v orelse break :body_pipeline;
        const l: i32 = c.v8__String__Utf8Length(s, isolate);
        if (l <= 0) break :body_pipeline;
        const blen: usize = @intCast(l);

        if (suppress) {
            // HEAD: full headers incl. GET-equivalent Content-Length,
            // zero body bytes staged (RFC 9110 §9.3.2). 204/304: no CL.
            const cl: ?usize = if (status == 204 or status == 304) null else blen;
            write_lens[id] = formatResponseHeader(
                write_bufs[id][0..],
                status,
                cl,
                keep_alive,
            );
            done = true;
            break :body_pipeline;
        }

        if (blen <= WRITE_BUF_SIZE - 1024) {
            // ---- inline fast path: static buffer, ZERO allocations ----
            const hlen = formatResponseHeader(write_bufs[id][0..], status, blen, keep_alive);
            const wrote_raw = c.v8__String__WriteUtf8(s, isolate, write_bufs[id][hlen..].ptr, blen, 0);
            const written: usize = if (wrote_raw > 0)
                @min(@as(usize, @intCast(wrote_raw)), blen)
            else
                0;
            if (written != blen) {
                // Byte-length prediction differed: reformat in place and
                // slide the body down (overlap-safe).
                const h2 = formatResponseHeader(write_bufs[id][0..], status, written, keep_alive);
                std.mem.copyForwards(
                    u8,
                    write_bufs[id][h2..][0..written],
                    write_bufs[id][hlen..][0..written],
                );
                write_lens[id] = h2 + written;
            } else {
                write_lens[id] = hlen + blen;
            }
            done = true;
            break :body_pipeline;
        }

        // ---- large-body spill (>16KB): ONE allocation, cold path.
        // Header formats into stack scratch (realistic max ~120B), body
        // lands behind it in the same buffer, utf8-mismatch slides in place
        // with copyForwards. Freed by freeBigWrite on drain/close. ----

        var hdr: [256]u8 = undefined;
        const hlen = formatResponseHeader(hdr[0..], status, blen, keep_alive);
        const out = gpa.alloc(u8, hlen + blen) catch {
            // Spill OOM: clean small rejection instead of a truncated lie.
            buildResponse(id, 500, "out of memory");
            done = true;
            break :body_pipeline;
        };
        @memcpy(out[0..hlen], hdr[0..hlen]);
        const wrote_raw = c.v8__String__WriteUtf8(s, isolate, out[hlen..].ptr, blen, 0);
        const written: usize = if (wrote_raw > 0)
            @min(@as(usize, @intCast(wrote_raw)), blen)
        else
            0;
        var total = hlen + blen;
        if (written != blen) {
            const h2 = formatResponseHeader(out[0..], status, written, keep_alive);
            std.mem.copyForwards(u8, out[h2..][0..written], out[hlen..][0..written]);
            total = h2 + written;
        }
        big_write[id] = out;
        write_lens[id] = total;
        write_offsets[id] = 0;
        done = true;
        break :body_pipeline;
    }
    if (!done) {
        write_lens[id] = formatResponseHeader(
            write_bufs[id][0..],
            status,
            0,
            cflags[id].keep_alive,
        );
    }
    if (builtin.mode == .Debug) { // DIAGNOSTIC (W3): budget proof + leak assert
        std.debug.print(
            "[allocs] req id={d}: allocs={d} frees={d} +{d}B -{d}B balanced={}\n",
            .{
                id,
                req_counter.alloc_count,
                req_counter.free_count,
                req_counter.bytes_allocated,
                req_counter.bytes_freed,
                req_counter.balanced(),
            },
        );
        std.debug.assert(req_counter.balanced()); // leak => loud failure
    }
}



// ---- WebSocket helpers ----

fn wsKick(id: usize) void {
    const l = g_loop orelse return;
    states[id] = .writing;
    cflags[id].ws_writing = true;
    write_offsets[id] = 0;
    ws_batch[id] = write_lens[id];
    fds[id].write(l, &write_comps[id], .{ .slice = write_bufs[id][0..write_lens[id]] }, u16, &slot_ids[id], writeCb);
}

fn armReadId(id: usize, l: *xev.Loop) void {
    cflags[id].ws_read_armed = true;
    fds[id].read(l, &read_comps[id], .{ .slice = read_bufs[id][buf_lens[id]..] }, u16, &slot_ids[id], readCb);
}

fn wsSocket(id: usize, isolate: ?*c.Isolate, context: *c.Context) ?*const c.Value {
    const iso = isolate orelse return null;
    if (ws_sockets[id].data_ptr != 0) return @ptrCast(c.v8__Global__Get(&ws_sockets[id], iso));
    const obj = api_ws.makeSocket(iso, context, @intCast(id)) orelse return null;
    c.v8__Global__New(iso, @ptrCast(obj), &ws_sockets[id]);
    return @ptrCast(obj);
}

fn wsNotify(id: usize, which: *c.Global, argc: u32) void {
    const isolate = handler_isolate orelse return;
    const ctxp = c.v8__Global__Get(&handler_context_global, isolate) orelse return;
    const context: *c.Context = @ptrCast(@constCast(ctxp));
    var hs: c.HandleScope = undefined;
    c.v8__HandleScope__CONSTRUCT(&hs, isolate);
    defer c.v8__HandleScope__DESTRUCT(&hs);
    c.v8__Context__Enter(context);
    defer c.v8__Context__Exit(context);
    const global = c.v8__Context__Global(context) orelse return;
    const cb_data = c.v8__Global__Get(which, isolate) orelse return;
    const cb_fn: *const c.Function = @ptrCast(cb_data);
    const sock = wsSocket(id, isolate, context) orelse return;
    if (argc == 1) {
        var argv = [_]*const c.Value{sock};
        _ = c.v8__Function__Call(cb_fn, context, @ptrCast(global), 1, &argv);
    } else if (argc == 2) {
        var argv = [_]*const c.Value{ sock, sock };
        _ = c.v8__Function__Call(cb_fn, context, @ptrCast(global), 2, &argv);
    }
}

// Binary payloads surface to JS as Uint8Array views over a fresh ArrayBuffer
// (matching the client side), so handlers can branch on
// `data instanceof Uint8Array` reliably.
fn wsNotifyMessage(id: usize, msg: []const u8, binary: bool) void {
    const isolate = handler_isolate orelse return;
    const ctxp = c.v8__Global__Get(&handler_context_global, isolate) orelse return;
    const context: *c.Context = @ptrCast(@constCast(ctxp));
    var hs: c.HandleScope = undefined;
    c.v8__HandleScope__CONSTRUCT(&hs, isolate);
    defer c.v8__HandleScope__DESTRUCT(&hs);
    c.v8__Context__Enter(context);
    defer c.v8__Context__Exit(context);
    const global = c.v8__Context__Global(context) orelse return;
    const cb_data = c.v8__Global__Get(&ws_on_message, isolate) orelse return;
    const cb_fn: *const c.Function = @ptrCast(cb_data);
    const sock = wsSocket(id, isolate, context) orelse return;
    const data_val: ?*const c.Value = if (binary) b: {
        const ab = c.v8__ArrayBuffer__New(isolate, msg.len);
        const store = c.v8__ArrayBuffer__GetBackingStore(ab);
        if (c.std__shared_ptr__v8__BackingStore__get(&store)) |bs| {
            if (c.v8__BackingStore__Data(bs)) |p| {
                const dst: [*]u8 = @ptrCast(p);
                @memcpy(dst[0..msg.len], msg);
            }
        }
        break :b @ptrCast(c.v8__Uint8Array__New(@ptrCast(ab), 0, msg.len));
    } else c.v8__String__NewFromUtf8(isolate, @ptrCast(msg.ptr), 0, @intCast(msg.len));
    const dv = data_val orelse return;
    var argv = [_]*const c.Value{ sock, dv };
    _ = c.v8__Function__Call(cb_fn, context, @ptrCast(global), 2, &argv);
}

pub fn wsSendTextUtf8(id: usize, str: ?*const c.Value, isolate: ?*c.Isolate) void {
    const iso = isolate orelse return;
    const s = str orelse return;
    if (!cflags[id].ws_open or states[id] == .closing) return;
    const ulen_raw = c.v8__String__Utf8Length(s, iso);
    if (ulen_raw <= 0) return;
    const ulen: usize = @intCast(ulen_raw);
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
    if (tail + need > WRITE_BUF_SIZE) return; // drop-new: no room in staging
    const buf = write_bufs[id][tail..];
    const wrote = c.v8__String__WriteUtf8(s, iso, buf[ws.MAX_HDR..].ptr, WRITE_BUF_SIZE - tail - ws.MAX_HDR, 0);
    if (wrote <= 0) return;
    const plen = @min(@as(usize, @intCast(wrote)), ulen);
    const hlen = ws.buildHeader(buf, ws.OP_TEXT, true, plen);
    // Slide payload behind the actual header: the wire slice must be
    // contiguous header||payload.
    if (hlen != ws.MAX_HDR) @memmove(buf[hlen..][0..plen], buf[ws.MAX_HDR..][0..plen]);
    write_lens[id] = tail + hlen + plen;
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
    if (tail + need > WRITE_BUF_SIZE) return; // drop-new staging policy
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
    if (tail + @as(usize, ws.MAX_HDR) + plen > WRITE_BUF_SIZE) return; // drop-new
    const buf = write_bufs[id][tail..];
    @memcpy(buf[ws.MAX_HDR..][0..plen], payload[0..plen]);
    const hlen = ws.buildHeader(buf, ws.OP_PONG, true, plen);
    if (hlen != ws.MAX_HDR) @memmove(buf[hlen..][0..plen], buf[ws.MAX_HDR..][0..plen]);
    write_lens[id] = tail + hlen + plen;
    if (!cflags[id].ws_writing) wsKick(id);
}

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
        // Fragmented message begins: remember its type until assembly.
        ws_partial_binary[id] = hdr.opcode == ws.OP_BINARY;
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
        wsNotifyMessage(id, ws_partial[id][0..ws_partial_len[id]], ws_partial_binary[id]);
        ws_partial_len[id] = 0;
    }
    return true;
}

// Three-pass engine over one read buffer: decode header -> unmask -> act.
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
    wsNotify(id, &ws_on_open, 1);
}

fn wsNotifyClose(id: usize) void {
    wsNotify(id, &ws_on_close, 1);
}

fn wsShutdown(id: usize) void {
    if (!cflags[id].ws_open) return;
    wsNotifyClose(id);
    if (ws_sockets[id].data_ptr != 0) c.v8__Global__Reset(&ws_sockets[id]);
    ws_sockets[id] = .{ .data_ptr = 0 };
    cflags[id].ws_open = false;
    ws_partial_len[id] = 0;
    ws_partial_binary[id] = false;
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
        fds[id].write(l, &write_comps[id], .{ .slice = write_bufs[id][0..write_lens[id]] }, u16, &slot_ids[id], writeCb);
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
    // FIX: hold ws_writing true during the 101 flush so no frame (echo/pong/close)
    // can be built over write_bufs until the handshake reply is fully drained.
    cflags[id].ws_writing = true;
    cflags[id].ws_close_after_write = false;
    cflags[id].ws_pending_open = true;
    ws_partial_len[id] = 0;
    ws_partial_binary[id] = false;
    states[id] = .writing;
    write_offsets[id] = 0;
    ws_batch[id] = write_lens[id];
    fds[id].write(l, &write_comps[id], .{ .slice = w[0..write_lens[id]] }, u16, &slot_ids[id], writeCb);
}

fn closeConn(id: usize) void {
    freeBigWrite(id); // release any spilled large response for this slot
    wsShutdown(id);
    if (states[id] == .closing) return;
    states[id] = .closing;
    const loop = g_loop orelse {
        states[id] = .idle;
        freePush(id);
        return;
    };
    fds[id].close(loop, &close_comps[id], u16, &slot_ids[id], closeCb);
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

fn setupSlot(l: *xev.Loop, tcp: xev.TCP) bool {
    const id = freePop() orelse {
        _ = c.close(tcp.fd);
        return false;
    };
    fds[id] = tcp;
    // Disable Nagle: keep-alive small responses otherwise interact with
    // delayed ACKs, producing multi-ms/p99 tail spikes.
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
    hdr_scan_off[id] = 0;
    write_lens[id] = 0;
    write_offsets[id] = 0;
    freeBigWrite(id); // defensive: slot must never inherit stale spill
    // One store replaces the previous six separate flag writes.
    cflags[id] = .{ .keep_alive = true, .ws_read_armed = true };
    ws_partial_len[id] = 0;
    ws_partial_binary[id] = false;
    ws_batch[id] = 0;
    fds[id].read(l, &read_comps[id], .{ .slice = &read_bufs[id] }, u16, &slot_ids[id], readCb);
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
    buf_lens[id] += n;
    if (cflags[id].ws_open) {
        wsConsume(id, l);
        return .disarm;
    }
    // Resume the header-terminator scan where the previous partial read left
    // off (3-byte overlap covers a "\r\n\r\n" straddling the boundary).
    const scan_from = if (hdr_scan_off[id] > 3) hdr_scan_off[id] - 3 else 0;
    const he_found = findHeaderEnd(read_bufs[id][0..buf_lens[id]], scan_from);
    if (he_found == null) {
        hdr_scan_off[id] = buf_lens[id];
        if (buf_lens[id] >= READ_BUF_SIZE) {
            closeConn(id);
            return .disarm;
        }
        fds[id].read(l, &read_comps[id], .{ .slice = read_bufs[id][buf_lens[id]..] }, u16, &slot_ids[id], readCb);
        return .disarm;
    }
    const headers_end = he_found.? + 4;
    hdr_scan_off[id] = 0;
    const pr = parseRequest(read_bufs[id][0..buf_lens[id]], headers_end);
    methods[id] = pr.method_tag;
    if (ws_enabled) {
        if (findTokenCI(read_bufs[id][0..buf_lens[id]], "sec-websocket-key:")) |kpos| {
            tryUpgrade(id, l, kpos, headers_end, &pr);
            return .disarm;
        }
    }
    if (pr.method.len == 0) {
        buildResponse(id, 400, "Bad Request");
        states[id] = .writing;
        fds[id].write(l, &write_comps[id], .{ .slice = write_bufs[id][0..write_lens[id]] }, u16, &slot_ids[id], writeCb);
        return .disarm;
    }
    const expect = headers_end + pr.content_length;
    if (expect > READ_BUF_SIZE) {
        buildResponse(id, 413, "Payload Too Large");
        states[id] = .writing;
        fds[id].write(l, &write_comps[id], .{ .slice = write_bufs[id][0..write_lens[id]] }, u16, &slot_ids[id], writeCb);
        return .disarm;
    }
    if (buf_lens[id] < expect) {
        fds[id].read(l, &read_comps[id], .{ .slice = read_bufs[id][buf_lens[id]..] }, u16, &slot_ids[id], readCb);
        return .disarm;
    }
    cflags[id].keep_alive = pr.keep_alive;
    if (native_echo) {
        buildResponse(id, 200, ECHO_BODY);
    } else {
        const body = read_bufs[id][headers_end .. headers_end + pr.content_length];
        callV8Handler(id, &pr, body);
    }
    states[id] = .writing;
    fds[id].write(l, &write_comps[id], .{ .slice = write_bufs[id][0..write_lens[id]] }, u16, &slot_ids[id], writeCb);
    return .disarm;
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

    if (cflags[id].ws_open) {
        // ---- WebSocket coalesced write path ----
        write_offsets[id] += written;
        if (write_offsets[id] < ws_batch[id]) {
            // partial batch: re-arm from current offset, extending into any
            // frames appended while this batch was in flight.
            ws_batch[id] = write_lens[id];
            tcp.write(l, &write_comps[id], .{ .slice = write_bufs[id][write_offsets[id]..write_lens[id]] }, u16, &slot_ids[id], writeCb);
            return .disarm;
        }
        // batch fully flushed: any appended frames become the new head.
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

    // ---- HTTP write path: source switches between the static fast buffer
    // and a spilled large-response allocation. The spill is freed exactly
    // when fully drained (before any keep-alive reuse of the slot). ----
    write_offsets[id] += written;

    if (big_write[id] != null) {
        if (write_offsets[id] < write_lens[id]) {
            tcp.write(
                l,
                &write_comps[id],
                .{ .slice = big_write[id].?[write_offsets[id]..write_lens[id]] },
                u16,
                &slot_ids[id],
                writeCb,
            );
            return .disarm;
        }
        freeBigWrite(id); // fully drained — release before keep-alive re-arm
    } else {
        if (write_offsets[id] < write_lens[id]) {
            tcp.write(l, &write_comps[id], .{ .slice = write_bufs[id][write_offsets[id]..write_lens[id]] }, u16, &slot_ids[id], writeCb);
            return .disarm;
        }
    }

    write_offsets[id] = 0;
    if (cflags[id].keep_alive) {
        states[id] = .reading;
        buf_lens[id] = 0;
        hdr_scan_off[id] = 0;
        write_lens[id] = 0;
        fds[id].read(l, &read_comps[id], .{ .slice = &read_bufs[id] }, u16, &slot_ids[id], readCb);
    } else {
        closeConn(id);
    }
    return .disarm;
}

pub fn init(loop: *xev.Loop, port: u16) !void {
    if (initialized) return;
    g_loop = loop;
    if (c.getenv("FF_ECHO") != null) native_echo = true;
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
    initialized = true;
    std.debug.print("[http] listening on 0.0.0.0:{d}\n", .{port});
}

pub fn deinit() void {
    if (!initialized) return;
    initialized = false;
    for (&states, 0..) |*s, i| {
        if (s.* != .idle) {
            closeConn(i);
        }
    }
    for (0..MAX_CONN) |i| freeBigWrite(i); // paranoia sweep; closeConn covers it
    g_loop = null;
}

pub fn setupStrings(isolate: ?*c.Isolate) void {
    var hs: c.HandleScope = undefined;
    c.v8__HandleScope__CONSTRUCT(&hs, isolate);
    defer c.v8__HandleScope__DESTRUCT(&hs);
    c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, "GET", 0, -1)), &str_methods[@intFromEnum(Method.get)]);
    c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, "POST", 0, -1)), &str_methods[@intFromEnum(Method.post)]);
    c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, "PUT", 0, -1)), &str_methods[@intFromEnum(Method.put)]);
    c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, "DELETE", 0, -1)), &str_methods[@intFromEnum(Method.delete)]);
    c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, "HEAD", 0, -1)), &str_methods[@intFromEnum(Method.head)]);
    c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, "OPTIONS", 0, -1)), &str_methods[@intFromEnum(Method.options)]);
    c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, "PATCH", 0, -1)), &str_methods[@intFromEnum(Method.patch)]);
    c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, "status", 0, -1)), &str_status);
    c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, "body", 0, -1)), &str_body);
    c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, "", 0, -1)), &str_empty);
}
