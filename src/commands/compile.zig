const std = @import("std");
const engine = @import("../engine/engine.zig");
const qjs = @import("../engine/quickjs_shim.zig");

// ff compile <file.js> [-o out.ffbc] — JS -> bytecode (source stripped).
// Run back with: ff <file.ffbc> (loader detects .ffbc magic).
pub fn run(io: std.Io, init: std.process.Init) !void {
    const dir = std.Io.Dir.cwd();
    const allocator = std.heap.page_allocator;

    var input: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var it = init.minimal.args.iterate();
    _ = it.next(); // ff
    _ = it.next(); // compile
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--output")) {
            output = it.next() orelse {
                std.debug.print("ff compile: -o requires a path\n", .{});
                return;
            };
        } else if (input == null) {
            input = a;
        }
    }
    const in_path = input orelse {
        std.debug.print("Usage: ff compile <file.js> [-o out.ffbc]\n", .{});
        return;
    };
    const out_path = output orelse blk: {
        const dot = std.mem.lastIndexOfScalar(u8, in_path, '.') orelse in_path.len;
        break :blk try std.fmt.allocPrint(allocator, "{s}.ffbc", .{in_path[0..dot]});
    };
    defer if (output == null) allocator.free(out_path);

    const js = try dir.readFileAlloc(io, in_path, allocator, .limited(20 * 1024 * 1024));
    defer allocator.free(js);
    const src: [:0]const u8 = try allocator.dupeZ(u8, js);
    defer allocator.free(src);

    const runtime = try engine.Runtime.init(init.minimal.args);
    defer {
        engine.deinitNetwork();
        runtime.event_loop.deinit();
        runtime.deinit();
    }

    const in_z = try allocator.dupeZ(u8, in_path);
    defer allocator.free(in_z);
    const fn_obj = qjs.eval(runtime.ctx, src.ptr, src.len, in_z.ptr,
        qjs.EVAL_TYPE_MODULE | qjs.EVAL_FLAG_COMPILE_ONLY);
    defer qjs.freeValue(runtime.ctx, fn_obj);
    if (qjs.isException(fn_obj) != 0) {
        std.debug.print("compile error in '{s}'\n", .{in_path});
        return;
    }
    var size: usize = 0;
    const buf = qjs.writeObject(runtime.ctx, &size, fn_obj,
        qjs.WRITE_OBJ_BYTECODE | qjs.WRITE_OBJ_STRIP_SOURCE | qjs.WRITE_OBJ_STRIP_DEBUG);
    if (buf == null) {
        std.debug.print("compile: JS_WriteObject failed\n", .{});
        return;
    }
    defer qjs.js_free(runtime.ctx, buf);
    try dir.writeFile(io, .{ .sub_path = out_path, .data = buf[0..size] });
    std.debug.print("Compiled {s} -> {s} ({d} bytes)\n", .{ in_path, out_path, size });
}
