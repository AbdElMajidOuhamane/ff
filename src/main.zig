const std = @import("std");
const engine = @import("engine/engine.zig");
const init_cmd = @import("commands/init.zig");
const start_cmd = @import("commands/start.zig");
const bench_cmd = @import("commands/bench.zig");
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
});
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
fn shutdownRuntime(runtime: *engine.Runtime) void {
    engine.deinitNetwork();
    runtime.event_loop.deinit();
    std.heap.page_allocator.destroy(runtime.event_loop);
    runtime.deinit();
    std.heap.page_allocator.destroy(runtime);
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
        .bench => try bench_cmd.run(init.io, init),
        .e_flag => {
            const code = args_iter.next() orelse {
                std.debug.print("Error: -e requires an argument", .{});
                std.process.exit(1);
            };
            const runtime = try engine.Runtime.init(init.minimal.args);
            defer shutdownRuntime(runtime);
            _ = runtime.eval(code, "<eval>");
            runtime.event_loop.runWithMicrotasks(runtime.isolate);
        },
        .file => {
            const runtime = try engine.Runtime.init(init.minimal.args);
            defer shutdownRuntime(runtime);
            const file = c.fopen(first_arg.ptr, "rb") orelse {
                std.debug.print("Error: could not open file '{s}'", .{first_arg});
                std.process.exit(1);
            };
            defer _ = c.fclose(file);
            _ = c.fseek(file, 0, c.SEEK_END);
            const size: usize = @intCast(c.ftell(file));
            _ = c.fseek(file, 0, c.SEEK_SET);
            // Sentinel-terminated allocation: the previous alloc(u8, size)
            // + [0..size :0] claim read one byte past the buffer.
            const buf = try std.heap.page_allocator.allocSentinel(u8, size, 0);
            defer std.heap.page_allocator.free(buf);
            _ = c.fread(buf.ptr, 1, size, file);
            const source: [:0]const u8 = buf;
            _ = runtime.evalModule(source, first_arg);
            runtime.event_loop.runWithMicrotasks(runtime.isolate);
        },
        .none => printUsage(),
    }
}
fn printUsage() void {
    std.debug.print("Usage:", .{});
    std.debug.print("  ff init              Initialize a new project", .{});
    std.debug.print("  ff start             Run the project's main file", .{});
    std.debug.print("  ff bench             Run benchmarks", .{});
    std.debug.print("  ff -e <code>         Run inline JavaScript", .{});
    std.debug.print("  ff <file.js>         Run a JavaScript file", .{});
}
