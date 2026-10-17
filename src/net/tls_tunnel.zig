//! TLS-over-CONNECT tunnel for https/wss through an HTTP proxy.
//!
//! Zig 0.16.0's std.http.Client.connectProxied returns the raw CONNECT
//! tunnel without TLS-upgrading it for .tls targets (ziglang/zig#19878,
//! codeberg PR #36484), so a proxied https/wss request would be written in
//! plaintext to the target's TLS port. This module opens the tunnel itself
//! and hands std.http.Client a ready TLS connection through the public
//! RequestOptions.connection, keeping all request/response handling in std.
//!
//! Layout contract: Connection.reader()/writer()/host()/destroy() recover
//! their owning container via @fieldParentPtr("connection", ...), and that
//! private container is `struct { client: std.crypto.tls.Client,
//! connection: Connection }`. TlsConn mirrors that layout exactly and the
//! allocation mirrors Connection.Tls.create/allocLen, so std's methods work
//! on our connection. The coupling is intentional and versioned: it holds
//! for Zig 0.16.0 only. When upstream lands TLS-over-CONNECT, delete this
//! module and let https_proxy work normally.
//!
//! Unlike std's tunnel error path, a failed CONNECT or TLS handshake is
//! returned as an error — never silently retried as a plaintext forward
//! proxy request.

const std = @import("std");
const http = std.http;
const Client = http.Client;
const Io = std.Io;
const HostName = std.Io.net.HostName;
const Writer = Io.Writer;
const tls_transport = @import("tls.zig");

/// Mirrors std.http.Client.Connection.Tls (private in 0.16.0).
const TlsConn = struct {
    client: std.crypto.tls.Client,
    connection: Client.Connection,
};

comptime {
    if (Client.disable_tls) @compileError("tls_tunnel requires std TLS (http_disable_tls=false)");
    std.debug.assert(@offsetOf(TlsConn, "client") == 0);
}

