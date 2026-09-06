const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const c = @cImport({
    @cInclude("stdio.h");
});

// ff sever [pkg[@ver] ...] [--force]
//   with names: remove named packages + pnpm-style prune of everything not
//     reachable from the remaining direct deps (orphans AND strays).
//   no names: confirm, then wipe node_modules, empty dependencies and lock.
// ff.json keeps all other fields; bad ff.json fails loud (InvalidManifest).
// A bad/missing lock never blocks removal: dir+ff.json proceed, lock skipped
// with a warning, next imprint regenerates v2.

pub fn run(io: Io, args: []const []const u8) !void {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var force = false;
    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(gpa);
    for (args) |a| {
        if (std.mem.eql(u8, a, "--force")) {
            force = true;
            continue;
        }
        try names.append(gpa, bareName(a));
    }
    if (names.items.len == 0) return severAll(io, gpa, force);
    return severMany(io, gpa, names.items);
}

// Scope-aware: split at LAST '@' past index 0 ("@scope/pkg@1.0" -> "@scope/pkg").
// Borrowed from args (process lifetime); version part ignored for removal.
fn bareName(arg: []const u8) []const u8 {
    var at: ?usize = null;
    var i: usize = 1;
    while (i < arg.len) : (i += 1) {
        if (arg[i] == '@') at = i;
    }
    if (at) |idx| return arg[0..idx];
    return arg;
}

fn severMany(io: Io, gpa: Alloc, names: []const []const u8) !void {
    const dir = Io.Dir.cwd();
    // Load ff.json (fail loud — never guess at manifest surgery).
    const ff_src = dir.readFileAlloc(io, "ff.json", gpa, .limited(1024 * 1024)) catch {
        std.debug.print("No ff.json found. Run 'ff init' first.\n", .{});
        return;
    };
    defer gpa.free(ff_src);
    const ff = try std.json.parseFromSlice(std.json.Value, gpa, ff_src, .{});
    defer ff.deinit();
    if (ff.value != .object) return error.InvalidManifest;
    // Rewrite root preserving every field except the removed dep keys.
    var root: std.json.Value = .{ .object = .{} };
    defer root.object.deinit(gpa);
    {
        var it = ff.value.object.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.key_ptr.*, "dependencies") and kv.value_ptr.* == .object) {
                var kept: std.json.ObjectMap = .{};
                var dit = kv.value_ptr.object.iterator();
                while (dit.next()) |dkv| {
                    if (isNamed(dkv.key_ptr.*, names)) continue;
                    try kept.put(gpa, try gpa.dupe(u8, dkv.key_ptr.*), try dupeValue(gpa, dkv.value_ptr.*));
                }
                try root.object.put(gpa, try gpa.dupe(u8, kv.key_ptr.*), .{ .object = kept });
            } else {
                try root.object.put(gpa, try gpa.dupe(u8, kv.key_ptr.*), try dupeValue(gpa, kv.value_ptr.*));
            }
        }
    }
    // Report misses before touching disk: warn, never abort the run.
    for (names) |n| {
        if (!hadDep(ff.value, n) and !dirExists(io, "node_modules", n)) {
            std.debug.print("  {s}: not installed\n", .{n});
        }
    }
    const out = try std.json.Stringify.valueAlloc(gpa, root, .{ .whitespace = .indent_2 });
    defer gpa.free(out);
    try dir.writeFile(io, .{ .sub_path = "ff.json.tmp", .data = out });
    try Io.Dir.cwd().rename("ff.json.tmp", Io.Dir.cwd(), "ff.json", io);
    // Prune: named packages + everything unreachable afterwards.
    try pruneTree(io, gpa, &root, names);
    std.debug.print("Done.\n", .{});
}

fn isNamed(key: []const u8, names: []const []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, key, n)) return true;
    }
    return false;
}

fn hadDep(manifest: std.json.Value, name: []const u8) bool {
    if (manifest != .object) return false;
    const d = manifest.object.get("dependencies") orelse return false;
    if (d != .object) return false;
    return d.object.get(name) != null;
}

