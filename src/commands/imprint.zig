const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;

pub fn run(io: Io, args: []const []const u8) !void {
    if (args.len == 0) return installAll(io);
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    for (args) |arg| {
        const parsed = try splitPkgArg(gpa, arg);
        defer gpa.free(parsed.name);
        defer if (parsed.ver) |v| gpa.free(v);
        var ver_owned: ?[]u8 = null;
        defer if (ver_owned) |v| gpa.free(v);
        const ver: []const u8 = parsed.ver orelse blk: {
            ver_owned = try resolveLatest(io, gpa, parsed.name);
            break :blk ver_owned.?;
        };
        try upsertFfJson(gpa, io, parsed.name, ver);
        try installOne(io, gpa, parsed.name, ver);
    }
    try writeLockHeader(io);
}

const PkgArg = struct { name: []u8, ver: ?[]u8 };

fn splitPkgArg(gpa: Alloc, arg: []const u8) !PkgArg {
    var at: ?usize = null;
    var i: usize = 1;
    while (i < arg.len) : (i += 1) { if (arg[i] == '@') at = i; }
    if (at) |idx| {
        return .{ .name = try gpa.dupe(u8, arg[0..idx]), .ver = try gpa.dupe(u8, arg[idx + 1 ..]) };
    }
    return .{ .name = try gpa.dupe(u8, arg), .ver = null };
}

fn resolveLatest(io: Io, gpa: Alloc, name: []const u8) ![]u8 {
    const url = try std.fmt.allocPrint(gpa, "https://registry.npmjs.org/{s}/latest", .{name});
    defer gpa.free(url);
    const body = try curlToAlloc(gpa, io, url);
    defer gpa.free(body);
    const j = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer j.deinit();
    const v = j.value.object.get("version").?.string;
    return try gpa.dupe(u8, v);
}

fn upsertFfJson(gpa: Alloc, io: Io, name: []const u8, ver: []const u8) !void {
    const dir = Io.Dir.cwd();
    var root: std.json.Value = .{ .object = .{} };
    defer root.object.deinit(gpa);
    if (dir.readFileAlloc(io, "ff.json", gpa, .limited(1024 * 1024))) |old| {
        defer gpa.free(old);
        const p = std.json.parseFromSlice(std.json.Value, gpa, old, .{}) catch {
            std.debug.print("ff.json is not valid JSON — refusing to overwrite it. Fix or delete it first.\n", .{});
            return error.InvalidManifest;
        };
        defer p.deinit();
        root = try dupeValue(gpa, p.value);
        std.debug.assert(root.object.count() == p.value.object.count());
    } else |_| {
        try root.object.put(gpa, try gpa.dupe(u8, "name"), .{ .string = try gpa.dupe(u8, "my-app") });
        try root.object.put(gpa, try gpa.dupe(u8, "version"), .{ .string = try gpa.dupe(u8, "0.0.1") });
        try root.object.put(gpa, try gpa.dupe(u8, "main"), .{ .string = try gpa.dupe(u8, "main.js") });
    }
    var deps: *std.json.ObjectMap = undefined;
    if (root.object.getPtr("dependencies")) |d| {
        deps = &d.object;
    } else {
        try root.object.put(gpa, try gpa.dupe(u8, "dependencies"), .{ .object = .{} });
        deps = &root.object.getPtr("dependencies").?.object;
    }
    if (deps.getPtr(name)) |slot| {
        gpa.free(slot.string);
        slot.* = .{ .string = try gpa.dupe(u8, ver) };
    } else {
        try deps.put(gpa, try gpa.dupe(u8, name), .{ .string = try gpa.dupe(u8, ver) });
    }
    const out = try std.json.Stringify.valueAlloc(gpa, root, .{ .whitespace = .indent_2 });
    defer gpa.free(out);
    try dir.writeFile(io, .{ .sub_path = "ff.json.tmp", .data = out });
    try Io.Dir.cwd().rename("ff.json.tmp", Io.Dir.cwd(), "ff.json", io);
}

