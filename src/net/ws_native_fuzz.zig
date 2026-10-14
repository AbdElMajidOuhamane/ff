const std = @import("std");
const assert = std.debug.assert;
const fuzz = @import("../testing/fuzz.zig");
const ws = @import("ws_native.zig");

// RFC6455 frame parser: header bounds, build/parse roundtrip, SIMD unmask
// vs scalar oracle, accept-key determinism.

pub const events_smoke: usize = 20_000;
pub const events_default: ?usize = null;

const Op = enum { header, roundtrip, unmask, accept };

pub fn main(gpa: std.mem.Allocator, args: fuzz.FuzzArgs) !void {
    _ = gpa;
    var prng = std.Random.DefaultPrng.init(args.seed);
    const rand = prng.random();
    const enabled = fuzz.swarmTake(rand, 4);
    comptime assert(4 == @typeInfo(Op).@"enum".fields.len);

    var buf: [256]u8 = undefined;
    var events: usize = 0;
    while (args.events_max == null or events < args.events_max.?) : (events += 1) {
        const op = fuzz.randomEnum(rand, Op);
        if (!enabled[@intFromEnum(op)]) continue;
        switch (op) {
            .header => try fuzzHeader(rand, &buf),
            .roundtrip => try fuzzRoundtrip(rand),
            .unmask => try fuzzUnmask(rand, &buf),
            .accept => try fuzzAccept(rand, &buf),
        }
    }
}

fn fuzzHeader(rand: std.Random, buf: *[256]u8) !void {
    const input = fuzz.randomSlice(rand, buf);
    const h = ws.parseHeader(input) orelse return;
    if (h.header_len > ws.MAX_HDR) return error.HeaderTooLong;
    if (h.header_len > input.len) return error.HeaderOverrun;
    // Reparsing the exact header prefix must agree (prefix determinism).
    const h2 = ws.parseHeader(input[0..h.header_len]) orelse
        return error.HeaderPrefixRejected;
    if (h2.header_len != h.header_len or h2.payload_len != h.payload_len or
        h2.opcode != h.opcode or h2.fin != h.fin) return error.HeaderUnstable;
}

fn fuzzRoundtrip(rand: std.Random) !void {
    const opcodes = [_]u8{ 0x0, 0x1, 0x2, 0x8, 0x9, 0xa, 0x3, 0xf };
    const opcode = opcodes[rand.intRangeLessThan(usize, 0, opcodes.len)];
    const fin = rand.boolean();
    const lens = [_]usize{ 0, 1, 125, 126, 127, 300, 0xffff, 0x10000, 70000, std.math.maxInt(u32), std.math.maxInt(u64) };
    const len = lens[rand.intRangeLessThan(usize, 0, lens.len)];
    var hdr: [14]u8 = undefined;
    const hlen = ws.buildHeader(&hdr, opcode, fin, len);
    if (hlen != 2 and hlen != 4 and hlen != 10) return error.BadHeaderLen;
    var full: [18]u8 = undefined;
    @memcpy(full[0..hlen], hdr[0..hlen]);
    var total = hlen;
    var mask: [4]u8 = .{ 0, 0, 0, 0 };
    if (rand.boolean()) {
        rand.bytes(&mask);
        full[1] |= 0x80;
        @memcpy(full[hlen..][0..4], &mask);
        total += 4;
    }
    const h = ws.parseHeader(full[0..total]) orelse return error.RoundtripRejected;
    if (h.opcode != opcode or h.fin != fin or
        h.payload_len != len or h.header_len != total) return error.RoundtripMismatch;
    if (!std.mem.eql(u8, &h.mask, &mask)) return error.MaskMismatch;
}

fn fuzzUnmask(rand: std.Random, buf: *[256]u8) !void {
    const len = @min(fuzz.randomIntExponential(rand, usize, 64), buf.len);
    var mask: [4]u8 = undefined;
    rand.bytes(&mask);
    rand.bytes(buf[0..len]);
    var want: [256]u8 = undefined;
    var got: [256]u8 = undefined;
    @memcpy(want[0..len], buf[0..len]);
    @memcpy(got[0..len], buf[0..len]);
    ws.unmaskScalar(want[0..len], mask);
    ws.unmask(got[0..len], mask);
    if (!std.mem.eql(u8, got[0..len], want[0..len])) return error.UnmaskMismatch;
    // Masking is an involution: a second pass restores the original bytes.
    ws.unmask(got[0..len], mask);
    if (!std.mem.eql(u8, got[0..len], buf[0..len])) return error.UnmaskNotInvolution;
}

fn fuzzAccept(rand: std.Random, buf: *[256]u8) !void {
    const key = fuzz.randomSlice(rand, buf);
    var out: [28]u8 = undefined;
    var out2: [28]u8 = undefined;
    ws.computeAccept(key, &out);
    ws.computeAccept(key, &out2);
    if (!std.mem.eql(u8, &out, &out2)) return error.AcceptUnstable;
    var dec: [20]u8 = undefined; // 28 base64 chars decode to exactly 20 bytes
    _ = std.base64.standard.Decoder.decode(&dec, &out) catch
        return error.AcceptNotBase64;
}
