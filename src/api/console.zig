const std = @import("std");
const c = @import("../c.zig").c;

const RED = "\x1b[31m";
const YELLOW = "\x1b[33m";
const RESET = "\x1b[0m";
const GREEN = "\x1b[32m";

fn consoleLogCallbackWithColor(info: ?*const c.FunctionCallbackInfo, color: []const u8) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const argc = c.v8__FunctionCallbackInfo__Length(info);
    var i: c_int = 0;
    if (color.len > 0) std.debug.print("{s}", .{color});
    while (i < argc) : (i += 1) {
        if (i > 0) std.debug.print(" ", .{});
        const val = c.v8__FunctionCallbackInfo__INDEX(info, i);
        const context = c.v8__Isolate__GetCurrentContext(isolate);
        const str = c.v8__Value__ToString(val, context);
        if (str == null) continue;
        const utf8_len = c.v8__String__Utf8Length(str, isolate);
        var buf: [4096]u8 = undefined;
        const len = @min(@as(usize, @intCast(utf8_len)), buf.len);
        _ = c.v8__String__WriteUtf8(str, isolate, &buf, @intCast(len), 0);
        std.debug.print("{s}", .{buf[0..len]});
    }
    if (color.len > 0) std.debug.print("{s}", .{RESET});
    std.debug.print("\n", .{});
}

fn consoleLogCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    consoleLogCallbackWithColor(info, "");
}

fn consoleSlopsCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    consoleLogCallbackWithColor(info, YELLOW);
}

fn consoleRedbalCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    consoleLogCallbackWithColor(info, RED);
}

fn consoleDetailCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    consoleLogCallbackWithColor(info, GREEN);
}

pub fn setup(isolate: ?*c.Isolate, context: ?*c.Context) void {
    var hs: c.HandleScope = undefined;
    c.v8__HandleScope__CONSTRUCT(&hs, isolate);
    defer c.v8__HandleScope__DESTRUCT(&hs);

    const global = c.v8__Context__Global(context);
    const console_obj = c.v8__Object__New(isolate);

    const log_func = c.v8__Function__New__DEFAULT(context, consoleLogCallback);
    const log_key = c.v8__String__NewFromUtf8(isolate, "log", 0, -1);
    var out: c.MaybeBool = undefined;
    c.v8__Object__Set(console_obj, context, log_key, log_func, &out);

    const slops_func = c.v8__Function__New__DEFAULT(context, consoleSlopsCallback);
    const slops_key = c.v8__String__NewFromUtf8(isolate, "slops", 0, -1);
    c.v8__Object__Set(console_obj, context, slops_key, slops_func, &out);

    const warn_func = c.v8__Function__New__DEFAULT(context, consoleRedbalCallback);
    const warn_key = c.v8__String__NewFromUtf8(isolate, "redbal", 0, -1);
    c.v8__Object__Set(console_obj, context, warn_key, warn_func, &out);

    const detail_func = c.v8__Function__New__DEFAULT(context, consoleDetailCallback);
    const detail_key = c.v8__String__NewFromUtf8(isolate, "detail", 0, -1);
    c.v8__Object__Set(console_obj, context, detail_key, detail_func, &out);

    const console_key = c.v8__String__NewFromUtf8(isolate, "console", 0, -1);
    _ = c.v8__Object__Set(global, context, console_key, console_obj, &out);
}
