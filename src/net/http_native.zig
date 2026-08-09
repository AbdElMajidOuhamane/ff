const std = @import("std");
const xev = @import("xev");
const c = @import("../c.zig").c;
const microtasks = @import("../event/microtasks.zig");

const gpa = std.heap.smp_allocator;

const MAX_CONN = 512;
const READ_BUF_SIZE = 16384;
const WRITE_BUF_SIZE = 16384;
const ACCEPT_BATCH = 8;

const ConnState = enum(u8) { idle, reading, writing, closing };

// Verbs classified to a u8 tag during the header scan; index into str_methods[].
const Method = enum(u8) { get, post, put, delete, head, options, patch, none };

// ---- SoA hot state: compact + contiguous ----
var states: [MAX_CONN]ConnState = [_]ConnState{.idle} ** MAX_CONN;
var fds: [MAX_CONN]xev.TCP = undefined;
var buf_lens: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
var write_lens: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
var write_offsets: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
var keep_alives: [MAX_CONN]bool = [_]bool{true} ** MAX_CONN;
var methods: [MAX_CONN]Method = [_]Method{.none} ** MAX_CONN;
var read_comps: [MAX_CONN]xev.Completion = [_]xev.Completion{.{}} ** MAX_CONN;
var write_comps: [MAX_CONN]xev.Completion = [_]xev.Completion{.{}} ** MAX_CONN;
var close_comps: [MAX_CONN]xev.Completion = [_]xev.Completion{.{}} ** MAX_CONN;

// ---- Cold bulk data: out-of-line so hot state stays dense ----
var read_bufs: [MAX_CONN][READ_BUF_SIZE]u8 = undefined;
var write_bufs: [MAX_CONN][WRITE_BUF_SIZE]u8 = undefined;

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

// Single-pass, case-insensitive substring search.
fn findTokenCI(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    outer: for (0..haystack.len - needle.len + 1) |i| {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) continue :outer;
        }
        return i;
    }
    return null;
}

// Length-dispatched verb classifier (case-sensitive, matches HTTP wire form).
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

// One scan of request-line + headers extracts method, url, HTTP version,
// content-length and keep-alive.
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

// Fast integer -> ASCII.
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

// Close immediately (no 0-delay timer hop). The states guard prevents double
// close; closeCb frees the slot. This is what keeps ff fast under connect churn.
fn closeConn(id: usize) void {
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

    fds[id].read(l, &read_comps[id], .{ .slice = &read_bufs[id] }, u16, &slot_ids[id], readCb);
    return true;
}

// DOD: drain up to ACCEPT_BATCH connections per wakeup instead of one
// event-loop round-trip each, to cut accept overhead under connection churn.
// (On Darwin, sockets accepted from a non-blocking listener inherit O_NONBLOCK,
// so no fcntl is needed here.)
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
        if (std.posix.errno(rc) != .SUCCESS) break; // EAGAIN / drained
        const fd: std.posix.socket_t = @intCast(rc);
        if (!setupSlot(l, xev.TCP.initFd(fd))) break; // slots exhausted
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

    const n = r catch {
        closeConn(id);
        return .disarm;
    };

    if (n == 0) {
        closeConn(id);
        return .disarm;
    }

    buf_lens[id] += n;

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

    write_offsets[id] += written;
    if (write_offsets[id] < write_lens[id]) {
        tcp.write(l, &write_comps[id], .{ .slice = write_bufs[id][write_offsets[id]..write_lens[id]] }, u16, &slot_ids[id], writeCb);
        return .disarm;
    }

    if (keep_alives[id]) {
        states[id] = .reading;
        buf_lens[id] = 0;
        write_offsets[id] = 0;
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
