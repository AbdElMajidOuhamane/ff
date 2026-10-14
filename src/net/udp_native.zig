//! Native UDP engine: fixed-capacity socket + send-op pools over libxev
//! completions (kqueue = sendto/recvfrom, io_uring/epoll = sendmsg/recvmsg).
//!
//! DOD: SoA slot arrays, zero allocation in send/recv hot paths (zero-copy
//! buffers held by dupValue refs), reusable completions/states, O(1) slot
//! free-list, generation counters instead of pointer-chasing handles.
//! Allocation happens only when JS values are created at settlement time.

const std = @import("std");
const xev = @import("xev");
const c = @import("../c.zig").c;
const engine = @import("../engine/engine.zig");

pub const MAX_SOCKS = 64;
pub const MAX_SEND_OPS = 64;
pub const MAX_DATAGRAM = 65507;

const Flags = packed struct(u8) {
    open: bool = false,
    closing: bool = false,
    recv_armed: bool = false,
    close_done: bool = false,
    recv_drained: bool = false,
    _pad: u3 = 0,
};

/// Identity of an in-flight operation: which socket slot it belongs to and
/// which incarnation of that slot (generation). Late or crossed callbacks
/// compare this against the live arrays and disarm if they don't match.
const SlotCtx = struct {
    slot: u16 = 0,
    sock_gen: u16 = 0,
};

/// Identity of an in-flight send; `epoch` also guards against pool-entry
/// reuse (the send op pool recycles entries independently of socket slots).
const SendCtx = struct {
    op: u16 = 0,
    slot: u16 = 0,
    sock_gen: u16 = 0,
    epoch: u16 = 0,
};

// ── socket slots (hot data, dense SoA) ──────────────────────────
var socks: [MAX_SOCKS]xev.UDP = undefined;
var gens: [MAX_SOCKS]u16 = @splat(1);
var flags: [MAX_SOCKS]Flags = @splat(.{});
var peers: [MAX_SOCKS]?std.Io.net.IpAddress = @splat(null);
var recv_ctx: [MAX_SOCKS]SlotCtx = @splat(.{});
var recv_comps: [MAX_SOCKS]xev.Completion = undefined;
var recv_states: [MAX_SOCKS]xev.UDP.State = undefined;
var recv_bufval: [MAX_SOCKS]?c.Value = @splat(null);
var recv_resolve: [MAX_SOCKS]?c.Value = @splat(null);
var recv_reject: [MAX_SOCKS]?c.Value = @splat(null);
var recv_with_peer: [MAX_SOCKS]bool = @splat(false);
var close_ctx: [MAX_SOCKS]SlotCtx = @splat(.{});
var close_comps: [MAX_SOCKS]xev.Completion = undefined;
var cancel_comps: [MAX_SOCKS]xev.Completion = undefined;
var free_list: [MAX_SOCKS]u16 = undefined;
var free_len: usize = 0;
var pool_ready: bool = false;

// ── send op pool ────────────────────────────────────────────────
var send_used: [MAX_SEND_OPS]bool = @splat(false);
var send_comps: [MAX_SEND_OPS]xev.Completion = undefined;
var send_states: [MAX_SEND_OPS]xev.UDP.State = undefined;
var send_ctx: [MAX_SEND_OPS]SendCtx = @splat(.{});
var send_epoch: [MAX_SEND_OPS]u16 = @splat(0);
var send_data: [MAX_SEND_OPS]?c.Value = @splat(null);
var send_resolve: [MAX_SEND_OPS]?c.Value = @splat(null);
var send_reject: [MAX_SEND_OPS]?c.Value = @splat(null);
var send_cancel_comps: [MAX_SEND_OPS]xev.Completion = undefined;

var g_ctx: ?*c.Context = null;

// ── address value (no self-referential slices) ──────────────────
pub const SockAddr = struct {
    text_buf: [64]u8 = undefined,
    text_len: u8 = 0,
    port: u16 = 0,
    is_v6: bool = false,

    pub fn text(self: *const SockAddr) []const u8 {
        return self.text_buf[0..self.text_len];
    }
};

