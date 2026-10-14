const std = @import("std");
const assert = std.debug.assert;
const fuzz = @import("../testing/fuzz.zig");
const http = @import("http_native.zig");

// HTTP/1.1 request line + header block: SIMD header-end scan vs naive
// oracle, request-field containment, method-tag consistency, determinism.

pub const events_smoke: usize = 20_000;
pub const events_default: ?usize = null;

const Op = enum { headers_end, request, method };

const verbs = [_][]const u8{ "GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS", "PATCH", "get", "GOT", "TELEPORT", "" };
const paths = [_][]const u8{ "/", "/a", "/a?b=c&d=e", "/x%20y", "//double", "/a/../b", "", "?", "/p", "/A%2FB%43" };
const protos = [_][]const u8{ "HTTP/1.1", "HTTP/1.0", "HTTP/2", "http/1.1", "" };
const hdict = [_][]const u8{
    "Host: x",
    "Content-Length: 0",
    "Content-Length: 13",
    "Content-Length: 9999999999999999999999",
    "Content-Length: 18446744073709551615",
    "Content-Length: abc",
    "Content-Length:  12 ",
    "Connection: keep-alive",
    "Connection: close",
    "Connection: Keep-Alive, Upgrade",
    "connection: CLOSE",
    "CONTENT-LENGTH: 5",
    "X-A: b",
    "",
};
const line_ends = [_][]const u8{ "\r\n", "\n", "\r", "" };
const known_methods = [_]struct { name: []const u8, tag: http.Method }{
    .{ .name = "GET", .tag = .get },
    .{ .name = "PUT", .tag = .put },
    .{ .name = "POST", .tag = .post },
    .{ .name = "HEAD", .tag = .head },
    .{ .name = "PATCH", .tag = .patch },
    .{ .name = "DELETE", .tag = .delete },
    .{ .name = "OPTIONS", .tag = .options },
};

pub fn main(gpa: std.mem.Allocator, args: fuzz.FuzzArgs) !void {
    _ = gpa;
    var prng = std.Random.DefaultPrng.init(args.seed);
    const rand = prng.random();
    const enabled = fuzz.swarmTake(rand, 3);
    comptime assert(3 == @typeInfo(Op).@"enum".fields.len);

    var buf: [8192]u8 = undefined;
    var events: usize = 0;
    while (args.events_max == null or events < args.events_max.?) : (events += 1) {
        const op = fuzz.randomEnum(rand, Op);
        if (!enabled[@intFromEnum(op)]) continue;
        switch (op) {
            .headers_end => try fuzzHeadersEnd(rand, &buf),
            .request => try fuzzRequest(rand, &buf),
            .method => try fuzzMethod(rand, &buf),
        }
    }
}

/// Obviously-correct scan mirroring the scalar tail: guards the SIMD path.
fn naiveHeadersEnd(h: []const u8, from: usize) ?usize {
    if (h.len < 4 or from + 4 > h.len) return null;
    var p: usize = @max(from + 3, 3);
    while (p < h.len) : (p += 1) {
        if (h[p] == '\n' and h[p - 3] == '\r' and
            h[p - 2] == '\n' and h[p - 1] == '\r') return p - 3;
    }
    return null;
}

fn fuzzHeadersEnd(rand: std.Random, buf: *[8192]u8) !void {
    const input = fuzz.randomSlice(rand, buf);
    const from = rand.intRangeAtMost(usize, 0, 9000);
    if (http.findHeaderEnd(input, from) != naiveHeadersEnd(input, from))
        return error.HeadersEndMismatch;
}

fn putNoise(rand: std.Random, buf: []u8, pos: *usize, max: usize) void {
    const n = @min(fuzz.randomIntExponential(rand, usize, 24), max);
    var i: usize = 0;
    while (i < n and pos.* < buf.len) : (i += 1) {
        const b = [_]u8{rand.int(u8)};
        pos.* = fuzz.appendTrunc(buf, pos.*, &b);
    }
}

fn checkSlice(region: []const u8, s: []const u8) !void {
    if (s.len == 0) return; // default "" borrows nothing
    if (s.len > region.len) return error.SliceEscape;
    const r0 = @intFromPtr(region.ptr);
    const s0 = @intFromPtr(s.ptr);
    if (s0 < r0 or s0 + s.len > r0 + region.len) return error.SliceEscape;
}

fn fuzzRequest(rand: std.Random, buf: *[8192]u8) !void {
    var pos: usize = 0;
    pos = fuzz.appendTrunc(buf, pos, fuzz.pick(rand, []const u8, &verbs));
    pos = fuzz.appendTrunc(buf, pos, " ");
    if (rand.boolean()) {
        pos = fuzz.appendTrunc(buf, pos, fuzz.pick(rand, []const u8, &paths));
    } else {
        putNoise(rand, buf, &pos, 256);
    }
    pos = fuzz.appendTrunc(buf, pos, " ");
    pos = fuzz.appendTrunc(buf, pos, fuzz.pick(rand, []const u8, &protos));
    pos = fuzz.appendTrunc(buf, pos, "\r\n"); // end request line
    const nlines = rand.intRangeAtMost(usize, 0, 6);
    var i: usize = 0;
    while (i < nlines) : (i += 1) {
        if (rand.float(f64) < 0.7) {
            pos = fuzz.appendTrunc(buf, pos, fuzz.pick(rand, []const u8, &hdict));
        } else {
            putNoise(rand, buf, &pos, 128);
        }
        pos = fuzz.appendTrunc(buf, pos, fuzz.pick(rand, []const u8, &line_ends));
    }
    if (rand.boolean()) pos = fuzz.appendTrunc(buf, pos, "\r\n");
    if (rand.float(f64) < 0.3) putNoise(rand, buf, &pos, 64); // trailing bytes

    const input = buf[0..pos];
    const end = http.findHeaderEnd(input, 0) orelse return; // incomplete: nothing to check
    const pr = http.parseRequest(input, end);
    const region = input[0..end];
    try checkSlice(region, pr.method);
    try checkSlice(region, pr.url);
    if (pr.method_tag != http.classifyMethod(pr.method)) return error.MethodTagMismatch;
    if (!std.meta.eql(pr, http.parseRequest(input, end))) return error.NotDeterministic;
}

fn fuzzMethod(rand: std.Random, buf: *[8192]u8) !void {
    const input = fuzz.randomSlice(rand, buf);
    const tag = http.classifyMethod(input);
    var want: http.Method = .none;
    for (known_methods) |kv| {
        if (std.mem.eql(u8, input, kv.name)) {
            want = kv.tag;
            break;
        }
    }
    if (tag != want) return error.ClassifyMismatch;
}
