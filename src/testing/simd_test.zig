const std = @import("std");
const headers = @import("../types/headers.zig");
const http = @import("../net/http_native.zig");
const ws = @import("../net/ws_native.zig");

test "header query operations are case insensitive across vector and scratch boundaries" {
    const width = std.simd.suggestVectorLength(u8) orelse 16;
    const lengths = [_]usize{ 0, 1, width - 1, width, width + 1, 127, 128, 129, 260 };
    for (lengths) |len| {
        var data = headers.HeadersData.init();
        defer data.deinit();
        var name: [260]u8 = undefined;
        var query: [260]u8 = undefined;
        for (0..len) |i| {
            name[i] = if (i % 3 == 0) 'Z' else 'a';
            query[i] = if (i % 3 == 0) 'z' else 'A';
        }
        try data.tryAppendEntry(name[0..len], "First");
        try data.tryAppendEntry(query[0..len], "Second");
        try data.tryAppendEntry("unrelated", "keep");
        try std.testing.expectEqualStrings("First, Second", data.getFirst(query[0..len]).?);
        const values = data.getAllValues(query[0..len]);
        try std.testing.expectEqual(@as(usize, 2), values.len);
        try std.testing.expectEqualStrings("First", values[0]);
        try std.testing.expectEqualStrings("Second", values[1]);
        try std.testing.expect(data.hasEntry(query[0..len], "First"));
        try std.testing.expect(!data.hasEntry(query[0..len], "first"));
        data.deleteEntry(query[0..len], "First");
        try std.testing.expectEqualStrings("Second", data.getFirst(name[0..len]).?);
        try data.tryAppendEntry(name[0..len], "Third");
        data.setEntry(query[0..len], "Replacement");
        try std.testing.expectEqualStrings("Replacement", data.getFirst(name[0..len]).?);
        try std.testing.expectEqual(@as(usize, 2), data.len());
        data.deleteEntry(query[0..len], null);
        try std.testing.expect(!data.hasEntry(name[0..len], null));
        try std.testing.expectEqual(@as(?[]const u8, null), data.getFirst(query[0..len]));
        try std.testing.expectEqualStrings("keep", data.getFirst("UNRELATED").?);
    }
}

test "header query lowering preserves punctuation and non-ASCII bytes" {
    var data = headers.HeadersData.init();
    defer data.deinit();
    // The SIMD comparison must lowercase only A-Z, not blindly set bit 0x20.
    const name = "X-@[\\]^_`AZ\x80\xff";
    try data.tryAppendEntry(name, "value");
    try std.testing.expectEqualStrings("value", data.getFirst("x-@[\\]^_`az\x80\xff").?);
    try std.testing.expect(!data.hasEntry("x-`{\\}~_`az\x80\xff", null));
    try std.testing.expect(!data.hasEntry("X-@[\\]^_`AZ\x80\xfe", null));
}

test "WebSocket unmask preserves guards and mask phase for unaligned slices" {
    const width = std.simd.suggestVectorLength(u8) orelse 16;
    const masks = [_][4]u8{ .{ 0, 0, 0, 0 }, .{ 0xff, 0xff, 0xff, 0xff }, .{ 0x00, 0x80, 0x7f, 0x01 } };
    for (masks) |mask| {
        for (0..4) |offset| {
            for (0..2 * width + 5) |len| {
                var bytes = [_]u8{0xa5} ** (2 * width + 12);
                var expected = bytes;
                for (0..len) |i| {
                    bytes[offset + i] = @truncate(i * 37 + 11);
                    expected[offset + i] = bytes[offset + i] ^ mask[i % 4];
                }
                const original = bytes;
                ws.unmask(bytes[offset..][0..len], mask);
                try std.testing.expectEqualSlices(u8, &expected, &bytes);
                ws.unmask(bytes[offset..][0..len], mask);
                try std.testing.expectEqualSlices(u8, &original, &bytes);
            }
        }
    }
}

test "WebSocket unmask decodes the RFC6455 Hello example" {
    var payload = [_]u8{ 0x7f, 0x9f, 0x4d, 0x51, 0x58 };
    ws.unmask(&payload, .{ 0x37, 0xfa, 0x21, 0x3d });
    try std.testing.expectEqualStrings("Hello", &payload);
}

test "HTTP header terminators are found at every SIMD alignment and from offset" {
    const width = std.simd.suggestVectorLength(u8) orelse 16;
    var bytes: [3 * width + 16]u8 = undefined;
    for (0..2 * width + 5) |at| {
        @memset(&bytes, '\n');
        @memcpy(bytes[at..][0..4], "\r\n\r\n");
        const second = at + width + 5;
        @memcpy(bytes[second..][0..4], "\r\n\r\n");
        const input = bytes[0 .. second + 4];
        try std.testing.expectEqual(@as(?usize, at), http.findHeaderEnd(input, 0));
        try std.testing.expectEqual(@as(?usize, at), http.findHeaderEnd(input, at));
        try std.testing.expectEqual(@as(?usize, second), http.findHeaderEnd(input, at + 1));
        try std.testing.expectEqual(@as(?usize, null), http.findHeaderEnd(input, second + 1));
        for (0..4) |tail| {
            try std.testing.expectEqual(@as(?usize, null), http.findHeaderEnd(bytes[0 .. at + tail], 0));
        }
    }
    try std.testing.expectEqual(@as(?usize, null), http.findHeaderEnd("\r\n\r", 0));
    try std.testing.expectEqual(@as(?usize, null), http.findHeaderEnd("\r\n\r\n", 4));
    try std.testing.expectEqual(@as(?usize, null), http.findHeaderEnd("\n\n\r\n\n\r", 0));
}
