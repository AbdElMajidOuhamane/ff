const std = @import("std");
const assert = std.debug.assert;
const fuzz = @import("../testing/fuzz.zig");
const env_file = @import("env_file.zig");

// `.env` file parser fuzzer: verifies zero leaks and trimmed-key invariants.

pub const events_smoke: usize = 20_000;
pub const events_default: ?usize = null;

const Op = enum { parse_random, parse_structured };

const line_tokens = [_][]const u8{
    "# comment\n",
    "FOO=bar\n",
    "  KEY  =  \"quoted val\"  \r\n",
    "SINGLE='val=1'\r\n",
    "EMPTY_VAL=\n",
    "=nokey\n",
    "NOEQUALS\n",
    "MISMATCH=\"abc'\n",
    "   \t\r\n",
    "Q=\"\"\n",
};

pub fn main(gpa: std.mem.Allocator, args: fuzz.FuzzArgs) !void {
    var prng = std.Random.DefaultPrng.init(args.seed);
    const rand = prng.random();
    const enabled = fuzz.swarmTake(rand, 2);
    comptime assert(2 == @typeInfo(Op).@"enum".fields.len);

    var buf: [512]u8 = undefined;
    var out: std.ArrayList(env_file.Entry) = .empty;
    defer out.deinit(gpa);

    var events: usize = 0;
    while (args.events_max == null or events < args.events_max.?) : (events += 1) {
        const op = fuzz.randomEnum(rand, Op);
        if (!enabled[@intFromEnum(op)]) continue;

        const input: []const u8 = switch (op) {
            .parse_random => fuzz.randomSlice(rand, &buf),
            .parse_structured => blk: {
                var pos: usize = 0;
                const n_lines = rand.intRangeAtMost(usize, 1, 8);
                var i: usize = 0;
                while (i < n_lines) : (i += 1) {
                    if (rand.float(f64) < 0.2) {
                        var tmp: [48]u8 = undefined;
                        pos = fuzz.appendTrunc(&buf, pos, fuzz.randomSlice(rand, &tmp));
                        pos = fuzz.appendTrunc(&buf, pos, "\n");
                    } else {
                        pos = fuzz.appendTrunc(&buf, pos, fuzz.pick(rand, []const u8, &line_tokens));
                    }
                }
                break :blk buf[0..pos];
            },
        };

        out.clearRetainingCapacity();
        try env_file.parseContent(gpa, input, &out);
        for (out.items) |e| {
            assert(e.key.len > 0);
            assert(e.key[0] != ' ' and e.key[0] != '\t' and e.key[0] != '\r');
            assert(e.key[e.key.len - 1] != ' ' and e.key[e.key.len - 1] != '\t');
            assert(std.mem.indexOfScalar(u8, e.key, '\n') == null);
            assert(std.mem.indexOfScalar(u8, e.val, '\n') == null);
        }
    }
}
