const std = @import("std");
const c = @import("../c.zig").c;
const builtin = @import("builtin");

const Io = std.Io;

// ============================================================
// Helpers
// ============================================================

fn getIo() Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn throw(isolate: ?*c.Isolate, msg: []const u8) void {
    const v8_msg = c.v8__String__NewFromUtf8(isolate, @ptrCast(msg.ptr), 0, @intCast(msg.len));
    const exc = c.v8__Exception__Error(v8_msg);
    _ = c.v8__Isolate__ThrowException(isolate, exc);
}

fn zigStringToV8(isolate: ?*c.Isolate, str: []const u8) *const c.Value {
    return @ptrCast(c.v8__String__NewFromUtf8(isolate, @ptrCast(str.ptr), 0, @intCast(str.len)));
}

fn extractString(info: ?*const c.FunctionCallbackInfo, index: c_int) ?[:0]const u8 {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    if (c.v8__FunctionCallbackInfo__Length(info) <= index) return null;
    const val = c.v8__FunctionCallbackInfo__INDEX(info, index);
    if (!c.v8__Value__IsString(val)) return null;
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    const str = c.v8__Value__ToDetailString(val, context);
    if (str == null) return null;
    const utf8_len: usize = @intCast(c.v8__String__Utf8Length(str, isolate));
    var buf: [4096]u8 = undefined;
    const len = @min(utf8_len, buf.len);
    _ = c.v8__String__WriteUtf8(str, isolate, &buf, @intCast(len), 0);
    return std.heap.page_allocator.dupeZ(u8, buf[0..len]) catch null;
}

// ============================================================
// process.exit(code)
// ============================================================

fn exitCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var code: u8 = 0;
    if (c.v8__FunctionCallbackInfo__Length(info) > 0) {
        const val = c.v8__FunctionCallbackInfo__INDEX(info, 0);
        var maybe: c.MaybeF64 = undefined;
        const ctx = c.v8__Isolate__GetCurrentContext(isolate);
        c.v8__Value__NumberValue(val, ctx, &maybe);
        if (maybe.has_value) {
            code = @intFromFloat(maybe.value);
        }
    }
    std.process.exit(code);
}

// ============================================================
// process.cwd()
// ============================================================

fn cwdCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const io = getIo();
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const len = std.process.currentPath(io, &buf) catch {
        throw(isolate, "getcwd failed");
        return;
    };
    const ret = zigStringToV8(isolate, buf[0..len]);

    var retval: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &retval);
    c.v8__ReturnValue__Set(retval, ret);
}

// ============================================================
// process.chdir(path)
// ============================================================

fn chdirCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const path = extractString(info, 0) orelse {
        throw(isolate, "chdir requires a path argument");
        return;
    };
    defer std.heap.page_allocator.free(path);

    const io = getIo();
    std.process.setCurrentPath(io, path) catch {
        throw(isolate, "chdir failed");
    };
}

// ============================================================
// process.nextTick(callback)
// ============================================================

fn nextTickCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    if (c.v8__FunctionCallbackInfo__Length(info) < 1) {
        throw(isolate, "nextTick requires a callback argument");
        return;
    }
    const val = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    if (!c.v8__Value__IsFunction(val)) {
        throw(isolate, "nextTick callback must be a function");
        return;
    }
    c.v8__Isolate__EnqueueMicrotaskFunc(isolate, @ptrCast(val));
}

// ============================================================
// process.memoryUsage()
// ============================================================

fn currentRssBytes() u64 {
    switch (builtin.os.tag) {
        .linux => {
            const fd = std.posix.open("/proc/self/statm", .{ .ACCMODE = .RDONLY }, 0) catch return 0;
            defer std.posix.close(fd);
            var buf: [64]u8 = undefined;
            const n = std.posix.read(fd, &buf) catch return 0;
            var it = std.mem.tokenizeScalar(u8, buf[0..n], ' ');
            _ = it.next() orelse return 0; // size (pages)
            const resident = it.next() orelse return 0; // resident pages
            const pages = std.fmt.parseInt(usize, resident, 10) catch return 0;
            const page_size: usize = @intCast(c.sysconf(c._SC_PAGESIZE));
            return pages * page_size;
        },
        .macos => {
            var usage: c.rusage = undefined;
            if (c.getrusage(c.RUSAGE_SELF, &usage) != 0) return 0;
            const peak: i64 = usage.ru_maxrss; // macOS: bytes
            return if (peak > 0) @intCast(peak) else 0;
        },
        else => return 0,
    }
}

fn memoryUsageCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var stats: c.HeapStatistics = undefined;
    c.v8__Isolate__GetHeapStatistics(isolate, &stats);

    const obj = c.v8__Object__New(isolate) orelse return;
    const set_n = struct {
        fn f(o: *const c.Object, ctx: ?*c.Context, is: ?*c.Isolate, name: [:0]const u8, v: u64) void {
            var ob: c.MaybeBool = undefined;
            _ = c.v8__Object__Set(o, ctx, c.v8__String__NewFromUtf8(is, name.ptr, 0, -1), c.v8__Number__New(is, @floatFromInt(@as(i64, @intCast(v)))), &ob);
        }
    }.f;
    set_n(obj, context, isolate, "rss", currentRssBytes());
    set_n(obj, context, isolate, "heapUsed", stats.used_heap_size);
    set_n(obj, context, isolate, "heapTotal", stats.total_heap_size);
    set_n(obj, context, isolate, "external", 0);
    set_n(obj, context, isolate, "arrayBuffers", 0);

    var retval: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &retval);
    c.v8__ReturnValue__Set(retval, @ptrCast(obj));
}

