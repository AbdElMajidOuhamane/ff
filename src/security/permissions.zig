//! Permission policy for native APIs.
//!
//! Parsed once from `--allow-*` before any JS runtime exists, then immutable
//! for the process lifetime. Worker threads inherit the same policy.
//!
//! Hot-path contract:
//!   .denied / .all  -> no allocation, no syscall
//!   .scoped         -> stack buffers only; overflow = deny (fail closed)

const std = @import("std");

const gpa = std.heap.page_allocator;
const max_path = std.fs.max_path_bytes;
const Io = std.Io;

pub const Kind = enum { read, write, net, env, run, ffi };
pub const Decision = enum { allowed, denied };

const PathScope = struct { path: []const u8 };
const NetScope = struct { host: []const u8, port: ?u16 = null, wildcard: bool = false };
const NameScope = struct { name: []const u8 };

const PathRule = union(enum) { denied, all, scoped: []const PathScope };
const NetRule = union(enum) { denied, all, scoped: []const NetScope };
const NameRule = union(enum) { denied, all, scoped: []const NameScope };

fn getIo() Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const Config = struct {
    read: PathRule = .denied,
    write: PathRule = .denied,
    net: NetRule = .denied,
    env: NameRule = .denied,
    run: NameRule = .denied,
    ffi: bool = false,

    pub fn isAllowed(self: *const Config, kind: Kind) bool {
        return switch (kind) {
            .read => switch (self.read) {
                .denied => false,
                else => true,
            },
            .write => switch (self.write) {
                .denied => false,
                else => true,
            },
            .net => switch (self.net) {
                .denied => false,
                else => true,
            },
            .env => switch (self.env) {
                .denied => false,
                else => true,
            },
            .run => switch (self.run) {
                .denied => false,
                else => true,
            },
            .ffi => self.ffi,
        };
    }

    pub fn checkPath(self: *const Config, kind: Kind, path: []const u8) Decision {
        const rule = switch (kind) {
            .read => self.read,
            .write => self.write,
            else => return .denied,
        };
        switch (rule) {
            .denied => return .denied,
            .all => return .allowed,
            .scoped => |scopes| {
                if (path.len == 0 or path.len >= max_path) return .denied;
                if (std.mem.indexOfScalar(u8, path, 0) != null) return .denied;

                var canon_buf: [max_path]u8 = undefined;
                const canon = canonicalizeInput(path, &canon_buf) catch return .denied;

                for (scopes) |scope| {
                    if (isWithin(scope.path, canon)) return .allowed;
                }
                return .denied;
            },
        }
    }

    pub fn checkNet(self: *const Config, host_in: []const u8, port: u16) Decision {
        switch (self.net) {
            .denied => return .denied,
            .all => return .allowed,
            .scoped => |scopes| {
                if (host_in.len == 0 or host_in.len > 255) return .denied;
                if (std.mem.indexOfScalar(u8, host_in, 0) != null) return .denied;

                var buf: [256]u8 = undefined;
                const host = lowerInto(host_in, &buf);

                for (scopes) |scope| {
                    if (scope.wildcard and scope.host.len == 0) return .allowed;
                    if (scope.port) |p| {
                        if (p != port) continue;
                    }
                    if (scope.wildcard) {
                        if (host.len > scope.host.len + 1 and
                            std.mem.endsWith(u8, host, scope.host) and
                            host[host.len - scope.host.len - 1] == '.')
                            return .allowed;
                    } else if (std.mem.eql(u8, host, scope.host)) {
                        return .allowed;
                    }
                }
                return .denied;
            },
        }
    }

    pub fn checkEnv(self: *const Config, name: []const u8) bool {
        switch (self.env) {
            .denied => return false,
            .all => return true,
            .scoped => |scopes| {
                for (scopes) |scope| {
                    if (std.mem.eql(u8, scope.name, name)) return true;
                }
                return false;
            },
        }
    }

    pub fn checkRun(self: *const Config, program: []const u8) Decision {
        switch (self.run) {
            .denied => return .denied,
            .all => return .allowed,
            .scoped => |scopes| {
                if (program.len == 0 or program.len >= max_path) return .denied;
                if (std.mem.indexOfScalar(u8, program, 0) != null) return .denied;

                const base = std.fs.path.basename(program);
                for (scopes) |scope| {
                    if (std.mem.indexOfScalar(u8, scope.name, '/') == null) {
                        // Bare name: matches the basename of the invocation.
                        if (std.mem.eql(u8, scope.name, base)) return .allowed;
                    } else {
                        // Absolute scope: only match an explicit path.
                        if (std.mem.indexOfScalar(u8, program, '/') == null) continue;
                        var canon_buf: [max_path]u8 = undefined;
                        const canon = canonicalizeInput(program, &canon_buf) catch continue;
                        if (isWithin(scope.name, canon)) return .allowed;
                    }
                }
                return .denied;
            },
        }
    }
    pub fn ffiAllowed(self: *const Config) bool {
        return self.ffi;
    }

    /// Cold path. All returned memory is owned by `alloc` (use an arena).
    pub fn parse(alloc: std.mem.Allocator, args: []const []const u8) !Config {
        var read_list: std.ArrayList(PathScope) = .empty;
        defer read_list.deinit(alloc);
        var write_list: std.ArrayList(PathScope) = .empty;
        defer write_list.deinit(alloc);
        var net_list: std.ArrayList(NetScope) = .empty;
        defer net_list.deinit(alloc);
        var env_list: std.ArrayList(NameScope) = .empty;
        defer env_list.deinit(alloc);
        var run_list: std.ArrayList(NameScope) = .empty;
        defer run_list.deinit(alloc);

        var all = false;
        var read_all = false;
        var write_all = false;
        var net_all = false;
        var env_all = false;
        var run_all = false;
        var ffi = false;

        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--allow-all")) {
                all = true;
                continue;
            }
            if (!std.mem.startsWith(u8, arg, "--allow-")) {
                if (std.mem.startsWith(u8, arg, "--deny-"))
                    return error.UnknownPermissionFlag;
                continue;
            }

            const rest = arg["--allow-".len..];
            const eq = std.mem.indexOfScalar(u8, rest, '=');
            const name = rest[0 .. eq orelse rest.len];
            const value: ?[]const u8 = if (eq) |i| rest[i + 1 ..] else null;
            const kind = kindFromName(name) orelse return error.UnknownPermissionFlag;

            if (kind == .ffi) {
                if (value != null) return error.InvalidScope;
                ffi = true;
                continue;
            }

            if (value == null) {
                switch (kind) {
                    .read => read_all = true,
                    .write => write_all = true,
                    .net => net_all = true,
                    .env => env_all = true,
                    .run => run_all = true,
                    .ffi => unreachable,
                }
                continue;
            }

            const v = value.?;
            if (v.len == 0) return error.InvalidScope;
            var it = std.mem.splitScalar(u8, v, ',');
            while (it.next()) |item| {
                if (item.len == 0) return error.InvalidScope;
                switch (kind) {
                    .read, .write => {
                        var path_buf: [max_path]u8 = undefined;
                        const canon = canonicalizeInput(item, &path_buf) catch return error.InvalidScope;
                        const stored = try alloc.dupe(u8, canon);
                        if (kind == .read) {
                            try read_list.append(alloc, .{ .path = stored });
                        } else {
                            try write_list.append(alloc, .{ .path = stored });
                        }
                    },
                    .net => try net_list.append(alloc, try parseNetScope(alloc, item)),
                    .env => {
                        try validateName(item);
                        try env_list.append(alloc, .{ .name = try alloc.dupe(u8, item) });
                    },
                    .run => {
                        if (std.mem.indexOfScalar(u8, item, '/') == null) {
                            try validateName(item);
                            try run_list.append(alloc, .{ .name = try alloc.dupe(u8, item) });
                        } else {
                            var path_buf: [max_path]u8 = undefined;
                            const canon = canonicalizeInput(item, &path_buf) catch return error.InvalidScope;
                            try run_list.append(alloc, .{ .name = try alloc.dupe(u8, canon) });
                        }
                    },
                    .ffi => unreachable,
                }
            }
        }

        if (all) {
            return .{
                .read = .all,
                .write = .all,
                .net = .all,
                .env = .all,
                .run = .all,
                .ffi = true,
            };
        }

        var cfg = Config{ .ffi = ffi };
        if (read_all) {
            cfg.read = .all;
        } else if (read_list.items.len > 0) {
            cfg.read = .{ .scoped = try read_list.toOwnedSlice(alloc) };
        }
        if (write_all) {
            cfg.write = .all;
        } else if (write_list.items.len > 0) {
            cfg.write = .{ .scoped = try write_list.toOwnedSlice(alloc) };
        }
        if (net_all) {
            cfg.net = .all;
        } else if (net_list.items.len > 0) {
            cfg.net = .{ .scoped = try net_list.toOwnedSlice(alloc) };
        }
        if (env_all) {
            cfg.env = .all;
        } else if (env_list.items.len > 0) {
            cfg.env = .{ .scoped = try env_list.toOwnedSlice(alloc) };
        }
        if (run_all) {
            cfg.run = .all;
        } else if (run_list.items.len > 0) {
            cfg.run = .{ .scoped = try run_list.toOwnedSlice(alloc) };
        }
        return cfg;
    }
};

