const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine/engine.zig");
const qjs = @import("engine/quickjs_shim.zig");
const tls = @import("net/tls.zig");
const ffcfg = @import("ffcfg");
const loop_mod = @import("event/loop.zig");
const init_cmd = @import("commands/init.zig");
const imprint_cmd = @import("commands/imprint.zig");
const sever_cmd = @import("commands/sever.zig");
const start_cmd = @import("commands/start.zig");
const bench_cmd = @import("commands/bench.zig");
const test_cmd = @import("commands/test.zig");
const repl_cmd = @import("commands/repl.zig");
const upgrade_cmd = @import("commands/upgrade.zig");
const compile_cmd = @import("commands/compile.zig");
const fmt_cmd = @import("commands/fmt.zig");
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
});
const Command = enum {
    init,
    imprint,
    sever,
    start,
    bench,
    test_cmd,
    repl,
    upgrade,
    compile,
    fmt,
    e_flag,
    file,
    version,
    none,
};
fn parseCommand(arg: []const u8) Command {
    if (std.mem.eql(u8, arg, "init")) return .init;
    if (std.mem.eql(u8, arg, "imprint")) return .imprint;
    if (std.mem.eql(u8, arg, "sever")) return .sever;
    if (std.mem.eql(u8, arg, "start")) return .start;
    if (std.mem.eql(u8, arg, "bench")) return .bench;
    if (std.mem.eql(u8, arg, "test")) return .test_cmd;
    if (std.mem.eql(u8, arg, "repl")) return .repl;
    if (std.mem.eql(u8, arg, "upgrade")) return .upgrade;
    if (std.mem.eql(u8, arg, "compile")) return .compile;
    if (std.mem.eql(u8, arg, "fmt")) return .fmt;
    if (std.mem.eql(u8, arg, "-e")) return .e_flag;
    if (std.mem.eql(u8, arg, "--version")) return .version;
    return .file;
}
fn shutdownRuntime(runtime: *engine.Runtime) void {
    engine.deinitNetwork();
    runtime.event_loop.deinit();
    runtime.deinit();
}
fn parseCaFlag(init: std.process.Init) void {
    var it = init.minimal.args.iterate();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--ca")) {
            tls.ca_file = it.next() orelse {
                std.debug.print("Error: --ca requires a path\n", .{});
                std.process.exit(1);
            };
            return;
        }
    }
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
        .init => {
            var gpa_state = std.heap.DebugAllocator(.{}).init;
            defer _ = gpa_state.deinit();
            const gpa = gpa_state.allocator();
            var rest = std.ArrayList([]const u8).empty;
            defer rest.deinit(gpa);
            while (args_iter.next()) |a| try rest.append(gpa, a);
            try init_cmd.run(init.io, rest.items);
        },
        .imprint => {
            var gpa_state = std.heap.DebugAllocator(.{}).init;
            defer _ = gpa_state.deinit();
            const gpa = gpa_state.allocator();
            var rest = std.ArrayList([]const u8).empty;
            defer rest.deinit(gpa);
            while (args_iter.next()) |a| try rest.append(gpa, a);
            try imprint_cmd.run(init.io, rest.items);
        },
        .sever => {
            var gpa_state = std.heap.DebugAllocator(.{}).init;
            defer _ = gpa_state.deinit();
            const gpa = gpa_state.allocator();
            var rest = std.ArrayList([]const u8).empty;
            defer rest.deinit(gpa);
            while (args_iter.next()) |a| try rest.append(gpa, a);
            try sever_cmd.run(init.io, rest.items);
        },
        .start => try start_cmd.run(init.io, init),
        .bench => try bench_cmd.run(init.io, init),
        .test_cmd => try test_cmd.run(init.io, init),
        .repl => try repl_cmd.run(init.io, init),
        .upgrade => try upgrade_cmd.run(init.io, init),
        .compile => try compile_cmd.run(init.io, init),
        .fmt => try fmt_cmd.run(init.io, init),
        .version => {
            std.debug.print("ff {s} ({s}-{s})\n", .{
                ffcfg.version,
                @tagName(builtin.os.tag),
                @tagName(builtin.cpu.arch),
            });
        },
        .e_flag => {
            const code = args_iter.next() orelse {
                std.debug.print("Error: -e requires an argument", .{});
                std.process.exit(1);
            };
            parseCaFlag(init);
            const runtime = try engine.Runtime.init(init.minimal.args);
            defer shutdownRuntime(runtime);
            _ = runtime.eval(code, "<eval>");
            runtime.event_loop.runWithMicrotasks(runtime.ctx);
        },
        .file => {
            parseCaFlag(init);
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
            const buf = try std.heap.page_allocator.allocSentinel(u8, size, 0);
            defer std.heap.page_allocator.free(buf);
            _ = c.fread(buf.ptr, 1, size, file);

            if (std.mem.endsWith(u8, first_arg, ".ffbc")) {
                const obj = qjs.readObject(runtime.ctx, buf.ptr, size, qjs.READ_OBJ_BYTECODE);
                defer qjs.freeValue(runtime.ctx, obj);
                if (qjs.isException(obj) != 0) {
                    const exc = qjs.getException(runtime.ctx);
                    defer qjs.freeValue(runtime.ctx, exc);
                    if (qjs.toCString(runtime.ctx, exc)) |m| {
                        defer qjs.freeCString(runtime.ctx, m);
                        std.debug.print("Error: {s}\n", .{m});
                    }
                    std.process.exit(1);
                }
                const result = qjs.evalFunction(runtime.ctx, obj);
                defer qjs.freeValue(runtime.ctx, result);
                if (qjs.isException(result) != 0) {
                    const exc = qjs.getException(runtime.ctx);
                    defer qjs.freeValue(runtime.ctx, exc);
                    if (qjs.toCString(runtime.ctx, exc)) |m| {
                        defer qjs.freeCString(runtime.ctx, m);
                        std.debug.print("Error: {s}\n", .{m});
                    }
                    std.process.exit(1);
                }
            } else {
                const source: [:0]const u8 = buf;
                _ = runtime.evalModule(source, first_arg);
            }
            runtime.event_loop.runWithMicrotasks(runtime.ctx);
        },
        .none => printUsage(),
    }
}
fn printUsage() void {
    std.debug.print("Usage:", .{});
    std.debug.print("  ff init [-y|--yes] [<dir>]  Initialize a new project", .{});
    std.debug.print("  ff imprint [pkg[@ver] ...]  Add exact dep(s) to ff.json + ff.lock", .{});
    std.debug.print("  ff sever [pkg ...] [--force]  Remove dep(s)", .{});
    std.debug.print("  ff start [--cert cert.pem --key key.pem]   Run the project", .{});
    std.debug.print("  ff bench             Run benchmarks", .{});
    std.debug.print("  ff test [filter]     Run test/*.test.js", .{});
    std.debug.print("  ff repl              Interactive REPL", .{});
    std.debug.print("  ff upgrade [--check] Self-update from GitHub Releases", .{});
    std.debug.print("  ff compile <f.js> [-o out.ffbc]  Compile to bytecode", .{});
    std.debug.print("  ff fmt [--write|--check] <files...>  Format via prettier", .{});
    std.debug.print("  ff -e <code>         Run inline JavaScript", .{});
    std.debug.print("  ff <file.js>         Run a JavaScript file", .{});
    std.debug.print("  ff --version         Print runtime version", .{});
}
