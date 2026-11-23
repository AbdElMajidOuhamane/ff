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
    deny_private_net: bool = false,
    deny_net: ?[]const NetScope = null,
    deny_read_paths: ?[]const PathScope = null,
    deny_write_paths: ?[]const PathScope = null,

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

    pub fn revoke(self: *Config, kind: Kind) void {
        switch (kind) {
            .read => self.read = .denied,
            .write => self.write = .denied,
            .net => self.net = .denied,
            .env => self.env = .denied,
            .run => self.run = .denied,
            .ffi => self.ffi = false,
        }
    }

    fn netScopeMatches(scope: NetScope, host: []const u8, port: u16) bool {
        if (scope.wildcard and scope.host.len == 0) return true;
        if (scope.port) |p| {
            if (p != port) return false;
        }
        if (scope.wildcard) {
            return (host.len > scope.host.len + 1 and
                std.mem.endsWith(u8, host, scope.host) and
                host[host.len - scope.host.len - 1] == '.');
        } else {
            return std.mem.eql(u8, host, scope.host);
        }
    }

    pub fn checkPath(self: *const Config, kind: Kind, path: []const u8) Decision {
        const d_scopes = switch (kind) {
            .read => self.deny_read_paths,
            .write => self.deny_write_paths,
            else => null,
        };
        if (d_scopes) |scopes| {
            var d_canon_buf: [max_path]u8 = undefined;
            if (canonicalizeInput(path, &d_canon_buf)) |canon| {
                for (scopes) |scope| {
                    if (isWithin(scope.path, canon)) return .denied;
                }
            } else |_| return .denied;
        }
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
        if (host_in.len == 0 or host_in.len > 255) return .denied;
        if (std.mem.indexOfScalar(u8, host_in, 0) != null) return .denied;

        var buf: [256]u8 = undefined;
        const host = lowerInto(host_in, &buf);

        if (self.deny_net) |d_scopes| {
            for (d_scopes) |scope| {
                if (netScopeMatches(scope, host, port)) return .denied;
            }
        }
        switch (self.net) {
            .denied => return .denied,
            .all => return .allowed,
            .scoped => |scopes| {
                for (scopes) |scope| {
                    if (netScopeMatches(scope, host, port)) return .allowed;
                }
                return .denied;
            },
        }
    }

    pub fn checkResolvedIp(self: *const Config, addr: std.Io.net.IpAddress) Decision {
        if (self.deny_private_net and isPrivateIpAddress(addr)) return .denied;
        return .allowed;
    }

    pub fn checkHostNotPrivate(self: *const Config, host_in: []const u8, port: u16) Decision {
        if (!self.deny_private_net) return .allowed;
        if (host_in.len == 0 or host_in.len >= 256) return .denied;
        if (std.mem.indexOfScalar(u8, host_in, 0) != null) return .denied;

        const host = if (host_in.len >= 2 and host_in[0] == '[' and host_in[host_in.len - 1] == ']')
            host_in[1 .. host_in.len - 1]
        else
            host_in;
        if (host.len == 0) return .denied;

        if (std.Io.net.IpAddress.parse(host, port)) |addr| {
            return self.checkResolvedIp(addr);
        } else |_| {}

        var host_buf: [256]u8 = undefined;
        @memcpy(host_buf[0..host.len], host);
        host_buf[host.len] = 0;
        const host_z: [:0]const u8 = host_buf[0..host.len :0];

        var port_buf: [8]u8 = undefined;
        const port_slice = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch return .denied;
        if (port_slice.len >= port_buf.len) return .denied;
        port_buf[port_slice.len] = 0;
        const port_z: [:0]const u8 = port_buf[0..port_slice.len :0];

        var hints: std.c.addrinfo = std.mem.zeroes(std.c.addrinfo);
        hints.family = std.posix.AF.UNSPEC;
        hints.socktype = std.posix.SOCK.STREAM;

        var res: ?*std.c.addrinfo = null;
        const eai = std.c.getaddrinfo(host_z.ptr, port_z.ptr, &hints, &res);
        if (@intFromEnum(eai) != 0) return .denied;
        defer if (res) |r| std.c.freeaddrinfo(r);

        var cur: ?*std.c.addrinfo = res;
        var saw_addr = false;
        while (cur) |info| : (cur = info.next) {
            const sa = info.addr orelse continue;
            saw_addr = true;
            if (info.family == std.posix.AF.INET) {
                const sin: *const std.c.sockaddr.in = @ptrCast(@alignCast(sa));
                const bytes: [4]u8 = @bitCast(sin.addr);
                if (isPrivateIpv4(bytes)) return .denied;
            } else if (info.family == std.posix.AF.INET6) {
                const sin6: *const std.c.sockaddr.in6 = @ptrCast(@alignCast(sa));
                if (isPrivateIpv6(sin6.addr)) return .denied;
            } else {
                return .denied; // fail closed on unknown family
            }
        }
        return if (saw_addr) .allowed else .denied;
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
        var deny_net_list: std.ArrayList(NetScope) = .empty;
        defer deny_net_list.deinit(alloc);
        var deny_read_list: std.ArrayList(PathScope) = .empty;
        defer deny_read_list.deinit(alloc);
        var deny_write_list: std.ArrayList(PathScope) = .empty;
        defer deny_write_list.deinit(alloc);

        var all = false;
        var read_all = false;
        var write_all = false;
        var net_all = false;
        var env_all = false;
        var run_all = false;
        var ffi = false;
        var deny_private_net = false;

        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--allow-all")) {
                all = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--deny-private-net")) {
                deny_private_net = true;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--deny-net=")) {
                const val = arg["--deny-net=".len..];
                if (val.len == 0) return error.InvalidScope;
                var count: usize = 0;
                var parts = std.mem.splitScalar(u8, val, ',');
                while (parts.next()) |p| {
                    if (p.len == 0) continue;
                    const s = parseNetScope(alloc, p) catch return error.InvalidScope;
                    try deny_net_list.append(alloc, s);
                    count += 1;
                }
                if (count == 0) return error.InvalidScope;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--deny-read=")) {
                const val = arg["--deny-read=".len..];
                if (val.len == 0) return error.InvalidScope;
                var count: usize = 0;
                var parts = std.mem.splitScalar(u8, val, ',');
                while (parts.next()) |p| {
                    if (p.len == 0) continue;
                    var path_buf: [max_path]u8 = undefined;
                    const canon = canonicalizeInput(p, &path_buf) catch return error.InvalidScope;
                    try deny_read_list.append(alloc, .{ .path = try alloc.dupe(u8, canon) });
                    count += 1;
                }
                if (count == 0) return error.InvalidScope;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--deny-write=")) {
                const val = arg["--deny-write=".len..];
                if (val.len == 0) return error.InvalidScope;
                var count: usize = 0;
                var parts = std.mem.splitScalar(u8, val, ',');
                while (parts.next()) |p| {
                    if (p.len == 0) continue;
                    var path_buf: [max_path]u8 = undefined;
                    const canon = canonicalizeInput(p, &path_buf) catch return error.InvalidScope;
                    try deny_write_list.append(alloc, .{ .path = try alloc.dupe(u8, canon) });
                    count += 1;
                }
                if (count == 0) return error.InvalidScope;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--deny-")) {
                return error.UnknownPermissionFlag;
            }
            if (!std.mem.startsWith(u8, arg, "--allow-")) {
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
                .deny_private_net = deny_private_net,
                .deny_net = if (deny_net_list.items.len > 0) try deny_net_list.toOwnedSlice(alloc) else null,
                .deny_read_paths = if (deny_read_list.items.len > 0) try deny_read_list.toOwnedSlice(alloc) else null,
                .deny_write_paths = if (deny_write_list.items.len > 0) try deny_write_list.toOwnedSlice(alloc) else null,
            };
        }

        var cfg = Config{
            .ffi = ffi,
            .deny_private_net = deny_private_net,
            .deny_net = if (deny_net_list.items.len > 0) try deny_net_list.toOwnedSlice(alloc) else null,
            .deny_read_paths = if (deny_read_list.items.len > 0) try deny_read_list.toOwnedSlice(alloc) else null,
            .deny_write_paths = if (deny_write_list.items.len > 0) try deny_write_list.toOwnedSlice(alloc) else null,
        };
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
var current_atomic: std.atomic.Value(?*const Config) = std.atomic.Value(?*const Config).init(null);
const Mutex = struct {
    state: std.atomic.Value(u8) = .init(0),

    pub fn lock(self: *Mutex) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
            std.Thread.yield() catch {};
        }
    }

    pub fn tryLock(self: *Mutex) bool {
        return self.state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null;
    }

    pub fn unlock(self: *Mutex) void {
        self.state.store(0, .release);
    }
};

