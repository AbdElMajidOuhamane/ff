//! JS binding: global `udp` namespace (udp.socket) + `UdpSocket` class.
//! Method names are the literal POSIX calls: bind, connect, sendto,
//! recvfrom, send, recv, getsockname, getpeername, close.

const std = @import("std");
const c = @import("../c.zig").c;
const udp_native = @import("../net/udp_native.zig");
const perm = @import("../security/permissions.zig");
const deny = @import("../security/deny.zig");

const gpa = std.heap.smp_allocator;

pub var udp_class_id: c.ClassID = 0;

const SocketHandle = struct {
    slot: u16,
    gen: u16,
    inet6: bool,
};

fn socketFinalizer(rt: ?*c.Runtime, val: c.Value) callconv(.c) void {
    _ = rt;
    if (c.getOpaque(val, udp_class_id)) |ptr| {
        const h: *SocketHandle = @ptrCast(@alignCast(ptr));
        if (udp_native.isOwned(h.slot, h.gen)) udp_native.closeSock(h.slot, h.gen);
        gpa.destroy(h);
    }
}

fn throwErr(ctx: ?*c.Context, comptime fmt: []const u8, args: anytype) c.Value {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    const err = c.newError(ctx);
    if (c.isException(err) != 0) return c.JS_EXCEPTION;
    const m = c.newStringLen(ctx, msg.ptr, msg.len);
    _ = c.setPropertyStr(ctx, err, "message", m);
    _ = c.throw(ctx, err);
    return c.JS_EXCEPTION;
}

/// Returns false with a pending PermissionDenied exception.
fn allowNet(ctx: ?*c.Context, api: []const u8, addr: []const u8, port: u16) bool {
    if (perm.global().checkNet(addr, port) == .allowed) return true;
    var detail_buf: [300]u8 = undefined;
    const detail = std.fmt.bufPrint(&detail_buf, "{s}:{d}", .{ addr, port }) catch addr;
    _ = deny.throw(ctx, api, .net, detail);
    return false;
}

fn makeSocketObj(ctx: ?*c.Context, slot: u16, inet6: bool) c.Value {
    const obj = c.newObjectClass(ctx, @intCast(udp_class_id));
    if (c.isException(obj) != 0) {
        udp_native.closeSock(slot, udp_native.genOf(slot));
        return obj;
    }
    const h = gpa.create(SocketHandle) catch {
        c.freeValue(ctx, obj);
        udp_native.closeSock(slot, udp_native.genOf(slot));
        return c.throwOutOfMemory(ctx);
    };
    h.* = .{ .slot = slot, .gen = udp_native.genOf(slot), .inet6 = inet6 };
    c.setOpaque(obj, h);
    return obj;
}

fn handleOf(ctx: ?*c.Context, this_val: c.Value) ?*SocketHandle {
    const p = c.getOpaque2(ctx, this_val, udp_class_id) orelse return null;
    const h: *SocketHandle = @ptrCast(@alignCast(p));
    if (!udp_native.isValid(h.slot, h.gen)) return null;
    return h;
}

fn getPort(ctx: ?*c.Context, opts: c.Value, comptime required: bool, comptime dflt: u16) ?u16 {
    const v = c.getPropertyStr(ctx, opts, "port");
    defer c.freeValue(ctx, v);
    if (c.isNumber(v) == 0) {
        if (required) return null;
        return dflt;
    }
    var out: i32 = 0;
    if (c.toInt32(ctx, &out, v) == -1 or out < 0 or out > 65535) return null;
    return @intCast(out);
}

fn getAddressCopy(
    ctx: ?*c.Context,
    opts: c.Value,
    dflt: ?[]const u8,
    out: *[256]u8,
) ?[]const u8 {
    const v = c.getPropertyStr(ctx, opts, "address");
    defer c.freeValue(ctx, v);
    if (c.isString(v) == 0) return dflt;
    const cs = c.toCString(ctx, v) orelse return null;
    defer c.freeCString(ctx, cs);
    const len = std.mem.len(cs);
    if (len == 0 or len > out.len) return null;
    @memcpy(out[0..len], cs[0..len]);
    return out[0..len];
}

// ── namespace: udp.socket([family]) — socket(2) ─────────────────

fn udpSocket(ctx: ?*c.Context, _: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    var inet6 = false;
    if (argc >= 1 and c.isString(argv[0]) != 0) {
        const s = c.toCString(ctx, argv[0]) orelse return c.JS_EXCEPTION;
        defer c.freeCString(ctx, s);
        const len = std.mem.len(s);
        if (std.mem.eql(u8, s[0..len], "inet6")) {
            inet6 = true;
        } else if (!std.mem.eql(u8, s[0..len], "inet")) {
            return throwErr(ctx, "udp.socket: family must be \"inet\" or \"inet6\"", .{});
        }
    }
    const slot = udp_native.open(inet6) catch {
        return throwErr(ctx, "udp.socket: no socket slots available", .{});
    };
    return makeSocketObj(ctx, slot, inet6);
}

