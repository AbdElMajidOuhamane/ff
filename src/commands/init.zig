
const std = @import("std");
const Io=std.Io;


pub fn run(io: Io) !void {
    const dir = Io.Dir.cwd();
    
    const main_content =
        \\console.log("Hello from fairyfly!");
        \\
    ;
    try dir.writeFile(io, .{ .sub_path = "main.js", .data = main_content });
    
    const ff_json_content =
        \\{
        \\  "name": "my-app",
        \\  "version": "0.0.1",
        \\  "main": "main.js"
        \\}
        \\
    ;
    try dir.writeFile(io, .{ .sub_path = "ff.json", .data = ff_json_content });
    // Logo
     const ff_logo =
\\                            ||
\\                     Fairyfly v0.0.1
\\███████╗  █████╗  ██╗ ██████╗  ██╗   ██╗ ███████╗ ██╗       ██╗   ██╗
\\██╔════╝ ██╔══██╗ ██║ ██╔══██╗ ╚██╗ ██╔╝ ██╔════╝ ██║       ╚██╗ ██╔╝
\\█████╗   ███████║ ██║ ██████╔╝  ╚████╔╝  █████╗   ██║        ╚████╔╝ 
\\██╔══╝   ██╔══██║ ██║ ██╔══██╗   ╚██╔╝   ██╔══╝   ██║         ╚██╔╝  
\\██║      ██║  ██║ ██║ ██║  ██║    ██║    ██║      ███████╗     ██║   
;
    std.debug.print("Initialized fairyfly project\n", .{});
    std.debug.print("{s}\n", .{ff_logo});
    std.debug.print("  main.js  — entry point\n", .{});
    std.debug.print("  ff.json  — project config\n", .{});
    std.debug.print("\nRun: ff main.js\n", .{});
}

