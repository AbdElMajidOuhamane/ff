const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

// ── Deterministic fuzzing helpers (TigerBeetle-style) ──
// Fuzzers are seed-driven: the same seed always replays the same input
// stream, so a failure is reproducible from the printed seed alone.
// No coverage feedback, no corpus — PRNG streams + oracles/assertions.

pub const FuzzArgs = struct {
    seed: u64,
    events_max: ?usize,
};

/// Exponentially-distributed integer with mean ~`avg` (`avg` must be ≥ 1):
/// small values dominate, long tail reaches structural limits. Feed it
/// lengths, counts and offsets.
pub fn randomIntExponential(rand: std.Random, comptime T: type, avg: T) T {
    comptime {
        const info = @typeInfo(T);
        assert(info == .int and info.int.signedness == .unsigned);
    }
    std.debug.assert(avg >= 1);
    const u: f64 = 1.0 - rand.float(f64); // (0, 1]
    const sample = -@log(u) * @as(f64, @floatFromInt(avg));
    // @floatFromInt(maxInt) can round up to an out-of-range float (notably
    // maxInt(u64) -> 2^64), so clamp against the integer itself.
    const cap_int = std.math.maxInt(T);
    const cap: f64 = @floatFromInt(cap_int);
    const v = @min(sample, cap);
    if (v >= cap) return cap_int;
    return @intFromFloat(v);
}

/// Uniform random enum variant.
pub fn randomEnum(rand: std.Random, comptime E: type) E {
    const n = @typeInfo(E).@"enum".fields.len;
    return std.enums.fromInt(E, rand.intRangeLessThan(usize, 0, n)) orelse unreachable;
}

/// Swarm testing (TigerBeetle): each run enables a random subset of
/// operations, so rare interactions surface across seeds.
pub fn swarmTake(rand: std.Random, comptime n: usize) [n]bool {
    const k = rand.intRangeAtMost(usize, 1, n);
    var enabled = [_]bool{false} ** n;
    var taken: usize = 0;
    while (taken < k) {
        const i = rand.intRangeLessThan(usize, 0, n);
        if (!enabled[i]) {
            enabled[i] = true;
            taken += 1;
        }
    }
    return enabled;
}

/// Fill `buf` with random bytes, return a random-length prefix. Lengths
/// skew small but the tail reaches `buf.len`.
pub fn randomSlice(rand: std.Random, buf: []u8) []u8 {
    rand.bytes(buf);
    const avg = buf.len / 4 + 1;
    return buf[0..@min(randomIntExponential(rand, usize, avg), buf.len)];
}

/// Pick a dictionary entry. Dictionaries mix realistic tokens with edge
/// cases; unstructured noise comes from `randomSlice`.
pub fn pick(rand: std.Random, comptime T: type, dict: []const T) T {
    return dict[rand.intRangeLessThan(usize, 0, dict.len)];
}

/// Append, saturating at capacity. Returns the new length.
pub fn appendTrunc(buf: []u8, len: usize, s: []const u8) usize {
    assert(len <= buf.len);
    const n = @min(s.len, buf.len - len);
    @memcpy(buf[len..][0..n], s[0..n]);
    return len + n;
}

/// Parse a seed: decimal u64, or a 40-char hex commit hash (CI passes the
/// commit SHA so every commit fuzzes a different-but-reproducible stream).
pub fn parseSeed(s: []const u8) !u64 {
    if (s.len == 40) {
        var hex = true;
        for (s) |ch| {
            hex = hex and ((ch >= '0' and ch <= '9') or
                (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F'));
        }
        if (hex) return std.fmt.parseInt(u64, s[24..], 16);
    }
    return std.fmt.parseInt(u64, s, 10);
}

/// Cap address space so a fuzzer feeding unbounded growth fails fast
/// instead of OOMing the machine. Linux-only (the `.AS` reference sits in
/// a comptime-dead branch on other targets, so this compiles everywhere).
pub fn limitRam() void {
    if (comptime builtin.os.tag != .linux) return;
    const gib: usize = 1024 * 1024 * 1024;
    std.posix.setrlimit(std.posix.rlimit_resource.AS, .{ .cur = 20 * gib, .max = 20 * gib }) catch {};
}
