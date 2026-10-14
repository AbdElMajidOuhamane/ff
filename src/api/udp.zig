//! JS binding: global `udp` namespace (udp.socket) + `UdpSocket` class.
//! Method names are the literal POSIX calls: bind, connect, sendto,
//! recvfrom, send, recv, getsockname, getpeername, close.

const std = @import("std");
const c = @import("../c.zig").c;
const udp_native = @import("../net/udp_native.zig");

const gpa = std.heap.smp_allocator;

pub var udp_class_id: c.ClassID = 0;

const SocketHandle = struct {
    slot: u16,
    gen: u16,
    inet6: bool,
};

/// Close the socket still owned by this handle and free the handle storage.
fn socketFinalizer(rt: ?*c.Runtime, val: c.Value) callconv(.c) void {
    _ = rt;
    if (c.getOpaque(val, udp_class_id)) |ptr| {
        const h: *SocketHandle = @ptrCast(@alignCast(ptr));
        if (udp_native.isOwned(h.slot, h.gen)) udp_native.closeSock(h.slot, h.gen);
        gpa.destroy(h);
    }
}

/// Throw a JS Error with the formatted message and return JS_EXCEPTION.
/// Use the literal format string if the message exceeds the local buffer.
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

/// Wrap an open slot with its current generation and address family.
/// Handle allocation failure raises a JS out-of-memory exception.
fn makeSocketObj(ctx: ?*c.Context, slot: u16, inet6: bool) c.Value {
    const obj = c.newObjectClass(ctx, @intCast(udp_class_id));
    const h = gpa.create(SocketHandle) catch return c.throwOutOfMemory(ctx);
    h.* = .{ .slot = slot, .gen = udp_native.genOf(slot), .inet6 = inet6 };
    c.setOpaque(obj, h);
    return obj;
}

/// Borrow a live, non-closing handle, or return null for a stale/closed socket.
/// A receiver of the wrong class also returns null and sets a JS TypeError.
fn handleOf(ctx: ?*c.Context, this_val: c.Value) ?*SocketHandle {
    const p = c.getOpaque2(ctx, this_val, udp_class_id) orelse return null;
    const h: *SocketHandle = @ptrCast(@alignCast(p));
    if (!udp_native.isValid(h.slot, h.gen)) return null;
    return h;
}

/// Coerce a numeric port to int32 and accept values in 0..65535.
/// A nonnumeric/missing property yields null if required, otherwise dflt;
/// conversion failure or an out-of-range converted value yields null.
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

/// Copy a string address into `out`, returning a borrowed slice without a NUL.
/// Missing/nonstrings yield dflt; conversion failure, empty strings, or strings
/// exceeding out's capacity yield null. Embedded NUL ends the copied address.
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

/// Create an unbound UDP socket: 'inet6' selects IPv6, 'inet' or nonstring/missing
/// input selects IPv4. Throw for other strings or native socket allocation failure;
/// native open errors share the 'no socket slots available' message.
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

/// Bind to a numeric IP, defaulting to the family wildcard and ephemeral port 0.
/// Return undefined; throw TypeError for missing/nonobject options and Error
/// for closed sockets, invalid addresses/ports, or native bind failure.
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
    udp_native.bindSock(h.slot, addr) catch {
        return throwErr(ctx, "bind: failed (address in use?)", .{});
    };
    return c.JS_UNDEFINED;
}

// ── connect(2) ──────────────────────────────────────────────────

/// Set the UDP peer from a required numeric IP and port; return undefined.
/// Throw TypeError for missing/nonobject options and Error for closed sockets,
/// invalid addresses/ports, or native connect errors (reported by name).
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
    udp_native.connectSock(h.slot, addr) catch |err| {
        return throwErr(ctx, "connect: {s}", .{@errorName(err)});
    };
    return c.JS_UNDEFINED;
}

// ── sendto(2) ───────────────────────────────────────────────────

/// Send buffer bytes to a required numeric IP and port, returning a byte-count
/// promise. Closed sockets, invalid arguments, and submission errors throw
/// synchronously; send I/O failure or cancellation rejects the promise.
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
    return submitSendPromise(ctx, h.slot, argv[0], addr);
}

// ── send(2) — connected ─────────────────────────────────────────

/// Send buffer bytes to the connected peer and return a byte-count promise.
/// Closed/unconnected sockets, missing data, and submission errors throw
/// synchronously; send I/O failure rejects the promise.
fn sockSend(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const h = handleOf(ctx, this_val) orelse return throwErr(ctx, "send: socket is closed", .{});
    if (argc < 1) {
        _ = c.throwTypeError(ctx, "send: requires data (ArrayBuffer or TypedArray)");
        return c.JS_EXCEPTION;
    }
    const dest = udp_native.peerOf(h.slot) orelse
        return throwErr(ctx, "send: socket is not connected", .{});
    return submitSendPromise(ctx, h.slot, argv[0], dest);
}

/// Create a send promise and submit without copying payload bytes.
/// Native submission errors become synchronous JS Errors by name;
/// I/O errors reject the promise. Promise creation failure returns JS_EXCEPTION.
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

/// Receive into a Uint8Array/ArrayBuffer, resolving to [data view, sender address].
/// Datagrams exceeding the buffer are truncated. Closed sockets, missing buffers,
/// and submission errors throw synchronously; I/O failure or close rejects.
fn sockRecvfrom(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const h = handleOf(ctx, this_val) orelse return throwErr(ctx, "recvfrom: socket is closed", .{});
    if (argc < 1) {
        _ = c.throwTypeError(ctx, "recvfrom: requires a buffer (Uint8Array or ArrayBuffer)");
        return c.JS_EXCEPTION;
    }
    return submitRecvPromise(ctx, h.slot, argv[0], true);
}

/// Receive from the connected peer into a Uint8Array/ArrayBuffer and resolve to
/// a view of the received bytes, truncated to buffer capacity. Closed/unconnected
/// sockets, missing buffers, and submission errors throw; I/O failure or close rejects.
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

/// Create a receive promise; with_peer selects [data, address] rather than data.
/// The result views the supplied buffer. Native submission errors throw JS Errors
/// by name; I/O errors reject. Promise creation failure returns JS_EXCEPTION.
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

/// Return the local {address, port, family}; throw for a closed socket or lookup failure.
fn sockGetsockname(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const h = handleOf(ctx, this_val) orelse return throwErr(ctx, "getsockname: socket is closed", .{});
    const sa = udp_native.localAddr(h.slot) catch
        return throwErr(ctx, "getsockname: failed", .{});
    return udp_native.sockAddrToJs(ctx, sa);
}

/// Return the peer {address, port, family}; throw for closed sockets or lookup
/// failure, with all native lookup errors reported as 'socket is not connected'.
fn sockGetpeername(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const h = handleOf(ctx, this_val) orelse return throwErr(ctx, "getpeername: socket is closed", .{});
    const sa = udp_native.peerAddr(h.slot) catch
        return throwErr(ctx, "getpeername: socket is not connected", .{});
    return udp_native.sockAddrToJs(ctx, sa);
}

/// Begin closing this handle's socket and reject pending operations.
/// Return undefined; repeated closes and stale generations are harmless.
fn sockClose(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const p = c.getOpaque2(ctx, this_val, udp_class_id) orelse return c.JS_UNDEFINED;
    const h: *SocketHandle = @ptrCast(@alignCast(p));
    udp_native.closeSock(h.slot, h.gen);
    return c.JS_UNDEFINED;
}

// ── registration ────────────────────────────────────────────────

/// Initialize native slots and register UdpSocket methods and the global udp.socket.
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
