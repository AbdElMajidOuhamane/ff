const std = @import("std");
const xev = @import("xev");
const c = @import("../c.zig").c;
const engine = @import("../engine/engine.zig");
const perm = @import("../security/permissions.zig");
const deny = @import("../security/deny.zig");

pub const MAX_TCP = 128;
pub const RBUF_SIZE = 16 * 1024;
pub const WBUF_SIZE = 16 * 1024;

pub const TcpSlotState = enum(u8) {
    free = 0,
    connecting = 1,
    connected = 2,
    closed = 3,
};

pub var states: [MAX_TCP]TcpSlotState = [_]TcpSlotState{.free} ** MAX_TCP;
pub var gens: [MAX_TCP]u16 = [_]u16{1} ** MAX_TCP;
pub var fds: [MAX_TCP]xev.TCP = undefined;
pub var connect_comps: [MAX_TCP]xev.Completion = [_]xev.Completion{.{}} ** MAX_TCP;
pub var read_comps: [MAX_TCP]xev.Completion = [_]xev.Completion{.{}} ** MAX_TCP;
pub var write_comps: [MAX_TCP]xev.Completion = [_]xev.Completion{.{}} ** MAX_TCP;
pub var close_comps: [MAX_TCP]xev.Completion = [_]xev.Completion{.{}} ** MAX_TCP;
pub var read_cancel_comps: [MAX_TCP]xev.Completion = [_]xev.Completion{.{}} ** MAX_TCP;
pub var write_cancel_comps: [MAX_TCP]xev.Completion = [_]xev.Completion{.{}} ** MAX_TCP;
pub var connect_cancel_comps: [MAX_TCP]xev.Completion = [_]xev.Completion{.{}} ** MAX_TCP;
pub var read_bufs: [MAX_TCP][RBUF_SIZE]u8 = undefined;
pub var write_bufs: [MAX_TCP][WBUF_SIZE]u8 = undefined;

pub var connect_resolves: [MAX_TCP]?c.Value = [_]?c.Value{null} ** MAX_TCP;
pub var connect_rejects: [MAX_TCP]?c.Value = [_]?c.Value{null} ** MAX_TCP;
pub var read_resolves: [MAX_TCP]?c.Value = [_]?c.Value{null} ** MAX_TCP;
pub var read_rejects: [MAX_TCP]?c.Value = [_]?c.Value{null} ** MAX_TCP;
pub var write_resolves: [MAX_TCP]?c.Value = [_]?c.Value{null} ** MAX_TCP;
pub var write_rejects: [MAX_TCP]?c.Value = [_]?c.Value{null} ** MAX_TCP;
pub var slot_ctx: [MAX_TCP]?*c.Context = [_]?*c.Context{null} ** MAX_TCP;

var tcp_class_id: c.ClassID = 0;

inline fn packHandle(slot: u16, gen: u16) ?*anyopaque {
    const raw = (@as(usize, gen) << 16) | @as(usize, slot);
    return @ptrFromInt(raw + 1);
}

inline fn unpackHandle(ptr: ?*anyopaque) struct { slot: u16, gen: u16 } {
    const raw = @intFromPtr(ptr) - 1;
    return .{
        .slot = @truncate(raw),
        .gen = @truncate(raw >> 16),
    };
}

fn liveSlot(ctx: ?*c.Context, this_val: c.Value) ?usize {
    const ptr = c.getOpaque2(ctx, this_val, tcp_class_id) orelse return null;
    const h = unpackHandle(ptr);
    const slot = h.slot;
    if (slot >= MAX_TCP) return null;
    if (states[slot] == .free) return null;
    if (gens[slot] != h.gen) return null;
    return slot;
}

fn onConnect(
    ud: ?*anyopaque,
    l: *xev.Loop,
    comp: *xev.Completion,
    tcp: xev.TCP,
    r: xev.ConnectError!void,
) xev.CallbackAction {
    _ = comp;
    _ = l;
    _ = tcp;
    const slot = @intFromPtr(ud);
    if (slot >= MAX_TCP) return .disarm;
    const ctx = slot_ctx[slot] orelse return .disarm;
    const res_fn = connect_resolves[slot];
    const rej_fn = connect_rejects[slot];
    connect_resolves[slot] = null;
    connect_rejects[slot] = null;

    r catch |err| {
        // Fix 1: Failed connect closes fd and frees slot so fd is not leaked
        _ = std.c.close(fds[slot].fd);
        states[slot] = .free;
        gens[slot] +%= 1;
        slot_ctx[slot] = null;

        if (rej_fn) |rf| {
            defer c.freeValue(ctx, rf);
            const err_msg = std.fmt.allocPrint(std.heap.page_allocator, "connect failed: {s}", .{@errorName(err)}) catch "connect failed";
            defer std.heap.page_allocator.free(err_msg);
            const err_str = c.newStringLen(ctx, err_msg.ptr, @intCast(err_msg.len));
            var argv = [_]c.Value{err_str};
            _ = c.call(ctx, rf, c.JS_UNDEFINED, 1, &argv);
            c.freeValue(ctx, err_str);
        }
        if (res_fn) |res| c.freeValue(ctx, res);
        return .disarm;
    };

    states[slot] = .connected;
    if (res_fn) |rf| {
        defer c.freeValue(ctx, rf);
        const sock_obj = c.newObjectClass(ctx, tcp_class_id);
        _ = c.setOpaque(sock_obj, packHandle(@intCast(slot), gens[slot]));
        var argv = [_]c.Value{sock_obj};
        _ = c.call(ctx, rf, c.JS_UNDEFINED, 1, &argv);
        c.freeValue(ctx, sock_obj);
    }
    if (rej_fn) |rej| c.freeValue(ctx, rej);
    return .disarm;
}

