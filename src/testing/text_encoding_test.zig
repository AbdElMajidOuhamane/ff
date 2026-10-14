const std = @import("std");
const text = @import("../api/text_encoding.zig");

test "lossy UTF-8 decoding preserves valid scalar boundaries and embedded NUL" {
    const inputs = [_][]const u8{
        "", "a\x00z\x7f", "\xc2\x80\xdf\xbf", "\xe0\xa0\x80\xed\x9f\xbf\xee\x80\x80", "\xf0\x90\x80\x80\xf4\x8f\xbf\xbf",
    };
    for (inputs) |input| {
        var out = [_]u8{0xa5} ** 64;
        const n = text.decodeUtf8Lossy(input, out[0 .. input.len * 3]);
        try std.testing.expectEqualStrings(input, out[0..n]);
        try std.testing.expectEqual(@as(u8, 0xa5), out[input.len * 3]);
    }
}

test "lossy UTF-8 decoding replaces invalid bytes without losing adjacent text" {
    const replacement = "\xef\xbf\xbd";
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "a\x80z", .expected = "a" ++ replacement ++ "z" },
        .{ .input = "\xc2", .expected = replacement },
        .{ .input = "\xe2\x82", .expected = replacement ++ replacement },
        .{ .input = "\xf0\x9f\x98", .expected = replacement ++ replacement ++ replacement },
        .{ .input = "\xc0\xaf", .expected = replacement ++ replacement },
        .{ .input = "\xe0\x80\x80", .expected = replacement ++ replacement ++ replacement },
        .{ .input = "\xed\xa0\x80", .expected = replacement ++ replacement ++ replacement },
        .{ .input = "\xf4\x90\x80\x80", .expected = replacement ++ replacement ++ replacement ++ replacement },
        .{ .input = "\xff\xfe", .expected = replacement ++ replacement },
        .{ .input = "\xe2(\xa1\xc3\xa9", .expected = replacement ++ "(" ++ replacement ++ "\xc3\xa9" },
    };
    for (cases) |case| {
        var out = [_]u8{0xa5} ** 64;
        const n = text.decodeUtf8Lossy(case.input, out[0 .. case.input.len * 3]);
        try std.testing.expectEqualStrings(case.expected, out[0..n]);
        try std.testing.expect(std.unicode.utf8ValidateSlice(out[0..n]));
        try std.testing.expectEqual(@as(u8, 0xa5), out[case.input.len * 3]);
        var again: [192]u8 = undefined;
        const n2 = text.decodeUtf8Lossy(out[0..n], &again);
        try std.testing.expectEqualSlices(u8, out[0..n], again[0..n2]);
    }
}

test "lossy UTF-8 worst-case expansion fits the exact output capacity" {
    const input = [_]u8{0xff} ** 16;
    var out: [input.len * 3]u8 = undefined;
    try std.testing.expectEqual(out.len, text.decodeUtf8Lossy(&input, &out));
    try std.testing.expectEqualStrings("\xef\xbf\xbd" ** input.len, &out);
}
