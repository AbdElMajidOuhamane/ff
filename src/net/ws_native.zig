const std = @import("std");

// ── DOD note ──
// FrameHdr is a stack transient (parse → consume in wsConsume), never stored
// in a hot array, so AoS-by-value is correct and MultiArrayList is wrong.
// `fin: bool` stays a bool: folding it into `opcode` bit 7 would save 0 BSS
// (no array) while adding parse/mask cost on every frame. Documented here so
// the skill §3 bool review is recorded as intentional, not missed.
// `masked` is the same trade: one bit in a 24-byte stack transient, no array.
// SIMD (§9): `unmask` uses explicit @Vector at suggestVectorLength with scalar
// tail + `unmaskScalar` oracle + test — the justified pattern, not "SIMD is
// faster". The 4B mask pattern is broadcast with std.simd.repeat (no manual
// fill loop, so there is no N%4 shape invariant to keep in sync).

// ---- RFC6455 constants ----
pub const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
pub const WS_MSG_SIZE = 16384;
pub const MAX_HDR = 14;
pub const OP_CONT: u8 = 0x0;
pub const OP_TEXT: u8 = 0x1;
pub const OP_BINARY: u8 = 0x2;
pub const OP_CLOSE: u8 = 0x8;
pub const OP_PING: u8 = 0x9;
pub const OP_PONG: u8 = 0xa;

