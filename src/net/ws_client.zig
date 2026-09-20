const std = @import("std");
const xev = @import("xev");
const c = @import("../c.zig").c;
const tls = @import("./tls.zig");
const ws = @import("./ws_native.zig");
const builtin = @import("builtin");
const microtasks = @import("../event/microtasks.zig"); // CHANGED
const http = std.http;
extern "c" fn arc4random_buf(buf: [*]u8, len: usize) void;
fn getRandomBytes(buf: []u8) void {
    switch (builtin.os.tag) {
        .linux => {
            var off: usize = 0;
            while (off < buf.len) {
                const n = std.c.getrandom(buf.ptr + off, buf.len - off, 0);
                if (n < 0) {
                    if (std.posix.errno(n) == .INTR) continue;
                    std.Io.Threaded.global_single_threaded.io().random(buf[off..]);
                    return;
                }
                off += @intCast(n);
            }
        },
        else => arc4random_buf(buf.ptr, buf.len),
    }
}
fn monoMillis() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.ms_per_s + @divTrunc(ts.nsec, std.time.ns_per_ms);
}

pub const MAX_WS = 64;
pub const WS_MSG_SIZE = ws.WS_MSG_SIZE;
pub const RDBUF = 65536;
const CLOSE_REASON_MAX = 123;
const JOB_FREE: u8 = 0;
const JOB_BUSY: u8 = 1;
const JOB_DONE: u8 = 2;
const JOB_CLAIMED: u8 = 3;
const EV_NONE: u8 = 0;
const EV_OPEN: u8 = 1;
const EV_MESSAGE: u8 = 2;
const EV_CLOSE: u8 = 3;
const TX_TEXT: u8 = 1;
const TX_BINARY: u8 = 2;
const TX_CLOSE: u8 = 3;

var states:       [MAX_WS]std.atomic.Value(u8) = [_]std.atomic.Value(u8){.{ .raw = JOB_FREE }} ** MAX_WS;
// Gap-2 fix: single-thread-owned flags packed to 1 byte/slot (cf.
// http_native ConnFlags). `want_connect`/`tx_pending` stay separate plain
// columns: they are cross-thread hints written by main while the worker
// reads/writes sibling flags — sharing a byte would tear on RMW.
// Packing is safe here because for any slot, at most one thread writes
// wflags at a time: main writes pre-publish (submit) or on CLAIMED slots
// (completeEvent/releaseSlot, which the worker skips as non-BUSY), the
// worker writes only on BUSY slots it owns. `tls_active` is written once
// pre-publish, then read-only.
const WsFlags = packed struct(u8) {
    tls_active: bool = false,
    ws_open: bool = false,
    ws_sent_close: bool = false,
    rx_binary: bool = false,
    partial_binary: bool = false,
    conn_live: bool = false,
    _pad: u2 = 0,
};
comptime {
    std.debug.assert(@sizeOf(WsFlags) == 1);
}
var wflags: [MAX_WS]WsFlags = [_]WsFlags{.{}} ** MAX_WS;
var sock_fds:     [MAX_WS]std.posix.fd_t = [_]std.posix.fd_t{-1} ** MAX_WS;
var hosts:        [MAX_WS][:0]const u8 = [_][:0]const u8{""} ** MAX_WS;
var paths:        [MAX_WS][]const u8 = [_][]const u8{""} ** MAX_WS;
var ports:        [MAX_WS]u16 = [_]u16{0} ** MAX_WS;
var keys:         [MAX_WS][28]u8 = undefined;
var close_deadline: [MAX_WS]i64 = [_]i64{0} ** MAX_WS;
var tx_pending:   [MAX_WS]std.atomic.Value(bool) = [_]std.atomic.Value(bool){.{ .raw = false }} ** MAX_WS;
var tx_job:       [MAX_WS]u8 = [_]u8{0} ** MAX_WS;
var tx_len:       [MAX_WS]usize = [_]usize{0} ** MAX_WS;
var tx_code:      [MAX_WS]u16 = [_]u16{0} ** MAX_WS;
var tx_reason_len:[MAX_WS]u8 = [_]u8{0} ** MAX_WS;
var tx_reason:    [MAX_WS][CLOSE_REASON_MAX]u8 = undefined;
var tx_msg:       [MAX_WS][WS_MSG_SIZE]u8 = undefined;
var rx_event:     [MAX_WS]u8 = [_]u8{0} ** MAX_WS;
var rx_len:       [MAX_WS]usize = [_]usize{0} ** MAX_WS;
var rx_code:      [MAX_WS]u16 = [_]u16{0} ** MAX_WS;
var rx_reason_len:[MAX_WS]u8 = [_]u8{0} ** MAX_WS;
var rx_reason:    [MAX_WS][CLOSE_REASON_MAX]u8 = undefined;
var rx_err_len:   [MAX_WS]u8 = [_]u8{0} ** MAX_WS;
var rx_err:       [MAX_WS][64]u8 = undefined;
var rx_msg:       [MAX_WS][WS_MSG_SIZE]u8 = undefined;
var rd_len:       [MAX_WS]usize = [_]usize{0} ** MAX_WS;
var partial_len:  [MAX_WS]usize = [_]usize{0} ** MAX_WS;
var wb:           [MAX_WS][WS_MSG_SIZE + ws.MAX_HDR]u8 = undefined;
var rd_buf:       [MAX_WS][RDBUF]u8 = undefined;
var partial:      [MAX_WS][WS_MSG_SIZE]u8 = undefined;
// F7-B: static per-slot URL storage — no per-connection dupe/free.
// `hosts`/`paths` stay slice views so all downstream uses are untouched.
var host_bufs:    [MAX_WS][256:0]u8 = undefined;
var path_bufs:    [MAX_WS][2048]u8 = undefined;
// F7-B: shared-worker coordination. The main thread is the sole producer of
// want_connect/tx flags; `states` (atomic) is the guard and flags are
// level-triggered hints re-verified against it. conn_live/w_conns/w_reqs are
// worker-owned (releaseSlot only clears want_connect once the slot is DONE).
var want_connect: [MAX_WS]bool = [_]bool{false} ** MAX_WS;
var w_conns:      [MAX_WS]?*http.Client.Connection = [_]?*http.Client.Connection{null} ** MAX_WS;
var w_reqs:       [MAX_WS]?http.Client.Request = [_]?http.Client.Request{null} ** MAX_WS;
var cmd_pipe:     [2]std.posix.fd_t = .{ -1, -1 };
var worker_started: bool = false; // guarded by poolLock (submit path only)
var free_list: [MAX_WS]u16 = undefined;
var free_count: usize = MAX_WS;
var pool_lock: std.atomic.Mutex = .unlocked;
const AsyncT = xev.Async;
var async_h: AsyncT = undefined;
var async_comp: xev.Completion = .{};
var async_armed = false;
var g_ctx: ?*c.Context = null; // CHANGED
var g_loop: ?*xev.Loop = null; // CHANGED
pub var pending: std.atomic.Value(u64) = .{ .raw = 0 };
var socks: [MAX_WS]?c.Value = [_]?c.Value{null} ** MAX_WS;

