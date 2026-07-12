
const std = @import("std");
pub fn run(io: std.Io) !void {
    const dir = std.Io.Dir.cwd();
    // Create main.js
    const main_content =
        \\console.log("Hello from fairyfly!");
        \\
    ;
    try dir.writeFile(io, .{ .sub_path = "main.js", .data = main_content });
    // Create ff.json
    const ff_json_content =
        \\{
        \\  "name": "my-app",
        \\  "version": "1.0.0",
        \\  "main": "main.js"
        \\}
        \\
    ;
    try dir.writeFile(io, .{ .sub_path = "ff.json", .data = ff_json_content });
    // Logo
    const ff_logo =
        \\    /||    ||\
        \\   / ||    || \
        \\  | /||    ||\ |
        \\  |/ ||    || \|
        \\    \||    ||/
        \\     \\    //
        \\      \\  //
        \\       \\//
        \\        ||
        \\        ||
        \\    Fairyfly v1.0.0
    ;
    std.debug.print("Initialized fairyfly project\n", .{});
    std.debug.print("{s}\n", .{ff_logo});
    std.debug.print("  main.js  — entry point\n", .{});
    std.debug.print("  ff.json  — project config\n", .{});
    std.debug.print("\nRun: ff main.js\n", .{});
}