pub const FrameHdr = struct {
    opcode: u8,
    fin: bool,
    masked: bool,
    payload_len: usize,
    header_len: u8,
    mask: [4]u8,
};
comptime {
    // Stack transient: assert exact stride so future field adds are deliberate.
    std.debug.assert(@sizeOf(FrameHdr) <= 32);
    std.debug.assert(@alignOf(FrameHdr) == 8);
}
pub fn isControl(op: u8) bool {
    return op >= 0x8;
}
pub fn isData(op: u8) bool {
    return op == OP_TEXT or op == OP_BINARY;
}
/// Opcodes this implementation accepts. 0x3-0x7 (reserved data) and 0xB-0xF
/// (reserved control) are protocol errors, not "unknown data with no handler".
pub fn isValidOpcode(op: u8) bool {
    return switch (op) {
        OP_CONT, OP_TEXT, OP_BINARY, OP_CLOSE, OP_PING, OP_PONG => true,
        else => false,
    };
}
/// RFC 6455 §5.5: control frames MUST NOT be fragmented (FIN must be set) and
/// MUST carry ≤125 bytes. A control frame carrying a 16 KiB payload is a
/// protocol error, and blindly echoing it back is an amplification primitive.
pub fn controlFrameOk(hdr: FrameHdr) bool {
    if (!isControl(hdr.opcode)) return true;
    return hdr.fin and hdr.payload_len <= 125;
}
/// RFC 6455 §5.6 / §8.1: text frames — and the assembled payload of a
/// fragmented text message — MUST be valid UTF-8. Invalid data must fail the
/// connection with 1007 rather than reach JS as a malformed string.
pub fn validUtf8(s: []const u8) bool {
    return std.unicode.utf8ValidateSlice(s);
}
// sec-websocket-key (base64, 24 chars max) -> 28-byte base64 accept.
pub fn computeAccept(key: []const u8, out: *[28]u8) void {
    var buf: [24 + WS_GUID.len]u8 = undefined;
    // NOTE: @min may narrow its result type; klen is only used as a slice
    // bound and in an addition whose other operand is comptime_int, which is
    // why this site compiles. Keep new arithmetic away from it.
    const klen = @min(key.len, 24);
    @memcpy(buf[0..klen], key[0..klen]);
    @memcpy(buf[klen..][0..WS_GUID.len], WS_GUID);
    var sha: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(buf[0 .. klen + WS_GUID.len], &sha, .{});
    _ = std.base64.standard.Encoder.encode(out, sha[0..]);
}
// Parse a frame header for either direction: client->server frames are
// masked (RFC6455 clients MUST), server->client frames are not (servers
// MUST NOT). `masked` is reported so each consumer can enforce its direction;
// a zero mask is an identity XOR so consumers can unmask unconditionally.
pub fn parseHeader(buf: []const u8) ?FrameHdr {
    if (buf.len < 2) return null;
    const b0 = buf[0];
    const b1 = buf[1];
    const fin = (b0 & 0x80) != 0;
    const masked = (b1 & 0x80) != 0;
    const opcode = b0 & 0x0f;
    var len: u64 = b1 & 0x7f;
    var header_len: u8 = 2;
    if (len == 126) {
        if (buf.len < 4) return null;
        len = (@as(u64, buf[2]) << 8) | buf[3];
        header_len = 4;
    } else if (len == 127) {
        if (buf.len < 10) return null;
        len = 0;
        for (0..8) |i| len = (len << 8) | buf[2 + i];
        header_len = 10;
    }
    // Mask key present only when the sender masked it into the header.
    const mlen: u8 = if (masked) 4 else 0;
    const total = header_len + mlen;
    if (buf.len < total) return null;
    var mask: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) @memcpy(&mask, buf[header_len..total]);
    return .{
        .opcode = opcode,
        .fin = fin,
        .masked = masked,
        .payload_len = @intCast(len),
        .header_len = total,
        .mask = mask,
    };
}
// Scalar reference (old implementation), kept as the test oracle.
pub fn unmaskScalar(buf: []u8, mask: [4]u8) void {
    var i: usize = 0;
    const last = buf.len - (buf.len % 4);
    while (i < last) : (i += 4) {
        buf[i] ^= mask[0];
        buf[i + 1] ^= mask[1];
        buf[i + 2] ^= mask[2];
        buf[i + 3] ^= mask[3];
    }
    while (i < buf.len) : (i += 1) {
        buf[i] ^= mask[i & 3];
    }
}
// In-place XOR with the 4-byte mask at CPU-native vector width
// (32 lanes on AVX2, 64 on AVX-512), scalar tail for the remainder.
// The 4B pattern is broadcast with std.simd.repeat — no manual fill
// loop, so there is no N%4 shape assumption to keep in sync.
pub fn unmask(buf: []u8, mask: [4]u8) void {
    const N = std.simd.suggestVectorLength(u8) orelse 16;
    const V = @Vector(N, u8);
    var i: usize = 0;
    const body = buf.len & ~@as(usize, N - 1);
    if (body >= N) {
        const mv: V = std.simd.repeat(N, @as(@Vector(4, u8), mask));
        while (i < body) : (i += N) {
            const v: V = buf[i..][0..N].*;
            buf[i..][0..N].* = v ^ mv;
        }
    }
    while (i < buf.len) : (i += 1) {
        buf[i] ^= mask[i & 3];
    }
}
// Server -> client frames are unmasked. Returns header length.
pub fn buildHeader(out: []u8, opcode: u8, fin: bool, payload_len: usize) u8 {
    out[0] = (if (fin) @as(u8, 0x80) else 0) | (opcode & 0x0f);
    if (payload_len <= 125) {
        out[1] = @intCast(payload_len);
        return 2;
    }
    if (payload_len <= 0xffff) {
        out[1] = 126;
        out[2] = @intCast((payload_len >> 8) & 0xff);
        out[3] = @intCast(payload_len & 0xff);
        return 4;
    }
    out[1] = 127;
    var shift: u6 = 56;
    for (0..8) |i| {
        out[2 + i] = @intCast((payload_len >> shift) & 0xff);
        shift -%= 8;
    }
    return 10;
}
test "computeAccept RFC6455 vector" {
    var out: [28]u8 = undefined;
    computeAccept("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", out[0..28]);
}
test "buildHeader lengths" {
    var buf: [14]u8 = undefined;
    try std.testing.expectEqual(@as(u8, 2), buildHeader(&buf, OP_TEXT, true, 100));
    try std.testing.expectEqual(@as(u8, 4), buildHeader(&buf, OP_TEXT, true, 300));
    try std.testing.expectEqual(@as(u8, 10), buildHeader(&buf, OP_TEXT, true, 70000));
    try std.testing.expectEqual(buf[1], @as(u8, 127));
}
test "parseHeader roundtrip" {
    var buf: [14]u8 = undefined;
    const h1 = buildHeader(&buf, OP_TEXT, true, 300);
    _ = h1;
    buf[0] = 0x81;
    buf[1] = 0x80 | 126;
    buf[2] = 0x01;
    buf[3] = 0x2c;
    buf[4] = 0x11;
    buf[5] = 0x22;
    buf[6] = 0x33;
    buf[7] = 0x44;
    const hdr = (parseHeader(&buf) orelse unreachable);
    try std.testing.expectEqual(@as(u8, OP_TEXT), hdr.opcode);
    try std.testing.expect(hdr.fin);
    try std.testing.expect(hdr.masked);
    try std.testing.expectEqual(@as(usize, 300), hdr.payload_len);
    try std.testing.expectEqual(@as(u8, 8), hdr.header_len);
}
test "parseHeader reports the mask bit for both directions" {
    // Client frame: FIN|TEXT, MASK|len=5.
    const client = [_]u8{ 0x81, 0x80 | 5, 1, 2, 3, 4, 'h', 'e', 'l', 'l', 'o' };
    const c = parseHeader(&client) orelse unreachable;
    try std.testing.expect(c.masked);
    try std.testing.expectEqual(@as(usize, 5), c.payload_len);
    // Server frame: same payload, no mask key.
    const server = [_]u8{ 0x81, 5, 'h', 'e', 'l', 'l', 'o' };
    const s = parseHeader(&server) orelse unreachable;
    try std.testing.expect(!s.masked);
    try std.testing.expectEqual(@as(usize, 5), s.payload_len);
    try std.testing.expectEqual(@as(u8, 2), s.header_len);
}
test "opcode and control-frame constraints" {
    try std.testing.expect(isValidOpcode(OP_CONT));
    try std.testing.expect(isValidOpcode(OP_TEXT));
    try std.testing.expect(isValidOpcode(OP_CLOSE));
    // Reserved data (0x3-0x7) and reserved control (0xB-0xF) are errors.
    try std.testing.expect(!isValidOpcode(0x3));
    try std.testing.expect(!isValidOpcode(0x7));
    try std.testing.expect(!isValidOpcode(0xb));
    try std.testing.expect(!isValidOpcode(0xf));

    const ping_ok = FrameHdr{ .opcode = OP_PING, .fin = true, .masked = true, .payload_len = 125, .header_len = 6, .mask = .{ 0, 0, 0, 0 } };
    try std.testing.expect(controlFrameOk(ping_ok));
    var ping_big = ping_ok;
    ping_big.payload_len = 126;
    try std.testing.expect(!controlFrameOk(ping_big));
    var ping_frag = ping_ok;
    ping_frag.fin = false;
    try std.testing.expect(!controlFrameOk(ping_frag));
    // Data frames are exempt from the control rules (bounded elsewhere).
    const text_big = FrameHdr{ .opcode = OP_TEXT, .fin = false, .masked = true, .payload_len = 16384, .header_len = 8, .mask = .{ 0, 0, 0, 0 } };
    try std.testing.expect(controlFrameOk(text_big));
}
test "validUtf8 matches the std oracle" {
    try std.testing.expect(validUtf8("hello"));
    try std.testing.expect(validUtf8("héllo")); // 2-byte sequence
    try std.testing.expect(validUtf8("🚀")); // 4-byte sequence
    try std.testing.expect(!validUtf8(&[_]u8{ 0xff, 0xfe }));
    try std.testing.expect(!validUtf8(&[_]u8{0xc3})); // truncated 2-byte
}
test "unmask vector equals scalar" {
    const mask = [4]u8{ 0x11, 0x22, 0x33, 0x44 };
    const sizes = [_]usize{ 0, 1, 3, 4, 15, 16, 17, 20, 63, 64, 100, 255, 256 };
    for (sizes) |s| {
        var a: [300]u8 = undefined;
        var b: [300]u8 = undefined;
        for (0..s) |k| {
            a[k] = @intCast((k * 37 + 11) & 0xff);
            b[k] = a[k];
        }
        unmask(a[0..s], mask);
        unmaskScalar(b[0..s], mask);
        try std.testing.expectEqualSlices(u8, a[0..s], b[0..s]);
    }
}