// ============================================================
// Registration
// ============================================================

pub fn setup(isolate: ?*c.Isolate, context: ?*c.Context, args: std.process.Args) void {
    var hs: c.HandleScope = undefined;
    c.v8__HandleScope__CONSTRUCT(&hs, isolate);
    defer c.v8__HandleScope__DESTRUCT(&hs);

    const global = c.v8__Context__Global(context);
    const process_obj = c.v8__Object__New(isolate);
    var out: c.MaybeBool = undefined;

    // --- process.exit(code) ---
    const exit_fn = c.v8__Function__New__DEFAULT(context, exitCallback);
    const exit_key = c.v8__String__NewFromUtf8(isolate, "exit", 0, -1);
    c.v8__Object__Set(process_obj, context, exit_key, exit_fn, &out);

    // --- process.cwd() ---
    const cwd_fn = c.v8__Function__New__DEFAULT(context, cwdCallback);
    const cwd_key = c.v8__String__NewFromUtf8(isolate, "cwd", 0, -1);
    c.v8__Object__Set(process_obj, context, cwd_key, cwd_fn, &out);

    // --- process.chdir(path) ---
    const chdir_fn = c.v8__Function__New__DEFAULT(context, chdirCallback);
    const chdir_key = c.v8__String__NewFromUtf8(isolate, "chdir", 0, -1);
    c.v8__Object__Set(process_obj, context, chdir_key, chdir_fn, &out);

    // --- process.nextTick(callback) ---
    const nextTick_fn = c.v8__Function__New__DEFAULT(context, nextTickCallback);
    const nextTick_key = c.v8__String__NewFromUtf8(isolate, "nextTick", 0, -1);
    c.v8__Object__Set(process_obj, context, nextTick_key, nextTick_fn, &out);

    // --- process.memoryUsage() ---
    const mu_fn = c.v8__Function__New__DEFAULT(context, memoryUsageCallback);
    const mu_key = c.v8__String__NewFromUtf8(isolate, "memoryUsage", 0, -1);
    c.v8__Object__Set(process_obj, context, mu_key, mu_fn, &out);

    // --- process.pid ---
    const pid_val = c.v8__Number__New(isolate, @floatFromInt(@as(i64, std.c.getpid())));
    const pid_key = c.v8__String__NewFromUtf8(isolate, "pid", 0, -1);
    c.v8__Object__Set(process_obj, context, pid_key, @ptrCast(pid_val), &out);

    // --- process.platform ---
    const platform_str = comptime switch (builtin.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        .windows => "win32",
        .freebsd => "freebsd",
        else => "unknown",
    };
    const platform_val = zigStringToV8(isolate, platform_str);
    const platform_key = c.v8__String__NewFromUtf8(isolate, "platform", 0, -1);
    c.v8__Object__Set(process_obj, context, platform_key, platform_val, &out);

    // --- process.arch ---
    const arch_str = comptime switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x64",
        .x86 => "ia32",
        .riscv64 => "riscv64",
        else => "unknown",
    };
    const arch_val = zigStringToV8(isolate, arch_str);
    const arch_key = c.v8__String__NewFromUtf8(isolate, "arch", 0, -1);
    c.v8__Object__Set(process_obj, context, arch_key, arch_val, &out);

    // --- process.env ---
    const env_obj = c.v8__Object__New(isolate);
    const c_environ = std.c.environ;
    var i: usize = 0;
    while (c_environ[i]) |entry| : (i += 1) {
        const entry_str = std.mem.span(entry);
        if (std.mem.indexOfScalar(u8, entry_str, '=')) |eq_pos| {
            const key = entry_str[0..eq_pos];
            const val = entry_str[eq_pos + 1 ..];
            const v8_key = zigStringToV8(isolate, key);
            const v8_val = zigStringToV8(isolate, val);
            c.v8__Object__Set(env_obj, context, v8_key, v8_val, &out);
        }
    }
    const env_key = c.v8__String__NewFromUtf8(isolate, "env", 0, -1);
    c.v8__Object__Set(process_obj, context, env_key, env_obj, &out);

    // --- process.argv ---
    const argv_arr = c.v8__Array__New(isolate, 0);
    var arg_idx: u32 = 0;
    var args_iter = args.iterate();
    while (args_iter.next()) |arg| {
        const v8_arg = zigStringToV8(isolate, arg);
        c.v8__Object__SetAtIndex(argv_arr, context, arg_idx, v8_arg, &out);
        arg_idx += 1;
    }
    const argv_key = c.v8__String__NewFromUtf8(isolate, "argv", 0, -1);
    c.v8__Object__Set(process_obj, context, argv_key, argv_arr, &out);

    // --- set globalThis.process ---
    const process_key = c.v8__String__NewFromUtf8(isolate, "process", 0, -1);
    _ = c.v8__Object__Set(global, context, process_key, process_obj, &out);
}