var arena_state: std.heap.ArenaAllocator = undefined;
var initialized = false;
var current: Config = .{};

var cwd_buf: [max_path]u8 = undefined;
var cwd_len: usize = 0;
var cwd_valid = false;

/// Refresh the cached working directory after `process.chdir`.
pub fn refreshCwd() void {
    const n = std.process.currentPath(getIo(), &cwd_buf) catch {
        cwd_valid = false;
        return;
    };
    cwd_len = n;
    cwd_valid = true;
}

fn currentCwd() ![]const u8 {
    if (!cwd_valid) refreshCwd();
    if (!cwd_valid) return error.CurrentDirUnlinked;
    return cwd_buf[0..cwd_len];
}

pub fn initFromArgs(args: std.process.Args) !void {
    if (initialized) return;
    arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer _ = arena_state.deinit();
    const alloc = arena_state.allocator();

    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(alloc);
    var it = args.iterate();
    while (it.next()) |a| try list.append(alloc, a);

    current = try Config.parse(alloc, list.items);
    initialized = true;
}

pub fn global() *const Config {
    return &current;
}

pub fn isPermissionFlag(arg: []const u8) bool {
    if (std.mem.eql(u8, arg, "--allow-all") or std.mem.eql(u8, arg, "--allow-ffi"))
        return true;
    if (!std.mem.startsWith(u8, arg, "--allow-")) return false;
    const rest = arg["--allow-".len..];
    const name = rest[0 .. std.mem.indexOfScalar(u8, rest, '=') orelse rest.len];
    return kindFromName(name) != null;
}

