const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const semver = @import("semver.zig");

// ff imprint [pkg[@ver] ...] — direct pins in ff.json, full transitive tree
// in node_modules/, exact snapshot in ff.lock v2.
// ff imprint (no args) — v2 lock present: exact rebuild (ci-like, no range
// queries). Otherwise: resolve from ff.json and write v2 lock.
// Pure-JS ESM only: the gate runs on EVERY copied file, and copying follows
// the ESM closure (route 1) so multi-format siblings (CJS/UMD twins) never
// enter node_modules to false-positive the gate. Packages with no `import`
// conditions anywhere fall back to the legacy whole-tree copy (route 2).
// Gating granularity: the package ROOT must be pure (abort on failure);
// each SUBPATH entry is gated independently — failure warns and skips that
// subpath (with partial-file cleanup) instead of aborting the install.

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
    // Route 1: root ESM closure (fail loud), then each subpath entry
    // isolated (warn + skip + partial cleanup). Empty root set: legacy
    // whole-tree copy (route 2, unchanged) — nanoid/valibot install
    // bit-identically through it.
    var entries = try collectImportEntries(io, gpa, stage);
    defer {
        for (entries.items) |e| {
            gpa.free(e.path);
            if (e.sub) |s| gpa.free(s);
        }
        entries.deinit(gpa);
    }
    var root_paths = std.ArrayList([]const u8).empty;
    defer root_paths.deinit(gpa);
    var sub_keys = std.ArrayList([]const u8).empty;
    defer sub_keys.deinit(gpa);
    for (entries.items) |e| {
        if (e.sub) |k| {
            if (!containsStr(sub_keys.items, k)) try sub_keys.append(gpa, k);
        } else {
            try root_paths.append(gpa, e.path);
        }
    }
    var n: usize = 0;
    if (root_paths.items.len > 0) {
        std.debug.print("  esm entries: {d} root", .{root_paths.items.len});
        if (sub_keys.items.len > 0) std.debug.print(" + {d} subpath", .{sub_keys.items.len});
        std.debug.print("\n", .{});
        n += try copyClosure(io, gpa, stage, dest, root_paths.items, null);
    } else {
        n = try gateAndCopyTree(io, gpa, stage, dest);
    }
    for (sub_keys.items) |key| {
        var paths = std.ArrayList([]const u8).empty;
        defer paths.deinit(gpa);
        for (entries.items) |e| {
            if (e.sub) |k| {
                if (std.mem.eql(u8, k, key)) try paths.append(gpa, e.path);
            }
        }
        var written = std.ArrayList([]u8).empty;
        defer {
            for (written.items) |w| gpa.free(w);
            written.deinit(gpa);
        }
        const m = copyClosure(io, gpa, stage, dest, paths.items, &written) catch |err| {
            if (err == error.NeedsNodeBuiltins or err == error.MissingImport) {
                for (written.items) |w| dir.deleteFile(io, w) catch {};
                std.debug.print("  warn: skip subpath {s} ({s})\n", .{ key, @errorName(err) });
                continue;
            }
            return err;
        };
        n += m;
    }
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

    // Seed an exact pin. Directs are seeded first, so they always win.
    fn requireExact(self: *Tree, io: Io, name: []const u8, version: []const u8, parent: []const u8) !void {
        if (self.chosen.get(name) != null) return;
        const doc = try fetchVersionDoc(self.gpa, io, name, version);
        defer doc.deinit();
        try self.chooseOwned(name, version, parent, false, doc.value);
    }

    // Extract + DUPE everything the tree keeps; the doc is freed by the caller.
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

    // Breadth-first over chosen deps until the tree is closed.
    // Queue + visiting hold OWNED dupes: map keys move on insert, so the
    // walk never borrows map-owned memory across a mutation.
    fn walk(self: *Tree, io: Io) !void {
        const gpa = self.gpa;
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

// An ESM-closure entry: manifest target + the exports key it came from
// (null = root entry: module field, root string/import). Both owned.
const Entry = struct {
    path: []u8,
    sub: ?[]u8,
};

// ESM-closure entries: manifest `exports.*.import` targets plus the
// top-level `module` field (ESM by convention). Only loadable-looking
// targets (.js/.mjs/.cjs/extensionless — see isLoadableTarget) qualify:
// data values like the "./package.json" self-reference must never route a
// package into the closure path with nothing copyable (that produced
// EmptyPackage for nanoid, which has zero import conditions and one
// self-reference). Subpath `default`-only entries are deliberately NOT
// collected.
fn isLoadableTarget(target: []const u8) bool {
    if (std.mem.endsWith(u8, target, ".js")) return true;
    if (std.mem.endsWith(u8, target, ".mjs")) return true;
    if (std.mem.endsWith(u8, target, ".cjs")) return true;
    const base = std.fs.path.basename(target);
    return std.mem.indexOfScalar(u8, base, '.') == null;
}

fn collectImportEntries(io: Io, gpa: Alloc, stage: []const u8) !std.ArrayList(Entry) {
    var out = std.ArrayList(Entry).empty;
    errdefer {
        for (out.items) |e| {
            gpa.free(e.path);
            if (e.sub) |s| gpa.free(s);
        }
        out.deinit(gpa);
    }
    const dir = Io.Dir.cwd();
    const pj_path = try std.fmt.allocPrint(gpa, "{s}/package.json", .{stage});
    defer gpa.free(pj_path);
    const pj_src = dir.readFileAlloc(io, pj_path, gpa, .limited(1024 * 1024)) catch return out;
    defer gpa.free(pj_src);
    const pj = std.json.parseFromSlice(std.json.Value, gpa, pj_src, .{}) catch return out;
    defer pj.deinit();
    if (pj.value != .object) return out;
    if (pj.value.object.get("module")) |m| {
        if (m == .string and isLoadableTarget(m.string)) {
            try out.append(gpa, .{ .path = try gpa.dupe(u8, m.string), .sub = null });
        }
    }
    const ex = pj.value.object.get("exports") orelse return out;
    if (ex == .string) {
        if (isLoadableTarget(ex.string)) try out.append(gpa, .{ .path = try gpa.dupe(u8, ex.string), .sub = null });
        return out;
    }
    if (ex != .object) return out;
    var it = ex.object.iterator();
    while (it.next()) |kv| {
        if (std.mem.eql(u8, kv.key_ptr.*, "./package.json")) continue; // manifest self-reference, never code
        if (std.mem.indexOfScalar(u8, kv.key_ptr.*, '*') != null) {
            std.debug.print("  note: skip wildcard export {s} (v1)\n", .{kv.key_ptr.*});
            continue;
        }
        const v = kv.value_ptr.*;
        const is_root = std.mem.eql(u8, kv.key_ptr.*, ".");
        if (v == .string) {
            if (!isLoadableTarget(v.string)) continue;
            try out.append(gpa, .{
                .path = try gpa.dupe(u8, v.string),
                .sub = if (is_root) null else try gpa.dupe(u8, kv.key_ptr.*),
            });
        } else if (v == .object) {
            if (v.object.get("import")) |imp| {
                if (imp == .string and isLoadableTarget(imp.string)) {
                    try out.append(gpa, .{
                        .path = try gpa.dupe(u8, imp.string),
                        .sub = if (is_root) null else try gpa.dupe(u8, kv.key_ptr.*),
                    });
                }
            }
        }
    }
    return out;
}

fn containsStr(list: []const []const u8, s: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, s)) return true;
    }
    return false;
}

