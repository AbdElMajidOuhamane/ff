const std = @import("std");
const cli = @import("../util/cli.zig");
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
                cli.failWithHint("-o requires a path", .{}, "usage: ff compile <file.js> [-o out.ffbc]", .{});
            };
        } else if (input == null) {
            input = a;
        }
    }
    const in_path = input orelse {
        cli.usageFail("ff compile <file.js> [-o out.ffbc]", "missing input file", .{});
    };
    const out_path = output orelse blk: {
        const dot = std.mem.lastIndexOfScalar(u8, in_path, '.') orelse in_path.len;
        break :blk try std.fmt.allocPrint(allocator, "{s}.ffbc", .{in_path[0..dot]});
    };
    defer if (output == null) allocator.free(out_path);

    const js = dir.readFileAlloc(io, in_path, allocator, .limited(20 * 1024 * 1024)) catch |err| {
        cli.failWithHint("cannot open '{s}': {s}", .{ in_path, cli.fileErrText(err) }, "check the path and try again", .{});
    };
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
    const fn_obj = qjs.eval(runtime.ctx, src.ptr, src.len, in_z.ptr, qjs.EVAL_TYPE_MODULE | qjs.EVAL_FLAG_COMPILE_ONLY);
    defer qjs.freeValue(runtime.ctx, fn_obj);
    if (qjs.isException(fn_obj) != 0) {
        const exc = qjs.getException(runtime.ctx);
        defer qjs.freeValue(runtime.ctx, exc);
        if (qjs.toCString(runtime.ctx, exc)) |m| {
            defer qjs.freeCString(runtime.ctx, m);
            cli.fail("compile failed in '{s}': {s}", .{ in_path, m });
        }
        cli.fail("compile failed in '{s}'", .{in_path});
    }
    var size: usize = 0;
    const buf = qjs.writeObject(runtime.ctx, &size, fn_obj, qjs.WRITE_OBJ_BYTECODE | qjs.WRITE_OBJ_STRIP_SOURCE | qjs.WRITE_OBJ_STRIP_DEBUG);
    if (buf == null) {
        cli.fail("could not write bytecode for '{s}'", .{in_path});
    }
    defer qjs.js_free(runtime.ctx, buf);
    dir.writeFile(io, .{ .sub_path = out_path, .data = buf[0..size] }) catch |err| {
        cli.failWithHint("cannot write '{s}': {s}", .{ out_path, cli.fileErrText(err) }, "check the output path", .{});
    };
    cli.ok("Compiled {s} → {s} ({d} bytes)", .{ in_path, out_path, size });
}
