const std = @import("std");
const c = @import("../c.zig").c;
const ws_client = @import("../net/ws_client.zig");
const ws = @import("../net/ws_native.zig");

const gpa = std.heap.page_allocator;

var slot_cells: [ws_client.MAX_WS]u16 = undefined;
var str_send: c.Global = .{ .data_ptr = 0 };
var str_close: c.Global = .{ .data_ptr = 0 };

fn throwTypeError(isolate: ?*c.Isolate, msg: []const u8) void {
    const v8_msg = c.v8__String__NewFromUtf8(isolate, @ptrCast(msg.ptr), 0, @intCast(msg.len));
    const exc = c.v8__Exception__TypeError(v8_msg);
    _ = c.v8__Isolate__ThrowException(isolate, exc);
}

const ParsedUrl = struct { host: []const u8, path: []const u8, port: u16, tls: bool };

fn parseWsUrl(url: []const u8) ?ParsedUrl {
    var tls_flag = false;
    var rest: []const u8 = url;
    if (std.mem.startsWith(u8, rest, "wss://")) {
        rest = rest[6..];
        tls_flag = true;
    } else if (std.mem.startsWith(u8, rest, "ws://")) {
        rest = rest[5..];
    } else return null;

    const slash = std.mem.indexOfScalar(u8, rest, '/');
    const hostport = if (slash) |i| rest[0..i] else rest;
    if (hostport.len == 0) return null;

    var host: []const u8 = hostport;
    var port: u16 = if (tls_flag) 443 else 80;
    if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |ci| {
        host = hostport[0..ci];
        if (host.len == 0) return null;
        const ps = hostport[ci + 1 ..];
        if (ps.len == 0) return null;
        port = std.fmt.parseInt(u16, ps, 10) catch return null;
    }
    if (host.len > 255) return null; // std HostName.max_len

    var path: []const u8 = "/";
    if (slash) |i| {
        path = rest[i..];
        if (std.mem.indexOfScalar(u8, path, '#')) |h| path = path[0..h];
        if (path.len == 0) path = "/";
        if (path.len > 512) return null;
    }
    return .{ .host = host, .path = path, .port = port, .tls = tls_flag };
}

fn extractString(isolate: ?*c.Isolate, val: ?*const c.Value) ?[:0]const u8 {
    const v = val orelse return null;
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    const str = c.v8__Value__ToDetailString(v, context);
    if (str == null) return null;
    const utf8_len: usize = @intCast(c.v8__String__Utf8Length(str, isolate));
    const buf = gpa.allocSentinel(u8, utf8_len, 0) catch return null;
    _ = c.v8__String__WriteUtf8(str, isolate, buf.ptr, @intCast(utf8_len), 0);
    return buf;
}

fn setIntProp(obj: *const c.Value, context: ?*c.Context, isolate: ?*c.Isolate, key: []const u8, v: i32) void {
    var out: c.MaybeBool = undefined;
    _ = c.v8__Object__Set(@ptrCast(obj), context, c.v8__String__NewFromUtf8(isolate, key.ptr, 0, -1), @ptrCast(c.v8__Integer__New(isolate, v)), &out);
}

fn slotFrom(info: ?*const c.FunctionCallbackInfo) ?usize {
    const data = c.v8__FunctionCallbackInfo__Data(info) orelse return null;
    const sp: *u16 = @ptrCast(@alignCast(c.v8__External__Value(@ptrCast(data))));
    return sp.*;
}

pub fn setup(isolate: ?*c.Isolate, context: ?*c.Context) void {
    ws_client.init();
    ws_client.setupStrings(isolate);
    var hs: c.HandleScope = undefined;
    c.v8__HandleScope__CONSTRUCT(&hs, isolate);
    defer c.v8__HandleScope__DESTRUCT(&hs);
    const global = c.v8__Context__Global(context);
    var out: c.MaybeBool = undefined;
    const ctor = c.v8__Function__New__DEFAULT(context, wsConstructor) orelse return;
    _ = c.v8__Object__Set(global, context, c.v8__String__NewFromUtf8(isolate, "WebSocket", 0, -1), ctor, &out);
    // static constants on the constructor (browser parity)
    setIntProp(ctor, context, isolate, "CONNECTING", 0);
    setIntProp(ctor, context, isolate, "OPEN", 1);
    setIntProp(ctor, context, isolate, "CLOSING", 2);
    setIntProp(ctor, context, isolate, "CLOSED", 3);
    // method-name strings
    c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, "send", 0, -1)), &str_send);
    c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, "close", 0, -1)), &str_close);
}

