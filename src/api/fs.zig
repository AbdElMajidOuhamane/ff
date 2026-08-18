const std = @import("std");
const c = @import("../c.zig").c;

const Io = std.Io;
const Dir = Io.Dir;
const V16 = @Vector(16, u8);

// ---------------------------------------------------------------------------
// DOD: layout is data, not pointers.
//
// Every syscall path draws from one flat Scratch slab: fixed-capacity path
// store, lazily-grown pooled read/write buffers, and SoA readdir columns.
// The engine is single-threaded (std.Io.Threaded.global_single_threaded),
// so single-slot scratch is lock-free by construction and zero per-call
// allocations survive the hot path — the biggest, reused objects are the
// 33 MB-style file buffers, exact-fit grown once and reclaimed on reuse.
// ---------------------------------------------------------------------------

pub const MAX_PATH = 4096;
pub const READ_MAX = 512 * 1024 * 1024; // fs.readFile cap (pooled, heap-backed)
pub const WRITE_MAX = 10 * 1024 * 1024; // fs.writeFile cap (pooled, heap-backed)
const DIR_ENTRY_MAX = 256;
const DIR_ENTRY_CAP = 1024;

const Scratch = struct {
    // path store: single slab + length lane (SoA)
    path: [MAX_PATH]u8 align(16) = undefined,
    path_len: usize = 0,

    // read buffer: exact-fit grown once to the largest file seen, reused forever.
    read_pool: []u8 = &.{},
    read_cap: usize = 0,

    // write transcode buffer (reused; replaces the old 10 MB stack array)
    write_pool: []u8 = &.{},
    write_cap: usize = 0,

    // readdir: SoA columns over one blob — no per-entry heap dupes, no growth
    dir_off: [DIR_ENTRY_CAP]u32 = undefined,
    dir_len: [DIR_ENTRY_CAP]u16 = undefined,
    dir_blob: [DIR_ENTRY_CAP * DIR_ENTRY_MAX]u8 = undefined,
    dir_count: usize = 0,
};

var scratch: Scratch = .{};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn getIo() Io {
    return std.Io.Threaded.global_single_threaded.io();
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

// Copies the JS string path straight into the shared slab — zero heap.
fn jsPath(info: ?*const c.FunctionCallbackInfo, index: c_int) ?[:0]const u8 {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    if (c.v8__FunctionCallbackInfo__Length(info) <= index) return null;
    const val = c.v8__FunctionCallbackInfo__INDEX(info, index);
    if (!c.v8__Value__IsString(val)) return null;

    const context = c.v8__Isolate__GetCurrentContext(isolate);
    const str = c.v8__Value__ToDetailString(val, context);
    if (str == null) return null;

    const utf8_len: usize = @intCast(c.v8__String__Utf8Length(str, isolate));
    if (utf8_len >= MAX_PATH) return null;

    const len = c.v8__String__WriteUtf8(str, isolate, &scratch.path, @intCast(utf8_len), 0);
    scratch.path[len] = 0;
    scratch.path_len = @intCast(len);
    return scratch.path[0..scratch.path_len :0];
}

// ---------------------------------------------------------------------------
// Pools: amortized, exact-fit-first, geometric growth otherwise.
// ---------------------------------------------------------------------------

fn poolRead(want: usize) ![]u8 {
    if (want > READ_MAX) return error.FileTooBig;
    if (want <= scratch.read_cap) return scratch.read_pool[0..want];

    var cap: usize = if (scratch.read_cap == 0) @max(want, 64 * 1024) else scratch.read_cap;
    while (cap < want) cap *= 2;
    cap = @min(cap, READ_MAX);

    const mem = std.heap.page_allocator.alloc(u8, cap) catch return error.OutOfMemory;
    if (scratch.read_cap > 0) std.heap.page_allocator.free(scratch.read_pool);
    scratch.read_pool = mem;
    scratch.read_cap = cap;
    return scratch.read_pool[0..want];
}

fn poolWrite(want: usize) ![]u8 {
    if (want > WRITE_MAX) return error.FileTooBig;
    if (want <= scratch.write_cap) return scratch.write_pool[0..want];

    var cap: usize = if (scratch.write_cap == 0) @max(want, 64 * 1024) else scratch.write_cap;
    while (cap < want) cap *= 2;
    cap = @min(cap, WRITE_MAX);

    const mem = std.heap.page_allocator.alloc(u8, cap) catch return error.OutOfMemory;
    if (scratch.write_cap > 0) std.heap.page_allocator.free(scratch.write_pool);
    scratch.write_pool = mem;
    scratch.write_cap = cap;
    return scratch.write_pool[0..want];
}

// ---------------------------------------------------------------------------
// SIMD: UTF-8 ASCII fast path. Pure-ASCII blobs (the common case — the
// 33 MB uas.txt is all ASCII) validate in 16-byte vectors; only the first
// high bit drops to the scalar fallback.
// ---------------------------------------------------------------------------

fn utf8ValidSimd(content: []const u8) bool {
    var i: usize = 0;
    const hi: V16 = @splat(0x80);
    while (i + 16 <= content.len) : (i += 16) {
        const v: V16 = content[i..][0..16].*;
        if (@reduce(.Or, v & hi) != 0) return utf8ValidScalar(content[i..]);
    }
    return utf8ValidScalar(content[i..]);
}

fn utf8ValidScalar(s: []const u8) bool {
    const continued = @as(u8, 0b10_000000);
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b < 0x80) {
            i += 1;
            continue;
        }
        var extra: usize = 0;
        if (b & 0xE0 == 0xC0) {
            extra = 1;
        } else if (b & 0xF0 == 0xE0) {
            extra = 2;
        } else if (b & 0xF8 == 0xF0) {
            extra = 3;
        } else {
            return false;
        }
        if (i + extra >= s.len + 1) return false;
        var k: usize = 1;
        while (k <= extra) : (k += 1) {
            if ((s[i + k] & 0xC0) != continued) return false;
        }
        i += extra + 1;
    }
    return true;
}