fn installAll(io: Io) !void {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    const dir = Io.Dir.cwd();
    const ff = dir.readFileAlloc(io, "ff.json", gpa, .limited(1024 * 1024)) catch {
        std.debug.print("No ff.json found. Run 'ff init' first.\n", .{});
        return;
    };
    defer gpa.free(ff);
    const p = try std.json.parseFromSlice(std.json.Value, gpa, ff, .{});
    defer p.deinit();
    const deps = if (p.value.object.get("dependencies")) |d| d.object else {
        std.debug.print("No dependencies in ff.json.\n", .{});
        return;
    };
    var it = deps.iterator();
    while (it.next()) |kv| try installOne(io, gpa, kv.key_ptr.*, kv.value_ptr.string);
    std.debug.print("Done. Run: ff start\n", .{});
}

fn installOne(io: Io, gpa: Alloc, name: []const u8, version: []const u8) !void {
    std.debug.print("imprint {s}@{s} ...\n", .{ name, version });
    const meta_url = try std.fmt.allocPrint(gpa, "https://registry.npmjs.org/{s}/{s}", .{ name, version });
    defer gpa.free(meta_url);
    const meta_json = try curlToAlloc(gpa, io, meta_url);
    defer gpa.free(meta_json);
    const meta = try std.json.parseFromSlice(std.json.Value, gpa, meta_json, .{});
    defer meta.deinit();
    const tarball = meta.value.object.get("dist").?.object.get("tarball").?.string;
    const tmp = try std.fmt.allocPrint(gpa, "/tmp/ff-{s}-{s}.tgz", .{ name, version });
    defer gpa.free(tmp);
    try runCmd(io, &.{ "curl", "-fsSL", "-o", tmp, tarball });
    const dest = try std.fmt.allocPrint(gpa, "node_modules/{s}", .{name});
    defer gpa.free(dest);
    const stage = try std.fmt.allocPrint(gpa, "/tmp/ff-stage-{s}-{s}", .{ name, version });
    defer gpa.free(stage);
    // Shell keeps only proven-simple commands (each independently debuggable).
    // The find|tar|tar pipe died silently under spawned sh — the tree copy
    // below is Zig-native (gateAndCopyTree). No `; true` anywhere.
    const sh = try std.fmt.allocPrint(gpa,
        "rm -rf {s} {s} && mkdir -p {s} {s} && tar -xzf {s} -C {s} --strip-components=1 && cp {s}/package.json {s}/",
        .{ stage, dest, stage, dest, tmp, stage, stage, dest });
    defer gpa.free(sh);
    try runCmd(io, &.{ "sh", "-c", sh });
    // One recursive walk: gate-scan every .js/.mjs, then copy it.
    // Fail loud on zero files — an empty copy must never pass as success.
    const n = try gateAndCopyTree(io, gpa, stage, dest);
    if (n == 0) {
        std.debug.print("  EMPTY node_modules/{s}: no .js/.mjs after copy\n", .{name});
        return error.EmptyPackage;
    }
    try upsertLock(io, gpa, name, version, tarball);
    std.debug.print("  ok -> {s}/ ({d} files, ff.json + ff.lock updated)\n", .{ dest, n });
}

fn isSkippedTreeDir(name: []const u8) bool {
    for ([_][]const u8{ "test", "tests", "__tests__", "spec", "bin", "examples", "example", ".git" }) |skip| {
        if (std.mem.eql(u8, name, skip)) return true;
        if (std.mem.startsWith(u8, name, "test")) return true;
    }
    return false;
}

fn isJsFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".js") or std.mem.endsWith(u8, name, ".mjs");
}

fn gateSource(path: []const u8, src: []const u8) !void {
    for ([_][]const u8{
        "from \"node:", "from 'node:",
        "from\"node:", "from'node:",
        "from \"buffer\"", "from 'buffer'",
        "from\"buffer\"", "from'buffer\"",
        "require(", "module.exports", "exports.",
    }) |needle| {
        if (std.mem.indexOf(u8, src, needle) != null) {
            std.debug.print("  REJECT {s}: needs {s} (pure-JS ESM only)\n", .{ path, needle });
            return error.NeedsNodeBuiltins;
        }
    }
}

// Walks the stage tree; for each .js/.mjs: gate-scan, then copy to the
// mirrored path under dest (creating parent dirs). Returns files copied.
// NOTE: stage is absolute (/tmp/...), dest relative: both resolve against
// base == cwd (openat ignores dirfd for absolute paths), so mixed forms work.
fn gateAndCopyTree(io: Io, gpa: Alloc, stage_rel: []const u8, dest_rel: []const u8) !usize {
    return gateAndCopyDir(io, gpa, Io.Dir.cwd(), stage_rel, dest_rel);
}

