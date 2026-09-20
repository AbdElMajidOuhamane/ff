


const std = @import("std");
const c = @import("../c.zig").c;
const ws_client = @import("../net/ws_client.zig");
const ws = @import("../net/ws_native.zig");

const gpa = std.heap.smp_allocator;

pub var ws_client_class_id: c.ClassID = 0;

const WsClientData = struct {
    slot_id: u16,
};

fn wsClientFinalizer(rt: ?*c.Runtime, val: c.Value) callconv(.c) void {
    _ = rt;
    if (c.getOpaque(val, ws_client_class_id)) |ptr| {
        const data: *WsClientData = @ptrCast(@alignCast(ptr));
        gpa.destroy(data);
    }
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
    if (host.len > 255) return null;
    var path: []const u8 = "/";
    if (slash) |i| {
        path = rest[i..];
        if (std.mem.indexOfScalar(u8, path, '#')) |h| path = path[0..h];
        if (path.len == 0) path = "/";
        if (path.len > 512) return null;
    }
    return .{ .host = host, .path = path, .port = port, .tls = tls_flag };
}

fn throwTypeError(ctx: ?*c.Context, msg: []const u8) void {
    _ = c.throwTypeError(ctx, "WebSocket: %s", @as([*c]const u8, @ptrCast(msg.ptr)));
}

fn extractString(ctx: ?*c.Context, val: c.Value) ?[:0]const u8 {
    const cstr = c.toCString(ctx, val) orelse return null;
    defer c.freeCString(ctx, cstr);
    const len = std.mem.len(cstr);
    const buf = gpa.allocSentinel(u8, len, 0) catch return null;
    @memcpy(buf[0..len], cstr[0..len]);
    return buf;
}

fn slotFromThis(ctx: ?*c.Context, this_val: c.Value) ?usize {
    const data_ptr = c.getOpaque2(ctx, this_val, ws_client_class_id) orelse return null;
    const data: *WsClientData = @ptrCast(@alignCast(data_ptr));
    return data.slot_id;
}

fn slotFromArg(ctx: ?*c.Context, arg: c.Value) ?usize {
    // Try opaque first
    if (c.isObject(arg) != 0) {
        if (c.getOpaque2(ctx, arg, ws_client_class_id)) |ptr| {
            const data: *WsClientData = @ptrCast(@alignCast(ptr));
            return data.slot_id;
        }
    }
    return null;
}