fn poolLock() void {
    while (!pool_lock.tryLock()) std.atomic.spinLoopHint();
}

fn poolUnlock() void {
    pool_lock.unlock();
}

fn poolInit() void {
    for (0..MAX_WS) |i| free_list[i] = @intCast(MAX_WS - 1 - i);
    free_count = MAX_WS;
}

fn acquireSlot() ?usize {
    if (free_count == 0) return null;
    free_count -= 1;
    const s: usize = free_list[free_count];
    states[s].store(JOB_BUSY, .release);
    return s;
}

fn releaseSlot(s: usize) void {
    if (socks[s]) |v| {
        if (g_ctx) |ctx| c.freeValue(ctx, v);
        socks[s] = null;
    }
    // F7-B: hosts/paths are views into static slot buffers — nothing to free.
    hosts[s] = "";
    paths[s] = "";
    want_connect[s] = false;
    wflags[s].ws_open = false;
    rx_event[s] = EV_NONE;
    rx_err_len[s] = 0;
    states[s].store(JOB_FREE, .release);
    free_list[free_count] = @intCast(s);
    free_count += 1;
}

pub fn init(ctx: ?*c.Context) void { // CHANGED: takes ctx
    g_ctx = ctx;
    poolInit();
    async_h = AsyncT.init() catch unreachable;
    async_armed = false;
    // F7-B: one shared command pipe for the single worker thread.
    makeCmdPipe() catch {
        async_h.deinit();
        return;
    };
}

pub fn submit(
    ctx: ?*c.Context,
    obj: c.Value,
    host: []const u8,
    path: []const u8,
    port: u16,
    tls_flag: bool,
) !usize {
    poolLock();
    defer poolUnlock();
    const s = acquireSlot() orelse return error.NoConnectionAvailable;
    // F7-B: bounded copy into static slot buffers — no per-connection dupes.
    if (host.len == 0 or host.len > 255 or path.len > 2047) {
        releaseSlot(s);
        return error.UrlTooLong;
    }
    @memcpy(host_bufs[s][0..host.len], host);
    host_bufs[s][host.len] = 0;
    hosts[s] = host_bufs[s][0..host.len :0];
    @memcpy(path_bufs[s][0..path.len], path);
    paths[s] = path_bufs[s][0..path.len];
    ports[s] = port;
    wflags[s].tls_active = tls_flag;
    var key16: [16]u8 = undefined;
    getRandomBytes(&key16);
    _ = std.base64.standard.Encoder.encode(keys[s][0..24], &key16);
    wflags[s].ws_open = false;
    wflags[s].ws_sent_close = false;
    rd_len[s] = 0;
    partial_len[s] = 0;
    tx_pending[s] = .{ .raw = false };
    rx_event[s] = EV_NONE;
    rx_err_len[s] = 0;
    close_deadline[s] = 0;
    socks[s] = c.dupValue(ctx, obj);
    _ = pending.fetchAdd(1, .acq_rel);
    startWorkerOnce() catch {
        _ = pending.fetchSub(1, .acq_rel);
        if (socks[s]) |v| {
            if (g_ctx) |cctx| c.freeValue(cctx, v);
            socks[s] = null;
        }
        releaseSlot(s);
        return error.SpawnFailed;
    };
    want_connect[s] = true;
    wakeWorker();
    ensureArmed();
    return s;
}

