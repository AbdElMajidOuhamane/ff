const std = @import("std");
const Io = std.Io;
const Alloc = std.mem.Allocator;
const c = @cImport({
    @cInclude("stdio.h");
});

// ff init [-y|--yes] [<dir>] — npm-style interactive scaffolding.
// Prompts: name, version, description, entry point, author, license.
// Enter accepts default. -y/--yes skips all prompts. Always overwrites.
pub fn run(io: Io, args: []const []const u8) !void {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var yes = false;
    var target_dir: ?[]const u8 = null;
    for (args) |a| {
        if (std.mem.eql(u8, a, "-y") or std.mem.eql(u8, a, "--yes")) {
            yes = true;
        } else if (target_dir == null) {
            target_dir = a;
        } else {
            std.debug.print("Unexpected argument '{s}'. Usage: ff init [-y|--yes] [<dir>]\n", .{a});
            return error.InvalidArgs;
        }
    }

    // Resolve target dir prefix: "" = cwd, else "dir/".
    var prefix: []const u8 = "";
    var prefix_owned: ?[]u8 = null;
    defer if (prefix_owned) |p| gpa.free(p);
    var default_name_owned: []u8 = try dupeDefaultName(gpa, io, target_dir);
    defer gpa.free(default_name_owned);

    if (target_dir) |d| {
        // mkdir -p target (cwd-relative)
        Io.Dir.cwd().createDirPath(io, d) catch |err| {
            std.debug.print("Could not create directory '{s}': {s}\n", .{ d, @errorName(err) });
            return err;
        };
        prefix_owned = try std.fmt.allocPrint(gpa, "{s}/", .{std.mem.trimEnd(u8, d, "/")});
        prefix = prefix_owned.?;
        // Default name = basename of target dir, sanitized.
        gpa.free(default_name_owned);
        default_name_owned = try sanitizeName(gpa, std.fs.path.basename(std.mem.trimEnd(u8, d, "/")));
        if (default_name_owned.len == 0) {
            gpa.free(default_name_owned);
            default_name_owned = try gpa.dupe(u8, "my-app");
        }
    }

    // ── Prompt (or defaults with -y) ──
    const name = if (yes) try gpa.dupe(u8, default_name_owned) else try prompt(gpa, "package name", default_name_owned);
    defer gpa.free(name);
    const version = if (yes) try gpa.dupe(u8, "1.0.0") else try prompt(gpa, "version", "1.0.0");
    defer gpa.free(version);
    const description = if (yes) try gpa.dupe(u8, "") else try prompt(gpa, "description", "");
    defer gpa.free(description);
    const main = if (yes) try gpa.dupe(u8, "main.js") else try prompt(gpa, "entry point", "main.js");
    defer gpa.free(main);
    const author = if (yes) try gpa.dupe(u8, "") else try prompt(gpa, "author", "");
    defer gpa.free(author);
    const license = if (yes) try gpa.dupe(u8, "ISC") else try prompt(gpa, "license", "ISC");
    defer gpa.free(license);

    const final_name = if (name.len == 0) default_name_owned else name;
    const final_version = if (version.len == 0) "1.0.0" else version;
    const final_main = if (main.len == 0) "main.js" else main;
    const final_license = if (license.len == 0) "ISC" else license;

    // ── Build ff.json ──
    var root: std.json.Value = .{ .object = .{} };
    defer root.object.deinit(gpa);
    try root.object.put(gpa, try gpa.dupe(u8, "name"), .{ .string = try gpa.dupe(u8, final_name) });
    try root.object.put(gpa, try gpa.dupe(u8, "version"), .{ .string = try gpa.dupe(u8, final_version) });
    if (description.len > 0) try root.object.put(gpa, try gpa.dupe(u8, "description"), .{ .string = try gpa.dupe(u8, description) });
    try root.object.put(gpa, try gpa.dupe(u8, "main"), .{ .string = try gpa.dupe(u8, final_main) });
    if (author.len > 0) try root.object.put(gpa, try gpa.dupe(u8, "author"), .{ .string = try gpa.dupe(u8, author) });
    try root.object.put(gpa, try gpa.dupe(u8, "license"), .{ .string = try gpa.dupe(u8, final_license) });
    try root.object.put(gpa, try gpa.dupe(u8, "dependencies"), .{ .object = .{} });

    const out = try std.json.Stringify.valueAlloc(gpa, root, .{ .whitespace = .indent_2 });
    defer gpa.free(out);

    // ── Write files (always overwrite) ──
    const dir = Io.Dir.cwd();
    const main_content =
        \\console.log("Hello from fairyfly!");
        \\
    ;
    const main_path = try std.fmt.allocPrint(gpa, "{s}{s}", .{ prefix, final_main });
    defer gpa.free(main_path);
    try dir.writeFile(io, .{ .sub_path = main_path, .data = main_content });

    const ff_path = try std.fmt.allocPrint(gpa, "{s}ff.json", .{prefix});
    defer gpa.free(ff_path);
    try dir.writeFile(io, .{ .sub_path = ff_path, .data = out });

    // ── Done (bun/deno style: no banner, just files + next steps) ──
    std.debug.print("\nDone! {s}@{s} initialized.\n", .{ final_name, final_version });
    std.debug.print(" + {s}\n", .{main_path});
    std.debug.print(" + {s}\n", .{ff_path});
    std.debug.print("\nTo get started, run:\n", .{});
    if (target_dir) |d| {
        std.debug.print("  cd {s}\n", .{std.mem.trimEnd(u8, d, "/")});
    }
    std.debug.print("  ff {s}\n", .{final_main});
    std.debug.print("  ff start\n", .{});
}