fn gateAndCopyDir(io: Io, gpa: Alloc, base: Io.Dir, stage_rel: []const u8, dest_rel: []const u8) !usize {
    var total: usize = 0;
    var d = base.openDir(io, stage_rel, .{ .iterate = true }) catch return 0;
    defer d.close(io);
    var iter = d.iterate();
    while (iter.next(io) catch null) |e| {
        const s_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ stage_rel, e.name });
        defer gpa.free(s_path);
        const d_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dest_rel, e.name });
        defer gpa.free(d_path);
        if (e.kind == .directory) {
            if (isSkippedTreeDir(e.name)) continue;
            total += try gateAndCopyDir(io, gpa, base, s_path, d_path);
        } else if (isJsFile(e.name)) {
            const src = base.readFileAlloc(io, s_path, gpa, .limited(4 * 1024 * 1024)) catch continue;
            defer gpa.free(src);
            try gateSource(s_path, src);
            if (std.fs.path.dirname(d_path)) |parent| {
                base.createDirPath(io, parent) catch {};
            }
            try base.writeFile(io, .{ .sub_path = d_path, .data = src });
            total += 1;
        }
    }
    return total;
}

fn upsertLock(io: Io, gpa: Alloc, name: []const u8, version: []const u8, tarball: []const u8) !void {
    const dir = Io.Dir.cwd();
    var lock: std.json.Value = .{ .object = .{} };
    defer lock.object.deinit(gpa);
    if (dir.readFileAlloc(io, "ff.lock", gpa, .limited(1024 * 1024))) |old| {
        defer gpa.free(old);
        if (std.json.parseFromSlice(std.json.Value, gpa, old, .{})) |p| {
            defer p.deinit();
            lock = try dupeValue(gpa, p.value);
        } else |_| {}
    } else |_| {}
    var entry: std.json.ObjectMap = .{};
    try entry.put(gpa, "version", .{ .string = try gpa.dupe(u8, version) });
    try entry.put(gpa, "tarball", .{ .string = try gpa.dupe(u8, tarball) });
    const owned_name = try gpa.dupe(u8, name);
    try lock.object.put(gpa, owned_name, .{ .object = entry });
    const out = try std.json.Stringify.valueAlloc(gpa, lock, .{ .whitespace = .indent_2 });
    defer gpa.free(out);
    try dir.writeFile(io, .{ .sub_path = "ff.lock.tmp", .data = out });
    try Io.Dir.cwd().rename("ff.lock.tmp", Io.Dir.cwd(), "ff.lock", io);
}

fn writeLockHeader(io: Io) !void {
    _ = io;
    std.debug.print("ff.lock written.\n", .{});
}

fn curlToAlloc(gpa: Alloc, io: Io, url: []const u8) ![]u8 {
    const res = try std.process.run(gpa, io, .{ .argv = &.{ "curl", "-fsSL", url } });
    defer gpa.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) return error.CurlFailed;
    return res.stdout;
}

fn runCmd(io: Io, argv: []const []const u8) !void {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    const res = try std.process.run(gpa, io, .{ .argv = argv });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) {
        std.debug.print("command failed: {s}\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n", .{ argv[0], res.stdout, res.stderr });
        return error.CommandFailed;
    }
}

fn dupeValue(gpa: Alloc, v: std.json.Value) !std.json.Value {
    switch (v) {
        .null => return .null,
        .bool => |b| return .{ .bool = b },
        .integer => |i| return .{ .integer = i },
        .float => |f| return .{ .float = f },
        .number_string => |s| return .{ .number_string = try gpa.dupe(u8, s) },
        .string => |s| return .{ .string = try gpa.dupe(u8, s) },
        .array => |arr| {
            var out = std.json.Array.init(gpa);
            for (arr.items) |item| try out.append(try dupeValue(gpa, item));
            return .{ .array = out };
        },
        .object => |obj| {
            var out: std.json.ObjectMap = .{};
            var it = obj.iterator();
            while (it.next()) |kv| {
                try out.put(gpa, try gpa.dupe(u8, kv.key_ptr.*), try dupeValue(gpa, kv.value_ptr.*));
            }
            return .{ .object = out };
        },
    }
}