fn onRead(
    ud: ?*anyopaque,
    l: *xev.Loop,
    comp: *xev.Completion,
    tcp: xev.TCP,
    buf: xev.ReadBuffer,
    r: xev.ReadError!usize,
) xev.CallbackAction {
    _ = comp;
    _ = l;
    _ = tcp;
    _ = buf;
    const slot = @intFromPtr(ud);
    if (slot >= MAX_TCP) return .disarm;
    const ctx = slot_ctx[slot] orelse return .disarm;
    const res_fn = read_resolves[slot];
    const rej_fn = read_rejects[slot];
    read_resolves[slot] = null;
    read_rejects[slot] = null;

    const n = r catch |err| {
        if (rej_fn) |rf| {
            defer c.freeValue(ctx, rf);
            const err_msg = std.fmt.allocPrint(std.heap.page_allocator, "read failed: {s}", .{@errorName(err)}) catch "read failed";
            defer std.heap.page_allocator.free(err_msg);
            const err_str = c.newStringLen(ctx, err_msg.ptr, @intCast(err_msg.len));
            var argv = [_]c.Value{err_str};
            _ = c.call(ctx, rf, c.JS_UNDEFINED, 1, &argv);
            c.freeValue(ctx, err_str);
        }
        if (res_fn) |res| c.freeValue(ctx, res);
        return .disarm;
    };

    if (res_fn) |rf| {
        defer c.freeValue(ctx, rf);
        if (n == 0) {
            var argv = [_]c.Value{c.JS_NULL};
            _ = c.call(ctx, rf, c.JS_UNDEFINED, 1, &argv);
        } else {
            const u8_arr = c.newUint8ArrayCopy(ctx, read_bufs[slot][0..n].ptr, n);
            var argv = [_]c.Value{u8_arr};
            _ = c.call(ctx, rf, c.JS_UNDEFINED, 1, &argv);
            c.freeValue(ctx, u8_arr);
        }
    }
    if (rej_fn) |rej| c.freeValue(ctx, rej);
    return .disarm;
}

fn onWrite(
    ud: ?*anyopaque,
    l: *xev.Loop,
    comp: *xev.Completion,
    tcp: xev.TCP,
    buf: xev.WriteBuffer,
    r: xev.WriteError!usize,
) xev.CallbackAction {
    _ = comp;
    _ = l;
    _ = tcp;
    _ = buf;
    const slot = @intFromPtr(ud);
    if (slot >= MAX_TCP) return .disarm;
    const ctx = slot_ctx[slot] orelse return .disarm;
    const res_fn = write_resolves[slot];
    const rej_fn = write_rejects[slot];
    write_resolves[slot] = null;
    write_rejects[slot] = null;

    const n = r catch |err| {
        if (rej_fn) |rf| {
            defer c.freeValue(ctx, rf);
            const err_msg = std.fmt.allocPrint(std.heap.page_allocator, "write failed: {s}", .{@errorName(err)}) catch "write failed";
            defer std.heap.page_allocator.free(err_msg);
            const err_str = c.newStringLen(ctx, err_msg.ptr, @intCast(err_msg.len));
            var argv = [_]c.Value{err_str};
            _ = c.call(ctx, rf, c.JS_UNDEFINED, 1, &argv);
            c.freeValue(ctx, err_str);
        }
        if (res_fn) |res| c.freeValue(ctx, res);
        return .disarm;
    };

    if (res_fn) |rf| {
        defer c.freeValue(ctx, rf);
        var argv = [_]c.Value{c.newInt32(ctx, @intCast(n))};
        _ = c.call(ctx, rf, c.JS_UNDEFINED, 1, &argv);
    }
    if (rej_fn) |rej| c.freeValue(ctx, rej);
    return .disarm;
}

