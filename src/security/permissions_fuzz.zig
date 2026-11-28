const std = @import("std");
const assert = std.debug.assert;
const fuzz = @import("../testing/fuzz.zig");
const perm = @import("permissions.zig");

// Permission policy parser, IPv4/IPv6 private-net classifiers, and net/env/run scope oracles.

pub const events_smoke: usize = 20_000;
pub const events_default: ?usize = null;

const Op = enum { parse_flags, private_ip, net_scope, env_run };

const flag_dict = [_][]const u8{
    "--allow-all",
    "--allow-net",
    "--allow-net=api.example.com:443,*.internal:8080",
    "--allow-net=[::1]:8080,127.0.0.1:3000",
    "--allow-net=*",
    "--allow-net=*:443",
    "--deny-net=blocked.example.com:443,*.corp.local",
    "--deny-net=",
    "--deny-private-net",
    "--deny-read=",
    "--deny-write=",
    "--deny-unknown=1",
    "--allow-env=HOME,PATH",
    "--allow-run=git,/bin/sh",
    "--allow-ffi",
    "--allow-ffi=bad",
    "--allow-unknown=x",
    "--max-heap=64MB",
};

const net_hosts = [_][]const u8{
    "api.example.com",
    "db.internal",
    "10.0.0.1",
    "sub.domain.test",
    "evil.local",
    "blocked.example.com",
};

const name_dict = [_][]const u8{
    "HOME",
    "PATH",
    "PORT",
    "SECRET",
    "git",
    "sh",
    "node",
    "ff",
};

pub fn main(gpa: std.mem.Allocator, args: fuzz.FuzzArgs) !void {
    var prng = std.Random.DefaultPrng.init(args.seed);
    const rand = prng.random();
    const enabled = fuzz.swarmTake(rand, 4);
    comptime assert(4 == @typeInfo(Op).@"enum".fields.len);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var events: usize = 0;
    while (args.events_max == null or events < args.events_max.?) : (events += 1) {
        _ = arena.reset(.retain_capacity);
        const alloc = arena.allocator();
        const op = fuzz.randomEnum(rand, Op);
        if (!enabled[@intFromEnum(op)]) continue;
        switch (op) {
            .parse_flags => try fuzzParseFlags(rand, alloc),
            .private_ip => try fuzzPrivateIp(rand),
            .net_scope => try fuzzNetScope(rand, alloc),
            .env_run => try fuzzEnvRun(rand, alloc),
        }
    }
}

fn fuzzParseFlags(rand: std.Random, alloc: std.mem.Allocator) !void {
    const k = rand.intRangeAtMost(usize, 1, 4);
    var argv: [4][]const u8 = undefined;
    var has_deny_priv = false;
    var noise: [64]u8 = undefined;

    for (0..k) |i| {
        if (rand.float(f64) < 0.2) {
            const s = fuzz.randomSlice(rand, &noise);
            argv[i] = try alloc.dupe(u8, s);
        } else {
            const tok = fuzz.pick(rand, []const u8, &flag_dict);
            if (std.mem.eql(u8, tok, "--deny-private-net")) has_deny_priv = true;
            argv[i] = tok;
        }
        _ = perm.isPermissionFlag(argv[i]);
    }

    const cfg = perm.Config.parse(alloc, argv[0..k]) catch return;
    if (has_deny_priv) {
        const v4_lo = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 80);
        const v6_lo = try std.Io.net.IpAddress.parseIp6("::1", 80);
        if (cfg.checkResolvedIp(v4_lo) != .denied) return error.PrivateIpv4NotDenied;
        if (cfg.checkResolvedIp(v6_lo) != .denied) return error.PrivateIpv6NotDenied;
    }
}

fn fuzzPrivateIp(rand: std.Random) !void {
    var b4: [4]u8 = undefined;
    rand.bytes(&b4);
    const v4 = std.Io.net.IpAddress{ .ip4 = .{ .bytes = b4, .port = 80 } };
    const is_v4_priv = perm.isPrivateIpv4(b4);
    if (perm.isPrivateIpAddress(v4) != is_v4_priv) return error.Ip4ClassifierMismatch;

    // Oracle: ::ffff:<b4> must match isPrivateIpv4(b4)
    const mapped_b6 = [16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, b4[0], b4[1], b4[2], b4[3] };
    if (perm.isPrivateIpv6(mapped_b6) != is_v4_priv) return error.MappedIpv6OracleMismatch;

    var b6: [16]u8 = undefined;
    rand.bytes(&b6);
    const v6 = std.Io.net.IpAddress{ .ip6 = .{ .bytes = b6, .port = 443 } };
    if (perm.isPrivateIpAddress(v6) != perm.isPrivateIpv6(b6)) return error.Ip6ClassifierMismatch;
}

fn fuzzNetScope(rand: std.Random, alloc: std.mem.Allocator) !void {
    const allow_h = fuzz.pick(rand, []const u8, &net_hosts);
    const deny_h = fuzz.pick(rand, []const u8, &net_hosts);
    const port = rand.intRangeAtMost(u16, 1, 65535);

    const allow_flag = try std.fmt.allocPrint(alloc, "--allow-net={s}:{d}", .{ allow_h, port });
    const deny_flag = try std.fmt.allocPrint(alloc, "--deny-net={s}", .{deny_h});
    const cfg = try perm.Config.parse(alloc, &.{ allow_flag, deny_flag });

    if (cfg.checkNet(deny_h, port) != .denied) return error.DenyNetFailed;
    if (!std.mem.eql(u8, allow_h, deny_h)) {
        if (cfg.checkNet(allow_h, port) != .allowed) return error.AllowNetFailed;
    }
}

fn fuzzEnvRun(rand: std.Random, alloc: std.mem.Allocator) !void {
    const env_name = fuzz.pick(rand, []const u8, &name_dict);
    const run_name = fuzz.pick(rand, []const u8, &name_dict);

    const default_cfg = perm.Config{};
    if (default_cfg.checkEnv(env_name)) return error.DefaultEnvAllowed;
    if (default_cfg.checkRun(run_name) != .denied) return error.DefaultRunAllowed;

    const env_flag = try std.fmt.allocPrint(alloc, "--allow-env={s}", .{env_name});
    const run_flag = try std.fmt.allocPrint(alloc, "--allow-run={s}", .{run_name});
    const cfg = try perm.Config.parse(alloc, &.{ env_flag, run_flag });

    if (!cfg.checkEnv(env_name)) return error.EnvScopeMissed;
    if (cfg.checkRun(run_name) != .allowed) return error.RunScopeMissed;
}
