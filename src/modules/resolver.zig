const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
});

pub fn resolveSpec(allocator: Allocator, importer_dir: []const u8, specifier: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, specifier, "./") or std.mem.startsWith(u8, specifier, "../")) {
        var parts = std.ArrayList([]const u8).empty;
        defer parts.deinit(allocator);
        var dir_iter = std.mem.splitScalar(u8, importer_dir, '/');
        while (dir_iter.next()) |p| {
            if (p.len > 0) try parts.append(allocator, p);
        }
        var spec_iter = std.mem.splitScalar(u8, specifier, '/');
        while (spec_iter.next()) |p| {
            if (std.mem.eql(u8, p, "..")) {
                if (parts.items.len > 0) _ = parts.pop();
            } else if (!std.mem.eql(u8, p, ".")) {
                try parts.append(allocator, p);
            }
        }
        var result = std.ArrayList(u8).empty;
        for (parts.items, 0..) |p, i| {
            if (i > 0) try result.append(allocator, '/');
            try result.appendSlice(allocator, p);
        }
        return try result.toOwnedSlice(allocator);
    }
    return try allocator.dupe(u8, specifier);
}

pub fn readFile(allocator: Allocator, path: []const u8) ![]const u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const file = c.fopen(path_z.ptr, "rb") orelse return error.FileNotFound;
    defer _ = c.fclose(file);
    _ = c.fseek(file, 0, c.SEEK_END);
    const size: usize = @intCast(c.ftell(file));
    _ = c.fseek(file, 0, c.SEEK_SET);
    const buf = try allocator.alloc(u8, size);
    _ = c.fread(buf.ptr, 1, size, file);
    return buf;
}