var perm_mutex: Mutex = .{};

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

    const initial_cfg = try alloc.create(Config);
    initial_cfg.* = try Config.parse(alloc, list.items);
    current = initial_cfg.*;
    current_atomic.store(initial_cfg, .release);
    initialized = true;
}

pub fn global() *const Config {
    return current_atomic.load(.acquire) orelse &current;
}

pub fn revoke(kind: Kind) void {
    perm_mutex.lock();
    defer perm_mutex.unlock();
    const cur = global();
    const alloc = arena_state.allocator();
    const copy = alloc.create(Config) catch return;
    copy.* = cur.*;
    switch (kind) {
        .read => copy.read = .denied,
        .write => copy.write = .denied,
        .net => copy.net = .denied,
        .env => copy.env = .denied,
        .run => copy.run = .denied,
        .ffi => copy.ffi = false,
    }
    current = copy.*;
    current_atomic.store(copy, .release);
}

pub fn revokePath(kind: Kind, target_path: []const u8) void {
    perm_mutex.lock();
    defer perm_mutex.unlock();
    const cur = global();
    const alloc = arena_state.allocator();
    const copy = alloc.create(Config) catch return;
    copy.* = cur.*;

    var canon_buf: [max_path]u8 = undefined;
    const canon = canonicalizeInput(target_path, &canon_buf) catch target_path;
    const owned_canon = alloc.dupe(u8, canon) catch return;

    switch (kind) {
        .read => {
            switch (copy.read) {
                .scoped => |scopes| {
                    var remaining: std.ArrayList(PathScope) = .empty;
                    for (scopes) |sc| {
                        if (!std.mem.eql(u8, sc.path, canon) and !std.mem.eql(u8, sc.path, target_path)) {
                            remaining.append(alloc, sc) catch return;
                        }
                    }
                    if (remaining.items.len == 0) {
                        copy.read = .denied;
                    } else {
                        var still_covered = false;
                        for (remaining.items) |sc| {
                            if (isWithin(sc.path, canon)) {
                                still_covered = true;
                                break;
                            }
                        }
                        copy.read = .{ .scoped = remaining.toOwnedSlice(alloc) catch return };
                        if (still_covered) {
                            var d_list: std.ArrayList(PathScope) = .empty;
                            if (copy.deny_read_paths) |d| {
                                d_list.appendSlice(alloc, d) catch return;
                            }
                            d_list.append(alloc, .{ .path = owned_canon }) catch return;
                            copy.deny_read_paths = d_list.toOwnedSlice(alloc) catch return;
                        }
                    }
                },
                .all => {
                    var d_list: std.ArrayList(PathScope) = .empty;
                    if (copy.deny_read_paths) |d| {
                        d_list.appendSlice(alloc, d) catch return;
                    }
                    d_list.append(alloc, .{ .path = owned_canon }) catch return;
                    copy.deny_read_paths = d_list.toOwnedSlice(alloc) catch return;
                },
                .denied => {},
            }
        },
        .write => {
            switch (copy.write) {
                .scoped => |scopes| {
                    var remaining: std.ArrayList(PathScope) = .empty;
                    for (scopes) |sc| {
                        if (!std.mem.eql(u8, sc.path, canon) and !std.mem.eql(u8, sc.path, target_path)) {
                            remaining.append(alloc, sc) catch return;
                        }
                    }
                    if (remaining.items.len == 0) {
                        copy.write = .denied;
                    } else {
                        var still_covered = false;
                        for (remaining.items) |sc| {
                            if (isWithin(sc.path, canon)) {
                                still_covered = true;
                                break;
                            }
                        }
                        copy.write = .{ .scoped = remaining.toOwnedSlice(alloc) catch return };
                        if (still_covered) {
                            var d_list: std.ArrayList(PathScope) = .empty;
                            if (copy.deny_write_paths) |d| {
                                d_list.appendSlice(alloc, d) catch return;
                            }
                            d_list.append(alloc, .{ .path = owned_canon }) catch return;
                            copy.deny_write_paths = d_list.toOwnedSlice(alloc) catch return;
                        }
                    }
                },
                .all => {
                    var d_list: std.ArrayList(PathScope) = .empty;
                    if (copy.deny_write_paths) |d| {
                        d_list.appendSlice(alloc, d) catch return;
                    }
                    d_list.append(alloc, .{ .path = owned_canon }) catch return;
                    copy.deny_write_paths = d_list.toOwnedSlice(alloc) catch return;
                },
                .denied => {},
            }
        },
        else => {},
    }
    current = copy.*;
    current_atomic.store(copy, .release);
}