// Lexically join a relative target onto a base file's directory.
// ("dist/sub/a.mjs" + "../b" -> "dist/b"). Escape above root -> BadImport.
fn joinRelPaths(gpa: Alloc, base_file: []const u8, target: []const u8) ![]u8 {
    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(gpa);
    if (std.fs.path.dirname(base_file)) |bd| {
        var bit = std.mem.splitScalar(u8, bd, '/');
        while (bit.next()) |p| {
            if (p.len == 0 or std.mem.eql(u8, p, ".")) continue;
            try parts.append(gpa, p);
        }
    }
    var tit = std.mem.splitScalar(u8, target, '/');
    while (tit.next()) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, ".")) continue;
        if (std.mem.eql(u8, p, "..")) {
            if (parts.items.len == 0) return error.BadImport;
            _ = parts.pop();
            continue;
        }
        try parts.append(gpa, p);
    }
    var total: usize = 0;
    for (parts.items, 0..) |p, i| {
        total += p.len;
        if (i + 1 < parts.items.len) total += 1;
    }
    if (total == 0) return error.BadImport;
    const out = try gpa.alloc(u8, total);
    errdefer gpa.free(out);
    var o: usize = 0;
    for (parts.items, 0..) |p, i| {
        @memcpy(out[o..][0..p.len], p);
        o += p.len;
        if (i + 1 < parts.items.len) {
            out[o] = '/';
            o += 1;
        }
    }
    return out;
}