/// One-time slot-pool init. Idempotent; builds the free list exactly once
/// so exhausting the pool can never silently re-issue live slots.
pub fn init() void {
    if (pool_ready) return;
    pool_ready = true;
    var i: usize = MAX_SOCKS;
    while (i > 0) {
        i -= 1;
        free_list[free_len] = @intCast(i);
        free_len += 1;
    }
}

// ── slot lifecycle ──────────────────────────────────────────────

pub fn open(inet6: bool) !u16 {
    init();
    if (free_len == 0) return error.OutOfSockets;
    const slot: u16 = free_list[free_len - 1];
    free_len -= 1;
    const addr = if (inet6)
        std.Io.net.IpAddress.parseIp6("::", 0) catch unreachable
    else
        std.Io.net.IpAddress.parseIp4("0.0.0.0", 0) catch unreachable;
    socks[slot] = xev.UDP.init(addr) catch {
        free_list[free_len] = slot;
        free_len += 1;
        return error.SystemResources;
    };
    flags[slot] = .{ .open = true };
    peers[slot] = null;
    return slot;
}

pub fn genOf(slot: u16) u16 {
    return gens[slot];
}

pub fn isOwned(slot: u16, gen: u16) bool {
    return flags[slot].open and gens[slot] == gen;
}

pub fn isValid(slot: u16, gen: u16) bool {
    return isOwned(slot, gen) and !flags[slot].closing;
}

pub fn peerOf(slot: u16) ?std.Io.net.IpAddress {
    return peers[slot];
}

/// close(2). Generation-checked so a stale JS handle can never close a
/// reused slot. Any in-flight recv/send completions are aborted with an
/// explicit xev `.cancel`: closing the fd alone would silently drop their
/// kevents (kqueue/epoll never deliver events for a closed fd) and the
/// completions would pin loop.active forever — the runtime could never
/// exit. Aborted promises reject immediately; buffer refs are released by
/// the cancel/op callbacks once the kernel can no longer touch them.
pub fn closeSock(slot: u16, gen: u16) void {
    if (!isOwned(slot, gen) or flags[slot].closing) return;
    flags[slot].closing = true;
    const l = engine.getEventLoop() orelse {
        // A recv cannot be armed without the loop (submitRecv requires it).
        _ = std.c.close(socks[slot].fd);
        flags[slot].close_done = true;
        flags[slot].recv_drained = true;
        maybeFinalize(slot);
        return;
    };
    if (flags[slot].recv_armed) {
        flags[slot].recv_armed = false;
        // Reject the pending promise now; the buffer ref stays alive
        // (recv_bufval) until the cancel drains — the kernel may still be
        // writing into it on io_uring until the cancellation is applied.
        if (g_ctx) |ctx| {
            if (recv_resolve[slot]) |v| c.freeValue(ctx, v);
            if (recv_reject[slot]) |rv| {
                rejectWith(ctx, rv, "recvfrom: socket closed");
                c.freeValue(ctx, rv);
            }
        }
        recv_resolve[slot] = null;
        recv_reject[slot] = null;
        cancel_comps[slot] = .{
            .op = .{ .cancel = .{ .c = &recv_comps[slot] } },
            .userdata = &recv_ctx[slot],
            .callback = cancelCb,
        };
        l.loop.add(&cancel_comps[slot]);
    }
    // Abort in-flight sends on this socket: reject immediately, keep the
    // data refs until the cancel/send callbacks release them.
    for (0..MAX_SEND_OPS) |i| {
        const op: u16 = @intCast(i);
        if (!send_used[op]) continue;
        const sc = send_ctx[op];
        if (sc.slot != slot or sc.sock_gen != gen) continue;
        if (g_ctx) |ctx| {
            if (send_resolve[op]) |v| c.freeValue(ctx, v);
            if (send_reject[op]) |rv| {
                rejectWith(ctx, rv, "send: socket closed");
                c.freeValue(ctx, rv);
            }
        }
        send_resolve[op] = null;
        send_reject[op] = null;
        send_cancel_comps[op] = .{
            .op = .{ .cancel = .{ .c = &send_comps[op] } },
            .userdata = &send_ctx[op],
            .callback = cancelSendCb,
        };
        l.loop.add(&send_cancel_comps[op]);
    }
    flags[slot].recv_drained = true;
    close_ctx[slot] = .{ .slot = slot, .sock_gen = gen };
    socks[slot].close(&l.loop, &close_comps[slot], SlotCtx, &close_ctx[slot], closeCb);
}