pub fn revokeNet(target_host: []const u8) void {
    perm_mutex.lock();
    defer perm_mutex.unlock();
    const cur = global();
    const alloc = arena_state.allocator();
    const copy = alloc.create(Config) catch return;
    copy.* = cur.*;

    const parsed_scope = parseNetScope(alloc, target_host) catch null;

    switch (copy.net) {
        .scoped => |scopes| {
            var remaining: std.ArrayList(NetScope) = .empty;
            for (scopes) |sc| {
                if (!std.mem.eql(u8, sc.host, target_host)) {
                    remaining.append(alloc, sc) catch return;
                }
            }
            if (remaining.items.len == 0) {
                copy.net = .denied;
            } else {
                copy.net = .{ .scoped = remaining.toOwnedSlice(alloc) catch return };
                if (parsed_scope) |ps| {
                    var d_list: std.ArrayList(NetScope) = .empty;
                    if (copy.deny_net) |d| {
                        d_list.appendSlice(alloc, d) catch return;
                    }
                    d_list.append(alloc, ps) catch return;
                    copy.deny_net = d_list.toOwnedSlice(alloc) catch return;
                }
            }
        },
        .all => {
            var d_list: std.ArrayList(NetScope) = .empty;
            if (copy.deny_net) |d| {
                d_list.appendSlice(alloc, d) catch return;
            }
            if (parsed_scope) |ps| {
                d_list.append(alloc, ps) catch return;
            } else {
                const owned_host = alloc.dupe(u8, target_host) catch return;
                d_list.append(alloc, .{ .host = owned_host }) catch return;
            }
            copy.deny_net = d_list.toOwnedSlice(alloc) catch return;
        },
        .denied => {},
    }
    current = copy.*;
    current_atomic.store(copy, .release);
}