fn wsConstructor(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate) orelse return;

    if (c.v8__FunctionCallbackInfo__Length(info) < 1) {
        throwTypeError(isolate, "WebSocket constructor requires a URL");
        return;
    }
    const url_arg = c.v8__FunctionCallbackInfo__INDEX(info, 0) orelse return;
    if (!c.v8__Value__IsString(url_arg)) {
        throwTypeError(isolate, "WebSocket URL must be a string");
        return;
    }
    const url_buf = extractString(isolate, @ptrCast(url_arg)) orelse {
        throwTypeError(isolate, "WebSocket URL too long");
        return;
    };
    defer gpa.free(url_buf);
    const parsed = parseWsUrl(url_buf) orelse {
        throwTypeError(isolate, "invalid WebSocket URL (expected ws:// or wss://)");
        return;
    };

    const obj = c.v8__Object__New(isolate) orelse return;
    setIntProp(@ptrCast(obj), context, isolate, "readyState", 0);
    setIntProp(@ptrCast(obj), context, isolate, "CONNECTING", 0);
    setIntProp(@ptrCast(obj), context, isolate, "OPEN", 1);
    setIntProp(@ptrCast(obj), context, isolate, "CLOSING", 2);
    setIntProp(@ptrCast(obj), context, isolate, "CLOSED", 3);

    const s = ws_client.submit(isolate, @ptrCast(obj), parsed.host, parsed.path, parsed.port, parsed.tls) catch {
        throwTypeError(isolate, "WebSocket: no connection slots available");
        return;
    };
    slot_cells[s] = @intCast(s);
    const ext = c.v8__External__New(isolate, @ptrCast(&slot_cells[s]));
    const send_fn = c.v8__Function__New__DEFAULT2(context, wsSend, @ptrCast(ext)) orelse return;
    const close_fn = c.v8__Function__New__DEFAULT2(context, wsClose, @ptrCast(ext)) orelse return;
    var out: c.MaybeBool = undefined;
    _ = c.v8__Object__Set(@ptrCast(obj), context, @ptrCast(c.v8__Global__Get(&str_send, isolate)), @ptrCast(send_fn), &out);
    _ = c.v8__Object__Set(@ptrCast(obj), context, @ptrCast(c.v8__Global__Get(&str_close, isolate)), @ptrCast(close_fn), &out);

    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(obj));
}

fn wsSend(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));

    const s = slotFrom(info) orelse return;
    if (c.v8__FunctionCallbackInfo__Length(info) < 1) return;
    const arg = c.v8__FunctionCallbackInfo__INDEX(info, 0) orelse return;

    if (c.v8__Value__IsString(arg)) {
        const str: *const c.Value = @ptrCast(arg);
        const ulen = c.v8__String__Utf8Length(str, isolate);
        if (ulen <= 0) return;
        const cap = @min(@as(usize, @intCast(ulen)), ws.WS_MSG_SIZE);
        var buf: [ws.WS_MSG_SIZE]u8 = undefined;
        const wrote = c.v8__String__WriteUtf8(str, isolate, &buf, @intCast(cap), 0);
        if (wrote <= 0) return;
        ws_client.sendBytes(s, buf[0..@intCast(wrote)], false);
        return;
    }
    if (c.v8__Value__IsArrayBuffer(arg)) {
        const ab: *const c.ArrayBuffer = @ptrCast(arg);
        var store = c.v8__ArrayBuffer__GetBackingStore(ab);
        const backing = c.std__shared_ptr__v8__BackingStore__get(&store) orelse return;
        const data = @as([*]u8, @ptrCast(c.v8__BackingStore__Data(backing) orelse return));
        const len = c.v8__BackingStore__ByteLength(backing);
        ws_client.sendBytes(s, data[0..@min(len, ws.WS_MSG_SIZE)], true);
        return;
    }
    if (c.v8__Value__IsArrayBufferView(arg)) {
        const view: *const c.Value = @ptrCast(arg);
        const ab = c.v8__ArrayBufferView__Buffer(@ptrCast(@constCast(view))) orelse return;
        var store = c.v8__ArrayBuffer__GetBackingStore(ab);
        const backing = c.std__shared_ptr__v8__BackingStore__get(&store) orelse return;
        const data = @as([*]u8, @ptrCast(c.v8__BackingStore__Data(backing) orelse return));
        const offset = c.v8__ArrayBufferView__ByteOffset(view);
        const len = c.v8__ArrayBufferView__ByteLength(view);
        ws_client.sendBytes(s, data[offset .. offset + @min(len, ws.WS_MSG_SIZE)], true);
    }
}

fn wsClose(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate) orelse return;
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));

    const s = slotFrom(info) orelse return;

    var code: u16 = 1000;
    if (c.v8__FunctionCallbackInfo__Length(info) >= 1) {
        if (c.v8__FunctionCallbackInfo__INDEX(info, 0)) |code_val| {
            var maybe: c.MaybeI32 = undefined;
            c.v8__Value__Int32Value(code_val, context, &maybe);
            if (maybe.has_value and maybe.value >= 0) {
                code = @intCast(@min(@as(i64, @intCast(maybe.value)), 65535));
            }
        }
    }
    var reason: []const u8 = "";
    var reason_buf: [123]u8 = undefined;
    if (c.v8__FunctionCallbackInfo__Length(info) >= 2) {
        if (c.v8__FunctionCallbackInfo__INDEX(info, 1)) |reason_arg| {
            const str: ?*const c.Value = if (c.v8__Value__IsString(reason_arg))
                @ptrCast(reason_arg)
            else
                c.v8__Value__ToDetailString(reason_arg, context);
            if (str) |strv| {
                const ulen = c.v8__String__Utf8Length(strv, isolate);
                if (ulen > 0) {
                    const cap = @min(@as(usize, @intCast(ulen)), reason_buf.len);
                    const wrote = c.v8__String__WriteUtf8(strv, isolate, &reason_buf, @intCast(cap), 0);
                    if (wrote > 0) reason = reason_buf[0..@intCast(wrote)];
                }
            }
        }
    }

    // readyState -> CLOSING (2) immediately (browser parity)
    if (c.v8__FunctionCallbackInfo__This(info)) |this_val| {
        if (c.v8__Value__IsObject(this_val)) {
            ws_client.setReadyState(@ptrCast(this_val), context, isolate, 2);
        }
    }
    ws_client.closeWs(s, code, reason);
}