fn makeCmdPipe() !void {
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeCreateFailed;
    const cur: c_int = std.c.fcntl(fds[0], std.posix.F.GETFL);
    var flags: std.c.O = @bitCast(@as(u32, @intCast(cur)));
    flags.NONBLOCK = true;
    _ = std.c.fcntl(fds[0], std.posix.F.SETFL, @as(c_int, @bitCast(@as(u32, @bitCast(flags)))));
    cmd_pipe = fds;
}

fn wakeWorker() void {
    if (cmd_pipe[1] < 0) return;
    _ = std.c.write(cmd_pipe[1], &[_]u8{1}, 1);
}

// F7-B: the single shared worker is started lazily on first submit, under
// the already-held poolLock. One 1MiB-stack thread for all 64 slots.
fn startWorkerOnce() !void {
    if (worker_started) return;
    const th = std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, sharedWorkerMain, .{}) catch {
        return error.SpawnFailed;
    };
    th.detach();
    worker_started = true;
}

pub fn sendBytes(s: usize, bytes: []const u8, binary: bool) void {
    if (states[s].load(.acquire) == JOB_FREE) return;
    if (!wflags[s].ws_open) return;
    if (bytes.len > WS_MSG_SIZE) return;
    if (tx_pending[s].load(.acquire)) return;
    @memcpy(tx_msg[s][0..bytes.len], bytes);
    tx_len[s] = bytes.len;
    tx_job[s] = if (binary) TX_BINARY else TX_TEXT;
    tx_pending[s].store(true, .release);
    wakeWorker();
}

pub fn closeWs(s: usize, code: u16, reason: []const u8) void {
    if (states[s].load(.acquire) == JOB_FREE) return;
    const rlen = @min(reason.len, @as(usize, CLOSE_REASON_MAX));
    @memcpy(tx_reason[s][0..rlen], reason[0..rlen]);
    tx_reason_len[s] = @intCast(rlen);
    tx_code[s] = code;
    tx_job[s] = TX_CLOSE;
    tx_pending[s].store(true, .release);
    wakeWorker();
}

// ---- Worker ----

// F7-B: blocking connect + handshake for one slot. The slot's conn/req are
// published to w_conns/w_reqs on success (locals are then nulled so the
// defer below is a no-op). On failure, failClose runs and the defer deinits
// the local req — exactly-once teardown either way, same as before.
fn connectSlot(s: usize) void {
    want_connect[s] = false;
    var conn: ?*http.Client.Connection = null;
    var req: ?http.Client.Request = null;
    defer if (req) |*r| r.deinit();
    if (wflags[s].tls_active) {
        var uri_buf: [768]u8 = undefined;
        const uri_str = std.fmt.bufPrint(&uri_buf, "wss://{s}:{d}{s}", .{ hosts[s], ports[s], paths[s] }) catch {
            failClose(s, null, "invalid url", &req);
            return;
        };
        const uri = std.Uri.parse(uri_str) catch {
            failClose(s, null, "invalid url", &req);
            return;
        };
        req = tls.client().request(.GET, uri, .{
            .extra_headers = &[_]http.Header{
                .{ .name = "Upgrade", .value = "websocket" },
                .{ .name = "Connection", .value = "Upgrade" },
                .{ .name = "Sec-WebSocket-Key", .value = keys[s][0..24] },
                .{ .name = "Sec-WebSocket-Version", .value = "13" },
            },
        }) catch {
            failClose(s, null, "connect failed", &req);
            return;
        };
        conn = req.?.connection.?;
        req.?.sendBodiless() catch {
            failClose(s, conn, "connect failed", &req);
            return;
        };
        var redirect_buf: [8000]u8 = undefined;
        const resp = req.?.receiveHead(&redirect_buf) catch {
            failClose(s, conn, "handshake failed", &req);
            return;
        };
        if (resp.head.status != http.Status.switching_protocols) {
            failClose(s, conn, "handshake failed", &req);
            return;
        }
        const accept = findHeaderValueCI(resp.head.bytes, "sec-websocket-accept") orelse {
            failClose(s, conn, "handshake failed", &req);
            return;
        };
        var expected: [28]u8 = undefined;
        ws.computeAccept(keys[s][0..24], &expected);
        if (!std.ascii.eqlIgnoreCase(accept, expected[0..])) {
            failClose(s, conn, "handshake failed", &req);
            return;
        }
        tls.tuneFd(conn.?.stream_reader.stream.socket.handle);
        sock_fds[s] = conn.?.stream_reader.stream.socket.handle;
    } else {
        const host = std.Io.net.HostName.init(hosts[s]) catch {
            failClose(s, null, "invalid host", &req);
            return;
        };
        conn = tls.client().connect(host, ports[s], .plain) catch {
            failClose(s, null, "connect failed", &req);
            return;
        };
        tls.tuneFd(conn.?.stream_reader.stream.socket.handle);
        sock_fds[s] = conn.?.stream_reader.stream.socket.handle;
        if (!doUpgrade(s, conn.?)) {
            failClose(s, conn, "handshake failed", &req);
            return;
        }
    }
    const cn = conn.?;
    w_conns[s] = conn;
    w_reqs[s] = req;
    conn = null;
    req = null;
    wflags[s].conn_live = true;
    rx_event[s] = EV_OPEN;
    signalEvent(s);
    _ = cn;
}

