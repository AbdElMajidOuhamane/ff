const std = @import("std");

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
    payload_len: usize,
    header_len: u8,
    mask: [4]u8,
};

pub fn isControl(op: u8) bool {
    return op >= 0x8;
}
pub fn isData(op: u8) bool {
    return op == OP_TEXT or op == OP_BINARY;
}

// sec-websocket-key (base64, 24 chars max) -> 28-byte base64 accept.
pub fn computeAccept(key: []const u8, out: *[28]u8) void {
    var buf: [24 + WS_GUID.len]u8 = undefined;
    const klen = @min(key.len, 24);
    @memcpy(buf[0..klen], key[0..klen]);
    @memcpy(buf[klen..][0..WS_GUID.len], WS_GUID);
    var sha: [20]u8 = undefined;
   std.crypto.hash.Sha1.hash(buf[0 .. klen + WS_GUID.len], &sha, .{});
   _ = std.base64.standard.Encoder.encode(out, sha[0..]);
}

// Parse a client frame header. Client frames are always masked -> 6/8/14 bytes.
pub fn parseHeader(buf: []const u8) ?FrameHdr {
    if (buf.len < 2) return null;
    const b0 = buf[0];
    const b1 = buf[1];
    const fin = (b0 & 0x80) != 0;
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
    const total = header_len + 4;
    if (buf.len < total) return null;
    var mask: [4]u8 = undefined;
    @memcpy(&mask, buf[header_len..total]);
    return .{
        .opcode = opcode,
        .fin = fin,
        .payload_len = @intCast(len),
        .header_len = total,
        .mask = mask,
    };
}

// In-place XOR with the 4-byte mask.
pub fn unmask(buf: []u8, mask: [4]u8) void {
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
        out[2 + i] = @intCast((payload_len >> @intCast(shift)) & 0xff);
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
    // simulate client masked frame: fin|text, mask bit, len126
    buf[0] = 0x81;
    buf[1] = 0x80 | 126;
    buf[2] = 0x01;
    buf[3] = 0x2c; // 300
    buf[4] = 0x11;
    buf[5] = 0x22;
    buf[6] = 0x33;
    buf[7] = 0x44;
    const hdr = (parseHeader(&buf) orelse unreachable);
    try std.testing.expectEqual(@as(u8, OP_TEXT), hdr.opcode);
    try std.testing.expect(hdr.fin);
    try std.testing.expectEqual(@as(usize, 300), hdr.payload_len);
    try std.testing.expectEqual(@as(u8, 8), hdr.header_len);
}