// "question (default): " — Enter/EOF accepts default. fgets via libc,
// same portable stdin pattern as sever.zig (glibc fn vs musl global).
fn prompt(gpa: Alloc, label: []const u8, def: []const u8) ![]u8 {
    if (def.len == 0) {
        std.debug.print("{s}: ", .{label});
    } else {
        std.debug.print("{s} ({s}): ", .{ label, def });
    }
    var buf: [512]u8 = undefined;
    const stdin_stream = if (@typeInfo(@TypeOf(c.stdin)) == .@"fn") c.stdin() else c.stdin;
    const line = c.fgets(@ptrCast(&buf), buf.len, stdin_stream) orelse {
        return try gpa.dupe(u8, def);
    };
    const len = std.mem.len(line);
    var s: []const u8 = buf[0..len];
    s = std.mem.trimEnd(u8, s, "\r\n");
    s = std.mem.trim(u8, s, " \t");
    if (s.len == 0) return try gpa.dupe(u8, def);
    return try gpa.dupe(u8, s);
}

// Default name: basename of cwd, sanitized (npm-style lowercase/dashes).
// target == null here; the [dir] case is handled in run().
fn dupeDefaultName(gpa: Alloc, io: Io, target: ?[]const u8) ![]u8 {
    _ = target;
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const len = std.process.currentPath(io, &buf) catch return try gpa.dupe(u8, "my-app");
    const base = std.fs.path.basename(buf[0..len]);
    return sanitizeName(gpa, base);
}

fn sanitizeName(gpa: Alloc, raw: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, raw.len);
    errdefer gpa.free(out);
    var n: usize = 0;
    for (raw) |ch| {
        var lower = ch;
        if (ch >= 'A' and ch <= 'Z') lower = ch + 32;
        if ((lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9') or lower == '-' or lower == '_' or lower == '.') {
            out[n] = lower;
            n += 1;
        } else if (ch == ' ' or ch == '/' or ch == '\\') {
            out[n] = '-';
            n += 1;
        }
        // drop all other chars (npm-style)
    }
    // trim leading ./-_ (npm disallows)
    var start: usize = 0;
    while (start < n and (out[start] == '.' or out[start] == '_' or out[start] == '-')) : (start += 1) {}
    const res = try gpa.dupe(u8, out[start..n]);
    gpa.free(out);
    return res;
}
