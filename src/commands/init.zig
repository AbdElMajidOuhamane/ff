const std = @import("std");
const Io = std.Io;
const version_meta = @import("../version.zig");

pub fn run(io: Io) !void {
    const dir = Io.Dir.cwd();

    const main_content =
        \\console.log("Hello from fairyfly!");
        \\
    ;
    try dir.writeFile(io, .{ .sub_path = "main.js", .data = main_content });

    const ff_json_content = std.fmt.comptimePrint(
        \\{{
        \\  "name": "my-app",
        \\  "version": "{s}",
        \\  "main": "main.js"
        \\}}
        \\
    , .{version_meta.version});
    try dir.writeFile(io, .{ .sub_path = "ff.json", .data = ff_json_content });

    // Logo
    const ff_logo =
        \\                            ||
        \\                     Fairyfly v{s}
        \\███████╗  █████╗  ██╗ ██████╗  ██╗   ██╗ ███████╗ ██╗       ██╗   ██╗
        \\██╔════╝ ██╔══██╗ ██║ ██╔══██╗ ╚██╗ ██╔╝ ██╔════╝ ██║       ╚██╗ ██╔╝
        \\█████╗   ███████║ ██║ ██████╔╝  ╚████╔╝  █████╗   ██║        ╚████╔╝ 
        \\██╔══╝   ██╔══██║ ██║ ██╔══██╗   ╚██╔╝   ██╔══╝   ██║         ╚██╔╝  
        \\██║      ██║  ██║ ██║ ██║  ██║    ██║    ██║      ███████╗     ██║   
        \\
    ;
    std.debug.print("Initialized fairyfly project\n", .{});
    std.debug.print(ff_logo, .{version_meta.version});
    std.debug.print("  main.js  — entry point\n", .{});
    std.debug.print("  ff.json  — project config\n", .{});
    std.debug.print("\nRun: ff main.js\n", .{});
}