fn isRelativeSpec(spec: []const u8) bool {
    return std.mem.startsWith(u8, spec, "./") or std.mem.startsWith(u8, spec, "../");
}

fn isIdChar(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_' or ch == '$';
}

fn matchWord(buf: []const u8, i: usize, w: []const u8) bool {
    if (i + w.len > buf.len) return false;
    if (!std.mem.eql(u8, buf[i..][0..w.len], w)) return false;
    if (i > 0 and (isIdChar(buf[i - 1]) or buf[i - 1] == '.')) return false;
    if (i + w.len < buf.len and isIdChar(buf[i + w.len])) return false;
    return true;
}

fn skipWs(buf: []const u8, i: usize) usize {
    var j = i;
    while (j < buf.len and (buf[j] == ' ' or buf[j] == '\t' or buf[j] == '\n' or buf[j] == '\r')) : (j += 1) {}
    return j;
}

fn readQuoted(src: []const u8, i: usize) ?struct { text: []const u8, end: usize } {
    if (i >= src.len) return null;
    const q = src[i];
    if (q != '"' and q != '\'') return null;
    var j = i + 1;
    while (j < src.len) {
        if (src[j] == '\\') {
            j += 2;
            continue;
        }
        if (src[j] == q) return .{ .text = src[i + 1 .. j], .end = j + 1 };
        j += 1;
    }
    return null;
}

fn skipQuoted(src: []const u8, i: usize) usize {
    if (readQuoted(src, i)) |r| return r.end;
    return src.len;
}

fn skipTemplate(src: []const u8, i: usize) usize {
    // src[i] == '`'. Tracks ${} depth + quotes inside expressions.
    // Limitation: nested template literals confuse depth counting, and regex
    // literals with quote-adjacent `from` text mis-scan. Either failure mode
    // is loud (MissingImport naming the path, or a runtime load error for a
    // missed dep) — never a silent hole. A `from` directly preceded by '.'
    // (method call like obj.from("x")) is rejected by matchWord's guard.
    var j = i + 1;
    var depth: usize = 0;
    var q: u8 = 0;
    while (j < src.len) {
        const ch = src[j];
        if (q != 0) {
            if (ch == '\\') {
                j += 2;
                continue;
            }
            if (ch == q) q = 0;
            j += 1;
            continue;
        }
        if (ch == '\\') {
            j += 2;
            continue;
        }
        if (ch == '`' and depth == 0) return j + 1;
        if ((ch == '"' or ch == '\'') and depth > 0) {
            q = ch;
            j += 1;
            continue;
        }
        if (ch == '$' and j + 1 < src.len and src[j + 1] == '{') {
            depth += 1;
            j += 2;
            continue;
        }
        if (ch == '{' and depth > 0) {
            depth += 1;
            j += 1;
            continue;
        }
        if (ch == '}' and depth > 0) {
            depth -= 1;
            j += 1;
            continue;
        }
        j += 1;
    }
    return src.len;
}

// Single-pass import scanner: code state only (comments, strings and
// template literals skipped). Recognizes `from "…"`, `import "…"`,
// `import("…")` and `export … from "…"` (via the from-keyword).
fn scanImports(gpa: Alloc, src: []const u8, out: *std.ArrayList([]u8)) !void {
    var i: usize = 0;
    const n = src.len;
    while (i < n) {
        const ch = src[i];
        if (ch == '/' and i + 1 < n and src[i + 1] == '/') {
            i += 2;
            while (i < n and src[i] != '\n') : (i += 1) {}
            continue;
        }
        if (ch == '/' and i + 1 < n and src[i + 1] == '*') {
            i += 2;
            while (i + 1 < n and !(src[i] == '*' and src[i + 1] == '/')) : (i += 1) {}
            i = @min(i + 2, n);
            continue;
        }
        if (ch == '\'' or ch == '"') {
            i = skipQuoted(src, i);
            continue;
        }
        if (ch == '`') {
            i = skipTemplate(src, i);
            continue;
        }
        const kw: ?[]const u8 = if (matchWord(src, i, "from"))
            "from"
        else if (matchWord(src, i, "import"))
            "import"
        else if (matchWord(src, i, "export"))
            "export"
        else
            null;
        if (kw) |k| {
            const j = skipWs(src, i + k.len);
            var advanced = false;
            if (j < n and src[j] == '(') {
                const k2 = skipWs(src, j + 1);
                if (k2 < n and (src[k2] == '"' or src[k2] == '\'')) {
                    if (readQuoted(src, k2)) |r| {
                        try out.append(gpa, try gpa.dupe(u8, r.text));
                        i = r.end;
                        advanced = true;
                    }
                }
            } else if (j < n and (src[j] == '"' or src[j] == '\'')) {
                if (readQuoted(src, j)) |r| {
                    try out.append(gpa, try gpa.dupe(u8, r.text));
                    i = r.end;
                    advanced = true;
                }
            }
            if (!advanced) i += k.len;
        } else {
            i += 1;
        }
    }
}

