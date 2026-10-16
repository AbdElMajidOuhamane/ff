const std = @import("std");
const builtin = @import("builtin");
const http = std.http;
const proxy_mod = @import("proxy.zig");
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
const Io = std.Io;
pub const MAX_CONN = 64;

/// Hard bound on any single socket read/write on pooled connections: a
/// dead/slow upstream must fail the job (surfacing as a JS rejection via
/// the existing catch paths) instead of parking a pool worker forever.
pub const IO_TIMEOUT_SEC: u32 = 30;

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
var io_backend: Io.Threaded = undefined;
var http_client: http.Client = undefined;
var client_initialized = false;

/// Optional client CA file (PEM) loaded into the shared HTTP client's CA
/// bundle at init(). Set by start.zig (--cert) or via FF_CA_FILE/FF_CERT env.
pub var ca_file: ?[]const u8 = null;

// ---- Proxy configuration ----
// initProxies() populates http_client.http_proxy / https_proxy from the
// standard env vars (http_proxy, HTTP_PROXY, all_proxy, ALL_PROXY and the
// https variants) through std's initDefaultProxies. std then does the
// actual proxying: absolute-form request lines for forward proxies,
// CONNECT tunnels for TLS, proxy-authorization from URL userinfo.
//
// std does not implement NO_PROXY, so matching hosts are routed to a
// second, proxy-free client instead. Both clients share the same io
// backend and CA configuration.
var proxy_arena_state: std.heap.ArenaAllocator = undefined;
var proxy_arena_ready = false;
var no_proxy: ?proxy_mod.NoProxy = null;
var direct_client: http.Client = undefined;
var direct_initialized = false;

pub fn init() void {
    if (client_initialized) return;
    poolInit();
    io_backend = std.Io.Threaded.init(std.heap.page_allocator, .{
        .async_limit = .limited(64),
    });
    http_client = .{
        .allocator = std.heap.page_allocator,
        .io = io_backend.io(),
    };
    // DO NOT set http_client.now here — leave it null so request()
    // auto-scans system root certificates on the first HTTPS call.
    initProxies();
    const ca_env: ?[]const u8 = ca_file orelse blk: {
        const p = std.c.getenv("FF_CA_FILE") orelse std.c.getenv("FF_CERT") orelse break :blk null;
        break :blk std.mem.span(p);
    };
    if (ca_env) |path| {
        applyCaFile(&http_client, path);
        if (direct_initialized) applyCaFile(&direct_client, path);
    }
    client_initialized = true;
}

/// Load a PEM CA bundle into one client. `path` is borrowed (argv/env
/// memory); the cert data is copied into the client's bundle.
/// Parameter is `target`, not `client`: Zig forbids shadowing the
/// container-level `pub fn client()`.
fn applyCaFile(target: *http.Client, path: []const u8) void {
    var file = std.Io.Dir.cwd().openFile(target.io, path, .{}) catch {
        std.debug.print("[tls] CA file: could not open '{s}'\n", .{path});
        return;
    };
    defer file.close(target.io);
    var file_reader = file.reader(target.io, &.{});
    target.ca_bundle.addCertsFromFile(
        std.heap.page_allocator,
        &file_reader,
        0,
    ) catch |e| {
        std.debug.print("[tls] CA file: load failed ({s})\n", .{@errorName(e)});
    };
}

fn initProxies() void {
    proxy_arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    proxy_arena_ready = true;
    const arena = proxy_arena_state.allocator();

    // initDefaultProxies takes an Environ.Map; build a borrowed one from
    // the process environment (same iteration as api/process.zig's env
    // setup). The map itself is only needed for this call.
    var env = std.process.Environ.Map.init(std.heap.page_allocator);
    defer env.deinit();
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const entry_str = std.mem.span(entry);
        const eq = std.mem.indexOfScalar(u8, entry_str, '=') orelse continue;
        if (eq == 0) continue;
        env.put(entry_str[0..eq], entry_str[eq + 1 ..]) catch return;
    }
    http_client.initDefaultProxies(arena, &env) catch |e| {
        std.debug.print("[proxy] env parse failed: {s}\n", .{@errorName(e)});
    };

    // Uri.getHostAlloc only copies when the host is percent-encoded; for a
    // normal URL it BORROWS the string it was parsed from — here, the env
    // map value that `defer env.deinit()` frees when this function returns.
    // Re-home both host slices in the arena (alive until tls.deinit), or the
    // first connect() self-proxy comparison reads freed memory (SIGSEGV).
    // supports_connect stays at std's default (true): CONNECT serves https://
    // tunnels and the ws:// raw handshake, and std falls back to forward-proxy
    // mode when the proxy rejects CONNECT (covered by test/proxy.test.js).
    if (http_client.http_proxy) |p| {
        if (arena.dupe(u8, p.host.bytes)) |owned| {
            p.host.bytes = owned;
        } else |_| {
            http_client.http_proxy = null;
        }
    }
    if (http_client.https_proxy) |p| {
        if (arena.dupe(u8, p.host.bytes)) |owned| {
            p.host.bytes = owned;
        } else |_| {
            http_client.https_proxy = null;
        }
    }

    if (http_client.http_proxy == null and http_client.https_proxy == null) return;

    // NO_PROXY: parsed here (std has no support) and enforced by routing
    // matching hosts to `direct_client` in clientForHost below.
    if (std.c.getenv("no_proxy") orelse std.c.getenv("NO_PROXY")) |raw| {
        if (proxy_mod.parse(arena, std.mem.span(raw))) |np| {
            no_proxy = np;
        } else |e| {
            std.debug.print("[proxy] NO_PROXY ignored ({s})\n", .{@errorName(e)});
        }
    }
    if (no_proxy) |np| {
        if (np.entries.len > 0 or np.bypass_all) {
            direct_client = .{
                .allocator = std.heap.page_allocator,
                .io = io_backend.io(),
            };
            direct_initialized = true;
        }
    }
    if (builtin.mode == .Debug) logProxies();
}

