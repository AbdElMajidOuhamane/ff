const std = @import("std");
const assert = std.debug.assert;
const fuzz = @import("../testing/fuzz.zig");
const semver = @import("semver.zig");

// Registry semver: parse roundtrip, range oracles, maxSatisfying soundness.

pub const events_smoke: usize = 20_000;
pub const events_default: ?usize = null;

const Op = enum { version, satisfies, max_satisfying };

const dict = [_][]const u8{
    "0",      "1",    "10", "007", "4294967295", "4294967296", "99999999999999999999",
    "v",      "=",    ".",  "-",   "+",          " ",          "alpha",
    "beta.1", "rc-1", "x",  "X",   "*",          "^",          "~",
    ">",      "<",    ">=", "<=",  "latest",     "||",         " - ",
    "1.2",    "1",    "",
};

pub fn main(gpa: std.mem.Allocator, args: fuzz.FuzzArgs) !void {
    _ = gpa;
    var prng = std.Random.DefaultPrng.init(args.seed);
    const rand = prng.random();
    const enabled = fuzz.swarmTake(rand, 3);
    comptime assert(3 == @typeInfo(Op).@"enum".fields.len);

    var buf: [512]u8 = undefined;
    var events: usize = 0;
    while (args.events_max == null or events < args.events_max.?) : (events += 1) {
        const op = fuzz.randomEnum(rand, Op);
        if (!enabled[@intFromEnum(op)]) continue;
        switch (op) {
            .version => try fuzzVersion(rand, &buf),
            .satisfies => try fuzzSatisfies(rand, &buf),
            .max_satisfying => try fuzzMaxSatisfying(rand, &buf),
        }
    }
}

/// Dictionary tokens, or (30%) raw noise, concatenated into `buf[pos..]`.
fn composeInto(rand: std.Random, buf: []u8, pos: usize, min_tok: usize, max_tok: usize) usize {
    if (rand.float(f64) < 0.3) {
        const tail = fuzz.randomSlice(rand, buf[pos..]);
        return pos + tail.len;
    }
    var p = pos;
    const n = rand.intRangeAtMost(usize, min_tok, max_tok);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        p = fuzz.appendTrunc(buf, p, fuzz.pick(rand, []const u8, &dict));
    }
    return p;
}

fn fuzzVersion(rand: std.Random, buf: *[512]u8) !void {
    const end = composeInto(rand, buf, 0, 1, 5);
    const s = buf[0..end];
    const v = semver.parseVersion(s) catch return; // errors fine, panics not
    if (semver.compare(v, v) != .eq) return error.CompareReflexive;
    var tmp: [512]u8 = undefined;
    const full = if (v.pre.len == 0)
        try std.fmt.bufPrint(&tmp, "{d}.{d}.{d}", .{ v.major, v.minor, v.patch })
    else
        try std.fmt.bufPrint(&tmp, "{d}.{d}.{d}-{s}", .{ v.major, v.minor, v.patch, v.pre });
    const v2 = try semver.parseVersion(full);
    if (semver.compare(v, v2) != .eq) return error.Roundtrip;
}

fn fuzzSatisfies(rand: std.Random, buf: *[512]u8) !void {
    const ve = composeInto(rand, buf, 0, 1, 4);
    const v = semver.parseVersion(buf[0..ve]) catch return;
    const re = composeInto(rand, buf, ve, 1, 3);
    const rs = buf[ve..re];
    _ = semver.satisfies(v, rs) catch |err| {
        if (err == error.UnsupportedRange) return; // documented loud failure
        return; // BadVersion/BadRange inside the range text: valid outcome
    };
    // Oracles over rules fixed by the spec comment at the top of semver.zig.
    if ((try semver.satisfies(v, "*")) != (v.pre.len == 0)) return error.StarRule;
    if (v.pre.len == 0 and !(try semver.satisfies(v, ">=0.0.0"))) return error.GteZero;
}

fn fuzzMaxSatisfying(rand: std.Random, buf: *[512]u8) !void {
    var pos: usize = 0;
    const k = rand.intRangeAtMost(usize, 0, 5);
    var list: [5][]const u8 = undefined;
    var i: usize = 0;
    while (i < k) : (i += 1) {
        const start = pos;
        pos = composeInto(rand, buf, pos, 1, 4);
        list[i] = buf[start..pos];
    }
    const rs_start = pos;
    pos = composeInto(rand, buf, pos, 1, 3);
    const rs = buf[rs_start..pos];
    const best = semver.maxSatisfying(list[0..k], rs) catch |err| {
        if (err == error.UnsupportedRange) return;
        return err; // only UnsupportedRange is documented; anything else is a bug
    };
    if (best) |b| {
        const bv = try semver.parseVersion(b);
        if (!(try semver.satisfies(bv, rs))) return error.BestUnsatisfying;
    }
}
