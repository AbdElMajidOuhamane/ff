const std = @import("std");
const fuzz = @import("testing/fuzz.zig");

// ── Deterministic parser fuzzers (TigerBeetle-style) ──
// Each target exposes `main(gpa, FuzzArgs)` plus `events_smoke` (fast CI
// cap) and `events_default` (null = unbounded, for long runs).
// Usage: zig build fuzz -- <target|smoke> [seed] [--events-max=N]
// Always run in ReleaseSafe so OOB/overflow checks fire.

const Fuzzers = .{
    .ws_frame = @import("net/ws_native_fuzz.zig"),
    .http_request = @import("net/http_native_fuzz.zig"),
    .http2_stream = @import("net/http2_server_fuzz.zig"),
    .semver = @import("commands/semver_fuzz.zig"),
    .tls_pem = @import("net/tls_server_fuzz.zig"),
    .utf8 = @import("api/text_encoding_fuzz.zig"),
    // A fuzzer that intentionally fails, to test fuzzing infrastructure itself.
    .canary = {},
    // Quickly run all fuzzers as a smoke test.
    .smoke = {},
};

const FuzzersEnum = std.meta.FieldEnum(@TypeOf(Fuzzers));

pub fn main(init: std.process.Init) !void {
    fuzz.limitRam();

    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer {
        if (gpa_state.deinit() == .leak) {
            std.debug.print("fuzz: allocator leak detected\n", .{});
            std.process.exit(1);
        }
    }
    const gpa = gpa_state.allocator();

    var it = init.minimal.args.iterate();
    _ = it.next(); // exe path
    const name = it.next() orelse return usage();
    if (std.mem.eql(u8, name, "smoke")) return mainSmoke(gpa);

    const target = std.meta.stringToEnum(FuzzersEnum, name) orelse return usage();
    if (target == .smoke) return mainSmoke(gpa);

    var seed: ?u64 = null;
    var events_max: ?usize = null;
    while (it.next()) |a| {
        if (std.mem.startsWith(u8, a, "--events-max=")) {
            events_max = std.fmt.parseInt(usize, a["--events-max=".len..], 10) catch
                return usage();
        } else if (seed == null) {
            seed = fuzz.parseSeed(a) catch return usage();
        } else return usage();
    }
    // Default seed keeps local runs deterministic; nightly CI passes the
    // commit SHA for a different-but-reproducible stream per commit.
    try mainSingle(gpa, target, seed orelse 123, events_max);
}

fn mainSmoke(gpa: std.mem.Allocator) !void {
    // `.*` + `comptime`: iterating the array (not the pointer) yields
    // comptime-known values, and the `switch` keeps the void
    // `.smoke`/`.canary` fields out of `@field` analysis.
    inline for (comptime std.meta.tags(FuzzersEnum).*) |f| {
        switch (f) {
            .smoke, .canary => continue,
            inline else => |t| try mainSingle(gpa, t, 123, @field(Fuzzers, @tagName(t)).events_smoke),
        }
    }
    std.debug.print("fuzz smoke ok\n", .{});
}

fn mainSingle(gpa: std.mem.Allocator, target: FuzzersEnum, seed: u64, events_max: ?usize) !void {
    std.debug.print("fuzz target={s} seed={d} events_max={?d}\n", .{ @tagName(target), seed, events_max });
    switch (target) {
        .smoke => unreachable,
        .canary => return error.CanaryFailed,
        inline else => |f| try @field(Fuzzers, @tagName(f)).main(gpa, .{
            .seed = seed,
            .events_max = events_max orelse @field(Fuzzers, @tagName(f)).events_default,
        }),
    }
    std.debug.print("fuzz done target={s} seed={d}\n", .{ @tagName(target), seed });
}

fn usage() void {
    std.debug.print("usage: fuzz <target|smoke> [seed] [--events-max=N]\n", .{});
    std.debug.print("targets:", .{});
    inline for (comptime std.meta.tags(FuzzersEnum).*) |f| {
        std.debug.print(" {s}", .{@tagName(f)});
    }
    std.debug.print("\n", .{});
}