// F7-B: one thread drives all WS client connections (was: one 1MiB-stack
// thread + one pipe per connection). Per-slot work is discovered by scanning
// columns on every wake: the wake byte is level-triggered (coalescing is
// harmless), `states` is the atomic guard, flags are re-verified hints.
// Event ordering per slot is preserved: a slot with an undispatched event
// (not JOB_BUSY) is skipped until drainCompleted flips it back.
fn sharedWorkerMain() void {
    var wake: [64]u8 = undefined;
    while (true) {
        // Drain wake pipe (bytes coalesce; the columns hold the work).
        while (true) {
            const n = std.c.read(cmd_pipe[0], &wake, wake.len);
            if (n <= 0) break;
        }
        // 1) New connections (blocking handshake, one slot at a time).
        for (0..MAX_WS) |s| {
            if (states[s].load(.acquire) == JOB_BUSY and want_connect[s] and !wflags[s].conn_live) {
                connectSlot(s);
            }
        }
        // 2) Pending transmits (SEND/CLOSE columns).
        for (0..MAX_WS) |s| {
            if (wflags[s].conn_live and states[s].load(.acquire) == JOB_BUSY and tx_pending[s].load(.acquire)) {
                if (w_conns[s]) |cn| {
                    if (!serviceTx(s, cn)) closeExit(s, cn, &w_reqs[s]);
                }
            }
        }
        // 3) Reads: poll cmd_pipe + all live BUSY sockets in one syscall.
        var pfd: [1 + MAX_WS]std.posix.pollfd = undefined;
        pfd[0] = .{ .fd = cmd_pipe[0], .events = std.posix.POLL.IN, .revents = 0 };
        var nfds: usize = 1;
        var slots: [MAX_WS]u16 = undefined;
        var nslots: usize = 0;
        var tls_ready_any = false;
        for (0..MAX_WS) |s| {
            if (!wflags[s].conn_live or states[s].load(.acquire) != JOB_BUSY) continue;
            if (w_conns[s]) |cn| {
                if (wflags[s].tls_active and tlsReadReady(s, cn)) tls_ready_any = true;
                pfd[nfds] = .{ .fd = sock_fds[s], .events = std.posix.POLL.IN, .revents = 0 };
                slots[nslots] = @intCast(s);
                nfds += 1;
                nslots += 1;
            }
        }
        // No live sockets: block in poll until the next submit/send/close.
        const rc = std.posix.poll(pfd[0..nfds], if (nfds == 1) -1 else (if (tls_ready_any) 0 else 50)) catch 0;
        _ = rc;
        for (0..nslots) |k| {
            const s: usize = slots[k];
            if (!wflags[s].conn_live or states[s].load(.acquire) != JOB_BUSY) continue;
            const cn = w_conns[s] orelse continue;
            const readable = (wflags[s].tls_active and tlsReadReady(s, cn)) or pfd[1 + k].revents != 0;
            if (readable) {
                if (rd_len[s] >= RDBUF) {
                    closeExit(s, cn, &w_reqs[s]);
                    continue;
                }
                const n = readWs(s, cn, rd_buf[s][rd_len[s]..]) catch |e| {
                    std.debug.print("[wss] read error: {s}\n", .{@errorName(e)});
                    closeExit(s, cn, &w_reqs[s]);
                    continue;
                };
                if (n == 0) {
                    if (!wflags[s].tls_active) {
                        closeExit(s, cn, &w_reqs[s]);
                        continue;
                    }
                } else {
                    rd_len[s] += n;
                }
            }
            // Bytes left from verifyUpgrade or an earlier partial frame are
            // consumed even when the socket had nothing new to report.
            if (rd_len[s] > 0) {
                if (!consumeFrames(s, cn)) {
                    closeExit(s, cn, &w_reqs[s]);
                    continue;
                }
            }
            if (wflags[s].ws_sent_close and monoMillis() > close_deadline[s]) {
                closeExit(s, cn, &w_reqs[s]);
                continue;
            }
        }
    }
}