fn dirExists(io: Io, parent: []const u8, name: []const u8) bool {
    var base = Io.Dir.cwd();
    var d = base.openDir(io, parent, .{ .iterate = true }) catch return false;
    defer d.close(io);
    var iter = d.iterate();
    while (iter.next(io) catch null) |e| {
        if (std.mem.eql(u8, e.name, name)) return true;
        // Scoped lookup: "node_modules" contains "@scope", not "@scope/pkg".
        if (e.name.len > 0 and e.name[0] == '@' and std.mem.startsWith(u8, name, e.name) and
            name.len > e.name.len and name[e.name.len] == '/')
        {
            return true;
        }
    }
    return false;
}

// pnpm-style strict prune: node_modules ends up containing EXACTLY the
// reachable set (orphaned transitives and strays are removed).
// Needs a usable v2 lock for the requires closure; without one, only the
// explicitly named packages are removed (deleting blind would nuke live
// transitives whose edges we cannot see).
fn pruneTree(io: Io, gpa: Alloc, root: *std.json.Value, removed: []const []const u8) !void {
    const dir = Io.Dir.cwd();
    var reachable = std.ArrayList([]u8).empty;
    defer {
        for (reachable.items) |r| gpa.free(r);
        reachable.deinit(gpa);
    }
    var have_lock = false;
    var lock: std.json.Parsed(std.json.Value) = undefined;
    if (dir.readFileAlloc(io, "ff.lock", gpa, .limited(4 * 1024 * 1024))) |lock_src| {
        defer gpa.free(lock_src);
        if (std.json.parseFromSlice(std.json.Value, gpa, lock_src, .{})) |p| {
            if (p.value == .object) {
                if (p.value.object.get("lockfileVersion")) |lv| {
                    if (lv == .integer and lv.integer == 1) {
                        if (p.value.object.get("packages")) |pkgs| {
                            if (pkgs == .object) {
                                lock = p;
                                have_lock = true;
                            } else {
                                p.deinit();
                            }
                        } else {
                            p.deinit();
                        }
                    } else {
                        p.deinit();
                    }
                } else {
                    p.deinit();
                }
            } else {
                // FIX: plain else (bool condition takes no payload) + deinit
                // the abandoned parse instead of leaking it.
                p.deinit();
            }
        } else |_| {}
    } else |_| {}
    defer if (have_lock) lock.deinit();
    if (!have_lock) {
        std.debug.print("  no usable ff.lock — removing named packages only (run ff imprint to regenerate the lock).\n", .{});
        for (removed) |n| removeEntry(io, n, true);
        return;
    }
    // Seed reachable with remaining direct deps, then close over requires.
    {
        const d = root.object.get("dependencies");
        if (d != null and d.? == .object) {
            var it = d.?.object.iterator();
            while (it.next()) |kv| try reachable.append(gpa, try gpa.dupe(u8, kv.key_ptr.*));
        }
    }
    const pkgs = lock.value.object.get("packages").?.object;
    var head: usize = 0;
    while (head < reachable.items.len) {
        const name = reachable.items[head];
        head += 1;
        const key = std.fmt.allocPrint(gpa, "node_modules/{s}", .{name}) catch continue;
        defer gpa.free(key);
        const e = pkgs.get(key) orelse continue;
        if (e != .object) continue;
        const req = e.object.get("requires") orelse continue;
        if (req != .object) continue;
        var rit = req.object.iterator();
        while (rit.next()) |kv| {
            if (containsName(reachable.items, kv.key_ptr.*)) continue;
            reachable.append(gpa, gpa.dupe(u8, kv.key_ptr.*) catch continue) catch continue;
        }
    }
    // Delete everything not reachable (explicit removals land here too,
    // since they are absent from reachable — one code path, no special case).
    var nm = dir.openDir(io, "node_modules", .{ .iterate = true }) catch {
        // Nothing installed at all — still rewrite the lock below for hygiene.
        try rewriteLock(io, gpa, &lock.value, reachable.items);
        return;
    };
    defer nm.close(io);
    var iter = nm.iterate();
    while (iter.next(io) catch null) |e| {
        if (e.name.len > 0 and e.name[0] == '@' and e.kind == .directory) {
            pruneScope(io, gpa, e.name, reachable.items);
            continue;
        }
        if (e.kind != .directory) {
            // Stray file at top level (we never write any) — pnpm-strict removes it.
            if (!containsName(reachable.items, e.name)) {
                const p = std.fmt.allocPrint(gpa, "node_modules/{s}", .{e.name}) catch continue;
                defer gpa.free(p);
                dir.deleteFile(io, p) catch {
                    std.debug.print("  warning: could not remove stray file {s}\n", .{p});
                    continue;
                };
                std.debug.print("  stray {s} removed\n", .{e.name});
            }
            continue;
        }
        if (!containsName(reachable.items, e.name)) {
            removeEntry(io, e.name, isExplicit(e.name, removed));
        }
    }
    try rewriteLock(io, gpa, &lock.value, reachable.items);
}

