const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const semver = @import("semver.zig");

// ff imprint [pkg[@ver] ...] — direct pins in ff.json, full transitive tree
// in node_modules/, exact snapshot in ff.lock v2.
// ff imprint (no args) — v2 lock present: exact rebuild (ci-like, no range
// queries). Otherwise: resolve from ff.json and write v2 lock.
// Pure-JS ESM only: the gate runs on EVERY package in the tree.

const Pin = struct { name: []const u8, spec: []const u8 }; // borrowed; owner frees
const Dep = struct { name: []u8, spec: []u8, optional: bool }; // owned
const Chosen = struct {
    version: []u8,
    tarball: []u8,
    integrity: []u8,
    parent: []u8,
    optional: bool,
    deps: std.ArrayList(Dep), // owned entries; complete before walk starts
};

pub fn run(io: Io, args: []const []const u8) !void {
    if (args.len == 0) return installAll(io);
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var directs = std.ArrayList(Pin).empty;
    defer {
        for (directs.items) |d| {
            gpa.free(d.name);
            gpa.free(d.spec);
        }
        directs.deinit(gpa);
    }
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
        try directs.append(gpa, .{
            .name = try gpa.dupe(u8, parsed.name),
            .spec = try gpa.dupe(u8, ver),
        });
    }
    try resolveTree(gpa, io, directs.items);
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

// Shared resolve+install+lock path. Pins borrowed; the tree owns everything.
fn resolveTree(gpa: Alloc, io: Io, directs: []const Pin) !void {
    var tree = Tree.init(gpa);
    defer tree.deinit();
    for (directs) |d| try tree.requireExact(io, d.name, d.spec, "ff.json");
    try tree.walk(io);
    var it = tree.chosen.iterator();
    while (it.next()) |kv| {
        const c = kv.value_ptr;
        try installDist(io, gpa, kv.key_ptr.*, c.version, c.tarball, c.integrity);
    }
    try tree.writeLock(io);
    std.debug.print("ff.lock written.\n", .{});
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
    if (dir.readFileAlloc(io, "ff.lock", gpa, .limited(4 * 1024 * 1024))) |lock_src| {
        defer gpa.free(lock_src);
        if (std.json.parseFromSlice(std.json.Value, gpa, lock_src, .{})) |lock| {
            defer lock.deinit();
            if (lock.value.object.get("lockfileVersion")) |lv| {
                if (lv == .integer and lv.integer == 1) {
                    if (lock.value.object.get("packages")) |pkgs| {
                        if (pkgs == .object) {
                            // FIX: pkgs is const — pass *const (signature below).
                            try installFromLock(io, gpa, &pkgs.object);
                            std.debug.print("Done (from ff.lock). Run: ff start\n", .{});
                            return;
                        }
                    }
                }
            }
            std.debug.print("ff.lock is not v2 — resolving from ff.json instead.\n", .{});
        } else |_| {
            std.debug.print("ff.lock is not valid JSON — resolving from ff.json instead.\n", .{});
        }
    } else |_| {}
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
    // Pins borrow from p (alive through resolveTree). The tree dupes all it keeps.
    var directs = std.ArrayList(Pin).empty;
    defer directs.deinit(gpa);
    var it = deps.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* != .string) continue;
        try directs.append(gpa, .{ .name = kv.key_ptr.*, .spec = kv.value_ptr.string });
    }
    try resolveTree(gpa, io, directs.items);
    std.debug.print("Done. Run: ff start\n", .{});
}

// FIX: *const — the lock value is borrowed const; body only reads.
fn installFromLock(io: Io, gpa: Alloc, pkgs: *const std.json.ObjectMap) !void {
    const prefix = "node_modules/";
    var it = pkgs.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        if (!std.mem.startsWith(u8, key, prefix)) {
            std.debug.print("  skip lock entry {s}: expected node_modules/<name>\n", .{key});
            continue;
        }
        const name = key[prefix.len..];
        const e = kv.value_ptr.*;
        if (e != .object) return error.BadLock;
        const version = if (e.object.get("version")) |v| (if (v == .string) v.string else return error.BadLock) else return error.BadLock;
        const tarball = if (e.object.get("resolved")) |v| (if (v == .string) v.string else return error.BadLock) else return error.BadLock;
        const integrity = if (e.object.get("integrity")) |v| (if (v == .string) v.string else return error.BadLock) else return error.MissingIntegrity;
        try installDist(io, gpa, name, version, tarball, integrity);
    }
}