pub fn revokeEnv(var_name: []const u8) void {
    perm_mutex.lock();
    defer perm_mutex.unlock();
    const cur = global();
    const alloc = arena_state.allocator();
    const copy = alloc.create(Config) catch return;
    copy.* = cur.*;

    switch (copy.env) {
        .scoped => |scopes| {
            var remaining: std.ArrayList(NameScope) = .empty;
            for (scopes) |sc| {
                if (!std.mem.eql(u8, sc.name, var_name)) {
                    remaining.append(alloc, sc) catch return;
                }
            }
            if (remaining.items.len == 0) {
                copy.env = .denied;
            } else {
                copy.env = .{ .scoped = remaining.toOwnedSlice(alloc) catch return };
            }
        },
        .all => {
            copy.env = .denied;
        },
        .denied => {},
    }
    current = copy.*;
    current_atomic.store(copy, .release);
}

pub fn isPermissionFlag(arg: []const u8) bool {
    if (std.mem.eql(u8, arg, "--allow-all") or std.mem.eql(u8, arg, "--allow-ffi"))
        return true;
    if (std.mem.startsWith(u8, arg, "--deny-")) return true;
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

/// Pure-bitmask check for private/reserved/loopback/metadata IPv4 ranges.
pub fn isPrivateIpv4(b: [4]u8) bool {
    if (b[0] == 0) return true; // 0.0.0.0/8 ("this" network)
    if (b[0] == 10) return true; // 10.0.0.0/8 (RFC1918)
    if (b[0] == 100 and (b[1] & 0xC0) == 64) return true; // 100.64.0.0/10 (CGNAT)
    if (b[0] == 127) return true; // 127.0.0.0/8 (loopback)
    if (b[0] == 169 and b[1] == 254) return true; // 169.254.0.0/16 (link-local / metadata)
    if (b[0] == 172 and (b[1] & 0xF0) == 16) return true; // 172.16.0.0/12 (RFC1918)
    if (b[0] == 192 and b[1] == 0 and b[2] == 0) return true; // 192.0.0.0/24 (IETF protocol)
    if (b[0] == 192 and b[1] == 168) return true; // 192.168.0.0/16 (RFC1918)
    if (b[0] == 198 and (b[1] & 0xFE) == 18) return true; // 198.18.0.0/15 (benchmark)
    if (b[0] >= 224) return true; // 224.0.0.0/4 multicast + 240.0.0.0/4 reserved
    return false;
}

/// Pure-bitmask check for private/loopback/link-local/IPv4-mapped IPv6 ranges.
pub fn isPrivateIpv6(b: [16]u8) bool {
    var all_zero = true;
    for (b[0..15]) |byte| {
        if (byte != 0) {
            all_zero = false;
            break;
        }
    }
    if (all_zero and (b[15] == 0 or b[15] == 1)) return true; // :: or ::1
    if ((b[0] & 0xFE) == 0xFC) return true; // fc00::/7 (ULA)
    if (b[0] == 0xFE and (b[1] & 0xC0) == 0x80) return true; // fe80::/10 (link-local)
    if (b[0] == 0xFF) return true; // ff00::/8 (multicast)
    // ::ffff:0:0/96 (IPv4-mapped IPv6)
    var v4_mapped = b[10] == 0xFF and b[11] == 0xFF;
    if (v4_mapped) {
        for (b[0..10]) |byte| {
            if (byte != 0) {
                v4_mapped = false;
                break;
            }
        }
    }
    if (v4_mapped) return isPrivateIpv4(b[12..16].*);
    return false;
}

pub fn isPrivateIpAddress(addr: std.Io.net.IpAddress) bool {
    return switch (addr) {
        .ip4 => |ip4| isPrivateIpv4(ip4.bytes),
        .ip6 => |ip6| isPrivateIpv6(ip6.bytes),
    };
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

test "a port suffix on a bare wildcard does not narrow the scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try Config.parse(arena.allocator(), &.{"--allow-net=*:443"});

    // Documented behaviour (docs/concepts/permissions.md): `*` matches every
    // host AND every port; a port suffix on `*` is ignored. This is
    // deliberate: checkNet short-circuits the bare wildcard before the port
    // comparison. Pinned so a future "fix" cannot silently change what an
    // existing deployment granted.
    try std.testing.expectEqual(Decision.allowed, cfg.checkNet("example.com", 80));
    try std.testing.expectEqual(Decision.allowed, cfg.checkNet("example.com", 443));
    try std.testing.expectEqual(Decision.allowed, cfg.checkNet("127.0.0.1", 5432));
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

test "isPrivateIpv4 and isPrivateIpv6 classify private, metadata, mapped, and public IPs" {
    // Private / loopback / metadata IPv4
    try std.testing.expect(isPrivateIpv4(.{ 127, 0, 0, 1 }));
    try std.testing.expect(isPrivateIpv4(.{ 10, 0, 0, 1 }));
    try std.testing.expect(isPrivateIpv4(.{ 172, 16, 0, 1 }));
    try std.testing.expect(isPrivateIpv4(.{ 172, 31, 255, 254 }));
    try std.testing.expect(!isPrivateIpv4(.{ 172, 32, 0, 1 }));
    try std.testing.expect(isPrivateIpv4(.{ 192, 168, 1, 1 }));
    try std.testing.expect(isPrivateIpv4(.{ 169, 254, 169, 254 }));
    try std.testing.expect(isPrivateIpv4(.{ 100, 64, 0, 1 }));
    try std.testing.expect(isPrivateIpv4(.{ 0, 0, 0, 0 }));
    try std.testing.expect(isPrivateIpv4(.{ 224, 0, 0, 1 }));

    // Public IPv4
    try std.testing.expect(!isPrivateIpv4(.{ 1, 1, 1, 1 }));
    try std.testing.expect(!isPrivateIpv4(.{ 8, 8, 8, 8 }));
    try std.testing.expect(!isPrivateIpv4(.{ 93, 184, 216, 34 }));

    // Private / mapped IPv6
    try std.testing.expect(isPrivateIpv6(.{0} ** 16)); // ::
    try std.testing.expect(isPrivateIpv6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 })); // ::1
    try std.testing.expect(isPrivateIpv6(.{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 })); // fe80::1
    try std.testing.expect(isPrivateIpv6(.{ 0xfd, 0x12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 })); // fd12::1
    try std.testing.expect(isPrivateIpv6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127, 0, 0, 1 })); // ::ffff:127.0.0.1
    try std.testing.expect(isPrivateIpv6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 169, 254, 169, 254 })); // ::ffff:169.254.169.254
    try std.testing.expect(!isPrivateIpv6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 8, 8, 8, 8 })); // ::ffff:8.8.8.8
    try std.testing.expect(!isPrivateIpv6(.{ 0x26, 0x06, 0x47, 0x00, 0x47, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0x11, 0x11 })); // 2606:4700:4700::1111
}

