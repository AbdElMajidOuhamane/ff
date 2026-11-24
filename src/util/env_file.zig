const std = @import("std");

pub const EnvEntry = struct {
    key: []const u8,
    val: []const u8,
};
pub const Entry = EnvEntry;

var file_arena: std.heap.ArenaAllocator = undefined;
var entries: std.ArrayList(EnvEntry) = .empty;
var loaded: bool = false;

/// Pure `.env` parser: appends entries whose `key`/`val` slices borrow into `content`.
pub fn parseContent(alloc: std.mem.Allocator, content: []const u8, out: *std.ArrayList(Entry)) !void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_pos], " \t");
        var val = std.mem.trim(u8, line[eq_pos + 1 ..], " \t");
        if (val.len >= 2 and ((val[0] == '"' and val[val.len - 1] == '"') or (val[0] == '\'' and val[val.len - 1] == '\''))) {
            val = val[1 .. val.len - 1];
        }
        if (key.len > 0) {
            try out.append(alloc, .{ .key = key, .val = val });
        }
    }
}

pub fn load(io: std.Io, path: []const u8) void {
    if (loaded) return;
    loaded = true;
    file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = file_arena.allocator();

    const content = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        alloc,
        .limited(2 * 1024 * 1024),
        .of(u8),
        0,
    ) catch return;

    parseContent(alloc, content, &entries) catch {};
}

pub fn getEntries() []const EnvEntry {
    if (!loaded) return &.{};
    return entries.items;
}

test "parseContent handles comments, blanks, quotes, whitespace, and malformed lines" {
    var list: std.ArrayList(Entry) = .empty;
    defer list.deinit(std.testing.allocator);

    const input =
        "# top comment\r\n" ++
        "   \t\r\n" ++
        "PLAIN=hello\n" ++
        "  SPACED  =  \"double quoted\"  \r\n" ++
        "SINGLE='single quoted'\n" ++
        "MISMATCH=\"abc'\n" ++
        "NO_EQ_LINE\n" ++
        "=empty_key\n" ++
        "CONTAINS_EQ=a=b=c\n" ++
        "EMPTY_QUOTES=\"\"\n";

    try parseContent(std.testing.allocator, input, &list);
    try std.testing.expectEqual(@as(usize, 6), list.items.len);
    try std.testing.expectEqualStrings("PLAIN", list.items[0].key);
    try std.testing.expectEqualStrings("hello", list.items[0].val);
    try std.testing.expectEqualStrings("SPACED", list.items[1].key);
    try std.testing.expectEqualStrings("double quoted", list.items[1].val);
    try std.testing.expectEqualStrings("SINGLE", list.items[2].key);
    try std.testing.expectEqualStrings("single quoted", list.items[2].val);
    try std.testing.expectEqualStrings("MISMATCH", list.items[3].key);
    try std.testing.expectEqualStrings("\"abc'", list.items[3].val);
    try std.testing.expectEqualStrings("CONTAINS_EQ", list.items[4].key);
    try std.testing.expectEqualStrings("a=b=c", list.items[4].val);
    try std.testing.expectEqualStrings("EMPTY_QUOTES", list.items[5].key);
    try std.testing.expectEqualStrings("", list.items[5].val);
}