fn maybeFinalize(slot: u16) void {
    if (!flags[slot].closing or !flags[slot].close_done or !flags[slot].recv_drained) return;
    flags[slot] = .{};
    gens[slot] +%= 1;
    if (gens[slot] == 0) gens[slot] = 1;
    peers[slot] = null;
    if (free_len < MAX_SOCKS) {
        free_list[free_len] = slot;
        free_len += 1;
    }
}

fn closeCb(
    ud: ?*SlotCtx,
    l: *xev.Loop,
    comp: *xev.Completion,
    sock: xev.UDP,
    r: xev.CloseError!void,
) xev.CallbackAction {
    _ = l;
    _ = comp;
    _ = sock;
    _ = r catch {};
    const c2 = ud orelse return .disarm;
    const id = c2.slot;
    if (gens[id] != c2.sock_gen) return .disarm; // late completion after reuse
    flags[id].close_done = true;
    maybeFinalize(id);
    return .disarm;
}

/// Cleanup for an aborted recv. A `.cancel` op always produces this
/// completion, including the case where the read never reached the kernel
/// and its own callback never fires.
fn cancelCb(
    ud: ?*anyopaque,
    l: *xev.Loop,
    comp: *xev.Completion,
    r: xev.Result,
) xev.CallbackAction {
    _ = l;
    _ = comp;
    _ = r;
    const c2: *SlotCtx = @ptrCast(@alignCast(ud orelse return .disarm));
    const id = c2.slot;
    if (gens[id] != c2.sock_gen) return .disarm; // slot already reused
    if (recv_bufval[id]) |v| {
        if (g_ctx) |ctx| c.freeValue(ctx, v);
    }
    recv_bufval[id] = null;
    return .disarm;
}

/// Cleanup for an aborted send (same never-fires rationale as cancelCb).
fn cancelSendCb(
    ud: ?*anyopaque,
    l: *xev.Loop,
    comp: *xev.Completion,
    r: xev.Result,
) xev.CallbackAction {
    _ = l;
    _ = comp;
    _ = r;
    const c2: *SendCtx = @ptrCast(@alignCast(ud orelse return .disarm));
    const op = c2.op;
    if (send_epoch[op] != c2.epoch) return .disarm; // op pool entry reused
    const ctx = g_ctx orelse return .disarm;
    if (send_resolve[op]) |v| c.freeValue(ctx, v);
    send_resolve[op] = null;
    if (send_reject[op]) |v| c.freeValue(ctx, v);
    send_reject[op] = null;
    if (send_data[op]) |v| c.freeValue(ctx, v);
    send_data[op] = null;
    freeSendOp(op);
    return .disarm;
}

// ── bind / connect / names ──────────────────────────────────────

pub fn bindSock(slot: u16, addr: std.Io.net.IpAddress) !void {
    try socks[slot].bind(addr);
}

/// connect(2) — synchronous for UDP (sets the default peer).
pub fn connectSock(slot: u16, addr: std.Io.net.IpAddress) !void {
    const fd = socks[slot].fd;
    const rc: c_int = switch (addr) {
        .ip4 => |a| blk: {
            var sin: std.c.sockaddr.in = .{
                .family = std.posix.AF.INET,
                .port = std.mem.nativeToBig(u16, a.port),
                .addr = @bitCast(a.bytes),
            };
            break :blk std.c.connect(fd, @ptrCast(&sin), @intCast(@sizeOf(std.c.sockaddr.in)));
        },
        .ip6 => |a| blk: {
            var sin6: std.c.sockaddr.in6 = .{
                .family = std.posix.AF.INET6,
                .port = std.mem.nativeToBig(u16, a.port),
                .flowinfo = 0,
                .addr = a.bytes,
                .scope_id = 0,
            };
            break :blk std.c.connect(fd, @ptrCast(&sin6), @intCast(@sizeOf(std.c.sockaddr.in6)));
        },
    };
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        .INVAL, .AFNOSUPPORT => return error.InvalidAddress,
        .BADF => return error.BadFileDescriptor,
        .NOTSOCK => return error.NotASocket,
        else => return error.ConnectFailed,
    }
    peers[slot] = addr;
}