pub fn setup(ctx: ?*c.Context) void {
    ws_client.init(ctx); // CHANGED: pass ctx so the pump can dispatch events

    var def = c.ClassDef{
        .class_name = "WebSocket",
        .finalizer = wsClientFinalizer,
    };
    _ = c.newClassID(c.getRuntime(ctx), &ws_client_class_id);
    _ = c.newClass(c.getRuntime(ctx), ws_client_class_id, &def);

    const proto = c.newObject(ctx);
    const methods = [_]struct { name: [*:0]const u8, func: *const c.CFunction, len: c_int }{
        .{ .name = "send", .func = &wsSend, .len = 1 },
        .{ .name = "close", .func = &wsClose, .len = 0 },
    };
    for (methods) |m| {
        const fn_val = c.newCFunction(ctx, m.func, m.name, m.len);
        _ = c.definePropertyValueStr(ctx, proto, m.name, fn_val, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
    }
    c.setClassProto(ctx, ws_client_class_id, proto);

    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);

    //const ctor = c.newCFunction(ctx, &wsConstructor, "WebSocket", 2);
    const ctor = c.newCFunction2(ctx, &wsConstructor, "WebSocket", 2, c.JS_CFUNC_constructor, 0);
    _ = c.definePropertyValueStr(ctx, global, "WebSocket", ctor, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
    // Static constants
    _ = c.definePropertyValueStr(ctx, ctor, "CONNECTING", c.newInt32(ctx, 0), c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
    _ = c.definePropertyValueStr(ctx, ctor, "OPEN", c.newInt32(ctx, 1), c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
    _ = c.definePropertyValueStr(ctx, ctor, "CLOSING", c.newInt32(ctx, 2), c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
    _ = c.definePropertyValueStr(ctx, ctor, "CLOSED", c.newInt32(ctx, 3), c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
}

fn wsConstructor(ctx: ?*c.Context, _: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    if (argc < 1) {
        throwTypeError(ctx, "WebSocket constructor requires a URL");
        return c.JS_EXCEPTION;
    }
    const url_arg = argv[0];
    if (c.isString(url_arg) == 0) {
        throwTypeError(ctx, "WebSocket URL must be a string");
        return c.JS_EXCEPTION;
    }
    const url_buf = extractString(ctx, url_arg) orelse {
        throwTypeError(ctx, "WebSocket URL too long");
        return c.JS_EXCEPTION;
    };
    defer gpa.free(url_buf);
    const parsed = parseWsUrl(url_buf) orelse {
        throwTypeError(ctx, "invalid WebSocket URL (expected ws:// or wss://)");
        return c.JS_EXCEPTION;
    };

    const obj = c.newObjectClass(ctx, @intCast(ws_client_class_id));
    _ = c.definePropertyValueStr(ctx, obj, "readyState", c.newInt32(ctx, 0), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "CONNECTING", c.newInt32(ctx, 0), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "OPEN", c.newInt32(ctx, 1), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "CLOSING", c.newInt32(ctx, 2), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "CLOSED", c.newInt32(ctx, 3), c.PROP_C_W_E);

    const s = ws_client.submit(ctx, obj, parsed.host, parsed.path, parsed.port, parsed.tls) catch {
        throwTypeError(ctx, "WebSocket: no connection slots available");
        return c.JS_EXCEPTION;
    };

    const data = gpa.create(WsClientData) catch return c.throwOutOfMemory(ctx);
    data.* = .{ .slot_id = @intCast(s) };
    c.setOpaque(obj, data);

    return obj;
}

fn wsSend(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const s = slotFromThis(ctx, this_val) orelse return c.JS_UNDEFINED;
    if (argc < 1) return c.JS_UNDEFINED;
    const arg = argv[0];

    if (c.isString(arg) != 0) {
        const cstr = c.toCString(ctx, arg) orelse return c.JS_UNDEFINED;
        defer c.freeCString(ctx, cstr);
        const len = std.mem.len(cstr);
        if (len == 0) return c.JS_UNDEFINED;
        const cap = @min(len, ws.WS_MSG_SIZE);
        ws_client.sendBytes(s, cstr[0..cap], false);
        return c.JS_UNDEFINED;
    }
    // ArrayBuffer
    var size: usize = 0;
    const p = c.getArrayBuffer(ctx, &size, arg);
    if (p != null and size > 0) {
    ws_client.sendBytes(s, p[0..@min(size, ws.WS_MSG_SIZE)], true);
        return c.JS_UNDEFINED;
    }
    // ArrayBufferView — try buffer property
    const buf_val = c.getPropertyStr(ctx, arg, "buffer");
    if (c.isObject(buf_val) != 0) {
        const p2 = c.getArrayBuffer(ctx, &size, buf_val);
        if (p2 != null and size > 0) {
            const offset_val = c.getPropertyStr(ctx, arg, "byteOffset");
            var offset: i32 = 0;
            _ = c.toInt32(ctx, &offset, offset_val);
            const len_val = c.getPropertyStr(ctx, arg, "byteLength");
            var view_len: i32 = 0;
            _ = c.toInt32(ctx, &view_len, len_val);
           const start = @as(usize, @intCast(@max(offset, 0)));
            const end = @min(start + @as(usize, @intCast(@max(view_len, 0))), size);
            if (end > start) ws_client.sendBytes(s, p2[start..end], true);
        }
    }
    return c.JS_UNDEFINED;
}

fn wsClose(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const s = slotFromThis(ctx, this_val) orelse return c.JS_UNDEFINED;

    var code: u16 = 1000;
    if (argc >= 1) {
        var maybe: i32 = 0;
        if (c.toInt32(ctx, &maybe, argv[0]) != -1 and maybe >= 0) {
            code = @intCast(@min(@as(i64, @intCast(maybe)), 65535));
        }
    }
    var reason: []const u8 = "";
    var reason_buf: [123]u8 = undefined;
    if (argc >= 2) {
        if (c.isString(argv[1]) != 0) {
    const cstr = c.toCString(ctx, argv[1]) orelse return c.JS_UNDEFINED;
    defer c.freeCString(ctx, cstr);
    const len = std.mem.len(cstr);
    if (len > 0) {
        const cap = @min(len, reason_buf.len);
        @memcpy(reason_buf[0..cap], cstr[0..cap]);
        reason = reason_buf[0..cap];
    }
}
    }

    // readyState -> CLOSING (2) immediately
    setReadyState(ctx, this_val, 2);
    ws_client.closeWs(s, code, reason);
    return c.JS_UNDEFINED;
}

fn setReadyState(ctx: ?*c.Context, obj: c.Value, v: i32) void {
    _ = c.definePropertyValueStr(ctx, obj, "readyState", c.newInt32(ctx, v), c.PROP_C_W_E);
}
