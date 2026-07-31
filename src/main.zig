const std = @import("std");
const engine = @import("engine/engine.zig");
const init_cmd = @import("commands/init.zig");
const start_cmd = @import("commands/start.zig");
const bench_cmd = @import("commands/bench.zig");
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
});
const microtasks =@import("./event/microtasks.zig");

const Command = enum {
    init,
    start,
    bench,
    e_flag,
    file,
    none,
};
fn parseCommand(arg: []const u8) Command {
    if (std.mem.eql(u8, arg, "init")) return .init;
    if (std.mem.eql(u8, arg, "start")) return .start;
    if (std.mem.eql(u8, arg, "bench")) return .bench;
    if (std.mem.eql(u8, arg, "-e")) return .e_flag;
    return .file;
}
pub fn main(init: std.process.Init) !void {
    var args_iter = init.minimal.args.iterate();
    _ = args_iter.next();
    const first_arg = args_iter.next() orelse {
        printUsage();
        return;
    };
    const cmd = parseCommand(first_arg);
    switch (cmd) {
        .init => try init_cmd.run(init.io),
        .start => try start_cmd.run(init.io, init),
        .bench => try bench_cmd.run(init.io,init),
        .e_flag => {
            const code = args_iter.next() orelse {
            std.debug.print("Error: -e requires an argument\n", .{});
            std.process.exit(1);
                };
            const runtime = try engine.Runtime.init(init.minimal.args);
            defer {
                runtime.event_loop.deinit();
                std.heap.page_allocator.destroy(runtime.event_loop);
                runtime.deinit();
                std.heap.page_allocator.destroy(runtime);
            }
            _ = runtime.eval(code, "<eval>");
            try runtime.event_loop.run();},
        .file => {
                 const runtime = try engine.Runtime.init(init.minimal.args);
                defer {
                    runtime.event_loop.deinit();
                    std.heap.page_allocator.destroy(runtime.event_loop);
                    runtime.deinit();
                    std.heap.page_allocator.destroy(runtime);
                     }   
                const file = c.fopen(first_arg.ptr, "rb") orelse {

                std.debug.print("Error: could not open file '{s}'\n", .{first_arg});
                std.process.exit(1);
            };
            defer _ = c.fclose(file);
            _ = c.fseek(file, 0, c.SEEK_END);
            const size: usize = @intCast(c.ftell(file));
            _ = c.fseek(file, 0, c.SEEK_SET);
            const buf = try std.heap.page_allocator.alloc(u8, size);
            defer std.heap.page_allocator.free(buf);
            _ = c.fread(buf.ptr, 1, size, file);
            const source: [:0]const u8 = buf.ptr[0..size :0];
             _ = runtime.evalModule(source, first_arg);
            microtasks.pumpMicrotasks(runtime.isolate);
            try runtime.event_loop.run();

            
        },
        .none => printUsage(),
    }
}
fn printUsage() void {
    std.debug.print("Usage:\n", .{});
    std.debug.print("  ff init              Initialize a new project\n", .{});
    std.debug.print("  ff start             Run the project's main file\n", .{});
    std.debug.print("  ff bench             Run benchmarks\n", .{});
    std.debug.print("  ff -e <code>         Run inline JavaScript\n", .{});
    std.debug.print("  ff <file.js>         Run a JavaScript file\n", .{});
}
