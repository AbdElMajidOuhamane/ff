const std = @import("std");
const simd = std.simd;
const xev = @import("xev");
const c = @import("../c.zig").c;
const microtasks = @import("../event/microtasks.zig");
const ws = @import("ws_native.zig");
const api_ws = @import("../api/websocket.zig");

const gpa = std.heap.smp_allocator;

pub const MAX_CONN = 512;
const READ_BUF_SIZE = 16384;
const WRITE_BUF_SIZE = 16384;
const ACCEPT_BATCH = 8;

const ConnState = enum(u8) { idle, reading, writing, closing };

const Method = enum(u8) { get, post, put, delete, head, options, patch, none };

// ---- SoA hot state: compact + contiguous ----
var states: [MAX_CONN]ConnState = [_]ConnState{.idle} ** MAX_CONN;
var sockets: [MAX_CONN]std.posix.socket_t = undefined;
var read_bytes: [MAX_CONN]usize = undefined;
var rbufs: [MAX_CONN][READ_BUF_SIZE]u8 = undefined;
var wbufs: [MAX_CONN][WRITE_BUF_SIZE]u8 = undefined;
var write_len: [MAX_CONN]usize = undefined;
var write_off: [MAX_CONN]usize = undefined;
var api_ids: [MAX_CONN]?u32 = undefined;
var total_bytes: [MAX_CONN]usize = undefined;
var fds: [MAX_CONN]xev.TCP = undefined;
var buf_lens: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
var write_lens: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
var write_offsets: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
var keep_alives: [MAX_CONN]bool = [_]bool{true} ** MAX_CONN;
var methods: [MAX_CONN]Method = [_]Method{.none} ** MAX_CONN;
var read_comps: [MAX_CONN]xev.Completion = [_]xev.Completion{.{}} ** MAX_CONN;
var write_comps: [MAX_CONN]xev.Completion = [_]xev.Completion{.{}} ** MAX_CONN;
var close_comps: [MAX_CONN]xev.Completion = [_]xev.Completion{.{}} ** MAX_CONN;