fn installDist(io: Io, gpa: Alloc, name: []const u8, version: []const u8, tarball: []const u8, integrity: []const u8) !void {
    std.debug.print("imprint {s}@{s} ...\n", .{ name, version });
    // FIX: const — element mutation goes through |*ch|, binding never reassigns.
    // (Also flattens scoped names: old code built /tmp paths with raw names.)
    const tmp_base = try gpa.dupe(u8, name);
    defer gpa.free(tmp_base);
    for (tmp_base) |*ch| {
        if (ch.* == '/' or ch.* == '@') ch.* = '_';
    }
    const safe = try std.fmt.allocPrint(gpa, "{s}-{s}", .{ tmp_base, version });
    defer gpa.free(safe);
    const tmp = try std.fmt.allocPrint(gpa, "/tmp/ff-{s}.tgz", .{safe});
    defer gpa.free(tmp);
    try runCmd(io, &.{ "curl", "-fsSL", "-o", tmp, tarball });
    const dir = Io.Dir.cwd();
    const data = try dir.readFileAlloc(io, tmp, gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(data);
    try verifyIntegrity(data, integrity);
    const dest = try std.fmt.allocPrint(gpa, "node_modules/{s}", .{name});
    defer gpa.free(dest);
    const stage = try std.fmt.allocPrint(gpa, "/tmp/ff-stage-{s}", .{safe});
    defer gpa.free(stage);
    const sh = try std.fmt.allocPrint(gpa,
        "rm -rf {s} {s} && mkdir -p {s} {s} && tar -xzf {s} -C {s} --strip-components=1 && cp {s}/package.json {s}/",
        .{ stage, dest, stage, dest, tmp, stage, stage, dest });
    defer gpa.free(sh);
    try runCmd(io, &.{ "sh", "-c", sh });
    const n = try gateAndCopyTree(io, gpa, stage, dest);
    if (n == 0) {
        std.debug.print("  EMPTY node_modules/{s}: no .js/.mjs after copy\n", .{name});
        return error.EmptyPackage;
    }
    std.debug.print("  ok -> {s}/ ({d} files)\n", .{ dest, n });
}

fn verifyIntegrity(data: []const u8, integrity: []const u8) !void {
    const prefix = "sha512-";
    if (!std.mem.startsWith(u8, integrity, prefix)) return error.UnsupportedIntegrity;
    const enc = integrity[prefix.len..];
    const b64 = std.base64.standard.Decoder;
    const size = b64.calcSizeForSlice(enc) catch return error.BadIntegrity;
    if (size != 64) return error.BadIntegrity;
    var expected: [64]u8 = undefined;
    b64.decode(&expected, enc) catch return error.BadIntegrity;
    var h = std.crypto.hash.sha2.Sha512.init(.{});
    h.update(data);
    var digest: [64]u8 = undefined;
    h.final(&digest);
    // mem.eql, not constant-time: the digest is public registry data.
    if (!std.mem.eql(u8, &expected, &digest)) return error.IntegrityMismatch;
}

const Tree = struct {
    gpa: Alloc,
    chosen: std.StringHashMap(Chosen),
    packs: std.StringHashMap(std.json.Parsed(std.json.Value)),
    visiting: std.ArrayList([]u8),

    fn init(gpa: Alloc) Tree {
        return .{
            .gpa = gpa,
            .chosen = std.StringHashMap(Chosen).init(gpa),
            .packs = std.StringHashMap(std.json.Parsed(std.json.Value)).init(gpa),
            .visiting = std.ArrayList([]u8).empty,
        };
    }

    fn deinit(self: *Tree) void {
        var it = self.chosen.iterator();
        while (it.next()) |kv| {
            self.gpa.free(kv.key_ptr.*);
            freeChosen(self.gpa, kv.value_ptr);
        }
        self.chosen.deinit();
        var pi = self.packs.iterator();
        while (pi.next()) |kv| {
            self.gpa.free(kv.key_ptr.*);
            kv.value_ptr.deinit();
        }
        self.packs.deinit();
        for (self.visiting.items) |v| self.gpa.free(v);
        self.visiting.deinit(self.gpa);
    }

    fn freeChosen(gpa: Alloc, c: *Chosen) void {
        gpa.free(c.version);
        gpa.free(c.tarball);
        gpa.free(c.integrity);
        gpa.free(c.parent);
        for (c.deps.items) |d| {
            gpa.free(d.name);
            gpa.free(d.spec);
        }
        c.deps.deinit(gpa);
    }

    fn requireExact(self: *Tree, io: Io, name: []const u8, version: []const u8, parent: []const u8) !void {
        if (self.chosen.get(name) != null) return;
        const doc = try fetchVersionDoc(self.gpa, io, name, version);
        defer doc.deinit();
        try self.chooseOwned(name, version, parent, false, doc.value);
    }

    fn chooseOwned(self: *Tree, name: []const u8, version: []const u8, parent: []const u8, optional: bool, doc: std.json.Value) !void {
        const gpa = self.gpa;
        if (doc != .object) return error.BadManifest;
        const dist = doc.object.get("dist") orelse return error.BadManifest;
        if (dist != .object) return error.BadManifest;
        const tarball = dist.object.get("tarball") orelse return error.BadManifest;
        if (tarball != .string) return error.BadManifest;
        const integrity = dist.object.get("integrity") orelse return error.MissingIntegrity;
        if (integrity != .string) return error.MissingIntegrity;
        var deps = std.ArrayList(Dep).empty;
        errdefer {
            for (deps.items) |d| {
                gpa.free(d.name);
                gpa.free(d.spec);
            }
            deps.deinit(gpa);
        }
        try collectDepMap(gpa, doc, "dependencies", false, &deps);
        try collectDepMap(gpa, doc, "optionalDependencies", true, &deps);
        warnPeers(name, doc);
        try self.chosen.put(try gpa.dupe(u8, name), .{
            .version = try gpa.dupe(u8, version),
            .tarball = try gpa.dupe(u8, tarball.string),
            .integrity = try gpa.dupe(u8, integrity.string),
            .parent = try gpa.dupe(u8, parent),
            .optional = optional,
            .deps = deps,
        });
    }

    fn walk(self: *Tree, io: Io) !void {
        const gpa = self.gpa;
        // Owned queue: map keys move on insert, so the walk never borrows
        // map-owned memory across a mutation.
        var queue = std.ArrayList([]u8).empty;
        defer {
            for (queue.items) |q| gpa.free(q);
            queue.deinit(gpa);
        }
        var it = self.chosen.iterator();
        while (it.next()) |kv| try queue.append(gpa, try gpa.dupe(u8, kv.key_ptr.*));
        var head: usize = 0;
        while (head < queue.items.len) {
            const name = queue.items[head];
            head += 1;
            if (self.inStack(name)) {
                std.debug.print("cyclic dependencies involving {s} — v1 fails loud\n", .{name});
                return error.CyclicDependencies;
            }
            try self.visiting.append(gpa, try gpa.dupe(u8, name));
            // Re-fetch entry every iteration: inserts may realloc the map.
            var i: usize = 0;
            while (true) {
                const e = self.chosen.getPtr(name) orelse return error.MissingPackage;
                if (i >= e.deps.items.len) break;
                const dd = e.deps.items[i];
                i += 1;
                // Dupe before the call: requireRange may insert (realloc).
                const need_name = try gpa.dupe(u8, dd.name);
                errdefer gpa.free(need_name);
                const need_spec = try gpa.dupe(u8, dd.spec);
                errdefer gpa.free(need_spec);
                try self.requireRange(io, name, need_name, need_spec, dd.optional, &queue);
                gpa.free(need_name);
                gpa.free(need_spec);
            }
            const v = self.visiting.pop();
            gpa.free(v.?);
        }
    }

    fn inStack(self: *Tree, name: []const u8) bool {
        for (self.visiting.items) |v| {
            if (std.mem.eql(u8, v, name)) return true;
        }
        return false;
    }

    fn requireRange(self: *Tree, io: Io, parent: []const u8, name: []const u8, spec: []const u8, optional: bool, queue: *std.ArrayList([]u8)) !void {
        const gpa = self.gpa;
        if (self.chosen.getPtr(name)) |have| {
            // Read-only use of the pointer: no map mutation before return.
            const have_v = semver.parseVersion(have.version) catch return error.BadVersion;
            const ok = semver.satisfies(have_v, spec) catch |err| {
                if (err == error.UnsupportedRange) {
                    std.debug.print("conflict: {s} needs {s}@{s} (unsupported range syntax)\n", .{ parent, name, spec });
                    return err;
                }
                return err;
            };
            if (ok) {
                if (!optional) have.optional = false;
                return;
            }
            if (optional) {
                std.debug.print("  skip optional {s}@{s} (have {s} via {s})\n", .{ name, spec, have.version, have.parent });
                return;
            }
            std.debug.print("conflict: {s} needs {s}@{s} but {s} is pinned via {s}. Pin \"{s}\" in ff.json dependencies to override.\n", .{ parent, name, spec, have.version, have.parent, name });
            return error.VersionConflict;
        }
        const pack = try self.getPack(io, name);
        const versions = pack.object.get("versions") orelse return error.BadManifest;
        if (versions != .object) return error.BadManifest;
        var list = std.ArrayList([]const u8).empty;
        defer list.deinit(gpa);
        var vit = versions.object.iterator();
        while (vit.next()) |kv| try list.append(gpa, kv.key_ptr.*);
        const pick = try semver.maxSatisfying(list.items, spec) orelse {
            if (optional) {
                std.debug.print("  skip optional {s}@{s}: no satisfying version\n", .{ name, spec });
                return;
            }
            std.debug.print("conflict: no version of {s} satisfies {s} (needed by {s})\n", .{ name, spec, parent });
            return error.NoSatisfyingVersion;
        };
        const entry = versions.object.get(pick).?;
        if (entry != .object) return error.BadManifest;
        // entry borrows from the run-long pack cache; chooseOwned dupes out.
        try self.chooseOwned(name, pick, parent, optional, entry);
        try queue.append(gpa, try gpa.dupe(u8, name));
    }

    fn getPack(self: *Tree, io: Io, name: []const u8) !std.json.Value {
        if (self.packs.get(name)) |p| return p.value;
        const url = try std.fmt.allocPrint(self.gpa, "https://registry.npmjs.org/{s}", .{name});
        defer self.gpa.free(url);
        std.debug.print("  resolve {s} ...\n", .{name});
        const body = try curlToAllocH(self.gpa, io, url, &.{ "-H", "Accept: application/vnd.npm.install-v1+json" });
        defer self.gpa.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, self.gpa, body, .{});
        errdefer parsed.deinit();
        try self.packs.put(try self.gpa.dupe(u8, name), parsed);
        return self.packs.get(name).?.value;
    }

    fn writeLock(self: *Tree, io: Io) !void {
        const gpa = self.gpa;
        const dir = Io.Dir.cwd();
        var migrated = false;
        if (dir.readFileAlloc(io, "ff.lock", gpa, .limited(4 * 1024 * 1024))) |old| {
            defer gpa.free(old);
            const ok_v2 = if (std.json.parseFromSlice(std.json.Value, gpa, old, .{})) |p| blk: {
                defer p.deinit();
                break :blk if (p.value.object.get("lockfileVersion")) |lv| (lv == .integer and lv.integer == 1) else false;
            } else |_| false;
            if (!ok_v2) migrated = true;
        } else |_| {}
        var project_name: []const u8 = "my-app";
        var project_ver: []const u8 = "0.0.1";
        var ff_doc: ?std.json.Parsed(std.json.Value) = null;
        if (dir.readFileAlloc(io, "ff.json", gpa, .limited(1024 * 1024))) |ff| {
            defer gpa.free(ff);
            if (std.json.parseFromSlice(std.json.Value, gpa, ff, .{})) |p| {
                ff_doc = p;
                if (p.value.object.get("name")) |n| {
                    if (n == .string) project_name = n.string;
                }
                if (p.value.object.get("version")) |v| {
                    if (v == .string) project_ver = v.string;
                }
            } else |_| {}
        } else |_| {}
        defer if (ff_doc) |*p| p.deinit();
        var root: std.json.Value = .{ .object = .{} };
        defer root.object.deinit(gpa);
        try root.object.put(gpa, try gpa.dupe(u8, "name"), .{ .string = try gpa.dupe(u8, project_name) });
        try root.object.put(gpa, try gpa.dupe(u8, "version"), .{ .string = try gpa.dupe(u8, project_ver) });
        try root.object.put(gpa, try gpa.dupe(u8, "lockfileVersion"), .{ .integer = 1 });
        try root.object.put(gpa, try gpa.dupe(u8, "packages"), .{ .object = .{} });
        // All root puts done before borrowing: no root mutation in the loop.
        var pkgs_ptr = &root.object.getPtr("packages").?.object;
        var it = self.chosen.iterator();
        while (it.next()) |kv| {
            const c = kv.value_ptr;
            const key = try std.fmt.allocPrint(gpa, "node_modules/{s}", .{kv.key_ptr.*});
            defer gpa.free(key);
            var entry: std.json.ObjectMap = .{};
            try entry.put(gpa, "version", .{ .string = try gpa.dupe(u8, c.version) });
            try entry.put(gpa, "resolved", .{ .string = try gpa.dupe(u8, c.tarball) });
            try entry.put(gpa, "integrity", .{ .string = try gpa.dupe(u8, c.integrity) });
            if (c.optional) try entry.put(gpa, "optional", .{ .bool = true });
            var req: std.json.ObjectMap = .{};
            for (c.deps.items) |d| {
                // Optional deps skipped at resolve time are simply absent.
                if (self.chosen.get(d.name)) |have| {
                    try req.put(gpa, try gpa.dupe(u8, d.name), .{ .string = try gpa.dupe(u8, have.version) });
                }
            }
            try entry.put(gpa, "requires", .{ .object = req });
            try pkgs_ptr.put(gpa, try gpa.dupe(u8, key), .{ .object = entry });
        }
        const out = try std.json.Stringify.valueAlloc(gpa, root, .{ .whitespace = .indent_2 });
        defer gpa.free(out);
        try dir.writeFile(io, .{ .sub_path = "ff.lock.tmp", .data = out });
        try Io.Dir.cwd().rename("ff.lock.tmp", Io.Dir.cwd(), "ff.lock", io);
        if (migrated) std.debug.print("migrated ff.lock to v2 format.\n", .{});
    }
};

