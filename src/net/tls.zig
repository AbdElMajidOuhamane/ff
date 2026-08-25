const std = @import("std");
const http = std.http;
// ============================================================
// Outbound TLS transport — DOD / SoA connection slot pool.
//
// Same idiom as net/http_native.zig: dense per-slot arrays instead of N
// heap structs, with an O(1) free-list slot allocator. Today fetch is
// single-connection-serial, so one slot is live at a time; the pool is
// sized for the async-fetch buildout where several requests overlap.
//
// Note: vectorized scanning/case-folding helpers live where they are used
// (types/headers.zig: lowerAsciiSimd, net/http_native.zig: findHeaderEnd);
// this module previously carried unused copies that have been removed.
// ============================================================
pub const MAX_CONN = 64;
const ConnState = enum(u8) { free, connecting, active, closing };
var states: [MAX_CONN]ConnState = [_]ConnState{.free} ** MAX_CONN;
var fds: [MAX_CONN]std.posix.fd_t = undefined;
var tls_active: [MAX_CONN]bool = [_]bool{false} ** MAX_CONN;
var free_list: [MAX_CONN]u16 = undefined;
var free_count: usize = MAX_CONN;
// Async-fetch buildout: workers call attach/detach from their own threads,
// so the free-list head is guarded by a tiny spinlock (std.atomic.Mutex).
var pool_lock: std.atomic.Mutex = .unlocked;
fn poolLock() void {
    while (!pool_lock.tryLock()) std.atomic.spinLoopHint();
}
fn poolUnlock() void {
    pool_lock.unlock();
}
// ---- O(1) slot allocator ----
fn poolInit() void {
    for (0..MAX_CONN) |i| free_list[i] = @intCast(MAX_CONN - 1 - i);
    free_count = MAX_CONN;
}
fn acquireSlot() ?usize {
    if (free_count == 0) return null;
    free_count -= 1;
    const s: usize = free_list[free_count];
    states[s] = .connecting;
    return s;
}
fn releaseSlot(s: usize) void {
    states[s] = .free;
    fds[s] = 0;
    tls_active[s] = false;
    free_list[free_count] = @intCast(s);
    free_count += 1;
}
// ============================================================
// TLS-capable HTTP client (std-backed, shared singleton)
// ============================================================
var io_backend: std.Io.Threaded = undefined;
var http_client: http.Client = undefined;
var client_initialized = false;
pub fn init() void {
    if (client_initialized) return;
    poolInit();
    // async_fetch spawns up to 10 concurrent connect+handshake paths through
    // this io instance. The std default limit is cpus-1 (7 here), which the
    // connect wave saturates — excess Io.async tasks then run inline on the
    // calling worker, ~1 RTT of scheduling contention per straggler. Raise it
    // so every connect+DNS dispatch gets a dedicated pool thread.
    io_backend = std.Io.Threaded.init(std.heap.page_allocator, .{
        .async_limit = .limited(64),
    });
    http_client = .{
        .allocator = std.heap.page_allocator,
        .io = io_backend.io(),
    };
    client_initialized = true;
}
pub fn deinit() void {
    if (!client_initialized) return;
    http_client.deinit();
    io_backend.deinit();
    client_initialized = false;
}
pub fn client() *http.Client {
    return &http_client;
}
// ============================================================
// Transport tuning
// ============================================================
/// TCP_NODELAY for one fd: std.http never sets it, so each small second
/// write (TLS Finished record, then the request segment) awaits a
/// delayed-ACK round trip — up to ~2 RTTs (~90ms) per fresh connection.
pub fn tuneFd(fd: std.posix.fd_t) void {
    const one: c_int = 1;
    std.posix.setsockopt(
        fd,
        @intCast(std.posix.IPPROTO.TCP),
        @intCast(std.posix.TCP.NODELAY),
        std.mem.asBytes(&one),
    ) catch {};
}
/// Register a connection handed back by std.http into the pool: records its
/// fd + TLS flag so reuse/tuning is data-oriented at fetch time.
/// Thread-safe (spinlock-guarded) for the async worker buildout.
pub fn attach(conn: *http.Client.Connection) ?usize {
    poolLock();
    defer poolUnlock();
    const s = acquireSlot() orelse return null;
    fds[s] = conn.stream_reader.stream.socket.handle;
    tls_active[s] = conn.protocol == .tls;
    states[s] = .active;
    tuneFd(fds[s]);
    return s;
}
pub fn detach(s: usize) void {
    poolLock();
    defer poolUnlock();
    releaseSlot(s);
}
