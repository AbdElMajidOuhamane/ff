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
    var first: ?[]u8 = null;
    defer if (first) |f| allocator.free(f);
    while (true) {
        const cand = try std.fmt.allocPrint(allocator, "{s}/node_modules/{s}", .{ dir, pkg });
        defer allocator.free(cand);
        if (first == null) first = try allocator.dupe(u8, cand);
        if (try resolvePackageDir(allocator, cand, rest)) |hit| return hit;
        if (std.mem.lastIndexOfScalar(u8, dir, '/')) |i| {
            const parent = try allocator.dupe(u8, dir[0..i]);
            allocator.free(dir);
            dir = parent;
            if (dir.len == 0) break;
        } else break;
    }
    // Walk exhausted: return the first candidate literally so the loader
    // prints its standard filename error (today's missing-module UX,
    // preserved — no new silent failure mode introduced).
    const base = first orelse return error.ModuleNotFound;
    first = null;
    defer allocator.free(base);
    if (rest.len > 0) {
        return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, rest });
    }
    return try std.fmt.allocPrint(allocator, "{s}/index.js", .{base});
}

// Import-condition target for an exports-map value, else null.
// (Borrowed from the parsed doc; the caller dupes what it keeps.)
fn importTarget(v: std.json.Value) ?[]const u8 {
    if (v == .string) return v.string;
    if (v != .object) return null;
    if (v.object.get("import")) |imp| {
        if (imp == .string) return imp.string;
    }
    if (v.object.get("default")) |d| {
        if (d == .string) return d.string;
    }
    return null;
}

// Join + normalize + verify. A manifest-named file that is absent is a
// broken install: single message, hard error — resolving a different
// version higher up would mask it (npm errors here too).
fn verifiedJoin(allocator: Allocator, pkgdir: []const u8, target: []const u8) ![]u8 {
    const clean = if (std.mem.startsWith(u8, target, "./")) target[2..] else target;
    const cand = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pkgdir, clean });
    defer allocator.free(cand);
    if (!pathExists(allocator, cand)) {
        std.debug.print("could not load module filename '{s}'\n", .{cand});
        return error.ModuleNotFound;
    }
    return try allocator.dupe(u8, cand);
}

fn resolvePackageDir(allocator: Allocator, pkgdir: []const u8, rest: []const u8) !?[]const u8 {
    const pj_path = try std.fmt.allocPrint(allocator, "{s}/package.json", .{pkgdir});
    defer allocator.free(pj_path);
    const pj_src = readFile(allocator, pj_path) catch null;
    if (pj_src) |src| {
        defer allocator.free(src);
        if (std.json.parseFromSlice(std.json.Value, allocator, src, .{})) |pj| {
            defer pj.deinit();
            if (pj.value == .object) {
                if (try manifestHit(allocator, pkgdir, rest, pj.value)) |hit| {
                    return hit;
                }
                // Manifest present but silent on this specifier: fall through
                // to the verified literal fallback (rest-passthrough for maps
                // like nanoid's, index.js for bare roots).
            }
        } else |_| {}
    }
    if (rest.len > 0) {
        const cand = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pkgdir, rest });
        defer allocator.free(cand);
        if (!pathExists(allocator, cand)) return null; // keep walking
        return try allocator.dupe(u8, cand);
    }
    const cand = try std.fmt.allocPrint(allocator, "{s}/index.js", .{pkgdir});
    defer allocator.free(cand);
    if (!pathExists(allocator, cand)) return null; // keep walking
    return try allocator.dupe(u8, cand);
}

// Manifest lookup with verification. Returns owned hit, null when silent,
// error only for named-but-missing (broken install, fail loud).
fn manifestHit(allocator: Allocator, pkgdir: []const u8, rest: []const u8, doc: std.json.Value) !?[]const u8 {
    if (rest.len > 0) {
        const ex = doc.object.get("exports") orelse return null;
        if (ex != .object) return null;
        const key = try std.fmt.allocPrint(allocator, "./{s}", .{rest});
        defer allocator.free(key);
        const target = ex.object.get(key) orelse return null;
        const rel = importTarget(target) orelse return null;
        return try verifiedJoin(allocator, pkgdir, rel);
    }
    if (doc.object.get("exports")) |ex| {
        if (ex == .string) {
            return try verifiedJoin(allocator, pkgdir, ex.string);
        }
        if (ex == .object) {
            if (importTarget(ex)) |rel| {
                return try verifiedJoin(allocator, pkgdir, rel);
            }
            // FIX: subpath map (the standard modern shape) — the root entry
            // lives under ".". Without this branch, packages like preact and
            // preact-render-to-string fall through to the legacy `module`
            // twin and silently load the wrong file (observed: the unparseable
            // microbundle source dist/index.module.js instead of dist/index.mjs).
            if (ex.object.get(".")) |dot| {
                if (dot == .string) {
                    return try verifiedJoin(allocator, pkgdir, dot.string);
                }
                if (dot == .object) {
                    if (importTarget(dot)) |rel| {
                        return try verifiedJoin(allocator, pkgdir, rel);
                    }
                }
            }
        }
    }
    if (doc.object.get("module")) |m| {
        if (m == .string) {
            return try verifiedJoin(allocator, pkgdir, m.string);
        }
    }
    if (doc.object.get("main")) |m| {
        if (m == .string) {
            return try verifiedJoin(allocator, pkgdir, m.string);
        }
    }
    return null;
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