test "Config.parse --deny-private-net blocks private IPs even under --allow-all" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try Config.parse(arena.allocator(), &.{ "--allow-all", "--deny-private-net" });

    try std.testing.expect(cfg.deny_private_net);
    try std.testing.expectEqual(Decision.denied, cfg.checkHostNotPrivate("127.0.0.1", 80));
    try std.testing.expectEqual(Decision.denied, cfg.checkHostNotPrivate("169.254.169.254", 80));
    try std.testing.expectEqual(Decision.denied, cfg.checkHostNotPrivate("[::1]", 443));
    try std.testing.expectEqual(Decision.allowed, cfg.checkHostNotPrivate("1.1.1.1", 443));
}

test "deny-read, deny-write, and deny-net override allow grants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(getIo(), "secret", .default_dir);

    var path_buf: [max_path]u8 = undefined;
    const root_len = try tmp.dir.realPath(getIo(), &path_buf);
    const root = path_buf[0..root_len];

    const allow_r = try std.fmt.allocPrint(alloc, "--allow-read={s}", .{root});
    const deny_r = try std.fmt.allocPrint(alloc, "--deny-read={s}/secret", .{root});
    const allow_w = try std.fmt.allocPrint(alloc, "--allow-write={s}", .{root});
    const deny_w = try std.fmt.allocPrint(alloc, "--deny-write={s}/secret", .{root});

    const cfg = try Config.parse(alloc, &.{
        allow_r,
        deny_r,
        allow_w,
        deny_w,
        "--allow-net",
        "--deny-net=blocked.example.com:443,*.corp.local",
    });

    const ok_file = try std.fmt.allocPrint(alloc, "{s}/ok.txt", .{root});
    const secret_file = try std.fmt.allocPrint(alloc, "{s}/secret/a.txt", .{root});

    try std.testing.expectEqual(Decision.allowed, cfg.checkPath(.read, ok_file));
    try std.testing.expectEqual(Decision.denied, cfg.checkPath(.read, secret_file));
    try std.testing.expectEqual(Decision.allowed, cfg.checkPath(.write, ok_file));
    try std.testing.expectEqual(Decision.denied, cfg.checkPath(.write, secret_file));

    try std.testing.expectEqual(Decision.allowed, cfg.checkNet("api.example.com", 443));
    try std.testing.expectEqual(Decision.denied, cfg.checkNet("blocked.example.com", 443));
    try std.testing.expectEqual(Decision.allowed, cfg.checkNet("blocked.example.com", 80));
    try std.testing.expectEqual(Decision.denied, cfg.checkNet("db.corp.local", 5432));
}