fn closeExit(s: usize, conn: *http.Client.Connection, r: *?http.Client.Request) void {
    if (rx_event[s] != EV_CLOSE) {
        rx_event[s] = EV_CLOSE;
        rx_code[s] = 1006;
        rx_reason_len[s] = 0;
    }
    cleanupConn(s, conn, r);
    if (w_reqs[s]) |*rr| rr.deinit();
    w_conns[s] = null;
    w_reqs[s] = null;
    wflags[s].conn_live = false;
    _ = pending.fetchSub(1, .release);
    signalEvent(s);
    finishSlot(s);
}

fn failClose(s: usize, conn: ?*http.Client.Connection, comptime msg: []const u8, r: *?http.Client.Request) void {
    const mlen = @min(msg.len, rx_err[s].len);
    @memcpy(rx_err[s][0..mlen], msg[0..mlen]);
    rx_err_len[s] = @intCast(mlen);
    rx_code[s] = 1006;
    rx_reason_len[s] = 0;
    rx_event[s] = EV_CLOSE;
    if (conn) |cn| cleanupConn(s, cn, r);
    wflags[s].conn_live = false;
    _ = pending.fetchSub(1, .release);
    signalEvent(s);
    finishSlot(s);
}

fn cleanupConn(s: usize, conn: ?*http.Client.Connection, r: *?http.Client.Request) void {
    const fd = sock_fds[s];
    sock_fds[s] = -1;
    if (wflags[s].tls_active) {
        if (r.*) |*rr| rr.connection = null;
        if (conn) |cn| {
            cn.closing = true;
            tls.client().connection_pool.release(cn, tls.client().io);
        }
    } else if (fd >= 0) {
        _ = std.c.close(fd);
    }
}

fn finishSlot(s: usize) void {
    states[s].store(JOB_DONE, .release);
    async_h.notify() catch {};
}

fn signalEvent(s: usize) void {
    states[s].store(JOB_DONE, .release);
    async_h.notify() catch {};
}

const UPGRADE_TIMEOUT_MS: i64 = 5000;

fn buildUpgradeRequest(s: usize, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf,
        "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}:{d}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "Sec-WebSocket-Version: 13\r\n\r\n",
        .{ paths[s], hosts[s], ports[s], keys[s][0..24] },
    );
}

fn writeWs(s: usize, cn: *http.Client.Connection, bytes: []const u8) !void {
    _ = s;
    try cn.writer().writeAll(bytes);
    try cn.flush();
}

