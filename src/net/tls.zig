const std = @import("std");
const http = std.http;
const simd = std.simd;

// ============================================================
// Outbound TLS transport — DOD / SoA connection slot pool.
//
// Same idiom as net/http_native.zig: dense per-slot arrays instead of N
// heap structs, with an O(1) free-list slot allocator. Today fetch is
// single-connection-serial, so one slot is live at a time; the pool is
// sized for the async-fetch buildout where several requests overlap.
//
// SIMD: everything we scan/case-fold ourselves uses vector lanes
// (@Vector + @select), mirroring types/headers.zig.
// ============================================================

pub const MAX_CONN = 64;
const ConnState = enum(u8) { free, connecting, active, closing };

var states: [MAX_CONN]ConnState = [_]ConnState{.free} ** MAX_CONN;
var fds: [MAX_CONN]std.posix.fd_t = undefined;
var tls_active: [MAX_CONN]bool = [_]bool{false} ** MAX_CONN;
var reuse_gen: [MAX_CONN]u32 = [_]u32{0} ** MAX_CONN;
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
// SIMD hot paths (vector, then scalar tail — headers.zig idiom)
// ============================================================

/// In-place ASCII uppercase->lowercase. Lanes in 'A'..'Z' get += 0x20.
pub fn lowerAsciiSimd(buf: []u8) void {
    const N = simd.suggestVectorLength(u8) orelse 16;
    const V = @Vector(N, u8);
    const spl_a: V = @splat('A');
    const spl_z: V = @splat('Z');
    const spl_32: V = @splat(0x20);
    const spl_0: V = @splat(0);
    var i: usize = 0;
    const tail = buf.len % N;
    const main_end = buf.len - tail;
    while (i < main_end) : (i += N) {
        var v: V = buf[i..][0..N].*;
        const upper = (v >= spl_a) & (v <= spl_z);
        v += @select(u8, upper, spl_32, spl_0);
        const arr: [N]u8 = v;
        buf[i..][0..N].* = arr;
    }
    while (i < buf.len) : (i += 1) {
        buf[i] = std.ascii.toLower(buf[i]);
    }
}

/// First index of any '\r' or '\n' lane, or null. Single vectorized pass
/// over the main body — the scan point for future chunked/record-boundary
/// parsing in the drain path.
pub fn findCrLf(haystack: []const u8) ?usize {
    const N = simd.suggestVectorLength(u8) orelse 16;
    const V = @Vector(N, u8);
    const spl_cr: V = @splat(0x0D);
    const spl_lf: V = @splat(0x0A);
    var i: usize = 0;
    const tail = haystack.len % N;
    const main_end = haystack.len - tail;
    while (i < main_end) : (i += N) {
        const v: V = haystack[i..][0..N].*;
        const m = (v == spl_cr) | (v == spl_lf);
        var bits: u64 = 0;
        for (0..N) |j| {
            if (m[j]) bits |= @as(u64, 1) << @intCast(j);
        }
        if (bits != 0) return i + @ctz(bits);
    }
    while (i < haystack.len) : (i += 1) {
        const b = haystack[i];
        if (b == 0x0D or b == 0x0A) return i;
    }
    return null;
}

// ============================================================
// Transport tuning (batch over the pool)
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

/// Apply NODELAY to every live slot (branchless stride over the SoA array).
/// Called after acquiring slots; hands off straight to std's request.
pub fn tuneAllLive() void {
    for (0..MAX_CONN) |s| {
        if (states[s] == .active) tuneFd(fds[s]);
    }
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
