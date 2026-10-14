const std = @import("std");
const assert = std.debug.assert;
const fuzz = @import("../testing/fuzz.zig");
const tls = @import("tls_server.zig");

// TLS PEM plumbing: base64 roundtrip vs std encoder, PEM block iteration
// (cursor must advance, slices must stay inside the output buffer).

pub const events_smoke: usize = 10_000;
pub const events_default: ?usize = null;

const Op = enum { base64, pem };
const ws_chars = [_]u8{ '\n', '\r', ' ', '\t' };
const labels = [_][]const u8{ "CERTIFICATE", "PRIVATE KEY", "EC PRIVATE KEY", "RSA PRIVATE KEY", "CERT", "X", "" };

pub fn main(gpa: std.mem.Allocator, args: fuzz.FuzzArgs) !void {
    _ = gpa;
    var prng = std.Random.DefaultPrng.init(args.seed);
    const rand = prng.random();
    const enabled = fuzz.swarmTake(rand, 2);
    comptime assert(2 == @typeInfo(Op).@"enum".fields.len);

    var inbuf: [2048]u8 = undefined;
    var pem_buf: [4096]u8 = undefined;
    var outbuf: [2048]u8 = undefined;
    var events: usize = 0;
    while (args.events_max == null or events < args.events_max.?) : (events += 1) {
        const op = fuzz.randomEnum(rand, Op);
        if (!enabled[@intFromEnum(op)]) continue;
        switch (op) {
            .base64 => try fuzzBase64(rand, &inbuf, &outbuf),
            .pem => try fuzzPem(rand, &pem_buf, &outbuf),
        }
    }
}

fn fuzzBase64(rand: std.Random, inbuf: *[2048]u8, outbuf: *[2048]u8) !void {
    if (rand.boolean()) {
        // Valid base64 (std-encoded) with injected whitespace and dropped
        // padding: must roundtrip exactly.
        const raw = fuzz.randomSlice(rand, inbuf[0..384]);
        const elen = std.base64.standard.Encoder.calcSize(raw.len);
        var enc: [512]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(enc[0..elen], raw);
        var body: [1152]u8 = undefined;
        var bp: usize = 0;
        for (enc[0..elen]) |ch| {
            if (rand.float(f64) < 0.2) {
                const w = [_]u8{ws_chars[rand.intRangeLessThan(usize, 0, 4)]};
                bp = fuzz.appendTrunc(&body, bp, &w);
            }
            const c = [_]u8{ch};
            bp = fuzz.appendTrunc(&body, bp, &c);
        }
        // Drop 0..2 trailing '=' to exercise the padded-final-group path.
        var drop: usize = 0;
        while (drop < 2 and bp - drop > 0 and body[bp - drop - 1] == '=') : (drop += 1) {}
        const cut = rand.intRangeAtMost(usize, 0, drop);
        const der = tls.base64Der(body[0 .. bp - cut], outbuf) orelse
            return error.ValidRejected;
        if (!std.mem.eql(u8, der, raw)) return error.Roundtrip;
    } else {
        const body = fuzz.randomSlice(rand, inbuf);
        const der = tls.base64Der(body, outbuf) orelse return;
        const o0 = @intFromPtr(outbuf.ptr);
        const d0 = @intFromPtr(der.ptr);
        if (d0 < o0 or d0 + der.len > o0 + outbuf.len) return error.Escape;
        if (der.len > (cleanLen(body) + 3) / 4 * 3) return error.TooLong;
    }
}

/// Visible (non-whitespace, pre-padding) chars: mirrors base64Der's scan.
fn cleanLen(body: []const u8) usize {
    var n: usize = 0;
    for (body) |ch| {
        switch (ch) {
            '\n', '\r', ' ', '\t' => {},
            '=' => return n,
            else => n += 1,
        }
    }
    return n;
}

fn fuzzPem(rand: std.Random, pem_buf: *[4096]u8, der_buf: *[2048]u8) !void {
    var pos: usize = 0;
    const nblocks = rand.intRangeAtMost(usize, 0, 3);
    var bi: usize = 0;
    while (bi < nblocks) : (bi += 1) {
        if (rand.float(f64) < 0.3) { // inter-block noise
            const nz = fuzz.randomSlice(rand, pem_buf[pos..@min(pos + 64, pem_buf.len)]);
            pos += nz.len;
        }
        const lbl = fuzz.pick(rand, []const u8, &labels);
        pos = fuzz.appendTrunc(pem_buf, pos, "-----BEGIN ");
        pos = fuzz.appendTrunc(pem_buf, pos, lbl);
        pos = fuzz.appendTrunc(pem_buf, pos, "-----\n");
        if (rand.boolean()) {
            // Valid body: random DER, std-encoded, folded at 64 columns.
            var raw: [512]u8 = undefined;
            const rl = fuzz.randomSlice(rand, &raw);
            const el = std.base64.standard.Encoder.calcSize(rl.len);
            var enc: [684]u8 = undefined;
            _ = std.base64.standard.Encoder.encode(enc[0..el], rl);
            var c: usize = 0;
            while (c < el) {
                const line = @min(64, el - c);
                pos = fuzz.appendTrunc(pem_buf, pos, enc[c..][0..line]);
                pos = fuzz.appendTrunc(pem_buf, pos, "\n");
                c += line;
            }
        } else {
            const nz = fuzz.randomSlice(rand, pem_buf[pos..@min(pos + 256, pem_buf.len)]);
            pos += nz.len;
            pos = fuzz.appendTrunc(pem_buf, pos, "\n");
        }
        pos = fuzz.appendTrunc(pem_buf, pos, "-----END ");
        // END label sometimes differs: the block must then be skipped.
        const elbl = if (rand.float(f64) < 0.8) lbl else fuzz.pick(rand, []const u8, &labels);
        pos = fuzz.appendTrunc(pem_buf, pos, elbl);
        pos = fuzz.appendTrunc(pem_buf, pos, "-----\n");
    }

    const pem = pem_buf[0..pos];
    const want = fuzz.pick(rand, []const u8, &labels);
    var cursor: usize = 0;
    var iters: usize = 0;
    while (tls.pemNextBlock(pem, want, &cursor, der_buf)) |der| {
        // The cursor must advance: a repeated hit is a hang, fail loud.
        iters += 1;
        if (iters > nblocks + 1) return error.NoAdvance;
        // Missing trailing newline parks the cursor at pem.len + 1: allow it.
        if (cursor > pem.len + 1) return error.CursorEscape;
        const o0 = @intFromPtr(der_buf.ptr);
        const d0 = @intFromPtr(der.ptr);
        if (d0 < o0 or d0 + der.len > o0 + der_buf.len) return error.Escape;
    }
    if (cursor > pem.len + 1) return error.CursorEscape;
}
