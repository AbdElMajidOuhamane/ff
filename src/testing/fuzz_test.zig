const std = @import("std");
const fuzz = @import("fuzz.zig");

test "fuzz seeds accept decimal limits and upper or lowercase commit hashes" {
    try std.testing.expectEqual(@as(u64, 0), try fuzz.parseSeed("0"));
    try std.testing.expectEqual(@as(u64, 123), try fuzz.parseSeed("123"));
    try std.testing.expectEqual(std.math.maxInt(u64), try fuzz.parseSeed("18446744073709551615"));
    try std.testing.expectEqual(@as(u64, 0x0123456789abcdef), try fuzz.parseSeed("aaaaaaaaaaaaaaaaaaaaaaaa0123456789abcdef"));
    try std.testing.expectEqual(@as(u64, 0x0123456789abcdef), try fuzz.parseSeed("BBBBBBBBBBBBBBBBBBBBBBBB0123456789ABCDEF"));
    try std.testing.expectEqual(std.math.maxInt(u64), try fuzz.parseSeed("ffffffffffffffffffffffffffffffffffffffff"));
    try std.testing.expectEqual(@as(u64, 0), try fuzz.parseSeed("0000000000000000000000000000000000000000"));
}

test "fuzz seeds reject overflow and malformed input" {
    try std.testing.expectError(error.Overflow, fuzz.parseSeed("18446744073709551616"));
    try std.testing.expectError(error.Overflow, fuzz.parseSeed("-1"));
    for ([_][]const u8{ "", "0x7b", "123z", "0123456789abcdef0123456789abcdef012345678", "g123456789abcdef0123456789abcdef0123456789" }) |seed| {
        try std.testing.expectError(error.InvalidCharacter, fuzz.parseSeed(seed));
    }
}

test "fuzz append truncates at capacity and preserves bytes outside the slice" {
    var bytes = [_]u8{0xa5} ** 8;
    const buf = bytes[1..7];
    var len = fuzz.appendTrunc(buf, 0, "ab");
    try std.testing.expectEqual(@as(usize, 2), len);
    len = fuzz.appendTrunc(buf, len, "cdefgh");
    try std.testing.expectEqual(buf.len, len);
    try std.testing.expectEqualStrings("abcdef", buf);
    try std.testing.expectEqual(len, fuzz.appendTrunc(buf, len, "ignored"));
    try std.testing.expectEqual(len, fuzz.appendTrunc(buf, len, ""));
    try std.testing.expectEqual(@as(usize, 0), fuzz.appendTrunc(buf[0..0], 0, "x"));
    try std.testing.expectEqual(@as(u8, 0xa5), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0xa5), bytes[7]);
}

test "fuzz random helpers replay deterministically within their bounds" {
    const Operation = enum { read, write, close };
    const dict = [_][]const u8{ "", "HTTP/1.1", "\x00\xff" };
    for ([_]u64{ 0, 123, std.math.maxInt(u64) }) |seed| {
        var first = std.Random.DefaultPrng.init(seed);
        var second = std.Random.DefaultPrng.init(seed);
        const a = first.random();
        const b = second.random();
        for (0..64) |_| {
            try std.testing.expectEqual(fuzz.randomIntExponential(a, u8, 255), fuzz.randomIntExponential(b, u8, 255));
            try std.testing.expectEqual(fuzz.randomIntExponential(a, u64, std.math.maxInt(u64)), fuzz.randomIntExponential(b, u64, std.math.maxInt(u64)));
            try std.testing.expectEqual(fuzz.randomEnum(a, Operation), fuzz.randomEnum(b, Operation));
            try std.testing.expectEqualStrings(fuzz.pick(a, []const u8, &dict), fuzz.pick(b, []const u8, &dict));
            const swarm = fuzz.swarmTake(a, 5);
            try std.testing.expectEqualSlices(bool, &swarm, &fuzz.swarmTake(b, 5));
            var enabled: usize = 0;
            for (swarm) |taken| enabled += @intFromBool(taken);
            try std.testing.expect(enabled >= 1 and enabled <= swarm.len);
            var left: [16]u8 = undefined;
            var right: [16]u8 = undefined;
            const prefix = fuzz.randomSlice(a, &left);
            try std.testing.expect(prefix.len <= left.len);
            try std.testing.expect(prefix.ptr == &left);
            try std.testing.expectEqualSlices(u8, prefix, fuzz.randomSlice(b, &right));
            try std.testing.expectEqualSlices(u8, &left, &right);
        }
        try std.testing.expect((fuzz.swarmTake(a, 1))[0]);
        var empty: [0]u8 = .{};
        try std.testing.expectEqual(@as(usize, 0), fuzz.randomSlice(a, &empty).len);
    }
}