fn containsName(list: []const []u8, name: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, name)) return true;
    }
    return false;
}

fn isExplicit(name: []const u8, removed: []const []const u8) bool {
    return isNamed(name, removed);
}

// removeEntry deletes node_modules/<name>; explicit ones print "severed",
// orphans print "pruned". Failures warn and continue — removal proceeds.
fn removeEntry(io: Io, name: []const u8, explicit: bool) void {
    const dir = Io.Dir.cwd();
    var buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "node_modules/{s}", .{name}) catch {
        std.debug.print("  warning: name too long, skipped {s}\n", .{name});
        return;
    };
    dir.deleteTree(io, path) catch {
        dir.deleteFile(io, path) catch {
            std.debug.print("  warning: could not remove {s}\n", .{path});
            return;
        };
    };
    // Best-effort empty-scope cleanup: "@scope/pkg" gone -> drop "@scope" if empty.
    if (std.mem.indexOfScalar(u8, name, '/')) |i| {
        if (name[0] == '@') {
            dir.deleteDir(io, path[0 .. "node_modules/".len + i]) catch {};
        }
    }
    if (explicit) {
        std.debug.print("  severed {s}\n", .{name});
    } else {
        std.debug.print("  pruned {s} (orphaned)\n", .{name});
    }
}

fn pruneScope(io: Io, gpa: Alloc, scope: []const u8, reachable: []const []u8) void {
    const dir = Io.Dir.cwd();
    const scope_path = std.fmt.allocPrint(gpa, "node_modules/{s}", .{scope}) catch return;
    defer gpa.free(scope_path);
    var d = dir.openDir(io, scope_path, .{ .iterate = true }) catch return;
    defer d.close(io);
    var iter = d.iterate();
    while (iter.next(io) catch null) |e| {
        if (e.kind != .directory) continue;
        const full = std.fmt.allocPrint(gpa, "{s}/{s}", .{ scope, e.name }) catch continue;
        defer gpa.free(full);
        if (!containsName(reachable, full)) removeEntry(io, full, false);
    }
    dir.deleteDir(io, scope_path) catch {}; // survives iff non-empty
}

