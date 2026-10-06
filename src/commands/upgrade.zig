const std = @import("std");
const builtin = @import("builtin");
const ffcfg = @import("ffcfg");
const semver = @import("semver.zig");
const c = @cImport({
    @cInclude("sys/stat.h");
    @cInclude("stdio.h");
});

const REPO = "AbdElMajidOuhamane/ff";

// Every failure path in this command previously `return`ed `void`, so
// `ff upgrade` exited 0 whether or not it did anything. Print, then exit 1.
fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("upgrade: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn assetName(allocator: std.mem.Allocator) ![]u8 {
    const os = @tagName(builtin.os.tag);
    const arch = @tagName(builtin.cpu.arch);
    return std.fmt.allocPrint(allocator, "ff-{s}-{s}", .{ os, arch });
}

pub fn run(io: std.Io, init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    var check_only = false;
    var it = init.minimal.args.iterate();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--check")) {
            check_only = true;
        }
    }

    const url = try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/releases/latest", .{REPO});
    defer allocator.free(url);
    const out = std.process.run(allocator, io, .{
        .argv = &.{ "curl", "-fsSL", url },
    }) catch fail("curl failed (is curl installed?)", .{});
    defer allocator.free(out.stdout);
    defer allocator.free(out.stderr);

    if (out.term != .exited or out.term.exited != 0) {
        // GitHub 404s releases/latest when the repo has no published
        // releases — say that plainly instead of leaking a curl error.
        if (std.mem.indexOf(u8, out.stderr, "404") != null) {
            fail("no releases published for {s}", .{REPO});
        }
        if (out.stderr.len > 0) {
            fail("{s}", .{std.mem.trim(u8, out.stderr, "\n")});
        }
        fail("curl failed", .{});
    }

    if (out.stdout.len == 0) {
        fail("no releases found for {s}", .{REPO});
    }

    const key = "\"tag_name\"";
    const ki = std.mem.indexOf(u8, out.stdout, key) orelse
        fail("no releases found for {s}", .{REPO});
    // `key` already contains both quotes, so q1/q2 bracket the *value*.
    // The old code sliced [q3+1..q4], which is the *next* key
    // ("target_commitish") — semver parsing then failed every time.
    const q1 = std.mem.indexOfScalarPos(u8, out.stdout, ki + key.len, '"') orelse
        fail("malformed release metadata (no opening quote)", .{});
    const q2 = std.mem.indexOfScalarPos(u8, out.stdout, q1 + 1, '"') orelse
        fail("malformed release metadata (no closing quote)", .{});
    const latest = out.stdout[q1 + 1 .. q2];

    var cur = ffcfg.version;
    if (std.mem.startsWith(u8, cur, "v")) cur = cur[1..];
    var lat = latest;
    if (std.mem.startsWith(u8, lat, "v")) lat = lat[1..];

    const cv = semver.parseVersion(cur) catch
        fail("current version '{s}' is not semver; latest is {s}", .{ ffcfg.version, latest });
    const lv = semver.parseVersion(lat) catch
        fail("latest version '{s}' is not semver", .{latest});
    if (semver.compare(cv, lv) != .lt) {
        std.debug.print("ff {s} is up to date.\n", .{ffcfg.version});
        return;
    }
    std.debug.print("Update available: {s} -> {s}\n", .{ ffcfg.version, latest });
    if (check_only) return;

    const asset = try assetName(allocator);
    defer allocator.free(asset);
    const dl_url = try std.fmt.allocPrint(allocator, "https://github.com/{s}/releases/download/{s}/{s}", .{ REPO, latest, asset });
    defer allocator.free(dl_url);

    var arg_it = init.minimal.args.iterate();
    const argv0 = arg_it.next() orelse "~/.local/bin/ff";
    var exe: []const u8 = argv0;
    var exe_owned: ?[]u8 = null;
    defer if (exe_owned) |p| allocator.free(p);
    if (!std.fs.path.isAbsolute(argv0)) {
        if (std.c.getenv("HOME")) |home| {
            const h = std.mem.span(home);
            exe_owned = try std.fmt.allocPrint(allocator, "{s}/.local/bin/ff", .{h});
            exe = exe_owned.?;
        }
    }

    // The install directory may not exist yet — rename() would fail ENOENT
    // and (before this) still exit 0, leaving the old binary in place.
    // createDirPath succeeds when the path already exists as a directory,
    // so an already-installed location is a no-op.
    if (std.fs.path.dirname(exe)) |dir_path| {
        if (dir_path.len > 0) {
            std.Io.Dir.cwd().createDirPath(io, dir_path) catch |e|
                fail("could not create {s}: {s}", .{ dir_path, @errorName(e) });
        }
    }

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.new", .{exe});
    defer allocator.free(tmp_path);

    var dl = try std.process.spawn(io, .{
        .argv = &.{ "curl", "-fSL", "-o", tmp_path, dl_url },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    defer dl.kill(io);
    const term = try dl.wait(io);
    if (term != .exited or term.exited != 0) {
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        fail("download failed ({s})", .{dl_url});
    }
    {
        const tmp_z = allocator.dupeZ(u8, tmp_path) catch tmp_path;
        defer if (tmp_z.ptr != tmp_path.ptr) allocator.free(tmp_z);
        _ = c.chmod(tmp_z.ptr, 0o755);
    }
    {
        const tmp_z = allocator.dupeZ(u8, tmp_path) catch tmp_path;
        defer if (tmp_z.ptr != tmp_path.ptr) allocator.free(tmp_z);
        const exe_z = allocator.dupeZ(u8, exe) catch exe;
        defer if (exe_z.ptr != exe.ptr) allocator.free(exe_z);
        if (c.rename(tmp_z.ptr, exe_z.ptr) != 0) {
            std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
            fail("failed to move {s} -> {s}", .{ tmp_path, exe });
        }
    }
    std.debug.print("Upgraded to {s} ({s}) at {s}.\n", .{ latest, asset, exe });
}
