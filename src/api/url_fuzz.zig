const std = @import("std");
const assert = std.debug.assert;
const fuzz = @import("../testing/fuzz.zig");
const url_mod = @import("url.zig");

// URL parser, relative resolver, dot-segment normalizer, and URLSearchParams fuzzer.

pub const events_smoke: usize = 15_000;
pub const events_default: ?usize = null;

const Op = enum { parse_absolute, parse_relative, search_params, dot_segments };

const url_dict = [_][]const u8{
    "https://example.com:443/a/b/../c?x=1&y=2#frag",
    "http://user:pass@localhost:8080/p?q=1",
    "ws://host.test/socket",
    "wss://host.test:8443/",
    "ftp://files.example/pub",
    "file:///tmp/test.txt",
    "custom://opaque/path",
    "not a url",
    "://missing-scheme",
    "",
};

const rel_dict = [_][]const u8{
    "",
    "?only=query",
    "#only-hash",
    "/root/../leaf?a=1#h",
    "//other.org:9090/path",
    "sub/../../item?x=y#z",
    "https://override.test/x",
    "../..",
    ".",
};

const path_dict = [_][]const u8{
    "",
    "/",
    "/a/b/c",
    "/a/b/..",
    "/a/b/../..",
    "/./a/./b/../c",
    "../foo",
    "./bar",
    "/../baz",
    "..",
    ".",
};

pub fn main(gpa: std.mem.Allocator, args: fuzz.FuzzArgs) !void {
    _ = gpa;
    var prng = std.Random.DefaultPrng.init(args.seed);
    const rand = prng.random();
    const enabled = fuzz.swarmTake(rand, 4);
    comptime assert(4 == @typeInfo(Op).@"enum".fields.len);

    var buf: [512]u8 = undefined;
    var events: usize = 0;
    while (args.events_max == null or events < args.events_max.?) : (events += 1) {
        const op = fuzz.randomEnum(rand, Op);
        if (!enabled[@intFromEnum(op)]) continue;
        switch (op) {
            .parse_absolute => fuzzAbsolute(rand, &buf),
            .parse_relative => fuzzRelative(rand, &buf),
            .search_params => fuzzSearchParams(rand, &buf),
            .dot_segments => try fuzzDotSegments(rand, &buf),
        }
    }
}

fn fuzzAbsolute(rand: std.Random, buf: *[512]u8) void {
    const s = if (rand.float(f64) < 0.5)
        fuzz.pick(rand, []const u8, &url_dict)
    else
        fuzz.randomSlice(rand, buf);
    const block = url_mod.parseUrlAbsolute(s) catch return;
    defer block.release();
    assert(block.url.scheme.len > 0);
    assert(block.url.href.len > 0);
    assert(std.mem.startsWith(u8, block.url.href, block.url.scheme));
    _ = url_mod.defaultPortForScheme(block.url.scheme);
    _ = url_mod.isSpecialScheme(block.url.scheme);
}

fn fuzzRelative(rand: std.Random, buf: *[512]u8) void {
    const input = if (rand.float(f64) < 0.5)
        fuzz.pick(rand, []const u8, &rel_dict)
    else
        fuzz.randomSlice(rand, buf[0..256]);
    const base = if (rand.float(f64) < 0.7)
        fuzz.pick(rand, []const u8, &url_dict)
    else
        fuzz.randomSlice(rand, buf[256..512]);
    const block = url_mod.parseUrlRelative(input, base) catch return;
    defer block.release();
    assert(block.url.scheme.len > 0);
    assert(block.url.href.len > 0);
}

fn fuzzSearchParams(rand: std.Random, buf: *[512]u8) void {
    var sp = url_mod.URLSearchParamsData.init();
    defer sp.deinit();
    const raw = fuzz.randomSlice(rand, buf[0..128]);
    sp.parseFromString(raw);
    sp.appendPair("alpha", "1");
    sp.setEntry("beta", "2");
    assert(sp.hasEntry("beta", "2"));
    assert(std.mem.eql(u8, sp.getFirst("beta").?, "2"));
    _ = sp.getAllValues("alpha");
    sp.deleteEntry("alpha", null);
    assert(!sp.hasEntry("alpha", null));
    sp.sortPairs();
    assert(sp.serialize().len > 0 or sp.entries.items.len == 0);
}

fn fuzzDotSegments(rand: std.Random, buf: *[512]u8) !void {
    const input = if (rand.float(f64) < 0.5)
        fuzz.pick(rand, []const u8, &path_dict)
    else
        fuzz.randomSlice(rand, buf[0..256]);
    var out: [513]u8 = undefined;
    const n = try url_mod.removeDotSegmentsInto(&out, input);
    if (n < 1 or n > input.len + 1) return error.DotSegmentBounds;
}
