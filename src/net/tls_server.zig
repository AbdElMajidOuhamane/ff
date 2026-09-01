const std = @import("std");
const ffcfg = @import("ffcfg");
const bssl = @import("../bearssl.zig").bssl;

pub const available: bool = ffcfg.bearssl;

// Lazy-safe decls: these compile even with -Dbearssl=false because the
// bssl.* references below are only analyzed when `available` is true.
pub const Ctx = if (available) bssl.br_ssl_server_context else struct { _pad: u8 = 0 };
pub const IOBUF_LEN: usize = if (available) bssl.BR_SSL_BUFSIZE_BIDI else 1;

comptime {
    if (available) std.debug.assert(IOBUF_LEN >= 32000);
}

// Engine state bits (bearssl_ssl.h) — mutually exclusive "current state" values.
pub const ST_CLOSED: c_uint = if (available) bssl.BR_SSL_CLOSED else 0;
pub const ST_SENDREC: c_uint = if (available) bssl.BR_SSL_SENDREC else 1;
pub const ST_RECVREC: c_uint = if (available) bssl.BR_SSL_RECVREC else 2;
pub const ST_SENDAPP: c_uint = if (available) bssl.BR_SSL_SENDAPP else 3;
pub const ST_RECVAPP: c_uint = if (available) bssl.BR_SSL_RECVAPP else 4;

pub const MAX_CERTS: usize = 4;

// ── Static server configuration (init-time only, zero hot-path allocations) ──
var g_cert_pool: [32 * 1024]u8 = undefined;
var g_certs: [MAX_CERTS]bssl.br_x509_certificate = undefined;
var g_nchains: usize = 0;
var g_skey: bssl.br_skey_decoder_context = undefined; // outlives get_ec/get_rsa pointers
var g_is_ec: bool = false;
var g_ready = false;

// ── PEM plumbing (pure Zig) ─────────────────────────────────────────

/// Extract the next `label` PEM block starting at *cursor; returns decoded DER.
fn pemNextBlock(pem: []const u8, label: []const u8, cursor: *usize, out: []u8) ?[]u8 {
    const begin_head = "-----BEGIN ";
    const end_head = "-----END ";
    var i = cursor.*;
    while (true) {
        const b = std.mem.indexOfPos(u8, pem, i, begin_head) orelse return null;
        i = b + begin_head.len;
        const lbl_end = std.mem.indexOfScalarPos(u8, pem, i, '-') orelse return null;
        const lbl = pem[i..lbl_end];
        const line_end = std.mem.indexOfScalarPos(u8, pem, lbl_end, '\n') orelse return null;
        const e_marker = std.mem.indexOfPos(u8, pem, line_end, end_head) orelse return null;
        const e_lbl_end = std.mem.indexOfScalarPos(u8, pem, e_marker + end_head.len, '-') orelse return null;
        const e_lbl = pem[e_marker + end_head.len .. e_lbl_end];
        const body_start = line_end + 1;
        if (std.mem.eql(u8, lbl, label) and std.mem.eql(u8, e_lbl, label)) {
            const body = pem[body_start..e_marker];
            const der = base64Der(body, out) orelse return null;
            const nl = std.mem.indexOfScalarPos(u8, pem, e_lbl_end, '\n') orelse pem.len;
            cursor.* = nl + 1;
            return der;
        }
        i = e_marker;
    }
}

fn base64Der(body: []const u8, out: []u8) ?[]u8 {
    var o: usize = 0;
    var group: [4]u8 = undefined;
    var gi: usize = 0;
    for (body) |ch| {
        switch (ch) {
            '\n', '\r', ' ', '\t' => continue,
            '=' => break,
            else => {},
        }
        group[gi] = ch;
        gi += 1;
        if (gi == 4) {
            if (o + 3 > out.len) return null;
            var dec: [3]u8 = undefined;
            std.base64.standard.Decoder.decode(&dec, &group) catch return null;
            @memcpy(out[o..][0..3], &dec);
            o += 3;
            gi = 0;
        }
    }
    // Padded final group: "xx==" carries 1 byte, "xxx=" carries 2.
    // Decode with zero-bit filler chars ('A') and keep only the real bytes.
    if (gi != 0) {
        if (gi == 1) return null; // invalid base64
        var full: [4]u8 = .{ group[0], group[1], 0, 0 };
        var dec: [3]u8 = undefined;
        if (gi == 2) {
            full[2] = 'A';
            full[3] = 'A';
            std.base64.standard.Decoder.decode(&dec, &full) catch return null;
            if (o + 1 > out.len) return null;
            out[o] = dec[0];
            o += 1;
        } else { // gi == 3
            full[2] = group[2];
            full[3] = 'A';
            std.base64.standard.Decoder.decode(&dec, &full) catch return null;
            if (o + 2 > out.len) return null;
            out[o] = dec[0];
            out[o + 1] = dec[1];
            o += 2;
        }
    }
    return out[0..o];
}

pub const InitError = error{
    BadPem,
    CertTooBig,
    TooManyCerts,
    BadKey,
    UnsupportedKey,
    NoBearssl,
};

