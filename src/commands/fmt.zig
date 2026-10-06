const std = @import("std");

// ff fmt [--write|--check] <files...> — delegate to prettier.
pub fn run(io: std.Io, init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    var write = false;
    var files = std.ArrayList([]const u8).empty;
    defer files.deinit(allocator);

    var it = init.minimal.args.iterate();
    _ = it.next();
    _ = it.next();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--write") or std.mem.eql(u8, a, "-w")) {
            write = true;
        } else if (std.mem.eql(u8, a, "--check")) {
            write = false;
        } else {
            try files.append(allocator, a);
        }
    }
    if (files.items.len == 0) {
        std.debug.print("Usage: ff fmt [--write|--check] <files...>\n", .{});
        return;
    }
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "npx", "--yes", "prettier", if (write) "--write" else "--check" });
    try argv.appendSlice(allocator, files.items);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    defer child.kill(io);
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) {
        std.debug.print("ff fmt: prettier failed (install with `npm i -g prettier`?)\n", .{});
        std.process.exit(1);
    }
}
