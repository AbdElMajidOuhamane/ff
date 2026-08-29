const std = @import("std");
const c = @import("../c.zig").c;
const RED = "\x1b[31m";
const YELLOW = "\x1b[33m";
const RESET = "\x1b[0m";
const GREEN = "\x1b[32m";

const LINE_MAX = 4096;

fn appendChunk(buf: []u8, len: *usize, s: []const u8) void {
    const space = buf.len - len.*;
    const n = @min(s.len, space);
    @memcpy(buf[len.*..][0..n], s[0..n]);
    len.* += n;
}

fn flush(buf: []u8, len: *usize) void {
    if (len.* == 0) return;
    std.debug.print("{s}", .{buf[0..len.*]});
    len.* = 0;
}

fn stageString(ctx: ?*c.Context, val: c.Value, buf: []u8, len: *usize) void {
    if (c.isString(val) == 0) return;
    var str_len: usize = 0;
    const str_ptr = c.toCStringLen(ctx, &str_len, val) orelse return;
    defer c.freeCString(ctx, str_ptr);
    var written: usize = 0;
    while (written < str_len) {
        if (len.* == buf.len) flush(buf, len);
        const n = @min(str_len - written, buf.len - len.*);
        @memcpy(buf[len.*..][0..n], str_ptr[written..][0..n]);
        len.* += n;
        written += n;
    }
}

fn consoleLogCallbackWithColor(ctx: ?*c.Context, argc: c_int, argv: [*c]const c.Value, color: []const u8) void {
    var buf: [LINE_MAX]u8 = undefined;
    var len: usize = 0;
    if (color.len > 0) appendChunk(&buf, &len, color);
    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        if (i > 0) appendChunk(&buf, &len, " ");
        stageString(ctx, argv[@intCast(i)], &buf, &len);
    }
    if (color.len > 0) appendChunk(&buf, &len, RESET);
    appendChunk(&buf, &len, "\n");
    flush(&buf, &len);
}

fn consoleLogCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    consoleLogCallbackWithColor(ctx, argc, argv, "");
    return c.JS_UNDEFINED;
}
fn consoleSlopsCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    consoleLogCallbackWithColor(ctx, argc, argv, YELLOW);
    return c.JS_UNDEFINED;
}
fn consoleRedbalCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    consoleLogCallbackWithColor(ctx, argc, argv, RED);
    return c.JS_UNDEFINED;
}
fn consoleDetailCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    consoleLogCallbackWithColor(ctx, argc, argv, GREEN);
    return c.JS_UNDEFINED;
}

pub fn setup(ctx: *c.Context) void {
    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);
    const console_obj = c.newObject(ctx);

    const log_func = c.newCFunction(ctx, consoleLogCallback, "log", 2);
    _ = c.definePropertyValueStr(ctx, console_obj, "log", log_func, c.PROP_C_W_E);

    const slops_func = c.newCFunction(ctx, consoleSlopsCallback, "slops", 2);
    _ = c.definePropertyValueStr(ctx, console_obj, "slops", slops_func, c.PROP_C_W_E);

    const warn_func = c.newCFunction(ctx, consoleRedbalCallback, "redbal", 2);
    _ = c.definePropertyValueStr(ctx, console_obj, "redbal", warn_func, c.PROP_C_W_E);

    const detail_func = c.newCFunction(ctx, consoleDetailCallback, "detail", 2);
    _ = c.definePropertyValueStr(ctx, console_obj, "detail", detail_func, c.PROP_C_W_E);

    const error_fn = c.newCFunction(ctx, consoleRedbalCallback, "error", 2);
    _ = c.definePropertyValueStr(ctx, console_obj, "error", error_fn, c.PROP_C_W_E);

    const std_warn_fn = c.newCFunction(ctx, consoleSlopsCallback, "warn", 2);
    _ = c.definePropertyValueStr(ctx, console_obj, "warn", std_warn_fn, c.PROP_C_W_E);

    const info_fn = c.newCFunction(ctx, consoleLogCallback, "info", 2);
    _ = c.definePropertyValueStr(ctx, console_obj, "info", info_fn, c.PROP_C_W_E);

    const debug_fn = c.newCFunction(ctx, consoleLogCallback, "debug", 2);
    _ = c.definePropertyValueStr(ctx, console_obj, "debug", debug_fn, c.PROP_C_W_E);

    _ = c.definePropertyValueStr(ctx, global, "console", console_obj, c.PROP_C_W_E);
}
