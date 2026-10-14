const std = @import("std");
const request = @import("../types/request.zig");
const response = @import("../types/response.zig");

fn expectBodySentinel(body: ?[]const u8, expected: []const u8) !void {
    const bytes = body orelse return error.MissingBody;
    try std.testing.expectEqualStrings(expected, bytes);
    try std.testing.expectEqual(@as(u8, 0), bytes.ptr[bytes.len]);
}

test "request body sentinel survives pool growth and clone ownership" {
    var src = request.RequestData.init();
    var live = true;
    defer if (live) src.deinit();
    src.setUrl("http://example.invalid/");
    src.setBody("{\"value\":42}");
    const old_capacity = src.pool.capacity;
    const metadata = try std.testing.allocator.alloc(u8, old_capacity + 4096);
    defer std.testing.allocator.free(metadata);
    @memset(metadata, 'X');
    src.setIntegrity(metadata);
    src.setMethod("CUSTOM");
    try std.testing.expect(src.pool.capacity > old_capacity);
    try expectBodySentinel(src.body(), "{\"value\":42}");
    try std.testing.expectEqualStrings(metadata, src.integrity());
    src.body_used = true;
    var clone = request.RequestData.init();
    defer clone.deinit();
    clone.cloneFrom(&src);
    try std.testing.expect(!clone.body_used);
    try std.testing.expect(clone.body().?.ptr != src.body().?.ptr);
    src.deinit();
    live = false;
    try expectBodySentinel(clone.body(), "{\"value\":42}");
    try std.testing.expectEqualStrings("CUSTOM", clone.method());
    try std.testing.expectEqualStrings(metadata, clone.integrity());
}

test "response body sentinel survives metadata and clone ownership" {
    var src = response.ResponseData.init();
    var live = true;
    defer if (live) src.deinit();
    src.setBody("[1,2,3]");
    const old_capacity = src.pool.capacity;
    const metadata = try std.testing.allocator.alloc(u8, old_capacity + 4096);
    defer std.testing.allocator.free(metadata);
    @memset(metadata, 'X');
    src.setStatusText(metadata);
    src.setUrl("http://example.invalid/");
    try std.testing.expect(src.pool.capacity > old_capacity);
    try expectBodySentinel(src.body(), "[1,2,3]");
    var clone = response.ResponseData.init();
    defer clone.deinit();
    clone.cloneFrom(&src);
    try std.testing.expect(clone.body().?.ptr != src.body().?.ptr);
    src.deinit();
    live = false;
    try expectBodySentinel(clone.body(), "[1,2,3]");
    try std.testing.expectEqualStrings(metadata, clone.statusText());
}

test "replacing and clearing bodies does not expose old bytes or sentinels" {
    var req = request.RequestData.init();
    defer req.deinit();
    var res = response.ResponseData.init();
    defer res.deinit();
    for ([_][]const u8{ "{\"long\":123456}", "0", "\"a\\u0000b\"", "null" }) |body| {
        req.setBody(body);
        res.setBody(body);
        try expectBodySentinel(req.body(), body);
        try expectBodySentinel(res.body(), body);
    }
    req.setBody("");
    res.setBody("");
    try std.testing.expect(!req.has_body and req.body() == null);
    try std.testing.expect(!res.has_body and res.body() == null);
    res.setBody("true");
    res.setBody(null);
    try std.testing.expect(!res.has_body and res.body() == null);
    req.setBody("false");
    res.setBody("false");
    try expectBodySentinel(req.body(), "false");
    try expectBodySentinel(res.body(), "false");
}