fn kindFromName(name: []const u8) ?Kind {
    if (std.mem.eql(u8, name, "read")) return .read;
    if (std.mem.eql(u8, name, "write")) return .write;
    if (std.mem.eql(u8, name, "net")) return .net;
    if (std.mem.eql(u8, name, "env")) return .env;
    if (std.mem.eql(u8, name, "run")) return .run;
    if (std.mem.eql(u8, name, "ffi")) return .ffi;
    return null;
}

fn validateName(name: []const u8) !void {
    if (name.len == 0) return error.InvalidScope;
    for (name) |ch| {
        if (ch == 0 or ch == '=') return error.InvalidScope;
    }
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return false;
    }
    return true;
}

fn lowerInto(input: []const u8, out: []u8) []const u8 {
    const n = @min(input.len, out.len);
    for (input[0..n], 0..) |ch, i| out[i] = std.ascii.toLower(ch);
    return out[0..n];
}

fn parseNetScope(alloc: std.mem.Allocator, raw: []const u8) !NetScope {
    if (raw.len == 0 or raw.len > 255) return error.InvalidScope;
    if (std.mem.indexOfScalar(u8, raw, 0) != null) return error.InvalidScope;

    var host: []const u8 = raw;
    var port: ?u16 = null;

    if (raw[0] == '[') {
        const end = std.mem.indexOfScalar(u8, raw, ']') orelse return error.InvalidScope;
        host = raw[1..end];
        if (end + 1 < raw.len) {
            if (raw[end + 1] != ':') return error.InvalidScope;
            if (end + 2 >= raw.len) return error.InvalidScope;
            port = std.fmt.parseInt(u16, raw[end + 2 ..], 10) catch return error.InvalidScope;
        }
    } else if (std.mem.count(u8, raw, ":") == 1) {
        const ci = std.mem.indexOfScalar(u8, raw, ':').?;
        if (ci + 1 < raw.len and allDigits(raw[ci + 1 ..])) {
            host = raw[0..ci];
            port = std.fmt.parseInt(u16, raw[ci + 1 ..], 10) catch return error.InvalidScope;
        }
    }

    if (host.len == 0) return error.InvalidScope;
    var wildcard = false;
    if (std.mem.eql(u8, host, "*")) {
        wildcard = true;
        host = "";
    } else if (std.mem.startsWith(u8, host, "*.")) {
        wildcard = true;
        host = host[2..];
    }

    const stored = try alloc.alloc(u8, host.len);
    for (host, 0..) |ch, i| stored[i] = std.ascii.toLower(ch);
    return .{ .host = stored, .port = port, .wildcard = wildcard };
}

/// Absolute + symlink-canonical for the existing prefix, lexically appended
/// for the not-yet-existing suffix. Stack-only.
fn canonicalizeInput(path: []const u8, out: []u8) ![]const u8 {
    const cwd = currentCwd() catch return error.CurrentDirUnlinked;

    var resolve_buf: [2 * max_path]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&resolve_buf);
    const abs = std.fs.path.resolve(fba.allocator(), &.{ cwd, path }) catch
        return error.PathTooLong;

    return canonicalizeLenient(abs, out);
}