fn logProxies() void {
    if (http_client.http_proxy) |p| {
        std.debug.print("[proxy] http -> {s}:{d}\n", .{ p.host.bytes, p.port });
    }
    if (http_client.https_proxy) |p| {
        std.debug.print("[proxy] https -> {s}:{d}\n", .{ p.host.bytes, p.port });
    }
    if (no_proxy) |np| {
        std.debug.print("[proxy] no_proxy: {d} entries, bypass_all={}\n", .{
            np.entries.len,
            np.bypass_all,
        });
    }
}

/// Pick the client for one outbound request: the direct client when
/// NO_PROXY matches the target (and a proxy is actually configured for the
/// request's protocol), otherwise the shared client.
/// Thread-safe: both clients and the NO_PROXY table are fixed after init().
pub fn clientForHost(host: []const u8, port: u16, protocol: http.Client.Protocol) *http.Client {
    if (direct_initialized) {
        const proxied = switch (protocol) {
            .plain => http_client.http_proxy != null,
            .tls => http_client.https_proxy != null,
        };
        if (proxied) {
            if (no_proxy) |np| {
                if (np.bypasses(host, port)) return &direct_client;
            }
        }
    }
    return &http_client;
}

/// Proxy to use for an https/wss request to `host:port`, or null when the
/// request goes direct (no https_proxy configured, or NO_PROXY matches).
/// Callers hand the result to net/tls_tunnel.connect, which upgrades the
/// CONNECT tunnel to TLS that std.http.Client cannot (ziglang/zig#19878).
pub fn httpsProxyFor(host: []const u8, port: u16) ?*http.Client.Proxy {
    const proxy = http_client.https_proxy orelse return null;
    if (no_proxy) |np| {
        if (np.bypasses(host, port)) return null;
    }
    return proxy;
}

pub fn deinit() void {
    if (!client_initialized) return;
    if (direct_initialized) {
        direct_client.deinit();
        direct_initialized = false;
    }
    http_client.deinit();
    io_backend.deinit();
    if (proxy_arena_ready) {
        proxy_arena_state.deinit();
        proxy_arena_ready = false;
    }
    no_proxy = null;
    client_initialized = false;
}
pub fn client() *http.Client {
    return &http_client;
}
// ============================================================
// Transport tuning
// ============================================================
/// Per-connection transport tuning: TCP_NODELAY + bounded idle waits.
///
/// NODELAY: std.http never sets it, so each small second write (TLS
/// Finished record, then the request segment) awaits a delayed-ACK round
/// trip — up to ~2 RTTs (~90ms) per fresh connection.
///
/// RCVTIMEO/SNDTIMEO: without them, any stalled upstream (half-open conn,
/// throttled host, mid-body stall) blocks a pool worker's read forever —
/// there is no other deadline in the fetch path. With them, the stalled
/// op errors after IO_TIMEOUT_SEC and the existing catch paths turn it
/// into a normal job failure -> JS rejection -> slot recycles.
pub fn tuneFd(fd: std.posix.fd_t) void {
    const one: c_int = 1;
    std.posix.setsockopt(
        fd,
        @intCast(std.posix.IPPROTO.TCP),
        @intCast(std.posix.TCP.NODELAY),
        std.mem.asBytes(&one),
    ) catch {};
    const tv = std.posix.timeval{ .sec = @intCast(IO_TIMEOUT_SEC), .usec = 0 };
    std.posix.setsockopt(
        fd,
        @intCast(std.posix.SOL.SOCKET),
        @intCast(std.posix.SO.RCVTIMEO),
        std.mem.asBytes(&tv),
    ) catch {};
    std.posix.setsockopt(
        fd,
        @intCast(std.posix.SOL.SOCKET),
        @intCast(std.posix.SO.SNDTIMEO),
        std.mem.asBytes(&tv),
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