fn getName(fd: std.posix.socket_t, comptime which: enum { local, peer }) !SockAddr {
    var storage: std.c.sockaddr.storage = undefined;
    var len: std.posix.socklen_t = @sizeOf(std.c.sockaddr.storage);
    const rc: c_int = switch (which) {
        .local => std.c.getsockname(fd, @ptrCast(&storage), &len),
        .peer => std.c.getpeername(fd, @ptrCast(&storage), &len),
    };
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        .BADF => return error.BadFileDescriptor,
        .NOTSOCK => return error.NotASocket,
        .NOTCONN => return error.NotConnected,
        else => return error.SystemResources,
    }
    var out: SockAddr = .{};
    if (storage.family == std.posix.AF.INET) {
        const sin: *const std.c.sockaddr.in = @ptrCast(@alignCast(&storage));
        const bytes: [4]u8 = @bitCast(sin.addr);
        const s = std.fmt.bufPrint(&out.text_buf, "{}.{}.{}.{}", .{
            bytes[0], bytes[1], bytes[2], bytes[3],
        }) catch return error.SystemResources;
        out.text_len = @intCast(s.len);
        out.port = std.mem.bigToNative(u16, sin.port);
        out.is_v6 = false;
    } else if (storage.family == std.posix.AF.INET6) {
        const sin6: *const std.c.sockaddr.in6 = @ptrCast(@alignCast(&storage));
        const s = formatIp6(sin6.addr, &out.text_buf);
        out.text_len = @intCast(s.len);
        out.port = std.mem.bigToNative(u16, sin6.port);
        out.is_v6 = true;
    } else return error.UnsupportedFamily;
    return out;
}

pub fn localAddr(slot: u16) !SockAddr {
    return getName(socks[slot].fd, .local);
}

pub fn peerAddr(slot: u16) !SockAddr {
    return getName(socks[slot].fd, .peer);
}

/// RFC 5952 text form: lowercase hex, longest run of >= 2 zero groups
/// compressed to "::" (first run wins on ties, single zero groups stay "0").
fn formatIp6(bytes: [16]u8, out: *[64]u8) []const u8 {
    const hex = "0123456789abcdef";
    var groups: [8]u16 = undefined;
    for (0..8) |i| {
        groups[i] = (@as(u16, bytes[i * 2]) << 8) | bytes[i * 2 + 1];
    }

    var best_start: usize = 8;
    var best_len: usize = 0;
    var i: usize = 0;
    while (i < 8) {
        if (groups[i] != 0) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < 8 and groups[j] == 0) j += 1;
        if (j - i > best_len) {
            best_start = i;
            best_len = j - i;
        }
        i = j;
    }
    if (best_len < 2) best_start = 8;

    var pos: usize = 0;
    var gi: usize = 0;
    while (gi < 8) {
        if (gi == best_start) {
            out[pos] = ':';
            pos += 1;
            out[pos] = ':';
            pos += 1;
            gi += best_len;
            if (gi >= 8) break; // trailing "::"
            // The group right after "::" carries no separator.
            writeIp6Group(out, &pos, groups[gi], hex);
            gi += 1;
            continue;
        }
        if (gi > 0) {
            out[pos] = ':';
            pos += 1;
        }
        writeIp6Group(out, &pos, groups[gi], hex);
        gi += 1;
    }
    return out[0..pos];
}

