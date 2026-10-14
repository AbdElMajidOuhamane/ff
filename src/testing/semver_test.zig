const std = @import("std");
const semver = @import("../commands/semver.zig");

test "max-major wildcards include only that major and exclude prereleases" {
    const ranges = [_][]const u8{ "4294967295", "4294967295.x", "4294967295.X", "4294967295.*", "v4294967295" };
    for (ranges) |range| {
        try std.testing.expect(try semver.satisfies(try semver.parseVersion("4294967295.0.0"), range));
        try std.testing.expect(try semver.satisfies(try semver.parseVersion("4294967295.4294967295.4294967295"), range));
        try std.testing.expect(!try semver.satisfies(try semver.parseVersion("4294967294.4294967295.4294967295"), range));
        try std.testing.expect(!try semver.satisfies(try semver.parseVersion("4294967295.1.0-beta"), range));
    }
    try std.testing.expect(try semver.satisfies(try semver.parseVersion("4294967295.1.9"), "4294967295 >=4294967295.1.0 <4294967295.2.0"));
    try std.testing.expect(!try semver.satisfies(try semver.parseVersion("4294967295.2.0"), "4294967295 <4294967295.2.0"));
}

test "overflowing wildcard caret and tilde bounds return UnsupportedRange" {
    const cases = [_]struct { version: []const u8, range: []const u8 }{
        .{ .version = "1.4294967295.0", .range = "1.4294967295" },
        .{ .version = "1.4294967295.0", .range = "1.4294967295.x" },
        .{ .version = "1.4294967295.0", .range = "1.4294967295.*" },
        .{ .version = "4294967295.4294967295.0", .range = "4294967295.4294967295.X" },
        .{ .version = "4294967295.0.0", .range = "^4294967295.0.0" },
        .{ .version = "0.4294967295.0", .range = "^0.4294967295.0" },
        .{ .version = "0.0.4294967295", .range = "^0.0.4294967295" },
        .{ .version = "1.4294967295.0", .range = "~1.4294967295.0" },
        .{ .version = "0.4294967295.0", .range = "~0.4294967295.0" },
    };
    for (cases) |case| {
        try std.testing.expectError(error.UnsupportedRange, semver.satisfies(try semver.parseVersion(case.version), case.range));
    }
}

test "representable bounds just below u32 max remain exclusive" {
    const cases = [_]struct { range: []const u8, lower: []const u8, inside: []const u8, upper: []const u8 }{
        .{ .range = "4294967294.x", .lower = "4294967294.0.0", .inside = "4294967294.4294967295.4294967295", .upper = "4294967295.0.0" },
        .{ .range = "1.4294967294.x", .lower = "1.4294967294.0", .inside = "1.4294967294.4294967295", .upper = "1.4294967295.0" },
        .{ .range = "^4294967294.0.0", .lower = "4294967294.0.0", .inside = "4294967294.1.0", .upper = "4294967295.0.0" },
        .{ .range = "^0.4294967294.0", .lower = "0.4294967294.0", .inside = "0.4294967294.4294967295", .upper = "0.4294967295.0" },
        .{ .range = "^0.0.4294967294", .lower = "0.0.4294967294", .inside = "0.0.4294967294", .upper = "0.0.4294967295" },
        .{ .range = "~1.4294967294.0", .lower = "1.4294967294.0", .inside = "1.4294967294.4294967295", .upper = "1.4294967295.0" },
    };
    for (cases) |case| {
        try std.testing.expect(try semver.satisfies(try semver.parseVersion(case.lower), case.range));
        try std.testing.expect(try semver.satisfies(try semver.parseVersion(case.inside), case.range));
        try std.testing.expect(!try semver.satisfies(try semver.parseVersion(case.upper), case.range));
        try std.testing.expect(!try semver.satisfies(try semver.parseVersion("0.0.0"), case.range));
    }
}

test "max components stay valid when they are not incremented" {
    const cases = [_]struct { version: []const u8, range: []const u8 }{
        .{ .version = "4294967295.2.4294967295", .range = "~4294967295.2.0" },
        .{ .version = "1.4294967295.4294967295", .range = "^1.0.0" },
        .{ .version = "0.1.4294967295", .range = "^0.1.0" },
        .{ .version = "4294967295.4294967295.4294967295", .range = "=4294967295.4294967295.4294967295" },
    };
    for (cases) |case| {
        try std.testing.expect(try semver.satisfies(try semver.parseVersion(case.version), case.range));
    }
}

test "maxSatisfying selects max-major candidates and propagates overflow errors" {
    const versions = [_][]const u8{ "4294967295.0.0", "invalid", "4294967295.2.0-beta", "4294967294.9.9", "4294967295.1.9", "4294967295.1.0" };
    try std.testing.expectEqualStrings("4294967295.1.9", (try semver.maxSatisfying(&versions, "4294967295.x")).?);
    try std.testing.expectError(error.UnsupportedRange, semver.maxSatisfying(&versions, "^4294967295.0.0"));
    try std.testing.expectEqual(@as(?[]const u8, null), try semver.maxSatisfying(&.{"4294967294.9.9"}, "4294967295.*"));
    try std.testing.expectError(error.UnsupportedRange, semver.maxSatisfying(&.{"0.0.4294967295"}, "^0.0.4294967295"));
}