// Lock rewrite keeps name/version/lockfileVersion and only reachable entries.
fn rewriteLock(io: Io, gpa: Alloc, lock_val: *std.json.Value, reachable: []const []u8) !void {
    const dir = Io.Dir.cwd();
    var root: std.json.Value = .{ .object = .{} };
    defer root.object.deinit(gpa);
    const old_pkgs = if (lock_val.object.get("packages")) |p| (if (p == .object) &p.object else null) else null;
    var it = lock_val.object.iterator();
    while (it.next()) |kv| {
        if (std.mem.eql(u8, kv.key_ptr.*, "packages")) continue;
        try root.object.put(gpa, try gpa.dupe(u8, kv.key_ptr.*), try dupeValue(gpa, kv.value_ptr.*));
    }
    var pkgs: std.json.ObjectMap = .{};
    if (old_pkgs) |op| {
        var oit = op.iterator();
        while (oit.next()) |kv| {
            const key = kv.key_ptr.*;
            const prefix = "node_modules/";
            if (!std.mem.startsWith(u8, key, prefix)) continue;
            if (!containsName(reachable, key[prefix.len..])) continue;
            try pkgs.put(gpa, try gpa.dupe(u8, key), try dupeValue(gpa, kv.value_ptr.*));
        }
    }
    try root.object.put(gpa, try gpa.dupe(u8, "packages"), .{ .object = pkgs });
    const out = try std.json.Stringify.valueAlloc(gpa, root, .{ .whitespace = .indent_2 });
    defer gpa.free(out);
    try dir.writeFile(io, .{ .sub_path = "ff.lock.tmp", .data = out });
    try Io.Dir.cwd().rename("ff.lock.tmp", Io.Dir.cwd(), "ff.lock", io);
}