fn writeIp6Group(out: *[64]u8, pos: *usize, g: u16, hex: []const u8) void {
    if (g == 0) {
        out[pos.*] = '0';
        pos.* += 1;
        return;
    }
    var tmp: [4]u8 = undefined;
    var n: usize = 0;
    var x = g;
    while (x > 0) : (x >>= 4) {
        tmp[n] = hex[x & 0xf];
        n += 1;
    }
    var k: usize = 0;
    while (k < n) : (k += 1) {
        out[pos.*] = tmp[n - 1 - k];
        pos.* += 1;
    }
}

// ── recvfrom / recv ─────────────────────────────────────────────

pub fn submitRecv(
    ctx: ?*c.Context,
    slot: u16,
    buf_val: c.Value,
    resolve: c.Value,
    reject: c.Value,
    with_peer: bool,
) !void {
    if (flags[slot].recv_armed) return error.RecvPending;
    const bytes = try writableBytes(ctx, buf_val);
    const l = engine.getEventLoop() orelse return error.NoLoop;
    g_ctx = ctx;
    if (recv_bufval[slot]) |old| c.freeValue(ctx, old); // reclaim a stale ref
    recv_ctx[slot] = .{ .slot = slot, .sock_gen = gens[slot] };
    recv_bufval[slot] = c.dupValue(ctx, buf_val);
    recv_resolve[slot] = c.dupValue(ctx, resolve);
    recv_reject[slot] = c.dupValue(ctx, reject);
    recv_with_peer[slot] = with_peer;
    flags[slot].recv_armed = true;
    socks[slot].read(
        &l.loop,
        &recv_comps[slot],
        &recv_states[slot],
        .{ .slice = bytes },
        SlotCtx,
        &recv_ctx[slot],
        recvCb,
    );
}

fn recvCb(
    ud: ?*SlotCtx,
    l: *xev.Loop,
    comp: *xev.Completion,
    st: *xev.UDP.State,
    addr: std.Io.net.IpAddress,
    sock: xev.UDP,
    buf: xev.ReadBuffer,
    r: xev.ReadError!usize,
) xev.CallbackAction {
    _ = l;
    _ = comp;
    _ = st;
    _ = sock;
    _ = buf;
    const c2 = ud orelse return .disarm;
    const id = c2.slot;
    if (gens[id] != c2.sock_gen) return .disarm; // stale incarnation
    if (!flags[id].recv_armed) {
        // Aborted by closeSock (or its cancel): promise already settled.
        // Release the held buffer ref (idempotent with cancelCb).
        if (recv_bufval[id]) |v| {
            if (g_ctx) |ctx| c.freeValue(ctx, v);
        }
        recv_bufval[id] = null;
        flags[id].recv_drained = true;
        maybeFinalize(id);
        return .disarm;
    }
    flags[id].recv_armed = false;
    const ctx = g_ctx orelse return .disarm;
    const n = r catch {
        settleRecvErr(ctx, id, "recvfrom failed");
        return .disarm;
    };
    const buf_val = recv_bufval[id] orelse return .disarm;
    const resolve = recv_resolve[id] orelse return .disarm;
    const reject = recv_reject[id] orelse return .disarm;
    defer c.freeValue(ctx, buf_val);
    defer c.freeValue(ctx, resolve);
    defer c.freeValue(ctx, reject);
    recv_bufval[id] = null;
    recv_resolve[id] = null;
    recv_reject[id] = null;

    const data = makeDataView(ctx, buf_val, n) catch {
        rejectWith(ctx, reject, "recvfrom: bad buffer");
        return .disarm;
    };

    if (recv_with_peer[id]) {
        // Resolve with a real [data, addr] array: a promise resolve
        // function only honors its first argument, so the pair has to be
        // packed into an array (Deno-style recvfrom result).
        const addr_obj = addrToJs(ctx, addr);
        const pair = c.newArray(ctx);
        if (c.isException(pair) != 0) {
            c.freeValue(ctx, addr_obj);
            c.freeValue(ctx, data);
            return .disarm;
        }
        // JS_SetPropertyUint32 consumes (frees) the value reference.
        _ = c.setPropertyUint32(ctx, pair, 0, data);
        _ = c.setPropertyUint32(ctx, pair, 1, addr_obj);
        var argv = [_]c.Value{pair};
        const ret = c.call(ctx, resolve, c.JS_UNDEFINED, 1, &argv);
        c.freeValue(ctx, ret);
        c.freeValue(ctx, pair);
    } else {
        var argv = [_]c.Value{data};
        const ret = c.call(ctx, resolve, c.JS_UNDEFINED, 1, &argv);
        c.freeValue(ctx, ret);
        c.freeValue(ctx, data);
    }
    return .disarm;
}

