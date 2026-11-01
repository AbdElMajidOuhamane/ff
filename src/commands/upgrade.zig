const std = @import("std");
const builtin = @import("builtin");
const cli = @import("../util/cli.zig");
const ffcfg = @import("ffcfg");
const semver = @import("semver.zig");
const c = @cImport({
    @cInclude("sys/stat.h");
    @cInclude("stdio.h");
});

const REPO = "AbdElMajidOuhamane/ff";

// Every failure path in this command previously `return`ed `void`, so
// `ff upgrade` exited 0 whether or not it did anything. Route through the
// shared error formatter, which prints `error: ...` and exits 1.
fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    cli.fail(fmt, args);
}

fn assetName(allocator: std.mem.Allocator) ![]u8 {
    const os = @tagName(builtin.os.tag);
    const arch = @tagName(builtin.cpu.arch);
    return std.fmt.allocPrint(allocator, "ff-{s}-{s}", .{ os, arch });
}

/// Find the digest for `asset` in a sha256sum-format manifest
/// ("<64 hex>  <name>", or "<64 hex> *<name>" for binary mode).
/// Returns null when the manifest has no entry for this asset — the caller
/// treats that as fatal rather than installing unverified.
fn expectedDigest(sums: []const u8, asset: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, sums, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len < 64) continue;
        const hash = line[0..64];
        var ok = true;
        for (hash) |ch| {
            if (!std.ascii.isHex(ch)) {
                ok = false;
                break;
            }
        }
        if (!ok) continue;
        var rest = std.mem.trimStart(u8, line[64..], " \t");
        if (rest.len > 0 and rest[0] == '*') rest = rest[1..];
        if (std.mem.eql(u8, rest, asset)) return hash;
    }
    return null;
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
        cli.ok("ff {s} is up to date", .{ffcfg.version});
        return;
    }
    cli.step("update available: {s} → {s}", .{ ffcfg.version, latest });
    if (check_only) return;

    const asset = try assetName(allocator);
    defer allocator.free(asset);
    const dl_base = try std.fmt.allocPrint(allocator, "https://github.com/{s}/releases/download/{s}", .{ REPO, latest });
    defer allocator.free(dl_base);
    const dl_url = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dl_base, asset });
    defer allocator.free(dl_url);
    const sums_url = try std.fmt.allocPrint(allocator, "{s}/sha256sums.txt", .{dl_base});
    defer allocator.free(sums_url);

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
    const sums_path = try std.fmt.allocPrint(allocator, "{s}.sums", .{exe});
    defer allocator.free(sums_path);

    var dl = std.process.spawn(io, .{
        .argv = &.{ "curl", "-fSL", "-o", tmp_path, dl_url },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| fail("cannot run curl: {s}", .{@errorName(err)});
    defer dl.kill(io);
    const term = try dl.wait(io);
    if (term != .exited or term.exited != 0) {
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        fail("download failed ({s})", .{dl_url});
    }

    // ── Integrity check before anything executable is written ──
    // install.sh verifies the release manifest; this command did not, so a
    // tampered release asset (or a hostile redirect) became `ff` verbatim.
    // The manifest comes from the same release, so it proves integrity in
    // transit, not publisher identity — signatures would be the next step.
    {
        var sums_dl = std.process.spawn(io, .{
            .argv = &.{ "curl", "-fSL", "-o", sums_path, sums_url },
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .inherit,
        }) catch |err| {
            std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
            fail("cannot run curl: {s}", .{@errorName(err)});
        };
        defer sums_dl.kill(io);
        const sums_term = try sums_dl.wait(io);
        if (sums_term != .exited or sums_term.exited != 0) {
            std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
            std.Io.Dir.cwd().deleteFile(io, sums_path) catch {};
            fail("checksum manifest download failed ({s}) — refusing to install unverified", .{sums_url});
        }
    }
    defer std.Io.Dir.cwd().deleteFile(io, sums_path) catch {};

    const sums_bytes = std.Io.Dir.cwd().readFileAlloc(io, sums_path, allocator, .limited(64 * 1024)) catch {
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        fail("cannot read checksum manifest", .{});
    };
    defer allocator.free(sums_bytes);
    const want = expectedDigest(sums_bytes, asset) orelse {
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        fail("release has no checksum for {s} — refusing to install unverified", .{asset});
    };

    // One-shot CLI: hashing the whole binary in memory is simpler than a
    // streaming reader and bounded by the same limit as the download.
    const bin = std.Io.Dir.cwd().readFileAlloc(io, tmp_path, allocator, .limited(64 * 1024 * 1024)) catch {
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        fail("cannot read downloaded binary", .{});
    };
    defer allocator.free(bin);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bin, &digest, .{});
    const got = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &got, want)) {
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        fail("checksum mismatch for {s}: expected {s}, got {s}", .{ asset, want, &got });
    }
    cli.ok("verified sha256 {s}", .{&got});

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
    cli.ok("upgraded to {s} ({s}) at {s}", .{ latest, asset, exe });
}