// Copy exactly the ESM closure: entry files + transitively imported
// relative files. Bare/absolute specifiers belong to other packages (or are
// unsupported) and are ignored here — the runtime resolver owns them.
// Unresolvable relative targets warn-and-skip (likely scanner edge);
// files that resolve but are missing FAIL LOUD (concrete broken package).
// `written`, when non-null, collects every dest path written (owned dupes)
// so a failed subpath walk can clean up after itself.
fn copyClosure(
    io: Io,
    gpa: Alloc,
    stage: []const u8,
    dest: []const u8,
    entries: []const []const u8,
    written: ?*std.ArrayList([]u8),
) !usize {
    const dir = Io.Dir.cwd();
    var total: usize = 0;
    var queue = std.ArrayList([]u8).empty;
    defer {
        for (queue.items) |q| gpa.free(q);
        queue.deinit(gpa);
    }
    var seen = std.ArrayList([]u8).empty;
    defer {
        for (seen.items) |s| gpa.free(s);
        seen.deinit(gpa);
    }
    for (entries) |e| try queue.append(gpa, try gpa.dupe(u8, e));
    var head: usize = 0;
    while (head < queue.items.len) {
        const rel = queue.items[head];
        head += 1;
        if (containsStr(seen.items, rel)) continue;
        try seen.append(gpa, try gpa.dupe(u8, rel));
        const clean = if (std.mem.startsWith(u8, rel, "./")) rel[2..] else rel;
        const suffixes = [_][]const u8{ "", ".js", ".mjs", "/index.js", "/index.mjs" };
        const found: struct {
            logical: []u8,
            bytes: []u8,
        } = blk: {
            for (suffixes) |sfx| {
                const cand = try std.fmt.allocPrint(gpa, "{s}{s}", .{ clean, sfx });
                const sp = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ stage, cand });
                defer gpa.free(sp);
                if (dir.readFileAlloc(io, sp, gpa, .limited(4 * 1024 * 1024))) |bytes| {
                    break :blk .{ .logical = cand, .bytes = bytes };
                } else |_| {
                    gpa.free(cand);
                }
            }
            std.debug.print("  missing file {s} (imported; failing loud)\n", .{clean});
            return error.MissingImport;
        };
        defer gpa.free(found.logical);
        defer gpa.free(found.bytes);
        if (!isJsFile(found.logical)) {
            // Data entries (e.g. a re-exported package.json): acknowledged,
            // not copied. package.json itself is always copied by installDist.
            std.debug.print("  note: skip non-JS entry {s}\n", .{found.logical});
            continue;
        }
        const dp = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dest, found.logical });
        defer gpa.free(dp);
        try gateSource(dp, found.bytes);
        if (std.fs.path.dirname(dp)) |parent| {
            dir.createDirPath(io, parent) catch {};
        }
        try dir.writeFile(io, .{ .sub_path = dp, .data = found.bytes });
        if (written) |w| try w.append(gpa, try gpa.dupe(u8, dp));
        total += 1;
        var specs = std.ArrayList([]u8).empty;
        defer {
            for (specs.items) |s| gpa.free(s);
            specs.deinit(gpa);
        }
        try scanImports(gpa, found.bytes, &specs);
        const base_dir = std.fs.path.dirname(found.logical);
        for (specs.items) |spec| {
            if (!isRelativeSpec(spec)) continue;
            const joined = joinRelPaths(gpa, base_dir orelse ".", spec) catch |err| {
                std.debug.print("  warning: cannot resolve {s} from {s}: {s}\n", .{ spec, found.logical, @errorName(err) });
                continue;
            };
            // Ownership to the queue; deduped at pop time via seen.
            errdefer gpa.free(joined);
            try queue.append(gpa, joined);
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