pub fn initServer(cert_pem: []const u8, key_pem: []const u8) InitError!void {
    if (!available) return error.NoBearssl;

    // 1) certificate chain (all "CERTIFICATE" PEM blocks)
    var pool_off: usize = 0;
    var cursor: usize = 0;
    g_nchains = 0;
    while (g_nchains < MAX_CERTS) {
        if (pemNextBlock(cert_pem, "CERTIFICATE", &cursor, g_cert_pool[pool_off..])) |der| {
            g_certs[g_nchains].data = &g_cert_pool[pool_off];
            g_certs[g_nchains].data_len = der.len;
            pool_off += der.len;
            g_nchains += 1;
        } else break;
    }
    if (g_nchains == 0) return error.BadPem;
    if (pool_off >= g_cert_pool.len) return error.CertTooBig;

    // 2) private key (PKCS#8 "PRIVATE KEY", or SEC1/RSA traditional)
    var key_cursor: usize = 0;
    var key_der_buf: [8 * 1024]u8 = undefined;
    const kder = pemNextBlock(key_pem, "PRIVATE KEY", &key_cursor, &key_der_buf) orelse
        blk: { key_cursor = 0; break :blk pemNextBlock(key_pem, "EC PRIVATE KEY", &key_cursor, &key_der_buf); } orelse
        blk: { key_cursor = 0; break :blk pemNextBlock(key_pem, "RSA PRIVATE KEY", &key_cursor, &key_der_buf); } orelse
        return error.BadPem;

    bssl.br_skey_decoder_init(&g_skey);
    bssl.br_skey_decoder_push(&g_skey, @ptrCast(kder.ptr), kder.len);
    if (bssl.br_skey_decoder_last_error(&g_skey) != 0) return error.BadKey;

    const kt = bssl.br_skey_decoder_key_type(&g_skey);
    if (kt == bssl.BR_KEYTYPE_EC) {
        g_is_ec = true;
    } else if (kt == bssl.BR_KEYTYPE_RSA) {
        g_is_ec = false;
    } else {
        return error.UnsupportedKey; // Ed25519/X25519 server certs unsupported in v1
    }

    g_ready = true;
}

/// True once initServer() parsed a cert chain + key successfully.
pub fn ready() bool {
    return g_ready;
}

/// One-time-per-accepted-connection setup. Cheap, allocation-free.
pub fn slotInit(ctx: *Ctx, iobuf: []u8) void {
    if (!g_ready) return;
    if (g_is_ec) {
        bssl.br_ssl_server_init_full_ec(
            ctx,
            &g_certs,
            g_nchains,
            bssl.BR_KEYTYPE_EC, // self-signed / assume EC-issued; unused for ECDHE suites
            bssl.br_skey_decoder_get_ec(&g_skey),
        );
    } else {
        bssl.br_ssl_server_init_full_rsa(
            ctx,
            &g_certs,
            g_nchains,
            bssl.br_skey_decoder_get_rsa(&g_skey),
        );
    }
    bssl.br_ssl_engine_set_buffer(&ctx.eng, @ptrCast(iobuf.ptr), iobuf.len, 1);
    _ = bssl.br_ssl_server_reset(ctx);
}

// ── Pump surface (engine fns take *br_ssl_engine_context via .eng) ──

pub fn curState(ctx: *Ctx) c_uint {
    return bssl.br_ssl_engine_current_state(&ctx.eng);
}

/// Ciphertext landing buffer the kernel may write directly into.
pub fn recvRecSpace(ctx: *Ctx) []u8 {
    var n: usize = 0;
    const p = bssl.br_ssl_engine_recvrec_buf(&ctx.eng, &n) orelse return &[_]u8{};
    const base: [*]u8 = @ptrCast(p);
    return base[0..n];
}

pub fn recvRecAck(ctx: *Ctx, len: usize) void {
    bssl.br_ssl_engine_recvrec_ack(&ctx.eng, len);
}

/// Ciphertext the engine wants on the wire (single contiguous span).
pub fn sendRecReady(ctx: *Ctx) []const u8 {
    var n: usize = 0;
    const p = bssl.br_ssl_engine_sendrec_buf(&ctx.eng, &n) orelse return &[_]u8{};
    const base: [*]const u8 = @ptrCast(p);
    return base[0..n];
}

pub fn sendRecAck(ctx: *Ctx, len: usize) void {
    bssl.br_ssl_engine_sendrec_ack(&ctx.eng, len);
}

/// Decrypted bytes available to the application.
pub fn recvAppReady(ctx: *Ctx) []const u8 {
    var n: usize = 0;
    const p = bssl.br_ssl_engine_recvapp_buf(&ctx.eng, &n) orelse return &[_]u8{};
    const base: [*]const u8 = @ptrCast(p);
    return base[0..n];
}

pub fn recvAppAck(ctx: *Ctx, len: usize) void {
    bssl.br_ssl_engine_recvapp_ack(&ctx.eng, len);
}

/// Copy as much plaintext `src` as the engine accepts this tick; returns fed count.
pub fn sendAppFeed(ctx: *Ctx, src: []const u8) usize {
    var n: usize = 0;
    const p = bssl.br_ssl_engine_sendapp_buf(&ctx.eng, &n) orelse return 0;
    const m = @min(src.len, n);
    if (m == 0) return 0;
    const dst: [*]u8 = @ptrCast(p);
    @memcpy(dst[0..m], src[0..m]);
    bssl.br_ssl_engine_sendapp_ack(&ctx.eng, m);
    return m;
}

pub fn flush(ctx: *Ctx) void {
    bssl.br_ssl_engine_flush(&ctx.eng, 0);
}

pub fn shutdown(ctx: *Ctx) void {
    bssl.br_ssl_engine_close(&ctx.eng);
}

pub fn lastError(ctx: *Ctx) c_int {
    return bssl.br_ssl_engine_last_error(&ctx.eng);
}
