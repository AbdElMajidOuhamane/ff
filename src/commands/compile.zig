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
    var standalone: bool = false;
    var it = init.minimal.args.iterate();
    _ = it.next(); // ff
    _ = it.next(); // compile
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--output")) {
            output = it.next() orelse {
                cli.failWithHint("-o requires a path", .{}, "usage: ff compile <file.js> [-o out.ffbc] [--standalone]", .{});
            };
        } else if (std.mem.eql(u8, a, "--standalone")) {
            standalone = true;
        } else if (input == null) {
            input = a;
        }
    }
    const in_path = input orelse {
        cli.usageFail("ff compile <file.js> [-o out.ffbc]", "missing input file", .{});
    };
    const out_path = output orelse blk: {
        if (standalone) {
            const dot = std.mem.lastIndexOfScalar(u8, in_path, '.') orelse in_path.len;
            break :blk try std.fmt.allocPrint(allocator, "{s}", .{in_path[0..dot]});
        }
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

    if (standalone) {
        if (std.mem.indexOf(u8, js, "import ") != null or std.mem.indexOf(u8, js, "import(") != null) {
            cli.failWithHint("standalone compilation does not support imports yet", .{}, "bundle your application into a single self-contained file first", .{});
        }
        var self_exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.process.executablePath(io, &self_exe_buf) catch {
            cli.fail("could not determine self executable path", .{});
        };
        const self_exe = self_exe_buf[0..n];
        const self_bin = dir.readFileAlloc(io, self_exe, allocator, .unlimited) catch |err| {
            cli.fail("could not read self executable: {s}", .{cli.fileErrText(err)});
        };
        defer allocator.free(self_bin);

        const trailer_magic = "FFSTANDA";
        const build_hash = std.hash.Wyhash.hash(0, self_bin);
        const total_len = self_bin.len + size + trailer_magic.len + 8 + 8;
        const out_bin = try allocator.alloc(u8, total_len);
        defer allocator.free(out_bin);

        @memcpy(out_bin[0..self_bin.len], self_bin);
        @memcpy(out_bin[self_bin.len..][0..size], buf[0..size]);
        const trailer_start = self_bin.len + size;
        @memcpy(out_bin[trailer_start..][0..trailer_magic.len], trailer_magic);
        std.mem.writeInt(u64, out_bin[trailer_start + trailer_magic.len ..][0..8], @intCast(size), .little);
        std.mem.writeInt(u64, out_bin[trailer_start + trailer_magic.len + 8 ..][0..8], build_hash, .little);

        dir.writeFile(io, .{ .sub_path = out_path, .data = out_bin }) catch |err| {
            cli.failWithHint("cannot write '{s}': {s}", .{ out_path, cli.fileErrText(err) }, "check the output path", .{});
        };
        const out_z = try allocator.dupeZ(u8, out_path);
        defer allocator.free(out_z);
        _ = std.c.chmod(out_z.ptr, 0o755);
        cli.ok("Compiled standalone binary {s} → {s} ({d} bytes)", .{ in_path, out_path, total_len });
        return;
    }

    dir.writeFile(io, .{ .sub_path = out_path, .data = buf[0..size] }) catch |err| {
        cli.failWithHint("cannot write '{s}': {s}", .{ out_path, cli.fileErrText(err) }, "check the output path", .{});
    };
    cli.ok("Compiled {s} → {s} ({d} bytes)", .{ in_path, out_path, size });
}