// ── bind(2) ─────────────────────────────────────────────────────

fn sockBind(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const h = handleOf(ctx, this_val) orelse return throwErr(ctx, "bind: socket is closed", .{});
    if (argc < 1 or c.isObject(argv[0]) == 0) {
        _ = c.throwTypeError(ctx, "bind: options object required ({ address?, port? })");
        return c.JS_EXCEPTION;
    }
    var abuf: [256]u8 = undefined;
    const dflt: ?[]const u8 = if (h.inet6) "::" else "0.0.0.0";
    const addr_s = getAddressCopy(ctx, argv[0], dflt, &abuf) orelse
        return throwErr(ctx, "bind: invalid address", .{});
    const port = getPort(ctx, argv[0], false, 0) orelse
        return throwErr(ctx, "bind: invalid port", .{});
    const addr = std.Io.net.IpAddress.parse(addr_s, port) catch
        return throwErr(ctx, "bind: invalid address", .{});

    if (!allowNet(ctx, "udp.bind", addr_s, port)) return c.JS_EXCEPTION;

    udp_native.bindSock(h.slot, addr) catch {
        return throwErr(ctx, "bind: failed (address in use?)", .{});
    };
    return c.JS_UNDEFINED;
}

// ── connect(2) ──────────────────────────────────────────────────

fn sockConnect(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const h = handleOf(ctx, this_val) orelse return throwErr(ctx, "connect: socket is closed", .{});
    if (argc < 1 or c.isObject(argv[0]) == 0) {
        _ = c.throwTypeError(ctx, "connect: options object required ({ address, port })");
        return c.JS_EXCEPTION;
    }
    var abuf: [256]u8 = undefined;
    const addr_s = getAddressCopy(ctx, argv[0], null, &abuf) orelse
        return throwErr(ctx, "connect: address required", .{});
    const port = getPort(ctx, argv[0], true, 0) orelse
        return throwErr(ctx, "connect: port required", .{});
    const addr = std.Io.net.IpAddress.parse(addr_s, port) catch
        return throwErr(ctx, "connect: invalid address", .{});

    if (!allowNet(ctx, "udp.connect", addr_s, port)) return c.JS_EXCEPTION;

    udp_native.connectSock(h.slot, addr) catch |err| {
        return throwErr(ctx, "connect: {s}", .{@errorName(err)});
    };
    return c.JS_UNDEFINED;
}

// ── sendto(2) ───────────────────────────────────────────────────

fn sockSendto(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const h = handleOf(ctx, this_val) orelse return throwErr(ctx, "sendto: socket is closed", .{});
    if (argc < 2 or c.isObject(argv[1]) == 0) {
        _ = c.throwTypeError(ctx, "sendto: requires (data, { address, port })");
        return c.JS_EXCEPTION;
    }
    var abuf: [256]u8 = undefined;
    const addr_s = getAddressCopy(ctx, argv[1], null, &abuf) orelse
        return throwErr(ctx, "sendto: address required", .{});
    const port = getPort(ctx, argv[1], true, 0) orelse
        return throwErr(ctx, "sendto: port required", .{});
    const addr = std.Io.net.IpAddress.parse(addr_s, port) catch
        return throwErr(ctx, "sendto: invalid address", .{});

    if (!allowNet(ctx, "udp.sendto", addr_s, port)) return c.JS_EXCEPTION;

    return submitSendPromise(ctx, h.slot, argv[0], addr);
}

// ── send(2) — connected ─────────────────────────────────────────

fn sockSend(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const h = handleOf(ctx, this_val) orelse return throwErr(ctx, "send: socket is closed", .{});
    if (argc < 1) {
        _ = c.throwTypeError(ctx, "send: requires data (ArrayBuffer or TypedArray)");
        return c.JS_EXCEPTION;
    }
    const dest = udp_native.peerOf(h.slot) orelse
        return throwErr(ctx, "send: socket is not connected", .{});
    // The destination was authorized at connect() time; send() inherits it.
    return submitSendPromise(ctx, h.slot, argv[0], dest);
}

fn submitSendPromise(
    ctx: ?*c.Context,
    slot: u16,
    data: c.Value,
    dest: ?std.Io.net.IpAddress,
) c.Value {
    var cap: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &cap);
    if (c.isException(promise) != 0) return promise;
    defer c.freeValue(ctx, cap[0]);
    defer c.freeValue(ctx, cap[1]);
    udp_native.submitSend(ctx, slot, data, dest, cap[0], cap[1]) catch |err| {
        return throwErr(ctx, "send: {s}", .{@errorName(err)});
    };
    return promise;
}