/// Zero-copy result view: Uint8Array → buf.subarray(0, n);
/// ArrayBuffer → new Uint8Array(ab, 0, n). Both keep the backing store
/// alive via JS refcounting, so freeing our held refs is safe.
fn makeDataView(ctx: ?*c.Context, buf_val: c.Value, n: usize) !c.Value {
    var size: usize = 0;
    if (c.getUint8Array(ctx, &size, buf_val)) |_| {
        clearExceptionIfAny(ctx);
        const sub = c.getPropertyStr(ctx, buf_val, "subarray");
        defer c.freeValue(ctx, sub);
        if (c.isFunction(ctx, sub) == 0) return error.NotABuffer;
        var args = [_]c.Value{ c.newInt32(ctx, 0), c.newInt32(ctx, @intCast(n)) };
        return c.call(ctx, sub, buf_val, 2, &args);
    }
    clearExceptionIfAny(ctx);
    var args = [_]c.Value{ buf_val, c.newInt32(ctx, 0), c.newInt32(ctx, @intCast(n)) };
    const view = c.newTypedArray(ctx, 3, &args, c.JS_TYPED_ARRAY_UINT8);
    if (c.isException(view) != 0) return error.NotABuffer;
    return view;
}

fn settleRecvErr(ctx: ?*c.Context, id: u16, msg: []const u8) void {
    const reject = recv_reject[id] orelse return;
    const buf_val = recv_bufval[id];
    const resolve = recv_resolve[id];
    recv_bufval[id] = null;
    recv_resolve[id] = null;
    recv_reject[id] = null;
    if (buf_val) |v| c.freeValue(ctx, v);
    if (resolve) |v| c.freeValue(ctx, v);
    rejectWith(ctx, reject, msg);
    c.freeValue(ctx, reject);
}

// ── sendto / send ───────────────────────────────────────────────

pub fn submitSend(
    ctx: ?*c.Context,
    slot: u16,
    data_val: c.Value,
    dest: ?std.Io.net.IpAddress,
    resolve: c.Value,
    reject: c.Value,
) !void {
    const bytes = try readBytes(ctx, data_val);
    if (bytes.len > MAX_DATAGRAM) return error.MessageTooLong;
    const d = dest orelse return error.NotConnected;
    // Connected sockets must send via send(2): xev's UDP write always
    // supplies a destination, and sendto(2) with a destination on a
    // connected socket fails with EISCONN on macOS. UDP sends don't block
    // meaningfully, so settle the promise right here.
    if (peers[slot]) |p| {
        if (p.eql(&d)) {
            const rc = std.c.send(socks[slot].fd, @ptrCast(bytes.ptr), bytes.len, 0);
            if (rc < 0) {
                rejectWith(ctx, reject, "send failed");
            } else {
                var args = [_]c.Value{c.newInt32(ctx, @intCast(rc))};
                const ret = c.call(ctx, resolve, c.JS_UNDEFINED, 1, &args);
                c.freeValue(ctx, ret);
            }
            return;
        }
    }
    const l = engine.getEventLoop() orelse return error.NoLoop;
    const op = allocSendOp() orelse return error.SendQueueFull;
    g_ctx = ctx;
    if (send_data[op]) |old| c.freeValue(ctx, old); // reclaim stale refs
    if (send_resolve[op]) |old| c.freeValue(ctx, old);
    if (send_reject[op]) |old| c.freeValue(ctx, old);
    send_epoch[op] +%= 1;
    if (send_epoch[op] == 0) send_epoch[op] = 1;
    send_ctx[op] = .{
        .op = op,
        .slot = slot,
        .sock_gen = gens[slot],
        .epoch = send_epoch[op],
    };
    send_data[op] = c.dupValue(ctx, data_val);
    send_resolve[op] = c.dupValue(ctx, resolve);
    send_reject[op] = c.dupValue(ctx, reject);
    socks[slot].write(
        &l.loop,
        &send_comps[op],
        &send_states[op],
        d,
        .{ .slice = bytes },
        SendCtx,
        &send_ctx[op],
        sendCb,
    );
}

