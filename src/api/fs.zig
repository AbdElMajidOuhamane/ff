const std = @import("std");
const c = @import("../c.zig").c;

const Io = std.Io;
const Dir = Io.Dir;

// Thread-safe general-purpose allocator: no mmap/munmap syscall pair per
// allocation (mirrors fetch.zig's rationale).
const gpa = std.heap.smp_allocator;

const MAX_PATH = 4096;
const MAX_READ = 10 * 1024 * 1024;

// ============================================================
// Helpers
// ============================================================

fn getIo() Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Extracts a string argument into the CALLER-provided buffer and returns a
/// borrowed slice of it — zero heap allocations on the hot path. All fs
/// consumers take plain []const u8 (std.Io.Dir APIs), so no sentinel needed.
fn jsPathArg(info: ?*const c.FunctionCallbackInfo, index: c_int, buf: []u8) ?[]const u8 {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    if (c.v8__FunctionCallbackInfo__Length(info) <= index) return null;
    const val = c.v8__FunctionCallbackInfo__INDEX(info, index);
    if (!c.v8__Value__IsString(val)) return null;
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    const str = c.v8__Value__ToDetailString(val, context);
    if (str == null) return null;
    const utf8_len: usize = @intCast(c.v8__String__Utf8Length(str, isolate));
    const len = @min(utf8_len, buf.len);
    _ = c.v8__String__WriteUtf8(str, isolate, buf.ptr, @intCast(len), 0);
    return buf[0..len];
}

fn throw(isolate: ?*c.Isolate, msg: []const u8) void {
    const v8_msg = c.v8__String__NewFromUtf8(isolate, @ptrCast(msg.ptr), 0, @intCast(msg.len));
    const exc = c.v8__Exception__Error(v8_msg);
    _ = c.v8__Isolate__ThrowException(isolate, exc);
}

fn jsBoolArg(info: ?*const c.FunctionCallbackInfo, index: c_int) bool {
    if (c.v8__FunctionCallbackInfo__Length(info) <= index) return false;
    const val = c.v8__FunctionCallbackInfo__INDEX(info, index);
    return c.v8__Value__BooleanValue(val, c.v8__FunctionCallbackInfo__GetIsolate(info));
}

// ============================================================
// readFile(path, "utf8")
// ============================================================

fn readFileCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = jsPathArg(info, 0, &path_buf) orelse return;

    const io = getIo();
    const content = Dir.cwd().readFileAlloc(
        io,
        path,
        gpa,
        .limited(MAX_READ),
    ) catch |err| {
        throw(isolate, @errorName(err));
        return;
    };
    defer gpa.free(content);

    const result = c.v8__String__NewFromUtf8(
        isolate,
        @ptrCast(content.ptr),
        0,
        @intCast(content.len),
    );

    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(result));
}

// ============================================================
// writeFile(path, data)
// ============================================================

fn writeFileCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = jsPathArg(info, 0, &path_buf) orelse return;

    if (c.v8__FunctionCallbackInfo__Length(info) < 2) return;
    const data_val = c.v8__FunctionCallbackInfo__INDEX(info, 1);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    const data_str = c.v8__Value__ToDetailString(data_val, context);
    if (data_str == null) return;
    // Exact-size allocation from the already-known length: the previous
    // fixed [MAX_READ] stack buffer risked blowing small stacks and faulted
    // thousands of pages even for tiny writes.
    const data_len: usize = @intCast(c.v8__String__Utf8Length(data_str, isolate));
    const data_final = @min(data_len, MAX_READ);
    const data_buf = gpa.alloc(u8, data_final) catch {
        throw(isolate, "OutOfMemory");
        return;
    };
    defer gpa.free(data_buf);
    _ = c.v8__String__WriteUtf8(data_str, isolate, data_buf.ptr, @intCast(data_final), 0);

    const io = getIo();
    Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = data_buf[0..data_final],
    }) catch |err| {
        throw(isolate, @errorName(err));
    };
}

// ============================================================
// exists(path)
// ============================================================

fn existsCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = jsPathArg(info, 0, &path_buf) orelse return;

    const io = getIo();
    const found = if (Dir.cwd().access(io, path, .{})) true else |_| false;

    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const result = if (found) c.v8__True(isolate) else c.v8__False(isolate);
    c.v8__ReturnValue__Set(ret, @ptrCast(result));
}