fn socketReadCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const slot = liveSlot(ctx, this_val) orelse return c.throwTypeError(ctx, "socket not connected or invalid");
    if (states[slot] != .connected) return c.throwTypeError(ctx, "socket not connected");

    // Fix 3: Reject concurrent read to avoid dropping previous promises
    if (read_resolves[slot] != null) {
        return c.throwTypeError(ctx, "concurrent read already in progress");
    }

    const loop_ptr = engine.getEventLoop() orelse return c.throwTypeError(ctx, "no event loop");

    var resolving_funcs: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &resolving_funcs);
    if (c.isException(promise) != 0) return promise;

    read_resolves[slot] = resolving_funcs[0];
    read_rejects[slot] = resolving_funcs[1];
    slot_ctx[slot] = ctx;

    fds[slot].read(&loop_ptr.loop, &read_comps[slot], .{ .slice = read_bufs[slot][0..] }, anyopaque, @ptrFromInt(slot), onRead);
    return promise;
}

fn socketWriteCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    if (argc < 1) return c.JS_UNDEFINED;
    const slot = liveSlot(ctx, this_val) orelse return c.throwTypeError(ctx, "socket not connected or invalid");
    if (states[slot] != .connected) return c.throwTypeError(ctx, "socket not connected");
    if (write_resolves[slot] != null) return c.throwTypeError(ctx, "concurrent write already in progress");

    const loop_ptr = engine.getEventLoop() orelse return c.throwTypeError(ctx, "no event loop");

    var slice: []const u8 = undefined;
    var u8_len: usize = 0;
    var cstr_to_free: ?[*c]const u8 = null;
    defer if (cstr_to_free) |cs| c.freeCString(ctx, cs);

    if (c.getUint8Array(ctx, &u8_len, argv[0])) |u8_ptr| {
        slice = u8_ptr[0..u8_len];
    } else {
        var str_len: usize = 0;
        const cstr = c.toCStringLen(ctx, &str_len, argv[0]) orelse return c.JS_EXCEPTION;
        cstr_to_free = cstr;
        slice = cstr[0..str_len];
    }

    if (slice.len > write_bufs[slot].len) {
        return c.throwTypeError(ctx, "write payload exceeds buffer size (16KB)");
    }
    @memcpy(write_bufs[slot][0..slice.len], slice);

    var resolving_funcs: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &resolving_funcs);
    if (c.isException(promise) != 0) return promise;

    write_resolves[slot] = resolving_funcs[0];
    write_rejects[slot] = resolving_funcs[1];
    slot_ctx[slot] = ctx;

    // Fix 4: Use xev write completions for correctness under backpressure
    fds[slot].write(&loop_ptr.loop, &write_comps[slot], .{ .slice = write_bufs[slot][0..slice.len] }, anyopaque, @ptrFromInt(slot), onWrite);
    return promise;
}

fn cleanupSlot(ctx: ?*c.Context, slot: usize) void {
    if (slot >= MAX_TCP or states[slot] == .free) return;

    // Reject in-flight reads
    if (read_resolves[slot]) |rf| {
        c.freeValue(ctx, rf);
        if (read_rejects[slot]) |rej| {
            defer c.freeValue(ctx, rej);
            const err_str = c.newStringLen(ctx, "socket closed", 13);
            var argv = [_]c.Value{err_str};
            _ = c.call(ctx, rej, c.JS_UNDEFINED, 1, &argv);
            c.freeValue(ctx, err_str);
        }
        read_resolves[slot] = null;
        read_rejects[slot] = null;
    }

    // Reject in-flight writes
    if (write_resolves[slot]) |rf| {
        c.freeValue(ctx, rf);
        if (write_rejects[slot]) |rej| {
            defer c.freeValue(ctx, rej);
            const err_str = c.newStringLen(ctx, "socket closed", 13);
            var argv = [_]c.Value{err_str};
            _ = c.call(ctx, rej, c.JS_UNDEFINED, 1, &argv);
            c.freeValue(ctx, err_str);
        }
        write_resolves[slot] = null;
        write_rejects[slot] = null;
    }

    // Fix: Cancel read, write, and connect watchers before close
    if (engine.getEventLoop()) |loop_ptr| {
        read_cancel_comps[slot] = .{
            .op = .{ .cancel = .{ .c = &read_comps[slot] } },
        };
        loop_ptr.loop.add(&read_cancel_comps[slot]);

        write_cancel_comps[slot] = .{
            .op = .{ .cancel = .{ .c = &write_comps[slot] } },
        };
        loop_ptr.loop.add(&write_cancel_comps[slot]);

        connect_cancel_comps[slot] = .{
            .op = .{ .cancel = .{ .c = &connect_comps[slot] } },
        };
        loop_ptr.loop.add(&connect_cancel_comps[slot]);
    }

    _ = std.c.close(fds[slot].fd);
    states[slot] = .free;
    gens[slot] +%= 1;
    slot_ctx[slot] = null;
}

