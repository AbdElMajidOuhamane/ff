const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
});

pub fn resolveSpec(allocator: Allocator, importer_dir: []const u8, specifier: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, specifier, "./") or std.mem.startsWith(u8, specifier, "../")) {
        return resolveRelative(allocator, importer_dir, specifier);
    }
    if (std.mem.startsWith(u8, specifier, "/")) return try allocator.dupe(u8, specifier);
    if (isBare(specifier)) return resolveBare(allocator, importer_dir, specifier);
    return try allocator.dupe(u8, specifier);
}

pub fn pathExists(gpa: Allocator, path: []const u8) bool {
    const path_z = gpa.dupeZ(u8, path) catch return false;
    defer gpa.free(path_z);
    const file = c.fopen(path_z.ptr, "rb") orelse return false;
    _ = c.fclose(file);
    return true;
}

fn isBare(s: []const u8) bool {
    if (s.len == 0) return false;
    if (s[0] == '.' or s[0] == '/') return false;
    if (std.mem.indexOf(u8, s, "://") != null) return false;
    return true;
}

fn resolveRelative(allocator: Allocator, importer_dir: []const u8, specifier: []const u8) ![]const u8 {
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
    defer result.deinit(allocator);
    for (parts.items, 0..) |p, i| {
        if (i > 0) try result.append(allocator, '/');
        try result.appendSlice(allocator, p);
    }
    return try result.toOwnedSlice(allocator);
}

fn resolveBare(allocator: Allocator, importer_dir: []const u8, specifier: []const u8) ![]const u8 {
    var pkg_end: usize = std.mem.indexOfScalar(u8, specifier, '/') orelse specifier.len;
    if (specifier[0] == '@') {
        if (std.mem.indexOfScalarPos(u8, specifier, 1, '/')) |s2| {
            pkg_end = std.mem.indexOfScalarPos(u8, specifier, s2 + 1, '/') orelse specifier.len;
        }
    }
    const pkg = specifier[0..pkg_end];
    const rest = if (pkg_end < specifier.len) specifier[pkg_end + 1 ..] else "";
    var dir = try allocator.dupe(u8, importer_dir);
    defer allocator.free(dir);
    while (true) {
        const cand = try std.fmt.allocPrint(allocator, "{s}/node_modules/{s}", .{ dir, pkg });
        defer allocator.free(cand);
        if (try resolvePackageDir(allocator, cand, rest)) |hit| return hit;
        if (std.mem.lastIndexOfScalar(u8, dir, '/')) |i| {
            const parent = try allocator.dupe(u8, dir[0..i]);
            allocator.free(dir);
            dir = parent;
            if (dir.len == 0) break;
        } else break;
    }
    return error.ModuleNotFound;
}

fn resolvePackageDir(allocator: Allocator, pkgdir: []const u8, rest: []const u8) !?[]const u8 {
    const pj_path = try std.fmt.allocPrint(allocator, "{s}/package.json", .{pkgdir});
    defer allocator.free(pj_path);
    const pj_src = readFile(allocator, pj_path) catch {
        if (rest.len > 0) return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pkgdir, rest });
        return try std.fmt.allocPrint(allocator, "{s}/index.js", .{pkgdir});
    };
    defer allocator.free(pj_src);
    const pj = std.json.parseFromSlice(std.json.Value, allocator, pj_src, .{}) catch {
        if (rest.len > 0) return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pkgdir, rest });
        return try std.fmt.allocPrint(allocator, "{s}/index.js", .{pkgdir});
    };
    defer pj.deinit();
    if (rest.len > 0) {
        if (pj.value.object.get("exports")) |ex| {
            if (ex == .object) {
                const key = try std.fmt.allocPrint(allocator, "./{s}", .{rest});
                defer allocator.free(key);
                if (ex.object.get(key)) |target| {
                    if (target == .string) return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pkgdir, target.string });
                    if (target == .object) {
                        if (target.object.get("import")) |imp| {
                            if (imp == .string) return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pkgdir, imp.string });
                        }
                        if (target.object.get("default")) |d| {
                            if (d == .string) return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pkgdir, d.string });
                        }
                    }
                }
            }
        }
        return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pkgdir, rest });
    }
    if (pj.value.object.get("exports")) |ex| {
        if (ex == .string) return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pkgdir, ex.string });
        if (ex == .object) {
            if (ex.object.get("import")) |imp| {
                if (imp == .string) return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pkgdir, imp.string });
            }
            if (ex.object.get("default")) |d| {
                if (d == .string) return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pkgdir, d.string });
            }
        }
    }
    if (pj.value.object.get("module")) |m| {
        if (m == .string) return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pkgdir, m.string });
    }
    if (pj.value.object.get("main")) |m| {
        if (m == .string) return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pkgdir, m.string });
    }
    return try std.fmt.allocPrint(allocator, "{s}/index.js", .{pkgdir});
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
