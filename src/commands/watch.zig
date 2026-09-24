const std = @import("std");
const builtin = @import("builtin");

// ff --watch <file|start> — supervisor process.
//
// The parent never runs a runtime: it polls the project tree (mtime + size,
// 200ms) and (re)spawns a plain `ff <file>` / `ff start` child with inherited
// stdio. Fresh runtime per restart — ports, pools, and workers all die with
// the child. Reaping is raw waitpid so nothing races std.process.Child.wait.

pub const Mode = enum { file, start };

const POLL_NS: i96 = 200_000_000;
const DEBOUNCE_NS: i96 = 100_000_000;
const TERM_GRACE_NS: i96 = 10_000_000;
const TERM_GRACE_TICKS: usize = 50; // 50 x 10ms, then SIGKILL
const WNOHANG: c_int = 1; // POSIX value on darwin + linux

const Snap = struct {
    path: []const u8,
    mtime_ns: i96,
    size: u64,
};

const skip_dirs = [_][]const u8{ ".git", "node_modules", "zig-out", ".zig-cache", "zig-cache" };

pub fn run(io: std.Io, exe: []const u8, mode: Mode, target: []const u8, forward: []const []const u8) !void {
    if (builtin.os.tag == .windows) {
        std.debug.print("Error: --watch requires a POSIX platform (darwin/linux)\n", .{});
        std.process.exit(1);
    } else {
        try supervise(io, exe, mode, target, forward);
    }
}

fn supervise(io: std.Io, exe: []const u8, mode: Mode, target: []const u8, forward: []const []const u8) !void {
    const allocator = std.heap.page_allocator;

    // Watch root: the project tree around the entry.
    const root_path: []const u8 = if (mode == .file) (std.fs.path.dirname(target) orelse ".") else ".";
    const dir = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Error: cannot watch '{s}': {s}\n", .{ root_path, @errorName(err) });
        std.process.exit(1);
    };
    defer dir.close(io);

    // start mode: entry comes from ff.json (same contract as `ff start`).
    const entry: []const u8 = switch (mode) {
        .file => target,
        .start => try resolveMain(io, allocator),
    };
    const disp: []const u8 = if (mode == .start) "start" else entry;

    // Child argv, built once: [exe, entry, ...forward]
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe);
    try argv.append(allocator, disp);
    try argv.appendSlice(allocator, forward);

    var prev = try snapshot(io, dir, allocator);
    defer freeList(allocator, &prev);
    std.debug.print("[watch] watching {d} files under {s} (poll 200ms)\n", .{ prev.items.len, root_path });

    var pid: std.posix.pid_t = 0;
    var running = false;
    var status: c_int = 0;

    spawnChild(io, argv.items, disp, &pid);
    running = true;

    while (true) {
        sleepFor(io, POLL_NS);

        // Notice a child that died on its own (crash or clean exit).
        if (running) {
            const r = std.c.waitpid(@intCast(pid), &status, WNOHANG);
            if (r == pid) {
                running = false;
                printExit(status);
            } else if (r == -1) {
                running = false;
            }
        }

        var next = try snapshot(io, dir, allocator);
        const changed = diff(prev.items, next.items);
        if (changed) |ch| {
            std.debug.print("[watch] change: {s} — restarting\n", .{ch});
            sleepFor(io, DEBOUNCE_NS); // let the writer finish; next poll catches follow-up churn
            freeList(allocator, &prev);
            prev = next;
            stopChild(io, &pid, &running, &status);
            spawnChild(io, argv.items, disp, &pid);
            running = true;
        } else {
            freeList(allocator, &next);
        }
    }
}

fn spawnChild(io: std.Io, argv: []const []const u8, disp: []const u8, pid: *std.posix.pid_t) void {
    const child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        std.debug.print("Error: cannot start ff: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    pid.* = child.id.?;
    std.debug.print("[watch] running: ff {s}\n", .{disp});
}

fn stopChild(io: std.Io, pid: *std.posix.pid_t, running: *bool, status: *c_int) void {
    if (!running.*) return;
    std.posix.kill(pid.*, .TERM) catch {};
    var i: usize = 0;
    while (i < TERM_GRACE_TICKS) : (i += 1) {
        const r = std.c.waitpid(@intCast(pid.*), status, WNOHANG);
        if (r == pid.* or r == -1) {
            running.* = false;
            return;
        }
        sleepFor(io, TERM_GRACE_NS);
    }
    std.posix.kill(pid.*, .KILL) catch {};
    _ = std.c.waitpid(@intCast(pid.*), status, 0);
    running.* = false;
}

fn printExit(status: c_int) void {
    if ((status & 0x7f) == 0) {
        std.debug.print("[watch] ff exited (code {d}) — waiting for changes\n", .{(status >> 8) & 0xff});
    } else {
        std.debug.print("[watch] ff killed (signal {d}) — waiting for changes\n", .{status & 0x7f});
    }
}

fn sleepFor(io: std.Io, ns: i96) void {
    std.Io.sleep(io, .{ .nanoseconds = ns }, .awake) catch {};
}

fn snapshot(io: std.Io, dir: std.Io.Dir, allocator: std.mem.Allocator) !std.ArrayList(Snap) {
    var list: std.ArrayList(Snap) = .empty;
    errdefer freeList(allocator, &list);
    var walker = try dir.walkSelectively(allocator);
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind == .directory) {
            if (isSkipped(entry.basename)) continue;
            walker.enter(io, entry) catch continue;
        } else if (entry.kind == .file) {
            const st = dir.statFile(io, entry.path, .{}) catch continue;
            const p = try allocator.dupe(u8, entry.path);
            try list.append(allocator, .{
                .path = p,
                .mtime_ns = st.mtime.nanoseconds,
                .size = st.size,
            });
        }
    }
    return list;
}

fn diff(old: []const Snap, new: []const Snap) ?[]const u8 {
    for (new) |n| {
        var found = false;
        for (old) |o| {
            if (std.mem.eql(u8, o.path, n.path)) {
                found = true;
                if (o.mtime_ns != n.mtime_ns or o.size != n.size) return n.path;
                break;
            }
        }
        if (!found) return n.path; // added
    }
    for (old) |o| {
        var gone = true;
        for (new) |n| {
            if (std.mem.eql(u8, o.path, n.path)) {
                gone = false;
                break;
            }
        }
        if (gone) return o.path; // deleted
    }
    return null;
}

fn isSkipped(name: []const u8) bool {
    for (skip_dirs) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

fn resolveMain(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    const src = std.Io.Dir.cwd().readFileAlloc(io, "ff.json", allocator, .limited(1024 * 1024)) catch {
        std.debug.print("No ff.json found. Run 'ff init' first.\n", .{});
        std.process.exit(1);
    };
    defer allocator.free(src);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, src, .{}) catch {
        std.debug.print("ff.json is not valid JSON.\n", .{});
        std.process.exit(1);
    };
    defer parsed.deinit();
    const main_val = parsed.value.object.get("main") orelse {
        std.debug.print("ff.json is missing the 'main' field.\n", .{});
        std.process.exit(1);
    };
    return try allocator.dupe(u8, main_val.string);
}

fn freeList(allocator: std.mem.Allocator, list: *std.ArrayList(Snap)) void {
    for (list.items) |s| allocator.free(s.path);
    list.deinit(allocator);
}
