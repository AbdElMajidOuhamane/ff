const std = @import("std");
const c = @import("../c.zig").c;
const RED = "\x1b[31m";
const YELLOW = "\x1b[33m";
const RESET = "\x1b[0m";
const GREEN = "\x1b[32m";
// Stack staging for typical log lines; longer payloads fall back to one
// heap allocation instead of being silently cut at 4096 bytes.
const STACK_LOG_MAX = 4096;
fn printString(isolate: ?*c.Isolate, str: ?*const c.String) void {
    const s = str orelse return;
    const utf8_len: usize = @intCast(c.v8__String__Utf8Length(s, isolate));
    if (utf8_len <= STACK_LOG_MAX) {
        var buf: [STACK_LOG_MAX]u8 = undefined;
        _ = c.v8__String__WriteUtf8(s, isolate, &buf, @intCast(utf8_len), 0);
        std.debug.print("{s}", .{buf[0..utf8_len]});
        return;
    }
    const heap_buf = std.heap.page_allocator.alloc(u8, utf8_len) catch {
        // OOM fallback: preserve old truncated behavior rather than dropping.
        var buf: [STACK_LOG_MAX]u8 = undefined;
        _ = c.v8__String__WriteUtf8(s, isolate, &buf, @intCast(STACK_LOG_MAX), 0);
        std.debug.print("{s}", .{buf});
        return;
    };
    defer std.heap.page_allocator.free(heap_buf);
    _ = c.v8__String__WriteUtf8(s, isolate, heap_buf.ptr, @intCast(utf8_len), 0);
    std.debug.print("{s}", .{heap_buf});
}
fn consoleLogCallbackWithColor(info: ?*const c.FunctionCallbackInfo, color: []const u8) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const argc = c.v8__FunctionCallbackInfo__Length(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var i: c_int = 0;
    if (color.len > 0) std.debug.print("{s}", .{color});
    while (i < argc) : (i += 1) {
        if (i > 0) std.debug.print(" ", .{});
        const val = c.v8__FunctionCallbackInfo__INDEX(info, i);
        const str = c.v8__Value__ToString(val, context);
        printString(isolate, str);
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