test "checkHostNotPrivate resolves localhost via DNS and rejects loopback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cfg_deny = try Config.parse(alloc, &.{ "--allow-net", "--deny-private-net" });
    try std.testing.expectEqual(Decision.denied, cfg_deny.checkHostNotPrivate("localhost", 80));
    try std.testing.expectEqual(Decision.denied, cfg_deny.checkHostNotPrivate("", 80));

    const cfg_allow = try Config.parse(alloc, &.{"--allow-net"});
    try std.testing.expectEqual(Decision.allowed, cfg_allow.checkHostNotPrivate("localhost", 80));
    const lo = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 80);
    try std.testing.expectEqual(Decision.allowed, cfg_allow.checkResolvedIp(lo));
}

test "IPv6 bracket scopes, isPermissionFlag, and invalid flag errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cfg = try Config.parse(alloc, &.{"--allow-net=[::1]:8080,[2001:db8::1]"});
    try std.testing.expectEqual(Decision.allowed, cfg.checkNet("::1", 8080));
    try std.testing.expectEqual(Decision.denied, cfg.checkNet("::1", 80));
    try std.testing.expectEqual(Decision.allowed, cfg.checkNet("2001:db8::1", 443));

    try std.testing.expect(isPermissionFlag("--allow-all"));
    try std.testing.expect(isPermissionFlag("--allow-ffi"));
    try std.testing.expect(isPermissionFlag("--allow-net=x"));
    try std.testing.expect(isPermissionFlag("--deny-net=x"));
    try std.testing.expect(isPermissionFlag("--deny-private-net"));
    try std.testing.expect(!isPermissionFlag("--max-heap=64MB"));
    try std.testing.expect(!isPermissionFlag("--allow-unknown"));
    try std.testing.expect(!isPermissionFlag("foo.js"));

    try std.testing.expectError(error.InvalidScope, Config.parse(alloc, &.{"--deny-net="}));
    try std.testing.expectError(error.InvalidScope, Config.parse(alloc, &.{"--deny-read="}));
    try std.testing.expectError(error.InvalidScope, Config.parse(alloc, &.{"--deny-write="}));
    try std.testing.expectError(error.InvalidScope, Config.parse(alloc, &.{"--allow-ffi=1"}));
    try std.testing.expectError(error.InvalidScope, Config.parse(alloc, &.{"--allow-net=[::1"}));
    try std.testing.expectError(error.UnknownPermissionFlag, Config.parse(alloc, &.{"--deny-foo=bar"}));
    try std.testing.expectError(error.UnknownPermissionFlag, Config.parse(alloc, &.{"--allow-foo=bar"}));
}

test "Config.isAllowed and Config.revoke across all categories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg = try Config.parse(arena.allocator(), &.{"--allow-all"});

    const kinds = [_]Kind{ .read, .write, .net, .env, .run, .ffi };
    for (kinds) |k| {
        try std.testing.expect(cfg.isAllowed(k));
        cfg.revoke(k);
        try std.testing.expect(!cfg.isAllowed(k));
    }
}