fn findHeaderValueCI(haystack: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, haystack, '\n');
    while (it.next()) |line_raw| {
        var line = line_raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn sockReadable(s: usize, timeout_ms: i32) bool {
    if (sock_fds[s] < 0) return false;
    var pfd = [_]std.posix.pollfd{
        .{ .fd = sock_fds[s], .events = std.posix.POLL.IN, .revents = 0 },
    };
    const rc = std.posix.poll(&pfd, timeout_ms) catch return false;
    return rc != 0 and pfd[0].revents != 0;
}

fn tlsReadReady(s: usize, cn: *http.Client.Connection) bool {
    if (cn.reader().bufferedLen() > 0) return true;
    return sockReadable(s, 0);
}

fn readWs(s: usize, cn: *http.Client.Connection, buf: []u8) !usize {
    if (!wflags[s].tls_active) {
        return std.posix.read(sock_fds[s], buf);
    }
    // TLS: never hand readSliceShort a large destination — it loops fill()
    // until the destination is FULL (short return only on EndOfStream), so
    // after decrypting one record it blocks reading the NEXT record header
    // until RCVTIMEO. Fill once, then copy exactly what is buffered.
    // (Verified against std/Io/Reader.zig readSliceShort.)
    const r = cn.reader();
    if (r.bufferedLen() == 0) {
        try r.fill(1); // one fill: decrypts one pending record (or EOF/error)
    }
    const n = @min(buf.len, r.bufferedLen());
    if (n == 0) return 0; // record consumed but no app data (alert/ticket)
    try r.readSliceAll(buf[0..n]); // fully satisfied from the buffer — no blocking
    return n;
}

fn verifyUpgrade(s: usize, cn: *http.Client.Connection) bool {
    _ = cn;
    var head_buf: [2048]u8 = undefined;
    var hlen: usize = 0;
    var head_end: ?usize = null;
    const deadline = monoMillis() + UPGRADE_TIMEOUT_MS;
    while (head_end == null) {
        if (std.mem.indexOf(u8, head_buf[0..hlen], "\r\n\r\n")) |idx| {
            head_end = idx;
            break;
        }
        if (monoMillis() > deadline) return false;
        if (sock_fds[s] < 0) return false;
        var pfd = [_]std.posix.pollfd{
            .{ .fd = sock_fds[s], .events = std.posix.POLL.IN, .revents = 0 },
        };
        const rc = std.posix.poll(&pfd, 50) catch return false;
        if (rc == 0) continue;
        var tmp: [512]u8 = undefined;
        const n = std.posix.read(sock_fds[s], &tmp) catch return false;
        if (n == 0) return false;
        const cp = @min(n, head_buf.len - hlen);
        @memcpy(head_buf[hlen..][0..cp], tmp[0..cp]);
        hlen += cp;
        if (hlen >= head_buf.len) return false;
    }
    const he = head_end.?;
    const eol = std.mem.indexOf(u8, head_buf[0..he], "\r\n") orelse return false;
    if (std.mem.indexOf(u8, head_buf[0..eol], " 101 ") == null) return false;
    const accept = findHeaderValueCI(head_buf[0..he], "sec-websocket-accept") orelse return false;
    var expected: [28]u8 = undefined;
    ws.computeAccept(keys[s][0..24], &expected);
    if (!std.ascii.eqlIgnoreCase(accept, expected[0..])) return false;
    const extra = hlen - (he + 4);
    if (extra > 0) {
        const cp = @min(extra, rd_buf[s].len);
        @memcpy(rd_buf[s][0..cp], head_buf[he + 4 ..][0..cp]);
        rd_len[s] = cp;
    }
    return true;
}

fn doUpgrade(s: usize, cn: *http.Client.Connection) bool {
    var req_buf: [768]u8 = undefined;
    const nreq = buildUpgradeRequest(s, &req_buf) catch return false;
    writeWs(s, cn, nreq) catch return false;
    return verifyUpgrade(s, cn);
}

fn sendFrame(s: usize, cn: *http.Client.Connection, opcode: u8, payload: []const u8) bool {
    if (payload.len > WS_MSG_SIZE) return false;
    var mask: [4]u8 = undefined;
    getRandomBytes(&mask);
    const hdr_len: usize = ws.buildHeader(&wb[s], opcode, true, payload.len);
    wb[s][1] |= 0x80;
    @memcpy(wb[s][hdr_len..][0..4], &mask);
    @memcpy(wb[s][hdr_len + 4 ..][0..payload.len], payload);
    ws.unmask(wb[s][hdr_len + 4 ..][0..payload.len], mask);
    writeWs(s, cn, wb[s][0 .. hdr_len + 4 + payload.len]) catch return false;
    return true;
}

fn writeCloseFrame(s: usize, cn: *http.Client.Connection, code: u16, reason: []const u8) bool {
    var payload: [2 + CLOSE_REASON_MAX]u8 = undefined;
    payload[0] = @intCast(code >> 8);
    payload[1] = @intCast(code & 0xff);
    const rl = @min(reason.len, CLOSE_REASON_MAX);
    @memcpy(payload[2..][0..rl], reason[0..rl]);
    return sendFrame(s, cn, ws.OP_CLOSE, payload[0 .. 2 + rl]);
}

fn initiateClose(s: usize, cn: *http.Client.Connection, code: u16, reason: []const u8) bool {
    if (wflags[s].ws_sent_close) return true;
    wflags[s].ws_sent_close = true;
    close_deadline[s] = monoMillis() + UPGRADE_TIMEOUT_MS;
    if (rx_event[s] != EV_CLOSE) {
        rx_event[s] = EV_CLOSE;
        rx_code[s] = code;
        rx_err_len[s] = 0;
        const rl = @min(reason.len, CLOSE_REASON_MAX);
        @memcpy(rx_reason[s][0..rl], reason[0..rl]);
        rx_reason_len[s] = @intCast(rl);
    }
    return writeCloseFrame(s, cn, code, reason);
}

fn recordClose(s: usize, payload: []const u8) void {
    if (payload.len >= 2) {
        rx_code[s] = (@as(u16, payload[0]) << 8) | @as(u16, payload[1]);
    }
    const rl: usize = if (payload.len > 2) @min(payload.len - 2, CLOSE_REASON_MAX) else 0;
    if (rl > 0) @memcpy(rx_reason[s][0..rl], payload[2..][0..rl]);
    rx_reason_len[s] = @intCast(rl);
}

fn emitMessage(s: usize, msg: []const u8, binary: bool) void {
    const n = @min(msg.len, WS_MSG_SIZE);
    @memcpy(rx_msg[s][0..n], msg[0..n]);
    rx_len[s] = n;
    wflags[s].rx_binary = binary;
    rx_event[s] = EV_MESSAGE;
    signalEvent(s);
    // F7-B: no waitState spin. The worker skips non-BUSY slots until
    // drainCompleted dispatches this event; consumeFrames stops after the
    // first undispatched event so rx_msg can't be overwritten meanwhile.
}

fn handleData(s: usize, cn: *http.Client.Connection, hdr: ws.FrameHdr, payload: []const u8) bool {
    const op = hdr.opcode;
    if (op == ws.OP_CONT and partial_len[s] == 0) {
        _ = initiateClose(s, cn, 1002, "");
        return false;
    }
    if (op != ws.OP_CONT and partial_len[s] != 0) {
        _ = initiateClose(s, cn, 1002, "");
        return false;
    }
    if (op != ws.OP_CONT and !hdr.fin) {
        wflags[s].partial_binary = op == ws.OP_BINARY;
    }
    if (!hdr.fin or op == ws.OP_CONT or partial_len[s] > 0) {
        if (payload.len > WS_MSG_SIZE - partial_len[s]) {
            _ = initiateClose(s, cn, 1009, "");
            return false;
        }
        @memcpy(partial[s][partial_len[s]..][0..payload.len], payload);
        partial_len[s] += payload.len;
        if (!hdr.fin) return true;
        emitMessage(s, partial[s][0..partial_len[s]], wflags[s].partial_binary);
        partial_len[s] = 0;
        return true;
    }
    emitMessage(s, payload, op == ws.OP_BINARY);
    return true;
}

fn handleFrame(s: usize, cn: *http.Client.Connection, hdr: ws.FrameHdr, payload: []const u8) bool {
    if (ws.isControl(hdr.opcode)) {
        switch (hdr.opcode) {
            ws.OP_PING => return sendFrame(s, cn, ws.OP_PONG, payload),
            ws.OP_PONG => return true,
            ws.OP_CLOSE => {
                recordClose(s, payload);
                _ = initiateClose(s, cn, rx_code[s], rx_reason[s][0..rx_reason_len[s]]);
                return false;
            },
            else => {
                _ = initiateClose(s, cn, 1002, "");
                return false;
            },
        }
    }
    return handleData(s, cn, hdr, payload);
}

fn consumeFrames(s: usize, cn: *http.Client.Connection) bool {
    var off: usize = 0;
    const buf = rd_buf[s][0..rd_len[s]];
    while (off < buf.len) {
        const hdr = ws.parseHeader(buf[off..]) orelse break;
        const total = @as(usize, hdr.header_len) + hdr.payload_len;
        if (buf.len - off < total) break;
        const payload = buf[off + hdr.header_len ..][0..hdr.payload_len];
        ws.unmask(payload, hdr.mask);
        if (!handleFrame(s, cn, hdr, payload)) return false;
        off += total;
        // F7-B: stop after the first undispatched event — the slot is now
        // DONE and its rx columns belong to the main thread until dispatch.
        // Leftover bytes stay buffered in rd_buf (accounted below).
        if (states[s].load(.acquire) != JOB_BUSY) break;
    }
    const left = rd_len[s] - off;
    if (off > 0 and left > 0) @memmove(rd_buf[s][0..left], rd_buf[s][off..rd_len[s]]);
    rd_len[s] = left;
    return true;
}

fn serviceTx(s: usize, cn: *http.Client.Connection) bool {
    // F7-B: the per-slot wake-pipe drain is gone (single cmd_pipe, drained in
    // the shared worker loop). The tx_* columns are the level-triggered work
    // description; the wake byte was only ever a notification.
    if (!tx_pending[s].load(.acquire)) return true;
    const job = tx_job[s];
    const code = tx_code[s];
    const rlen: usize = tx_reason_len[s];
    var reason: [CLOSE_REASON_MAX]u8 = undefined;
    @memcpy(reason[0..rlen], tx_reason[s][0..rlen]);
    var msg: [WS_MSG_SIZE]u8 = undefined;
    var mlen: usize = 0;
    if (job != TX_CLOSE) {
        mlen = @min(tx_len[s], WS_MSG_SIZE);
        @memcpy(msg[0..mlen], tx_msg[s][0..mlen]);
    }
    tx_pending[s].store(false, .release);
    switch (job) {
        TX_TEXT => return sendFrame(s, cn, ws.OP_TEXT, msg[0..mlen]),
        TX_BINARY => return sendFrame(s, cn, ws.OP_BINARY, msg[0..mlen]),
        TX_CLOSE => return initiateClose(s, cn, code, reason[0..rlen]),
        else => return true,
    }
}

// ---- Main-thread pump (QuickJS) ----

pub fn arm(l: *xev.Loop) void { // CHANGED: remembers the loop
    if (async_armed) return;
    async_armed = true;
    g_loop = l;
    async_h.wait(l, &async_comp, void, null, asyncCb);
}

/// CHANGED: re-arm after a disarm→submit sequence (single main thread: no race).
pub fn ensureArmed() void {
    if (async_armed) return;
    if (g_loop) |l| arm(l);
}

pub fn setLoop(l: *xev.Loop) void {
    g_loop = l;
}
fn asyncCb( // CHANGED: drains events and pumps microtasks
    ud: ?*void,
    l: *xev.Loop,
    comp: *xev.Completion,
    r: AsyncT.WaitError!void,
) xev.CallbackAction {
    _ = ud;
    _ = comp;
    _ = r catch return .disarm;
    if (g_ctx) |ctx| {
        drainCompleted(ctx);
        microtasks.pumpMicrotasks(ctx);
    }
    if (pending.load(.acquire) > 0) {
        async_armed = true;
        async_h.wait(l, &async_comp, void, null, asyncCb);
    } else {
        async_armed = false;
    }
    return .disarm;
}

fn doneMask() u64 {
    var raw: [MAX_WS]u8 = undefined;
    for (0..MAX_WS) |i| raw[i] = states[i].raw;
    const v: @Vector(MAX_WS, u8) = @bitCast(raw);
    const eq = v == @as(@Vector(MAX_WS, u8), @splat(JOB_DONE));
    return @bitCast(eq);
}

fn claimSlot(s: usize) bool {
    return states[s].cmpxchgStrong(JOB_DONE, JOB_CLAIMED, .acq_rel, .acquire) == null;
}

pub fn drainCompleted(ctx: ?*c.Context) void {
    var mask = doneMask();
    // F7-B: one wake per batch so the worker promptly resumes polling slots
    // the dispatch just flipped back to BUSY (replaces the old per-message
    // spin handshake).
    if (mask != 0) wakeWorker();
    while (mask != 0) {
        const s: usize = @ctz(mask);
        mask &= mask - 1;
        if (claimSlot(s)) completeEvent(ctx, s);
    }
}

fn setReadyState(ctx: ?*c.Context, obj: c.Value, v: i32) void {
    const val = c.newInt32(ctx, v);
    _ = c.definePropertyValueStr(ctx, obj, "readyState", val, c.PROP_C_W_E);
}

fn dispatchEvent(
    ctx: ?*c.Context,
    sock_val: c.Value,
    event_name: [*:0]const u8,
    event_val: ?c.Value,
) void {
    const prop = c.getPropertyStr(ctx, sock_val, event_name);
    if (c.isFunction(ctx, prop) == 0) return;
    if (event_val) |ev| {
        var argv = [_]c.Value{ev};
        _ = c.call(ctx, prop, sock_val, 1, &argv);
    } else {
        _ = c.call(ctx, prop, sock_val, 0, null);
    }
}

fn newEventObj(ctx: ?*c.Context, comptime type_name: []const u8) c.Value {
    const obj = c.newObject(ctx);
    const type_val = c.newStringLen(ctx, type_name.ptr, type_name.len);
    _ = c.definePropertyValueStr(ctx, obj, "type", type_val, c.PROP_C_W_E);
    return obj;
}

fn makeOpenEvent(ctx: ?*c.Context) c.Value {
    return newEventObj(ctx, "open");
}

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

fn makeMessageEvent(ctx: ?*c.Context, s: usize) c.Value {
    const obj = newEventObj(ctx, "message");
    const n = @min(rx_len[s], WS_MSG_SIZE);
    const data_val = if (wflags[s].rx_binary)
        u8ArrayFromBytes(ctx, rx_msg[s][0..n])
    else
        c.newStringLen(ctx, &rx_msg[s], n);
    _ = c.definePropertyValueStr(ctx, obj, "data", data_val, c.PROP_C_W_E);
    return obj;
}

fn makeCloseEvent(ctx: ?*c.Context, s: usize) c.Value {
    const obj = newEventObj(ctx, "close");
    const code_val = c.newInt32(ctx, @intCast(rx_code[s]));
    _ = c.definePropertyValueStr(ctx, obj, "code", code_val, c.PROP_C_W_E);
    const reason_val = c.newStringLen(ctx, &rx_reason[s], rx_reason_len[s]);
    _ = c.definePropertyValueStr(ctx, obj, "reason", reason_val, c.PROP_C_W_E);
    return obj;
}

fn makeErrorEvent(ctx: ?*c.Context, s: usize) c.Value {
    const obj = newEventObj(ctx, "error");
    const msg_val = c.newStringLen(ctx, &rx_err[s], rx_err_len[s]);
    _ = c.definePropertyValueStr(ctx, obj, "message", msg_val, c.PROP_C_W_E);
    return obj;
}

fn completeEvent(ctx: ?*c.Context, s: usize) void {
    const ev = rx_event[s];

    if (ev == EV_CLOSE) {
        if (socks[s]) |sv| {
            if (rx_err_len[s] > 0) {
                dispatchEvent(ctx, sv, "onerror", makeErrorEvent(ctx, s));
            }
            setReadyState(ctx, sv, 3);
            dispatchEvent(ctx, sv, "onclose", makeCloseEvent(ctx, s));
        }
        releaseSlot(s);
        return;
    }

    const sv = socks[s] orelse {
        states[s].store(JOB_BUSY, .release);
        return;
    };
    switch (ev) {
        EV_OPEN => {
            wflags[s].ws_open = true;
            setReadyState(ctx, sv, 1);
            dispatchEvent(ctx, sv, "onopen", makeOpenEvent(ctx));
            states[s].store(JOB_BUSY, .release);
        },
        EV_MESSAGE => {
            dispatchEvent(ctx, sv, "onmessage", makeMessageEvent(ctx, s));
            states[s].store(JOB_BUSY, .release);
        },
        else => states[s].store(JOB_BUSY, .release),
    }
}
