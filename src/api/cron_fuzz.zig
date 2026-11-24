const std = @import("std");
const assert = std.debug.assert;
const fuzz = @import("../testing/fuzz.zig");
const cron = @import("cron.zig");

// Cron expression parser + next-fire calculator fuzzer.

pub const events_smoke: usize = 10_000;
pub const events_default: ?usize = null;

const Op = enum { parse_schedule_dict, parse_schedule_random, parse_single_field, next_fire_delay };

const schedule_dict = [_][]const u8{
    "* * * * *",
    "*/15 0-23/2 1,15,28 * 1-5",
    "0 0 31 2 *",
    "59 23 * * 7",
    "@every 100ms",
    "@every 5s",
    "@every 3m",
    "@every 99999999999999999999s",
    "@every bad",
    "  0   12   *  1-12/3  0,7 ",
    "* * *",
    "* * * * * *",
    "60 * * * *",
    "",
};

const field_dict = [_][]const u8{
    "*",    "*/5", "0-59/10", "1,3,5,7", "5-2",
    "0",    "59",  "60",      "*/0",     "1,,2",
    "1-32", "*/x", "7",       "",
};

pub fn main(gpa: std.mem.Allocator, args: fuzz.FuzzArgs) !void {
    _ = gpa;
    var prng = std.Random.DefaultPrng.init(args.seed);
    const rand = prng.random();
    const enabled = fuzz.swarmTake(rand, 4);
    comptime assert(4 == @typeInfo(Op).@"enum".fields.len);

    var buf: [128]u8 = undefined;
    var events: usize = 0;
    while (args.events_max == null or events < args.events_max.?) : (events += 1) {
        const op = fuzz.randomEnum(rand, Op);
        if (!enabled[@intFromEnum(op)]) continue;
        switch (op) {
            .parse_schedule_dict => fuzzSchedule(fuzz.pick(rand, []const u8, &schedule_dict)),
            .parse_schedule_random => fuzzSchedule(fuzz.randomSlice(rand, &buf)),
            .parse_single_field => fuzzSingleField(rand, &buf),
            .next_fire_delay => try fuzzNextFireDelay(rand, &buf),
        }
    }
}

fn fuzzSchedule(s: []const u8) void {
    const sched = cron.parseSchedule(s) orelse return;
    switch (sched) {
        .interval_ms => {},
        .fields => |f| {
            // Parsed field masks must be non-zero for valid cron fields.
            assert(f.min != 0);
            assert(f.hour != 0);
            assert(f.dom != 0);
            assert(f.mon != 0);
            assert(f.dow != 0);
        },
    }
}

fn fuzzSingleField(rand: std.Random, buf: *[128]u8) void {
    const bounds = [_][2]u8{
        .{ 0, 59 },
        .{ 0, 23 },
        .{ 1, 31 },
        .{ 1, 12 },
        .{ 0, 7 },
    };
    const b = fuzz.pick(rand, [2]u8, &bounds);
    const s = if (rand.float(f64) < 0.5)
        fuzz.pick(rand, []const u8, &field_dict)
    else
        fuzz.randomSlice(rand, buf);
    const mask = cron.parseSingleField(s, b[0], b[1]) orelse return;
    for (0..64) |bit| {
        if (bit < b[0] or bit > b[1]) {
            assert((mask & (@as(u64, 1) << @intCast(bit))) == 0);
        }
    }
}

fn fuzzNextFireDelay(rand: std.Random, buf: *[128]u8) !void {
    const s = if (rand.float(f64) < 0.85)
        fuzz.pick(rand, []const u8, &schedule_dict)
    else
        fuzz.randomSlice(rand, buf);
    const sched = cron.parseSchedule(s) orelse return;
    const f = switch (sched) {
        .interval_ms => return,
        .fields => |fld| fld,
    };
    const timestamps = [_]i64{
        -100,
        0,
        1_704_067_230,
        1_709_164_790, // leap-year Feb 28 -> Feb 29 boundary
        1_899_999_999_900,
        2_000_000_000_001,
        std.math.minInt(i64),
        std.math.maxInt(i64),
    };
    const ts = if (rand.float(f64) < 0.5)
        fuzz.pick(rand, i64, &timestamps)
    else
        rand.intRangeAtMost(i64, 1_500_000_000, 1_900_000_000);

    const delay = cron.computeNextFireDelay(f, ts) orelse return;
    if (delay < 1000 or delay > 366 * 86400 * 1000) return error.DelayOutOfBounds;
}
