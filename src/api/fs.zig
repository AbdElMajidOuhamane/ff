const std = @import("std");
const c = @import("../c.zig").c;

const Io = std.Io;
const Dir = Io.Dir;

const gpa = std.heap.smp_allocator;

const MAX_PATH = 4096;
const MAX_READ = 10 * 1024 * 1024;

fn getIo() Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn jsPathArg(ctx: ?*c.Context, argc: c_int, argv: [*c]const c.Value, index: c_int, buf: []u8) ?[]const u8 {
    if (argc <= index) return null;
    const val = argv[@intCast(index)];
    if (c.isString(val) == 0) return null;
    var str_len: usize = 0;
    const str_ptr = c.toCStringLen(ctx, &str_len, val) orelse return null;
    defer c.freeCString(ctx, str_ptr);
    const len = @min(str_len, buf.len);
    @memcpy(buf[0..len], str_ptr[0..len]);
    return buf[0..len];
}

fn throwErr(ctx: ?*c.Context, msg: []const u8) void {
    const msg_val = c.newStringLen(ctx, msg.ptr, msg.len);
    _ = c.throw(ctx, msg_val);
}

fn jsBoolArg(ctx: ?*c.Context, argc: c_int, argv: [*c]const c.Value, index: c_int) bool {
    if (argc <= index) return false;
    return c.toBool(ctx, argv[@intCast(index)]) != 0;
}

fn readFileCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = jsPathArg(ctx, argc, argv, 0, &path_buf) orelse return c.JS_UNDEFINED;

    const io = getIo();
    const content = Dir.cwd().readFileAlloc(
        io,
        path,
        gpa,
        .limited(MAX_READ),
    ) catch |err| {
        throwErr(ctx, @errorName(err));
        return c.JS_UNDEFINED;
    };
    defer gpa.free(content);

    return c.newStringLen(ctx, content.ptr, content.len);
}

fn writeFileCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = jsPathArg(ctx, argc, argv, 0, &path_buf) orelse return c.JS_UNDEFINED;

    if (argc < 2) return c.JS_UNDEFINED;
    const data_val = argv[1];
    var str_len: usize = 0;
    const str_ptr = c.toCStringLen(ctx, &str_len, data_val) orelse return c.JS_UNDEFINED;
    defer c.freeCString(ctx, str_ptr);
    const data_final = @min(str_len, MAX_READ);

    const io = getIo();
    Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = str_ptr[0..data_final],
    }) catch |err| {
        throwErr(ctx, @errorName(err));
    };
    return c.JS_UNDEFINED;
}

fn existsCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = jsPathArg(ctx, argc, argv, 0, &path_buf) orelse return c.JS_FALSE;

    const io = getIo();
    const found = if (Dir.cwd().access(io, path, .{})) true else |_| false;
    return if (found) c.JS_TRUE else c.JS_FALSE;
}

fn mkdirCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = jsPathArg(ctx, argc, argv, 0, &path_buf) orelse return c.JS_UNDEFINED;

    const recursive = jsBoolArg(ctx, argc, argv, 1);
    const io = getIo();

    if (recursive) {
        Dir.cwd().createDirPath(io, path) catch |err| {
            throwErr(ctx, @errorName(err));
        };
    } else {
        Dir.cwd().createDir(io, path, .default_dir) catch |err| {
            throwErr(ctx, @errorName(err));
        };
    }
    return c.JS_UNDEFINED;
}

fn rmCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = jsPathArg(ctx, argc, argv, 0, &path_buf) orelse return c.JS_UNDEFINED;

    const recursive = jsBoolArg(ctx, argc, argv, 1);
    const io = getIo();

    if (recursive) {
        Dir.cwd().deleteTree(io, path) catch |err| {
            throwErr(ctx, @errorName(err));
        };
    } else {
        Dir.cwd().deleteFile(io, path) catch {
            Dir.cwd().deleteDir(io, path) catch |err| {
                throwErr(ctx, @errorName(err));
            };
        };
    }
    return c.JS_UNDEFINED;
}

fn readdirCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;

    var path_buf: [MAX_PATH]u8 = undefined;
    const path = jsPathArg(ctx, argc, argv, 0, &path_buf) orelse return c.JS_UNDEFINED;

    const io = getIo();
    var dir = Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        throwErr(ctx, @errorName(err));
        return c.JS_UNDEFINED;
    };
    defer dir.close(io);

    var names = std.ArrayList([:0]const u8).empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        const name = gpa.dupeZ(u8, entry.name) catch continue;
        names.append(gpa, name) catch continue;
    }

    const arr = c.newArray(ctx);
    for (names.items, 0..) |name, i| {
        const js_name = c.newStringLen(ctx, name.ptr, name.len);
        _ = c.setPropertyUint32(ctx, arr, @intCast(i), js_name);
    }
    return arr;
}

pub fn setup(ctx: *c.Context) void {
    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);
    const fs_obj = c.newObject(ctx);

    const readFile_fn = c.newCFunction(ctx, readFileCallback, "readFile", 2);
    _ = c.definePropertyValueStr(ctx, fs_obj, "readFile", readFile_fn, c.PROP_C_W_E);

    const writeFile_fn = c.newCFunction(ctx, writeFileCallback, "writeFile", 2);
    _ = c.definePropertyValueStr(ctx, fs_obj, "writeFile", writeFile_fn, c.PROP_C_W_E);

    const exists_fn = c.newCFunction(ctx, existsCallback, "exists", 1);
    _ = c.definePropertyValueStr(ctx, fs_obj, "exists", exists_fn, c.PROP_C_W_E);

    const mkdir_fn = c.newCFunction(ctx, mkdirCallback, "mkdir", 2);
    _ = c.definePropertyValueStr(ctx, fs_obj, "mkdir", mkdir_fn, c.PROP_C_W_E);

    const rm_fn = c.newCFunction(ctx, rmCallback, "rm", 2);
    _ = c.definePropertyValueStr(ctx, fs_obj, "rm", rm_fn, c.PROP_C_W_E);

    const readdir_fn = c.newCFunction(ctx, readdirCallback, "readdir", 1);
    _ = c.definePropertyValueStr(ctx, fs_obj, "readdir", readdir_fn, c.PROP_C_W_E);

    _ = c.definePropertyValueStr(ctx, global, "fs", fs_obj, c.PROP_C_W_E);
}