fn collectDepMap(gpa: Alloc, doc: std.json.Value, field: []const u8, optional: bool, out: *std.ArrayList(Dep)) !void {
    if (doc != .object) return error.BadManifest;
    const d = doc.object.get(field) orelse return;
    if (d != .object) return;
    var it = d.object.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* != .string) continue;
        try out.append(gpa, .{
            .name = try gpa.dupe(u8, kv.key_ptr.*),
            .spec = try gpa.dupe(u8, kv.value_ptr.string),
            .optional = optional,
        });
    }
}

fn warnPeers(pkg: []const u8, doc: std.json.Value) void {
    if (doc != .object) return;
    const d = doc.object.get("peerDependencies") orelse return;
    if (d != .object or d.object.count() == 0) return;
    std.debug.print("  note {s}: peerDependencies skipped in v1 (", .{pkg});
    var it = d.object.iterator();
    var first = true;
    while (it.next()) |kv| {
        if (!first) std.debug.print(", ", .{});
        std.debug.print("{s}", .{kv.key_ptr.*});
        first = false;
    }
    std.debug.print(")\n", .{});
}

fn fetchVersionDoc(gpa: Alloc, io: Io, name: []const u8, version: []const u8) !std.json.Parsed(std.json.Value) {
    const url = try std.fmt.allocPrint(gpa, "https://registry.npmjs.org/{s}/{s}", .{ name, version });
    defer gpa.free(url);
    const body = try curlToAlloc(gpa, io, url);
    defer gpa.free(body);
    return try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
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

fn curlToAlloc(gpa: Alloc, io: Io, url: []const u8) ![]u8 {
    return curlToAllocH(gpa, io, url, &.{});
}

fn curlToAllocH(gpa: Alloc, io: Io, url: []const u8, extra: []const []const u8) ![]u8 {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "curl", "-fsSL" });
    try argv.appendSlice(gpa, extra);
    try argv.append(gpa, url);
    const res = try std.process.run(gpa, io, .{ .argv = argv.items });
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