fn allocSendOp() ?u16 {
    for (send_used, 0..) |used, i| {
        if (!used) {
            send_used[i] = true;
            return @intCast(i);
        }
    }
    return null;
}

fn freeSendOp(op: u16) void {
    send_used[op] = false;
}

fn sendCb(
    ud: ?*SendCtx,
    l: *xev.Loop,
    comp: *xev.Completion,
    st: *xev.UDP.State,
    sock: xev.UDP,
    buf: xev.WriteBuffer,
    r: xev.WriteError!usize,
) xev.CallbackAction {
    _ = l;
    _ = comp;
    _ = st;
    _ = sock;
    _ = buf;
    const c2 = ud orelse return .disarm;
    const op = c2.op;
    if (send_epoch[op] != c2.epoch) return .disarm; // op pool entry reused
    const ctx = g_ctx orelse return .disarm;
    defer freeSendOp(op);
    const resolve = send_resolve[op] orelse return .disarm;
    const reject = send_reject[op] orelse return .disarm;
    send_resolve[op] = null;
    send_reject[op] = null;
    defer c.freeValue(ctx, resolve);
    defer c.freeValue(ctx, reject);
    if (send_data[op]) |dv| {
        c.freeValue(ctx, dv);
        send_data[op] = null;
    }
    if (gens[c2.slot] != c2.sock_gen or flags[c2.slot].closing) {
        rejectWith(ctx, reject, "send: socket closed");
        return .disarm;
    }
    const n = r catch {
        rejectWith(ctx, reject, "send failed");
        return .disarm;
    };
    var args = [_]c.Value{c.newInt32(ctx, @intCast(n))};
    const ret = c.call(ctx, resolve, c.JS_UNDEFINED, 1, &args);
    c.freeValue(ctx, ret);
    return .disarm;
}

// ── JS value helpers ────────────────────────────────────────────

fn clearExceptionIfAny(ctx: ?*c.Context) void {
    if (c.hasException(ctx)) {
        const exc = c.getException(ctx);
        c.freeValue(ctx, exc);
    }
}

/// Writable bytes of a Uint8Array or ArrayBuffer (recv buffers).
fn writableBytes(ctx: ?*c.Context, val: c.Value) ![]u8 {
    var size: usize = 0;
    if (c.getUint8Array(ctx, &size, val)) |p| {
        clearExceptionIfAny(ctx);
        return p[0..size];
    }
    clearExceptionIfAny(ctx);
    if (c.getArrayBuffer(ctx, &size, val)) |p| {
        clearExceptionIfAny(ctx);
        return p[0..size];
    }
    clearExceptionIfAny(ctx);
    return error.NotABuffer;
}

/// Borrowed bytes of any ArrayBuffer / TypedArray view (send payloads).
fn readBytes(ctx: ?*c.Context, val: c.Value) ![]const u8 {
    var size: usize = 0;
    if (c.getArrayBuffer(ctx, &size, val)) |p| {
        clearExceptionIfAny(ctx);
        return p[0..size];
    }
    clearExceptionIfAny(ctx);
    if (c.getUint8Array(ctx, &size, val)) |p| {
        clearExceptionIfAny(ctx);
        return p[0..size];
    }
    clearExceptionIfAny(ctx);
    var off: usize = 0;
    var len: usize = 0;
    var bpe: usize = 0;
    const ab = c.getTypedArrayBuffer(ctx, val, &off, &len, &bpe);
    if (c.getTag(ab) == c.TAG_EXCEPTION) {
        clearExceptionIfAny(ctx);
        return error.NotABuffer;
    }
    defer c.freeValue(ctx, ab);
    if (c.isNull(ab) != 0 or c.isUndefined(ab) != 0) return error.NotABuffer;
    var asize: usize = 0;
    const base = c.getArrayBuffer(ctx, &asize, ab) orelse {
        clearExceptionIfAny(ctx);
        return error.NotABuffer;
    };
    clearExceptionIfAny(ctx);
    if (off + len > asize) return error.NotABuffer;
    return base[off..][0..len];
}