// ---- WebSocket SoA state ----
var ws_open: [MAX_CONN]bool = [_]bool{false} ** MAX_CONN;
var ws_writing: [MAX_CONN]bool = [_]bool{false} ** MAX_CONN;
var ws_close_after_write: [MAX_CONN]bool = [_]bool{false} ** MAX_CONN;
var ws_read_armed: [MAX_CONN]bool = [_]bool{false} ** MAX_CONN;
var ws_pending_open: [MAX_CONN]bool = [_]bool{false} ** MAX_CONN;
var ws_partial_len: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
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
    const spl_first: V = @splat(first);
    const spl_lower: V = @splat(@as(u8, 0x20));
    var i: usize = 0;
    while (i < window_end and window_end - i >= N) : (i += N) {
        const v: V = haystack[i..][0..N].*;
        const m: [N]bool = (v | spl_lower) == spl_first;
        var bits: u64 = 0;
        for (0..N) |j| {
            if (m[j]) bits |= @as(u64, 1) << @intCast(j);
        }
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

fn parseRequest(buf: []const u8, headers_end: usize) ParsedRequest {
    var pr = ParsedRequest{ .method = "", .method_tag = .none, .url = "", .content_length = 0, .keep_alive = true };
    const line = buf[0..headers_end];
    if (line.len < 10) return pr;

    const sp1 = std.mem.indexOfScalar(u8, line, ' ') orelse return pr;
    if (sp1 + 1 >= line.len) return pr;
    const sp2 = std.mem.indexOfScalarPos(u8, line, sp1 + 1, ' ') orelse return pr;
    pr.method = line[0..sp1];
    pr.method_tag = classifyMethod(pr.method);
    pr.url = line[sp1 + 1 .. sp2];

    const rest = line[sp2 + 1 ..];
    const is_11 = std.mem.indexOf(u8, rest, "HTTP/1.1") != null or
                  std.mem.indexOf(u8, rest, "HTTP/2") != null;
    const has_close = findTokenCI(line, "Connection: close") != null;
    pr.keep_alive = if (is_11)
        !has_close
    else
        findTokenCI(line, "Connection: keep-alive") != null;

    if (findTokenCI(line, "content-length:")) |pos| {
        var start = pos + "content-length:".len;
        while (start < line.len and (line[start] == ' ' or line[start] == '\t')) start += 1;
        var end = start;
        while (end < line.len and line[end] >= '0' and line[end] <= '9') end += 1;
        if (end > start) {
            if (std.fmt.parseInt(usize, line[start..end], 10)) |n| pr.content_length = n else |_| {}
        }
    }
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

fn buildResponseHeader(id: usize, status: u16, body_len: usize) usize {
    var pos: usize = 0;
    const w: *[WRITE_BUF_SIZE]u8 = &write_bufs[id];

    pushStr(w, &pos, "HTTP/1.1 ");
    appendUInt(w, &pos, status);
    pushStr(w, &pos, " ");
    pushStr(w, &pos, statusReason(status));
    pushStr(w, &pos, "\r\n");
    pushStr(w, &pos, "Content-Type: text/plain\r\n");
    pushStr(w, &pos, "Content-Length: ");
    appendUInt(w, &pos, body_len);
    pushStr(w, &pos, "\r\n");
    if (keep_alives[id]) pushStr(w, &pos, "Connection: keep-alive\r\n");
    pushStr(w, &pos, "\r\n");
    return pos;
}

fn buildResponse(id: usize, status: u16, body: []const u8) void {
    const header_len = buildResponseHeader(id, status, body.len);
    const w: *[WRITE_BUF_SIZE]u8 = &write_bufs[id];
    var pos = header_len;
    if (body.len > 0 and pos + body.len <= WRITE_BUF_SIZE) {
        @memcpy(w[pos..][0..body.len], body);
        pos += body.len;
    }
    write_lens[id] = pos;
}

fn v8BodyLen(isolate: ?*c.Isolate, context: ?*c.Context, val: ?*const c.Value) ?usize {
    const v = val orelse return null;
    if (c.v8__Value__IsUndefined(v) or c.v8__Value__IsNull(v)) return null;
    const str: ?*const c.Value = if (c.v8__Value__IsString(v)) v else c.v8__Value__ToDetailString(v, context);
    const s = str orelse return null;
    const l: i32 = c.v8__String__Utf8Length(s, isolate);
    if (l <= 0) return null;
    return @intCast(l);
}

fn v8BodyWrite(isolate: ?*c.Isolate, context: ?*c.Context, val: ?*const c.Value, buf: []u8) ?usize {
    const v = val orelse return null;
    const str: ?*const c.Value = if (c.v8__Value__IsString(v)) v else c.v8__Value__ToDetailString(v, context);
    const s = str orelse return null;
    const l: i32 = c.v8__String__Utf8Length(s, isolate);
    if (l <= 0) return null;
    const len = @min(@as(usize, @intCast(l)), buf.len);
    _ = c.v8__String__WriteUtf8(s, isolate, buf.ptr, len, 0);
    return len;
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
    const w: *[WRITE_BUF_SIZE]u8 = &write_bufs[id];
    const max_body = WRITE_BUF_SIZE - 1024;

    var body_len: usize = 0;
    if (v8BodyLen(isolate, context, body_out_val)) |len| body_len = @min(len, max_body);

    const header_len = buildResponseHeader(id, status, body_len);

    if (body_len > 0) {
        if (v8BodyWrite(isolate, context, body_out_val, w[header_len .. header_len + body_len])) |written| {
            if (written != body_len) {
                _ = buildResponseHeader(id, status, written);
                write_lens[id] = header_len + written;
                return;
            }
            write_lens[id] = header_len + written;
        } else {
            write_lens[id] = header_len;
        }
    } else {
        write_lens[id] = header_len;
    }
}

// ---- WebSocket helpers ----

fn wsKick(id: usize) void {
    const l = g_loop orelse return;
    states[id] = .writing;
    ws_writing[id] = true;
    write_offsets[id] = 0;
    ws_batch[id] = write_lens[id];
    fds[id].write(l, &write_comps[id], .{ .slice = write_bufs[id][0..write_lens[id]] }, u16, &slot_ids[id], writeCb);
}

fn armReadId(id: usize, l: *xev.Loop) void {
    ws_read_armed[id] = true;
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
        var argv = [_]*const c.Value{sock, sock};
        _ = c.v8__Function__Call(cb_fn, context, @ptrCast(global), 2, &argv);
    }
}

fn wsNotifyMessage(id: usize, msg: []const u8) void {
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
    const msg_val = c.v8__String__NewFromUtf8(isolate, @ptrCast(msg.ptr), 0, @intCast(msg.len)) orelse return;

    var argv = [_]*const c.Value{ sock, @ptrCast(msg_val) };
    _ = c.v8__Function__Call(cb_fn, context, @ptrCast(global), 2, &argv);
}

pub fn wsSendTextUtf8(id: usize, str: ?*const c.Value, isolate: ?*c.Isolate) void {
    const iso = isolate orelse return;
    const s = str orelse return;
    if (!ws_open[id] or states[id] == .closing) return;

    const ulen_raw = c.v8__String__Utf8Length(s, iso);
    if (ulen_raw <= 0) return;
    const ulen: usize = @intCast(ulen_raw);
    if (ulen > ws.WS_MSG_SIZE) {
        wsSendClose(id, 1009);
        return;
    }

    if (!ws_writing[id]) {
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
    write_lens[id] = tail + hlen + plen;

    if (!ws_writing[id]) wsKick(id);
}

pub fn wsSendClose(id: usize, code: u16) void {
    if (states[id] == .closing) return;
    if (!ws_open[id]) {
        closeConn(id);
        return;
    }
    if (!ws_writing[id]) {
        write_lens[id] = 0;
        write_offsets[id] = 0;
        ws_batch[id] = 0;
    }
    var payload: [2]u8 = undefined;
    payload[0] = @intCast((code >> 8) & 0xff);
    payload[1] = @intCast(code & 0xff);
    const tail = write_lens[id];
    const buf = write_bufs[id][tail..];
    @memcpy(buf[ws.MAX_HDR..][0..2], &payload);
    const hlen = ws.buildHeader(buf, ws.OP_CLOSE, true, 2);
    write_lens[id] = tail + hlen + 2;
    ws_close_after_write[id] = true;
    if (!ws_writing[id]) wsKick(id);
}

fn wsSendCloseEcho(id: usize, payload: []const u8) void {
    if (states[id] == .closing) return;
    if (!ws_writing[id]) {
        write_lens[id] = 0;
        write_offsets[id] = 0;
        ws_batch[id] = 0;
    }
    const plen = @min(payload.len, @as(usize, 2));
    const tail = write_lens[id];
    const buf = write_bufs[id][tail..];
    @memcpy(buf[ws.MAX_HDR..][0..plen], payload[0..plen]);
    const hlen = ws.buildHeader(buf, ws.OP_CLOSE, true, plen);
    write_lens[id] = tail + hlen + plen;
    ws_close_after_write[id] = true;
    if (!ws_writing[id]) wsKick(id);
}

fn wsSendPong(id: usize, payload: []const u8) void {
    if (!ws_writing[id]) {
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
    write_lens[id] = tail + hlen + plen;
    if (!ws_writing[id]) wsKick(id);
}

fn wsHandleData(id: usize, hdr: ws.FrameHdr, payload: []const u8) bool {
    if (ws.isData(hdr.opcode)) {
        if (ws_partial_len[id] != 0) {
            wsSendClose(id, 1002);
            return false;
        }
        if (hdr.fin) {
            wsNotifyMessage(id, payload);
            return true;
        }
        if (payload.len > ws.WS_MSG_SIZE) {
            wsSendClose(id, 1009);
            return false;
        }
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
        wsNotifyMessage(id, ws_partial[id][0..ws_partial_len[id]]);
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
    if (states[id] == .reading and !ws_writing[id]) armReadId(id, l);
}

fn wsNotifyOpen(id: usize) void {
    wsNotify(id, &ws_on_open, 1);
}
fn wsNotifyClose(id: usize) void {
    wsNotify(id, &ws_on_close, 1);
}

fn wsShutdown(id: usize) void {
    if (!ws_open[id]) return;
    wsNotifyClose(id);
    if (ws_sockets[id].data_ptr != 0) c.v8__Global__Reset(&ws_sockets[id]);
    ws_sockets[id] = .{ .data_ptr = 0 };
    ws_open[id] = false;
    ws_partial_len[id] = 0;
    ws_close_after_write[id] = false;
    ws_writing[id] = false;
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

    ws_open[id] = true;
    // FIX: hold ws_writing true during the 101 flush so no frame (echo/pong/close)
    // can be built over write_bufs until the handshake reply is fully drained.
    ws_writing[id] = true;
    ws_close_after_write[id] = false;
    ws_pending_open[id] = true;
    ws_partial_len[id] = 0;
    states[id] = .writing;
    write_offsets[id] = 0;
    ws_batch[id] = write_lens[id];
    fds[id].write(l, &write_comps[id], .{ .slice = w[0..write_lens[id]] }, u16, &slot_ids[id], writeCb);
}

fn closeConn(id: usize) void {
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
    states[id] = .reading;
    methods[id] = Method.none;
    buf_lens[id] = 0;
    write_lens[id] = 0;
    write_offsets[id] = 0;
    keep_alives[id] = true;
    ws_open[id] = false;
    ws_writing[id] = false;
    ws_close_after_write[id] = false;
    ws_pending_open[id] = false;
    ws_partial_len[id] = 0;
    ws_batch[id] = 0;
    ws_read_armed[id] = true;

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

    ws_read_armed[id] = false;

    const n = r catch {
        closeConn(id);
        return .disarm;
    };

    if (n == 0) {
        closeConn(id);
        return .disarm;
    }

    buf_lens[id] += n;

    if (ws_open[id]) {
        wsConsume(id, l);
        return .disarm;
    }

    const search = std.mem.indexOf(u8, read_bufs[id][0..buf_lens[id]], "\r\n\r\n");
    if (search == null) {
        if (buf_lens[id] >= READ_BUF_SIZE) {
            closeConn(id);
            return .disarm;
        }
        fds[id].read(l, &read_comps[id], .{ .slice = read_bufs[id][buf_lens[id]..] }, u16, &slot_ids[id], readCb);
        return .disarm;
    }
    const headers_end = search.? + 4;

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

    keep_alives[id] = pr.keep_alive;

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

    if (ws_open[id]) {
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
        ws_writing[id] = false;
        if (ws_pending_open[id]) {
            ws_pending_open[id] = false;
            wsNotifyOpen(id);
        }
        if (ws_close_after_write[id]) {
            wsShutdown(id);
            closeConn(id);
            return .disarm;
        }
        if (!ws_read_armed[id]) {
            states[id] = .reading;
            armReadId(id, l);
        }
        return .disarm;
    }

    // ---- HTTP write path (unchanged) ----
    write_offsets[id] += written;
    if (write_offsets[id] < write_lens[id]) {
        tcp.write(l, &write_comps[id], .{ .slice = write_bufs[id][write_offsets[id]..write_lens[id]] }, u16, &slot_ids[id], writeCb);
        return .disarm;
    }
    write_offsets[id] = 0;

    if (keep_alives[id]) {
        states[id] = .reading;
        buf_lens[id] = 0;
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
