const std = @import("std");
const fuzz = @import("../testing/fuzz.zig");
const te = @import("text_encoding.zig");

// TextDecoder lossy UTF-8 core: output always valid UTF-8, valid input
// passes through unchanged, decoding is idempotent. The `bytes.len * 3`
// allocation bound from decoderDecode is checked on every event.

pub const events_smoke: usize = 20_000;
pub const events_default: ?usize = null;

const pieces = [_][]const u8{
    "a", "Z", "0", " ", "\x7f",
    "\xc3\xa9", // U+00E9
    "\xe2\x82\xac", // U+20AC
    "\xf0\x9f\x98\x80", // U+1F600
    "\xc2\x80", // U+0080, smallest 2-byte
    "\xe0\xa0\x80", // U+0800, smallest 3-byte
    "\xf0\x90\x80\x80", // U+10000, smallest 4-byte
    "\xf4\x8f\xbf\xbf", // U+10FFFF, largest scalar
};

pub fn main(gpa: std.mem.Allocator, args: fuzz.FuzzArgs) !void {
    _ = gpa;
    var prng = std.Random.DefaultPrng.init(args.seed);
    const rand = prng.random();

    var in: [512]u8 = undefined;
    var out: [1536]u8 = undefined;
    var out2: [4608]u8 = undefined;
    var events: usize = 0;
    while (args.events_max == null or events < args.events_max.?) : (events += 1) {
        const r = rand.float(f64);
        const input = if (r < 0.4)
            fuzz.randomSlice(rand, &in)
        else if (r < 0.7)
            validUtf8(rand, &in)
        else
            mutateValid(rand, &in);
        const n = te.decodeUtf8Lossy(input, &out);
        if (n > out.len) return error.Overrun;
        const dec = out[0..n];
        if (!std.unicode.utf8ValidateSlice(dec)) return error.InvalidOutput;
        if (std.unicode.utf8ValidateSlice(input) and !std.mem.eql(u8, dec, input))
            return error.ValidChanged;
        const n2 = te.decodeUtf8Lossy(dec, &out2);
        if (!std.mem.eql(u8, out2[0..n2], dec)) return error.NotIdempotent;
    }
}

fn validUtf8(rand: std.Random, buf: *[512]u8) []u8 {
    var len: usize = 0;
    const n = rand.intRangeAtMost(usize, 0, 8);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        len = fuzz.appendTrunc(buf, len, fuzz.pick(rand, []const u8, &pieces));
    }
    return buf[0..len];
}

fn mutateValid(rand: std.Random, buf: *[512]u8) []u8 {
    const v = validUtf8(rand, buf);
    var len = v.len;
    const nmut = rand.intRangeAtMost(usize, 1, 3);
    var k: usize = 0;
    while (k < nmut and len > 0) : (k += 1) {
        const at = rand.intRangeLessThan(usize, 0, len);
        switch (rand.intRangeLessThan(u8, 0, 3)) {
            0 => buf[at] ^= @as(u8, 1) << rand.int(u3),
            1 => buf[at] = rand.int(u8),
            else => len -= 1, // drop trailing byte: truncated sequences
        }
    }
    return buf[0..len];
}
