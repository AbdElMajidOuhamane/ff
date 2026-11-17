const std = @import("std");

pub const EnvEntry = struct {
    key: []const u8,
    val: []const u8,
};

var file_arena: std.heap.ArenaAllocator = undefined;
var entries: std.ArrayList(EnvEntry) = .empty;
var loaded: bool = false;

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
            entries.append(alloc, .{ .key = key, .val = val }) catch {};
        }
    }
}

pub fn getEntries() []const EnvEntry {
    if (!loaded) return &.{};
    return entries.items;
}