// ── recvfrom(2) / recv(2) ───────────────────────────────────────

fn sockRecvfrom(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const h = handleOf(ctx, this_val) orelse return throwErr(ctx, "recvfrom: socket is closed", .{});
    if (argc < 1) {
        _ = c.throwTypeError(ctx, "recvfrom: requires a buffer (Uint8Array or ArrayBuffer)");
        return c.JS_EXCEPTION;
    }
    return submitRecvPromise(ctx, h.slot, argv[0], true);
}

fn sockRecv(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const h = handleOf(ctx, this_val) orelse return throwErr(ctx, "recv: socket is closed", .{});
    if (udp_native.peerOf(h.slot) == null)
        return throwErr(ctx, "recv: socket is not connected", .{});
    if (argc < 1) {
        _ = c.throwTypeError(ctx, "recv: requires a buffer (Uint8Array or ArrayBuffer)");
        return c.JS_EXCEPTION;
    }
    return submitRecvPromise(ctx, h.slot, argv[0], false);
}

fn submitRecvPromise(
    ctx: ?*c.Context,
    slot: u16,
    buf: c.Value,
    with_peer: bool,
) c.Value {
    var cap: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &cap);
    if (c.isException(promise) != 0) return promise;
    defer c.freeValue(ctx, cap[0]);
    defer c.freeValue(ctx, cap[1]);
    udp_native.submitRecv(ctx, slot, buf, cap[0], cap[1], with_peer) catch |err| {
        return throwErr(ctx, "recvfrom: {s}", .{@errorName(err)});
    };
    return promise;
}

// ── getsockname(2) / getpeername(2) / close(2) ──────────────────

fn sockGetsockname(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const h = handleOf(ctx, this_val) orelse return throwErr(ctx, "getsockname: socket is closed", .{});
    const sa = udp_native.localAddr(h.slot) catch
        return throwErr(ctx, "getsockname: failed", .{});
    return udp_native.sockAddrToJs(ctx, sa);
}

fn sockGetpeername(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const h = handleOf(ctx, this_val) orelse return throwErr(ctx, "getpeername: socket is closed", .{});
    const sa = udp_native.peerAddr(h.slot) catch
        return throwErr(ctx, "getpeername: socket is not connected", .{});
    return udp_native.sockAddrToJs(ctx, sa);
}

fn sockClose(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const p = c.getOpaque2(ctx, this_val, udp_class_id) orelse return c.JS_UNDEFINED;
    const h: *SocketHandle = @ptrCast(@alignCast(p));
    udp_native.closeSock(h.slot, h.gen);
    return c.JS_UNDEFINED;
}

// ── registration ────────────────────────────────────────────────

pub fn setup(ctx: ?*c.Context) void {
    udp_native.init();

    var def = c.ClassDef{
        .class_name = "UdpSocket",
        .finalizer = socketFinalizer,
    };
    _ = c.newClassID(c.getRuntime(ctx), &udp_class_id);
    _ = c.newClass(c.getRuntime(ctx), udp_class_id, &def);

    const proto = c.newObject(ctx);
    const methods = [_]struct { name: [*:0]const u8, func: *const c.CFunction, len: c_int }{
        .{ .name = "bind", .func = &sockBind, .len = 1 },
        .{ .name = "connect", .func = &sockConnect, .len = 1 },
        .{ .name = "sendto", .func = &sockSendto, .len = 2 },
        .{ .name = "recvfrom", .func = &sockRecvfrom, .len = 1 },
        .{ .name = "send", .func = &sockSend, .len = 1 },
        .{ .name = "recv", .func = &sockRecv, .len = 1 },
        .{ .name = "getsockname", .func = &sockGetsockname, .len = 0 },
        .{ .name = "getpeername", .func = &sockGetpeername, .len = 0 },
        .{ .name = "close", .func = &sockClose, .len = 0 },
    };
    for (methods) |m| {
        const fn_val = c.newCFunction(ctx, m.func, m.name, m.len);
        _ = c.definePropertyValueStr(ctx, proto, m.name, fn_val, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
    }
    c.setClassProto(ctx, udp_class_id, proto);

    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);
    const udp_obj = c.newObject(ctx);
    const socket_fn = c.newCFunction(ctx, &udpSocket, "socket", 1);
    _ = c.definePropertyValueStr(ctx, udp_obj, "socket", socket_fn, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
    _ = c.definePropertyValueStr(ctx, global, "udp", udp_obj, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
}