/// Connect to `host:port` through `proxy` using CONNECT and return a
/// TLS-upgraded Connection registered in the client's pool (reused when one
/// is already free, exactly like std's connectProxied).
pub fn connect(
    client: *Client,
    proxy: *Client.Proxy,
    host: HostName,
    port: u16,
) !*Client.Connection {
    if (proxy.protocol == .tls) return error.TlsProxyUnsupported;
    const io = client.io;

    // Reuse a pooled TLS connection to the same target if available (ours or
    // direct — identical semantics for the request).
    if (client.connection_pool.findConnection(io, .{
        .host = host,
        .port = port,
        .protocol = .tls,
    })) |node| return node;

    var stream = try proxy.host.connect(io, proxy.port, .{ .mode = .stream });
    var stream_owned = true;
    errdefer if (stream_owned) stream.close(io);
    tls_transport.tuneFd(stream.socket.handle);

    // 1. CONNECT host:port — minimal head, no user-agent needed.
    var head_buf: [1024]u8 = undefined;
    var hw: Writer = .fixed(&head_buf);
    hw.print("CONNECT {s}:{d} HTTP/1.1\r\nhost: {s}:{d}\r\n", .{
        host.bytes, port, host.bytes, port,
    }) catch return error.TunnelHeadTooLarge;
    if (proxy.authorization) |auth| {
        hw.print("proxy-authorization: {s}\r\n", .{auth}) catch return error.TunnelHeadTooLarge;
    }
    hw.writeAll("\r\n") catch return error.TunnelHeadTooLarge;

    var wbuf: [512]u8 = undefined;
    var sw = stream.writer(io, &wbuf);
    sw.interface.writeAll(hw.buffered()) catch return error.TunnelWriteFailed;
    sw.interface.flush() catch return error.TunnelWriteFailed;

    // 2. Read the response head. readSliceShort fills its whole destination
    // (it is short only at EOF), so use fill(1) + buffered/toss for short
    // reads. Nothing follows the head until we send ClientHello, so no
    // target bytes can be lost here.
    var rbuf: [1024]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    var resp_buf: [2048]u8 = undefined;
    var resp_len: usize = 0;
    while (std.mem.indexOf(u8, resp_buf[0..resp_len], "\r\n\r\n") == null) {
        if (resp_len == resp_buf.len) return error.TunnelHeadTooLarge;
        if (sr.interface.bufferedLen() == 0) {
            sr.interface.fill(1) catch return error.TunnelReadFailed;
        }
        const buffered = sr.interface.buffered();
        const n = @min(buffered.len, resp_buf.len - resp_len);
        @memcpy(resp_buf[resp_len..][0..n], buffered[0..n]);
        resp_len += n;
        sr.interface.toss(n);
    }
    const eol = std.mem.indexOf(u8, resp_buf[0..resp_len], "\r\n") orelse return error.TunnelReadFailed;
    const status_line = resp_buf[0..eol];
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 200") and
        !std.mem.startsWith(u8, status_line, "HTTP/1.0 200"))
    {
        return error.TunnelRefused;
    }

    // 3. Load the CA bundle if needed — same lazy rescan std.http.Client's
    // request() performs before connecting for .tls URIs.
    rescan: {
        {
            try client.ca_bundle_lock.lockShared(io);
            defer client.ca_bundle_lock.unlockShared(io);
            if (client.now != null) break :rescan;
        }
        var bundle: std.crypto.Certificate.Bundle = .empty;
        defer bundle.deinit(client.allocator);
        const now = Io.Clock.real.now(io);
        bundle.rescan(client.allocator, io, now) catch return error.CertificateBundleLoadFailure;
        try client.ca_bundle_lock.lock(io);
        defer client.ca_bundle_lock.unlock(io);
        client.now = now;
        std.mem.swap(std.crypto.Certificate.Bundle, &client.ca_bundle, &bundle);
    }

    // 4. Mirror Connection.Tls.create: one allocation, host bytes first,
    // then the TLS/read/write buffers, with the TLS client's ciphertext
    // output buffer (stream_writer) and ciphertext input buffer
    // (stream_reader) both at least min_buffer_len, as std's crypto TLS
    // client requires (writableSliceGreedy(min_buffer_len)).
    const alloc_len = allocLen(client, host.bytes.len);
    const base = try client.allocator.alignedAlloc(u8, .of(TlsConn), alloc_len);
    errdefer client.allocator.free(base);
    const host_buffer = base[@sizeOf(TlsConn)..][0..host.bytes.len];
    const tls_read_buffer_len = client.tls_buffer_size + client.read_buffer_size;
    const tls_read_buffer = host_buffer.ptr[host_buffer.len..][0..tls_read_buffer_len];
    const tls_write_buffer = tls_read_buffer.ptr[tls_read_buffer_len..][0..client.tls_buffer_size];
    const socket_write_buffer = tls_write_buffer.ptr[client.tls_buffer_size..][0..client.write_buffer_size];
    const socket_read_buffer = socket_write_buffer.ptr[client.write_buffer_size..][0..client.tls_buffer_size];
    @memcpy(host_buffer, host.bytes);

    const tc: *TlsConn = @ptrCast(base);
    tc.connection = .{
        .client = client,
        .stream_writer = stream.writer(io, tls_write_buffer),
        .stream_reader = stream.reader(io, socket_read_buffer),
        .pool_node = .{},
        .port = port,
        .host_len = @intCast(host.bytes.len),
        .proxied = false,
        .closing = false,
        .protocol = .tls,
    };
    var random_buffer: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
    io.random(&random_buffer);
    tc.client = std.crypto.tls.Client.init(
        &tc.connection.stream_reader.interface,
        &tc.connection.stream_writer.interface,
        .{
            .host = .{ .explicit = host.bytes },
            .ca = .{ .bundle = .{
                .gpa = client.allocator,
                .io = client.io,
                .lock = &client.ca_bundle_lock,
                .bundle = &client.ca_bundle,
            } },
            .ssl_key_log = client.ssl_key_log,
            .read_buffer = tls_read_buffer,
            .write_buffer = socket_write_buffer,
            .entropy = &random_buffer,
            .realtime_now = client.now.?,
            .allow_truncation_attacks = true,
        },
    ) catch |err| switch (err) {
        error.WriteFailed => return tc.connection.stream_writer.err.?,
        error.ReadFailed => return tc.connection.stream_reader.err.?,
        else => |e| return e,
    };

    // 5. Publish: the stream is now owned by the connection (destroy() will
    // close it), and the pool decides reuse vs teardown at Request.deinit.
    stream_owned = false;
    client.connection_pool.addUsed(io, &tc.connection);
    return &tc.connection;
}

/// Mirrors Connection.Tls.allocLen (0.16.0); destroy() frees exactly this.
fn allocLen(client: *Client, host_len: usize) usize {
    const tls_read_buffer_len = client.tls_buffer_size + client.read_buffer_size;
    return @sizeOf(TlsConn) + host_len + tls_read_buffer_len + client.tls_buffer_size +
        client.write_buffer_size + client.tls_buffer_size;
}
