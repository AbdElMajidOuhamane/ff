const std = @import("std");
const assert = std.debug.assert;
const fuzz = @import("../testing/fuzz.zig");
const sql = @import("sql.zig");

// PostgreSQL DSN & sslmode parser fuzzer: proves zero allocator leaks across success/error paths.

pub const events_smoke: usize = 20_000;
pub const events_default: ?usize = null;

const Op = enum { dsn_structured, dsn_random, sslmode };

const dsn_parts = [_][]const u8{
    "postgres://",
    "postgresql://",
    "user:pass@",
    "onlyuser@",
    "[::1]:5432",
    "[::1",
    "db.local:65535",
    "badhost:99999",
    "/mydb",
    "?sslmode=disable",
    "?sslmode=verify-full&sslrootcert=/ca.pem",
    "?sslmode=require",
    "&",
    "noparam",
    "",
};

const ssl_dict = [_][]const u8{
    "disable", "DISABLE", "verify-full", "verify_full", "VERIFY-FULL", "require", "prefer", "verify-ca", "",
};

pub fn main(gpa: std.mem.Allocator, args: fuzz.FuzzArgs) !void {
    var prng = std.Random.DefaultPrng.init(args.seed);
    const rand = prng.random();
    const enabled = fuzz.swarmTake(rand, 3);
    comptime assert(3 == @typeInfo(Op).@"enum".fields.len);

    var buf: [256]u8 = undefined;
    var events: usize = 0;
    while (args.events_max == null or events < args.events_max.?) : (events += 1) {
        const op = fuzz.randomEnum(rand, Op);
        if (!enabled[@intFromEnum(op)]) continue;

        switch (op) {
            .dsn_structured => {
                var pos: usize = 0;
                const n = rand.intRangeAtMost(usize, 1, 5);
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    pos = fuzz.appendTrunc(&buf, pos, fuzz.pick(rand, []const u8, &dsn_parts));
                }
                var cfg = try sql.initConfigWithAlloc(gpa);
                defer sql.freeConfigWithAlloc(gpa, cfg);
                sql.parseDsnWithAlloc(gpa, buf[0..pos], &cfg) catch {};
            },
            .dsn_random => {
                const s = fuzz.randomSlice(rand, &buf);
                var cfg = try sql.initConfigWithAlloc(gpa);
                defer sql.freeConfigWithAlloc(gpa, cfg);
                sql.parseDsnWithAlloc(gpa, s, &cfg) catch {};
            },
            .sslmode => {
                const s = if (rand.float(f64) < 0.5)
                    fuzz.pick(rand, []const u8, &ssl_dict)
                else
                    fuzz.randomSlice(rand, &buf);
                if (sql.parseSslMode(s)) |m| {
                    assert(m == .disable or m == .verify_full);
                }
            },
        }
    }
}