// ---------------------------------------------------------------------------
// readFile(path, "utf8")
// ---------------------------------------------------------------------------

fn readFileCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const path = jsPath(info, 0) orelse return;

    const io = getIo();
    var file = Dir.cwd().openFile(io, path, .{}) catch |err| {
        throw(isolate, @errorName(err));
        return;
    };
    defer file.close(io);

    const st = file.stat(io) catch |err| {
        throw(isolate, @errorName(err));
        return;
    };

    const buf = poolRead(@intCast(st.size)) catch |err| {
        throw(isolate, @errorName(err));
        return;
    };

    const n = file.readPositionalAll(io, buf, 0) catch |err| {
        throw(isolate, @errorName(err));
        return;
    };
    if (n != st.size) {
        throw(isolate, "ShortRead");
        return;
    }

    // SIMD validation gate. Pass-through by default (Node parity: bytes that
    // aren't valid UTF-8 get substituted, not rejected). Flip for strict mode.
    const strict_decode = false;
    if (strict_decode and !utf8ValidSimd(buf[0..n])) {
        throw(isolate, "InvalidUtf8");
        return;
    }

    const result = c.v8__String__NewFromUtf8(isolate, @ptrCast(buf.ptr), 0, @intCast(n));

    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(result));
}

// ---------------------------------------------------------------------------
// writeFile(path, data)
// ---------------------------------------------------------------------------

fn writeFileCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const path = jsPath(info, 0) orelse return;

    if (c.v8__FunctionCallbackInfo__Length(info) < 2) return;
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    const data_val = c.v8__FunctionCallbackInfo__INDEX(info, 1);
    const data_str = c.v8__Value__ToDetailString(data_val, context);
    if (data_str == null) return;

    const data_len: usize = @intCast(c.v8__String__Utf8Length(data_str, isolate));
    const buf = poolWrite(data_len) catch |err| {
        throw(isolate, @errorName(err));
        return;
    };
    _ = c.v8__String__WriteUtf8(data_str, isolate, buf.ptr, @intCast(data_len), 0);

    const io = getIo();
    Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = buf[0..data_len],
    }) catch |err| {
        throw(isolate, @errorName(err));
    };
}