fn socketCloseCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const slot = liveSlot(ctx, this_val) orelse return c.JS_UNDEFINED;
    cleanupSlot(ctx, slot);
    return c.JS_UNDEFINED;
}

fn tcpFinalizer(rt: ?*c.Runtime, val: c.Value) callconv(.c) void {
    _ = rt;
    const opaque_ptr = c.getOpaque(val, tcp_class_id);
    if (opaque_ptr) |ptr| {
        const h = unpackHandle(ptr);
        const slot = h.slot;
        if (slot < MAX_TCP and gens[slot] == h.gen and states[slot] != .free) {
            cleanupSlot(slot_ctx[slot], slot);
        }
    }
}

fn tcpConnectCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 2 or c.isString(argv[0]) == 0 or c.isNumber(argv[1]) == 0) {
        return c.throwTypeError(ctx, "tcp.connect requires (hostname, port)");
    }

    var h_len: usize = 0;
    const h_cstr = c.toCStringLen(ctx, &h_len, argv[0]) orelse return c.JS_EXCEPTION;
    defer c.freeCString(ctx, h_cstr);
    const host = h_cstr[0..h_len];

    var port_int: i32 = 0;
    _ = c.toInt32(ctx, &port_int, argv[1]);
    if (port_int < 1 or port_int > 65535) {
        return c.throwTypeError(ctx, "port out of range (1..65535)");
    }
    const port: u16 = @intCast(port_int);

    if (perm.global().checkNet(host, port) == .denied) {
        var detail_buf: [64]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_buf, "{s}:{d}", .{ host, port }) catch "net";
        return deny.throw(ctx, "tcp.connect", .net, detail);
    }

    const loop_ptr = engine.getEventLoop() orelse return c.throwTypeError(ctx, "no event loop");

    var target_slot: ?usize = null;
    for (0..MAX_TCP) |i| {
        if (states[i] == .free) {
            target_slot = i;
            break;
        }
    }
    const slot = target_slot orelse return c.throwTypeError(ctx, "max TCP connections exceeded (128)");

    const addr = std.Io.net.IpAddress.parseIp4(host, port) catch blk: {
        const a6 = std.Io.net.IpAddress.parseIp6(host, port) catch {
            return c.throwTypeError(ctx, "invalid IPv4/IPv6 address for tcp.connect");
        };
        break :blk a6;
    };

    const tcp_sock = xev.TCP.init(addr) catch {
        return c.throwTypeError(ctx, "failed to create TCP socket");
    };

    fds[slot] = tcp_sock;
    states[slot] = .connecting;
    slot_ctx[slot] = ctx;

    var resolving_funcs: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &resolving_funcs);
    if (c.isException(promise) != 0) {
        _ = std.c.close(tcp_sock.fd);
        states[slot] = .free;
        return promise;
    }

    connect_resolves[slot] = resolving_funcs[0];
    connect_rejects[slot] = resolving_funcs[1];

    tcp_sock.connect(&loop_ptr.loop, &connect_comps[slot], addr, anyopaque, @ptrFromInt(slot), onConnect);
    return promise;
}

pub fn setup(ctx: *c.Context) void {
    const rt = c.getRuntime(ctx);
    if (tcp_class_id == 0) {
        _ = c.newClassID(rt, &tcp_class_id);
        const class_def: c.ClassDef = .{
            .class_name = "Socket",
            .finalizer = tcpFinalizer,
            .gc_mark = null,
            .call = null,
            .exotic = null,
        };
        _ = c.newClass(rt, tcp_class_id, &class_def);
    }

    const proto = c.newObject(ctx);
    defer c.freeValue(ctx, proto);

    const read_fn = c.newCFunction(ctx, socketReadCallback, "read", 0);
    _ = c.definePropertyValueStr(ctx, proto, "read", read_fn, c.PROP_C_W_E);
    const write_fn = c.newCFunction(ctx, socketWriteCallback, "write", 1);
    _ = c.definePropertyValueStr(ctx, proto, "write", write_fn, c.PROP_C_W_E);
    const close_fn = c.newCFunction(ctx, socketCloseCallback, "close", 0);
    _ = c.definePropertyValueStr(ctx, proto, "close", close_fn, c.PROP_C_W_E);

    c.setClassProto(ctx, tcp_class_id, c.dupValue(ctx, proto));

    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);

    const tcp_obj = c.newObject(ctx);
    const connect_fn = c.newCFunction(ctx, tcpConnectCallback, "connect", 2);
    _ = c.definePropertyValueStr(ctx, tcp_obj, "connect", connect_fn, c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, global, "tcp", tcp_obj, c.PROP_C_W_E);
}
