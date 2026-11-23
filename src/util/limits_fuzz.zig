const std = @import("std");
const assert = std.debug.assert;
const fuzz = @import("../testing/fuzz.zig");
const limits = @import("limits.zig");
const console = @import("../api/console.zig");

// Runtime limit parsers, stack alignment math, and atomic console log budget fuzzers.

pub const events_smoke: usize = 20_000;
pub const events_default: ?usize = null;

const Op = enum { byte_size, wall_timeout, max_log_bytes, stack_math, log_budget };

const size_dict = [_][]const u8{
    "",
    "0",
    "1",
    "1024",
    "4k",
    "4K",
    "4KB",
    "8mb",
    "16M",
    "64MB",
    "100MB",
    "101MB",
    "1g",
    "4GB",
    "99999999999999999999GB",
    "-1",
    "abc",
    "3600000",
    "3600001",
};

pub fn main(gpa: std.mem.Allocator, args: fuzz.FuzzArgs) !void {
    _ = gpa;
    var prng = std.Random.DefaultPrng.init(args.seed);
    const rand = prng.random();
    const enabled = fuzz.swarmTake(rand, 5);
    comptime assert(5 == @typeInfo(Op).@"enum".fields.len);

    var buf: [64]u8 = undefined;
    var events: usize = 0;
    while (args.events_max == null or events < args.events_max.?) : (events += 1) {
        const op = fuzz.randomEnum(rand, Op);
        if (!enabled[@intFromEnum(op)]) continue;
        switch (op) {
            .byte_size => fuzzByteSize(rand, &buf),
            .wall_timeout => try fuzzWallTimeout(rand, &buf),
            .max_log_bytes => try fuzzMaxLogBytes(rand, &buf),
            .stack_math => try fuzzStackMath(rand),
            .log_budget => try fuzzLogBudget(rand),
        }
    }
}

fn pickInput(rand: std.Random, buf: *[64]u8) []const u8 {
    if (rand.float(f64) < 0.4) {
        return fuzz.randomSlice(rand, buf);
    }
    return fuzz.pick(rand, []const u8, &size_dict);
}

fn fuzzByteSize(rand: std.Random, buf: *[64]u8) void {
    const s = pickInput(rand, buf);
    _ = limits.parseByteSize(s) catch return;
}

fn fuzzWallTimeout(rand: std.Random, buf: *[64]u8) !void {
    const s = pickInput(rand, buf);
    const ms = limits.parseWallTimeout(s) catch return;
    if (ms > limits.WALL_TIMEOUT_MAX_MS) return error.WallTimeoutExceedsCap;
}

fn fuzzMaxLogBytes(rand: std.Random, buf: *[64]u8) !void {
    const s = pickInput(rand, buf);
    const bytes = limits.parseMaxLogBytes(s) catch return;
    if (bytes > limits.MAX_LOG_BYTES_CAP) return error.MaxLogBytesExceedsCap;
}

fn fuzzStackMath(rand: std.Random) !void {
    const native = rand.intRangeAtMost(usize, 512 * 1024, 64 * 1024 * 1024);
    const smax = limits.safeStackMax(native);
    if (smax > native / 2) return error.SafeStackExceedsHalf;

    const js_stack = rand.intRangeAtMost(usize, 128 * 1024, 16 * 1024 * 1024);
    const wstack = limits.workerStackFor(js_stack);
    if (wstack < limits.WORKER_STACK_MIN) return error.WorkerStackBelowMin;
    if (wstack % std.heap.pageSize() != 0) return error.WorkerStackUnaligned;
}

fn fuzzLogBudget(rand: std.Random) !void {
    const lim = if (rand.float(f64) < 0.15)
        @as(usize, 0)
    else
        rand.intRangeAtMost(usize, 1, 8192);
    var written: std.atomic.Value(usize) = .{ .raw = 0 };
    var total_granted: usize = 0;

    const steps = rand.intRangeAtMost(usize, 1, 20);
    for (0..steps) |_| {
        const req = rand.intRangeAtMost(usize, 0, 2048);
        const got = console.takeLogBudget(req, lim, &written);
        if (got > req) return error.GrantedExceedsRequested;
        if (lim == 0) {
            if (got != req) return error.UnlimitedTruncated;
        } else {
            total_granted += got;
            if (written.load(.acquire) > lim) return error.BudgetOverflow;
        }
    }

    if (lim > 0 and written.load(.acquire) != total_granted) {
        return error.BudgetAccountingMismatch;
    }
}
