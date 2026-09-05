const std = @import("std");
const Io = std.Io;
const ffcfg = @import("ffcfg");

pub fn run(io: Io) !void {
    const dir = Io.Dir.cwd();
    const gpa = std.heap.page_allocator;

    const main_content =
        \\console.log("Hello from fairyfly!");
        \\
    ;
    try dir.writeFile(io, .{ .sub_path = "main.js", .data = main_content });

    // Project version = the runtime version scaffolding it (matches ff --version).
    const ff_json_content = try std.fmt.allocPrint(gpa,
        \\{{
        \\  "name": "my-app",
        \\  "version": "{s}",
        \\  "main": "main.js"
        \\}}
        \\
    , .{ffcfg.version});
    defer gpa.free(ff_json_content);
    try dir.writeFile(io, .{ .sub_path = "ff.json", .data = ff_json_content });
    // Logo
    const ff_logo = try std.fmt.allocPrint(gpa,
        \\                            ||
        \\                     Fairyfly v{s}
        \\███████╗  █████╗  ██╗ ██████╗  ██╗   ██╗ ███████╗ ██╗       ██╗   ██╗
        \\██╔════╝ ██╔══██╗ ██║ ██╔══██╗ ╚██╗ ██╔╝ ██╔════╝ ██║       ╚██╗ ██╔╝
        \\█████╗   ███████║ ██║ ██████╔╝  ╚████╔╝  █████╗   ██║        ╚████╔╝
        \\██╔══╝   ██╔══██║ ██║ ██╔══██╗   ╚██╔╝   ██╔══╝   ██║         ╚██╔╝
        \\██║      ██║  ██║ ██║ ██║  ██║    ██║    ██║      ███████╗     ██║
        \\
    , .{ffcfg.version});
    defer gpa.free(ff_logo);
    std.debug.print("Initialized fairyfly project\n", .{});
    std.debug.print("{s}\n", .{ff_logo});
    std.debug.print("  main.js  — entry point\n", .{});
    std.debug.print("  ff.json  — project config\n", .{});
    std.debug.print("\nRun: ff main.js\n", .{});
}