fn makeJsError(ctx: ?*c.Context, msg: []const u8) c.Value {
    const err = c.newError(ctx);
    if (c.isException(err) != 0) return err;
    const m = c.newStringLen(ctx, msg.ptr, msg.len);
    _ = c.setPropertyStr(ctx, err, "message", m);
    return err;
}

fn rejectWith(ctx: ?*c.Context, reject: c.Value, msg: []const u8) void {
    const err = makeJsError(ctx, msg);
    var args = [_]c.Value{err};
    const ret = c.call(ctx, reject, c.JS_UNDEFINED, 1, &args);
    c.freeValue(ctx, ret);
    c.freeValue(ctx, err);
}

fn addrToJs(ctx: ?*c.Context, addr: std.Io.net.IpAddress) c.Value {
    var sa: SockAddr = .{};
    switch (addr) {
        .ip4 => |a| {
            const s = std.fmt.bufPrint(&sa.text_buf, "{}.{}.{}.{}", .{
                a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3],
            }) catch "0.0.0.0";
            sa.text_len = @intCast(s.len);
            sa.port = a.port;
            sa.is_v6 = false;
        },
        .ip6 => |a| {
            const s = formatIp6(a.bytes, &sa.text_buf);
            sa.text_len = @intCast(s.len);
            sa.port = a.port;
            sa.is_v6 = true;
        },
    }
    return sockAddrToJs(ctx, sa);
}

pub fn sockAddrToJs(ctx: ?*c.Context, sa: SockAddr) c.Value {
    const obj = c.newObject(ctx);
    const a = c.newStringLen(ctx, sa.text().ptr, sa.text().len);
    _ = c.setPropertyStr(ctx, obj, "address", a);
    const p = c.newInt32(ctx, sa.port);
    _ = c.setPropertyStr(ctx, obj, "port", p);
    const fam: []const u8 = if (sa.is_v6) "inet6" else "inet";
    const f = c.newStringLen(ctx, fam.ptr, fam.len);
    _ = c.setPropertyStr(ctx, obj, "family", f);
    return obj;
}

// ── unit tests (slot pool; no event loop needed) ────────────────

test "udp slot pool alloc/free bumps generation" {
    init();
    const s1 = try open(false);
    const g1 = genOf(s1);
    try std.testing.expect(isValid(s1, g1));
    const s2 = try open(true);
    try std.testing.expect(s1 != s2);
    closeSock(s1, g1);
    try std.testing.expect(!isValid(s1, g1));
    closeSock(s2, genOf(s2));
    try std.testing.expect(!isValid(s2, genOf(s2)));
}

test "formatIp6 renders compressed groups" {
    var buf: [64]u8 = undefined;
    const s = formatIp6(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01 }, &buf);
    try std.testing.expectEqualStrings("2001:db8::1", s);
    var buf2: [64]u8 = undefined;
    const z = formatIp6(@splat(0), &buf2);
    try std.testing.expectEqualStrings("::", z);
    var buf3: [64]u8 = undefined;
    const one = formatIp6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, &buf3);
    try std.testing.expectEqualStrings("::1", one);
    var buf4: [64]u8 = undefined;
    const mixed = formatIp6(.{
        0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1,
    }, &buf4);
    try std.testing.expectEqualStrings("2001:db8:0:1::1", mixed);
}

test "udp open/isValid generation fencing" {
    init();
    const s = try open(false);
    const g = genOf(s);
    try std.testing.expect(isOwned(s, g));
    try std.testing.expect(isValid(s, g));
    try std.testing.expect(!isOwned(s, g +% 1));
    try std.testing.expect(!isValid(s, g +% 1));
    closeSock(s, g);
    try std.testing.expect(!isOwned(s, g));
    try std.testing.expect(!isValid(s, g));
}