fn severAll(io: Io, gpa: Alloc, force: bool) !void {
    const dir = Io.Dir.cwd();
    // Inventory for the summary (missing pieces are fine, not errors).
    var installed = std.ArrayList([]u8).empty;
    defer {
        for (installed.items) |n| gpa.free(n);
        installed.deinit(gpa);
    }
    if (dir.openDir(io, "node_modules", .{ .iterate = true })) |*d| {
        defer d.close(io);
        var iter = d.iterate();
        while (iter.next(io) catch null) |e| {
            if (e.kind != .directory) continue;
            if (e.name.len > 0 and e.name[0] == '@') {
                const scope_path = std.fmt.allocPrint(gpa, "node_modules/{s}", .{e.name}) catch continue;
                defer gpa.free(scope_path);
                var sd = dir.openDir(io, scope_path, .{ .iterate = true }) catch continue;
                defer sd.close(io);
                var sit = sd.iterate();
                while (sit.next(io) catch null) |se| {
                    if (se.kind != .directory) continue;
                    const full = std.fmt.allocPrint(gpa, "{s}/{s}", .{ e.name, se.name }) catch continue;
                    installed.append(gpa, full) catch {
                        gpa.free(full);
                        continue;
                    };
                }
                continue;
            }
            installed.append(gpa, gpa.dupe(u8, e.name) catch continue) catch continue;
        }
    } else |_| {}
    var dep_count: usize = 0;
    if (dir.readFileAlloc(io, "ff.json", gpa, .limited(1024 * 1024))) |ff_src| {
        defer gpa.free(ff_src);
        if (std.json.parseFromSlice(std.json.Value, gpa, ff_src, .{})) |p| {
            defer p.deinit();
            if (p.value == .object) {
                if (p.value.object.get("dependencies")) |d| {
                    if (d == .object) dep_count = d.object.count();
                }
            }
        } else |_| {}
    } else |_| {}
    if (installed.items.len == 0 and dep_count == 0) {
        std.debug.print("Nothing to sever: node_modules is absent and dependencies are empty.\n", .{});
        return;
    }
    if (!force and !promptYesNo(gpa, installed.items.len, dep_count)) return;
    dir.deleteTree(io, "node_modules") catch |err| {
        if (err != error.FileNotFound and err != error.NotDir) {
            std.debug.print("  warning: node_modules removal: {s}\n", .{@errorName(err)});
        }
    };
    // ff.json: preserve everything, empty only dependencies (fail loud if bad).
    if (dir.readFileAlloc(io, "ff.json", gpa, .limited(1024 * 1024))) |ff_src| {
        defer gpa.free(ff_src);
        const p = std.json.parseFromSlice(std.json.Value, gpa, ff_src, .{}) catch {
            std.debug.print("ff.json is not valid JSON — refusing to overwrite it. Fix or delete it first.\n", .{});
            return error.InvalidManifest;
        };
        defer p.deinit();
        if (p.value != .object) return error.InvalidManifest;
        var root: std.json.Value = .{ .object = .{} };
        defer root.object.deinit(gpa);
        var it = p.value.object.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.key_ptr.*, "dependencies")) {
                try root.object.put(gpa, try gpa.dupe(u8, kv.key_ptr.*), .{ .object = .{} });
            } else {
                try root.object.put(gpa, try gpa.dupe(u8, kv.key_ptr.*), try dupeValue(gpa, kv.value_ptr.*));
            }
        }
        const out = try std.json.Stringify.valueAlloc(gpa, root, .{ .whitespace = .indent_2 });
        defer gpa.free(out);
        try dir.writeFile(io, .{ .sub_path = "ff.json.tmp", .data = out });
        try Io.Dir.cwd().rename("ff.json.tmp", Io.Dir.cwd(), "ff.json", io);
    } else |_| {}
    // Lock: fresh empty v2 skeleton (name/version preserved when readable).
    {
        var lname: []const u8 = "my-app";
        var lver: []const u8 = "0.0.1";
        var ldoc: ?std.json.Parsed(std.json.Value) = null;
        if (dir.readFileAlloc(io, "ff.lock", gpa, .limited(4 * 1024 * 1024))) |lsrc| {
            defer gpa.free(lsrc);
            if (std.json.parseFromSlice(std.json.Value, gpa, lsrc, .{})) |p| {
                ldoc = p;
                if (p.value == .object) {
                    if (p.value.object.get("name")) |n| {
                        if (n == .string) lname = n.string;
                    }
                    if (p.value.object.get("version")) |v| {
                        if (v == .string) lver = v.string;
                    }
                }
            } else |_| {}
        } else |_| {}
        defer if (ldoc) |*p| p.deinit();
        var root: std.json.Value = .{ .object = .{} };
        defer root.object.deinit(gpa);
        try root.object.put(gpa, try gpa.dupe(u8, "name"), .{ .string = try gpa.dupe(u8, lname) });
        try root.object.put(gpa, try gpa.dupe(u8, "version"), .{ .string = try gpa.dupe(u8, lver) });
        try root.object.put(gpa, try gpa.dupe(u8, "lockfileVersion"), .{ .integer = 1 });
        try root.object.put(gpa, try gpa.dupe(u8, "packages"), .{ .object = .{} });
        const out = try std.json.Stringify.valueAlloc(gpa, root, .{ .whitespace = .indent_2 });
        defer gpa.free(out);
        try dir.writeFile(io, .{ .sub_path = "ff.lock.tmp", .data = out });
        try Io.Dir.cwd().rename("ff.lock.tmp", Io.Dir.cwd(), "ff.lock", io);
    }
    for (installed.items) |n| std.debug.print("  severed {s}\n", .{n});
    if (dep_count > 0) std.debug.print("  dependencies cleared ({d})\n", .{dep_count});
}

// y/N prompt, default No. EOF and empty input mean No.
// Reads via libc fgets (same stdio import as resolver.zig) to avoid
// unverified std.Io stdin-reader spellings.
fn promptYesNo(gpa: Alloc, n_pkgs: usize, n_deps: usize) bool {
    _ = gpa;
    std.debug.print("Remove all {d} installed packages and clear {d} dependencies? [y/N] ", .{ n_pkgs, n_deps });
    var ans: [16]u8 = undefined;
    // PORTABLE FIX: glibc/host translate-c exposes stdin as fn () -> FILE*,
    // musl translate-c exposes it as a global FILE* variable.
    // Branch on the translated type so both targets compile.
    const stdin_stream = if (@typeInfo(@TypeOf(c.stdin)) == .@"fn") c.stdin() else c.stdin;
    const line = c.fgets(@ptrCast(&ans), ans.len, stdin_stream) orelse return false;
    const len = std.mem.len(line);
    if (len == 0) return false;
    const ch = ans[0];
    return ch == 'y' or ch == 'Y';
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
