const std = @import("std");
const engine = @import("../engine/engine.zig");
const qjs = @import("../engine/quickjs_shim.zig");
const microtasks = @import("../event/microtasks.zig");
const c = @cImport({
    @cInclude("stdio.h");
});

fn readLine(buf: []u8) ?[]const u8 {
    std.debug.print("ff> ", .{});
    const stdin_stream = if (@typeInfo(@TypeOf(c.stdin)) == .@"fn") c.stdin() else c.stdin;
    const line = c.fgets(@ptrCast(buf.ptr), @intCast(buf.len), stdin_stream) orelse return null;
    const len = std.mem.len(line);
    var s: []const u8 = buf[0..len];
    s = std.mem.trimEnd(u8, s, "\r\n");
    return s;
}

pub fn run(io: std.Io, init: std.process.Init) !void {
    _ = io;
    const allocator = std.heap.page_allocator;
    const runtime = try engine.Runtime.init(init.minimal.args);
    defer {
        engine.deinitNetwork();
        runtime.event_loop.deinit();
        runtime.deinit();
    }

    std.debug.print("Fairyfly REPL — .exit to quit, .clear to clear\n", .{});
    var buf: [8192]u8 = undefined;

    while (readLine(&buf)) |line| {
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, ".exit") or std.mem.eql(u8, line, ".quit")) break;
        if (std.mem.eql(u8, line, ".clear")) {
            std.debug.print("\x1b[2J\x1b[H", .{});
            continue;
        }

        const src = allocator.dupeZ(u8, line) catch continue;
        defer allocator.free(src);
        const result = qjs.eval(runtime.ctx, src.ptr, src.len, "<repl>", qjs.EVAL_TYPE_GLOBAL);
        defer qjs.freeValue(runtime.ctx, result);
        if (qjs.isException(result) != 0) {
            const exc = qjs.getException(runtime.ctx);
            defer qjs.freeValue(runtime.ctx, exc);
            if (qjs.toCString(runtime.ctx, exc)) |m| {
                defer qjs.freeCString(runtime.ctx, m);
                std.debug.print("Error: {s}\n", .{m});
            }
        } else {
            if (qjs.isUndefined(result) == 0) {
                if (qjs.toCString(runtime.ctx, result)) |s| {
                    defer qjs.freeCString(runtime.ctx, s);
                    std.debug.print("{s}\n", .{s});
                }
            }
        }
        microtasks.pumpMicrotasks(runtime.ctx);
        runtime.event_loop.runWithMicrotasks(runtime.ctx);
    }
    std.debug.print("\n", .{});
}