// ============================================================
// mkdir(path, recursive?)
// ============================================================

fn mkdirCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = jsPathArg(info, 0, &path_buf) orelse return;

    const recursive = jsBoolArg(info, 1);
    const io = getIo();

    if (recursive) {
        Dir.cwd().createDirPath(io, path) catch |err| {
            throw(isolate, @errorName(err));
        };
    } else {
        Dir.cwd().createDir(io, path, .default_dir) catch |err| {
            throw(isolate, @errorName(err));
        };
    }
}

// ============================================================
// rm(path, recursive?)
// ============================================================

fn rmCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = jsPathArg(info, 0, &path_buf) orelse return;

    const recursive = jsBoolArg(info, 1);
    const io = getIo();

    if (recursive) {
        Dir.cwd().deleteTree(io, path) catch |err| {
            throw(isolate, @errorName(err));
        };
    } else {
        Dir.cwd().deleteFile(io, path) catch {
            Dir.cwd().deleteDir(io, path) catch |err| {
                throw(isolate, @errorName(err));
            };
        };
    }
}

// ============================================================
// readdir(path)
// ============================================================

fn readdirCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = jsPathArg(info, 0, &path_buf) orelse return;

    const io = getIo();
    var dir = Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        throw(isolate, @errorName(err));
        return;
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

    const context = c.v8__Isolate__GetCurrentContext(isolate);
    const arr = c.v8__Array__New(isolate, @intCast(names.items.len));

    for (names.items, 0..) |name, i| {
        const js_name = c.v8__String__NewFromUtf8(isolate, @ptrCast(name.ptr), 0, @intCast(name.len));
        var out: c.MaybeBool = undefined;
        c.v8__Object__SetAtIndex(arr, context, @intCast(i), @ptrCast(js_name), &out);
    }

    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(arr));
}

// ============================================================
// Registration
// ============================================================

pub fn setup(isolate: ?*c.Isolate, context: ?*c.Context) void {
    var hs: c.HandleScope = undefined;
    c.v8__HandleScope__CONSTRUCT(&hs, isolate);
    defer c.v8__HandleScope__DESTRUCT(&hs);

    const global = c.v8__Context__Global(context);
    const fs_obj = c.v8__Object__New(isolate);
    var out: c.MaybeBool = undefined;

    const readFile_fn = c.v8__Function__New__DEFAULT(context, readFileCallback);
    const readFile_key = c.v8__String__NewFromUtf8(isolate, "readFile", 0, -1);
    c.v8__Object__Set(fs_obj, context, readFile_key, readFile_fn, &out);

    const writeFile_fn = c.v8__Function__New__DEFAULT(context, writeFileCallback);
    const writeFile_key = c.v8__String__NewFromUtf8(isolate, "writeFile", 0, -1);
    c.v8__Object__Set(fs_obj, context, writeFile_key, writeFile_fn, &out);

    const exists_fn = c.v8__Function__New__DEFAULT(context, existsCallback);
    const exists_key = c.v8__String__NewFromUtf8(isolate, "exists", 0, -1);
    c.v8__Object__Set(fs_obj, context, exists_key, exists_fn, &out);

    const mkdir_fn = c.v8__Function__New__DEFAULT(context, mkdirCallback);
    const mkdir_key = c.v8__String__NewFromUtf8(isolate, "mkdir", 0, -1);
    c.v8__Object__Set(fs_obj, context, mkdir_key, mkdir_fn, &out);

    const rm_fn = c.v8__Function__New__DEFAULT(context, rmCallback);
    const rm_key = c.v8__String__NewFromUtf8(isolate, "rm", 0, -1);
    c.v8__Object__Set(fs_obj, context, rm_key, rm_fn, &out);

    const readdir_fn = c.v8__Function__New__DEFAULT(context, readdirCallback);
    const readdir_key = c.v8__String__NewFromUtf8(isolate, "readdir", 0, -1);
    c.v8__Object__Set(fs_obj, context, readdir_key, readdir_fn, &out);

    const fs_key = c.v8__String__NewFromUtf8(isolate, "fs", 0, -1);
    _ = c.v8__Object__Set(global, context, fs_key, fs_obj, &out);
}