// ---------------------------------------------------------------------------
// exists(path)
// ---------------------------------------------------------------------------

fn existsCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const path = jsPath(info, 0) orelse return;

    const io = getIo();
    const found = if (Dir.cwd().access(io, path, .{})) true else |_| false;

    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const result = if (found) c.v8__True(isolate) else c.v8__False(isolate);
    c.v8__ReturnValue__Set(ret, @ptrCast(result));
}

// ---------------------------------------------------------------------------
// mkdir(path, recursive?)
// ---------------------------------------------------------------------------

fn mkdirCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const path = jsPath(info, 0) orelse return;

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

// ---------------------------------------------------------------------------
// rm(path, recursive?)
// ---------------------------------------------------------------------------

fn rmCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const path = jsPath(info, 0) orelse return;

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

// ---------------------------------------------------------------------------
// readdir(path) — SoA columns over a single name blob
// ---------------------------------------------------------------------------

fn readdirCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const path = jsPath(info, 0) orelse return;

    const io = getIo();
    var dir = Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        throw(isolate, @errorName(err));
        return;
    };
    defer dir.close(io);

    scratch.dir_count = 0;
    var cursor: usize = 0;
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (scratch.dir_count >= DIR_ENTRY_CAP) break;
        const n = @min(entry.name.len, DIR_ENTRY_MAX);
        @memcpy(scratch.dir_blob[cursor..][0..n], entry.name[0..n]);
        scratch.dir_off[scratch.dir_count] = @intCast(cursor);
        scratch.dir_len[scratch.dir_count] = @intCast(n);
        cursor += n;
        scratch.dir_count += 1;
    }

    const context = c.v8__Isolate__GetCurrentContext(isolate);
    const arr = c.v8__Array__New(isolate, @intCast(scratch.dir_count));

    for (0..scratch.dir_count) |i| {
        const off: usize = scratch.dir_off[i];
        const len: usize = scratch.dir_len[i];
        const js_name = c.v8__String__NewFromUtf8(
            isolate,
            @ptrCast(scratch.dir_blob[off..][0..len].ptr),
            0,
            @intCast(len),
        );
        var out: c.MaybeBool = undefined;
        c.v8__Object__SetAtIndex(arr, context, @intCast(i), @ptrCast(js_name), &out);
    }

    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(arr));
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

fn register(
    isolate: ?*c.Isolate,
    context: ?*c.Context,
    obj: ?*const c.Object,        // v8__Object__New returns a const handle
    comptime name: []const u8,
    comptime cb: fn (?*const c.FunctionCallbackInfo) callconv(.c) void,
) void {
    var out: c.MaybeBool = undefined;
    const f = c.v8__Function__New__DEFAULT(context, cb);
    const key = c.v8__String__NewFromUtf8(isolate, name.ptr, 0, -1);
    c.v8__Object__Set(obj, context, key, f, &out);
}

pub fn setup(isolate: ?*c.Isolate, context: ?*c.Context) void {
    var hs: c.HandleScope = undefined;
    c.v8__HandleScope__CONSTRUCT(&hs, isolate);
    defer c.v8__HandleScope__DESTRUCT(&hs);

    const global = c.v8__Context__Global(context);
    const fs_obj = c.v8__Object__New(isolate);
    var out: c.MaybeBool = undefined;

    register(isolate, context, fs_obj, "readFile", readFileCallback);
    register(isolate, context, fs_obj, "writeFile", writeFileCallback);
    register(isolate, context, fs_obj, "exists", existsCallback);
    register(isolate, context, fs_obj, "mkdir", mkdirCallback);
    register(isolate, context, fs_obj, "rm", rmCallback);
    register(isolate, context, fs_obj, "readdir", readdirCallback);

    const fs_key = c.v8__String__NewFromUtf8(isolate, "fs", 0, -1);
    _ = c.v8__Object__Set(global, context, fs_key, fs_obj, &out);
}
