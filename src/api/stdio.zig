const std = @import("std");
const c = @import("../c.zig").c;
const xev = @import("xev");
const engine = @import("../engine/engine.zig");

var stdin_stream: ?xev.Stream = null;
var stdin_comp: xev.Completion = .{};
var stdin_buf: [64 * 1024]u8 = undefined;
var stdin_resolve: ?c.Value = null;
var stdin_reject: ?c.Value = null;
var stdin_ctx: ?*c.Context = null;
var stdin_pending: bool = false;

pub fn isStdinPending() bool {
    return stdin_pending;
}

/// Direct writes to stdout in fairyfly are unbuffered (std.c.write), so explicit
/// flushing is a no-op. Retained as a documented compatibility hook.
pub fn flushStdout() void {}

fn stdoutWriteCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 1) return c.JS_FALSE;

    var slice: []const u8 = undefined;
    var u8_len: usize = 0;
    var cstr_to_free: ?[*c]const u8 = null;
    defer if (cstr_to_free) |cs| c.freeCString(ctx, cs);

    if (c.getUint8Array(ctx, &u8_len, argv[0])) |u8_ptr| {
        slice = u8_ptr[0..u8_len];
    } else {
        var str_len: usize = 0;
        const cstr = c.toCStringLen(ctx, &str_len, argv[0]) orelse return c.JS_FALSE;
        cstr_to_free = cstr;
        slice = cstr[0..str_len];
    }

    var total_written: usize = 0;
    while (total_written < slice.len) {
        const rc = std.c.write(std.posix.STDOUT_FILENO, slice[total_written..].ptr, slice.len - total_written);
        if (rc < 0) {
            const err = std.posix.errno(rc);
            if (err == .INTR) continue;
            return c.JS_FALSE;
        }
        total_written += @intCast(rc);
    }
    return c.JS_TRUE;
}

fn stdinReadSyncCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    _ = argc;
    _ = argv;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.read(std.posix.STDIN_FILENO, &buf, buf.len);
        if (n < 0) {
            const err = std.posix.errno(n);
            if (err == .INTR) continue;
            return c.JS_NULL;
        }
        if (n == 0) return c.JS_NULL;
        const un: usize = @intCast(n);
        return c.newUint8ArrayCopy(ctx, buf[0..un].ptr, un);
    }
}

fn onStdinRead(
    ud: ?*anyopaque,
    l: *xev.Loop,
    comp: *xev.Completion,
    stream: xev.Stream,
    buf: xev.ReadBuffer,
    r: xev.ReadError!usize,
) xev.CallbackAction {
    _ = ud;
    _ = l;
    _ = comp;
    _ = stream;
    _ = buf;
    stdin_pending = false;
    const ctx = stdin_ctx orelse return .disarm;
    const res_fn = stdin_resolve;
    const rej_fn = stdin_reject;
    stdin_resolve = null;
    stdin_reject = null;

    const n = r catch {
        if (res_fn) |rf| {
            defer c.freeValue(ctx, rf);
            var r_argv = [_]c.Value{c.JS_NULL};
            _ = c.call(ctx, rf, c.JS_UNDEFINED, 1, &r_argv);
        }
        if (rej_fn) |rj| c.freeValue(ctx, rj);
        return .disarm;
    };

    if (res_fn) |rf| {
        defer c.freeValue(ctx, rf);
        if (n == 0) {
            var r_argv = [_]c.Value{c.JS_NULL};
            _ = c.call(ctx, rf, c.JS_UNDEFINED, 1, &r_argv);
        } else {
            const u8_arr = c.newUint8ArrayCopy(ctx, stdin_buf[0..n].ptr, n);
            var r_argv = [_]c.Value{u8_arr};
            _ = c.call(ctx, rf, c.JS_UNDEFINED, 1, &r_argv);
            c.freeValue(ctx, u8_arr);
        }
    }
    if (rej_fn) |rj| c.freeValue(ctx, rj);
    return .disarm;
}

fn stdinReadCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    _ = argc;
    _ = argv;
    if (stdin_pending) {
        return c.throwTypeError(ctx, "concurrent stdin.read already in progress");
    }

    const loop_ptr = engine.getEventLoop() orelse return c.throwTypeError(ctx, "no event loop");

    var resolving_funcs: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &resolving_funcs);
    if (c.isException(promise) != 0) return promise;

    stdin_resolve = resolving_funcs[0];
    stdin_reject = resolving_funcs[1];
    stdin_ctx = ctx;
    stdin_pending = true;

    if (stdin_stream == null) {
        stdin_stream = xev.Stream.initFd(std.posix.STDIN_FILENO);
    }
    stdin_stream.?.read(&loop_ptr.loop, &stdin_comp, .{ .slice = stdin_buf[0..] }, anyopaque, null, onStdinRead);
    return promise;
}

pub fn setup(ctx: *c.Context, process_obj: c.Value) void {
    // process.stdout
    const stdout_obj = c.newObject(ctx);
    const write_fn = c.newCFunction(ctx, stdoutWriteCallback, "write", 1);
    _ = c.definePropertyValueStr(ctx, stdout_obj, "write", write_fn, c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, stdout_obj, "isTTY", if (std.c.isatty(std.posix.STDOUT_FILENO) != 0) c.JS_TRUE else c.JS_FALSE, c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, process_obj, "stdout", stdout_obj, c.PROP_C_W_E);

    // process.stdin
    const stdin_obj = c.newObject(ctx);
    const read_fn = c.newCFunction(ctx, stdinReadCallback, "read", 0);
    _ = c.definePropertyValueStr(ctx, stdin_obj, "read", read_fn, c.PROP_C_W_E);
    const read_sync_fn = c.newCFunction(ctx, stdinReadSyncCallback, "readSync", 0);
    _ = c.definePropertyValueStr(ctx, stdin_obj, "readSync", read_sync_fn, c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, stdin_obj, "isTTY", if (std.c.isatty(std.posix.STDIN_FILENO) != 0) c.JS_TRUE else c.JS_FALSE, c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, process_obj, "stdin", stdin_obj, c.PROP_C_W_E);
}