fn canonicalizeLenient(abs_in: []const u8, out: []u8) ![]const u8 {
    if (abs_in.len == 0 or abs_in.len >= out.len) return error.PathTooLong;
    if (!std.fs.path.isAbsolute(abs_in)) return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, abs_in, 0) != null) return error.InvalidPath;

    var end = abs_in.len;
    while (end > 1 and abs_in[end - 1] == '/') end -= 1;
    const abs = abs_in[0..end];

    var cut = abs.len;
    while (true) {
        if (std.Io.Dir.cwd().realPathFile(getIo(), abs[0..cut], out)) |n| {
            if (cut == abs.len) return out[0..n];

            // `realPathFile` failed for the full path, so any symlink in the
            // not-yet-existing suffix is dangling or points at a non-directory.
            // Appending it lexically and letting the OS follow it would escape
            // the scope. Inspect only the first missing component: nothing
            // deeper can exist under a missing parent.
            const first_end = std.mem.indexOfScalarPos(u8, abs, cut + 1, '/') orelse abs.len;
            var link_buf: [max_path]u8 = undefined;
            if (std.Io.Dir.cwd().readLink(getIo(), abs[0..first_end], &link_buf)) |_| {
                return error.SymLinkLoop;
            } else |link_err| switch (link_err) {
                error.NotLink, error.FileNotFound, error.NotDir => {},
                else => return link_err,
            }

            const suffix = abs[cut..];
            if (n + suffix.len >= out.len) return error.PathTooLong;
            if (n == 1 and suffix.len > 0 and suffix[0] == '/') {
                @memcpy(out[1..][0 .. suffix.len - 1], suffix[1..]);
                return out[0 .. n + suffix.len - 1];
            }
            @memcpy(out[n..][0..suffix.len], suffix);
            return out[0 .. n + suffix.len];
        } else |err| switch (err) {
            error.FileNotFound, error.NotDir => {},
            else => return err,
        }

        if (cut == 1) return error.InvalidPath;
        const slash = std.mem.lastIndexOfScalar(u8, abs[0..cut], '/') orelse
            return error.InvalidPath;
        cut = if (slash == 0) 1 else slash;
    }
}

fn isWithin(root: []const u8, target: []const u8) bool {
    if (std.mem.eql(u8, root, target)) return true;
    if (std.mem.eql(u8, root, "/")) return std.fs.path.isAbsolute(target);
    if (!std.mem.startsWith(u8, target, root)) return false;
    return target.len > root.len and target[root.len] == '/';
}

// ── tests ───────────────────────────────────────────────────────────

test "path scope is component-exact and blocks traversal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [max_path]u8 = undefined;
    const root_len = try tmp.dir.realPath(getIo(), &path_buf);
    const root = path_buf[0..root_len];

    const arg = try std.fmt.allocPrint(alloc, "--allow-read={s}", .{root});
    const cfg = try Config.parse(alloc, &.{arg});

    const inside = try std.fmt.allocPrint(alloc, "{s}/nested/file.txt", .{root});
    const sibling = try std.fmt.allocPrint(alloc, "{s}x", .{root});
    const escape = try std.fmt.allocPrint(alloc, "{s}/../escape.txt", .{root});

    try std.testing.expectEqual(Decision.allowed, cfg.checkPath(.read, inside));
    try std.testing.expectEqual(Decision.denied, cfg.checkPath(.read, sibling));
    try std.testing.expectEqual(Decision.denied, cfg.checkPath(.read, escape));
}

test "net scopes match host, wildcard, and port" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try Config.parse(
        arena.allocator(),
        &.{"--allow-net=api.example.com:443,*.internal:8080"},
    );

    try std.testing.expectEqual(Decision.allowed, cfg.checkNet("API.EXAMPLE.COM", 443));
    try std.testing.expectEqual(Decision.denied, cfg.checkNet("api.example.com", 80));
    try std.testing.expectEqual(Decision.allowed, cfg.checkNet("db.internal", 8080));
    try std.testing.expectEqual(Decision.denied, cfg.checkNet("internal", 8080));
}

test "env and run scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try Config.parse(
        arena.allocator(),
        &.{ "--allow-env=HOME", "--allow-run=git,/bin/sh" },
    );

    try std.testing.expect(cfg.checkEnv("HOME"));
    try std.testing.expect(!cfg.checkEnv("SECRET"));
    try std.testing.expectEqual(Decision.allowed, cfg.checkRun("git"));
    try std.testing.expectEqual(Decision.allowed, cfg.checkRun("/usr/bin/git"));
    try std.testing.expectEqual(Decision.allowed, cfg.checkRun("/bin/sh"));
    try std.testing.expectEqual(Decision.denied, cfg.checkRun("/bin/echo"));
}
