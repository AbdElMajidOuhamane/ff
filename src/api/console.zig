const std = @import("std");
const c = @import("../c.zig").c;
const RED = "\x1b[31m";
const YELLOW = "\x1b[33m";
const RESET = "\x1b[0m";
const GREEN = "\x1b[32m";

// Single-write staging (buffer-reuse rule): one log call stages color,
// arguments, separators, and the trailing newline into a fixed buffer and
// issues exactly ONE write — previously N+2 separate writes per call.
// Lines longer than the buffer stream as chunked continuations (the cap is
// now per-line rather than silently truncating each argument).
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

/// Stages one JS string argument into the line buffer, flushing mid-token
/// when the buffer fills so arbitrarily long payloads stream completely.
fn stageString(isolate: ?*c.Isolate, str: ?*const c.String, buf: []u8, len: *usize) void {
    const s = str orelse return;
    const utf8_len: usize = @intCast(c.v8__String__Utf8Length(s, isolate));
    var written: usize = 0;
    while (written < utf8_len) {
        if (len.* == buf.len) flush(buf, len);
        const capacity = @min(utf8_len - written, buf.len - len.*);
        const n = c.v8__String__WriteUtf8(
            s,
            isolate,
            buf[len.*..].ptr,
            @intCast(capacity),
            0,
        );
        if (n <= 0) break; // encode failure: drop remainder, keep prior output
        const advanced: usize = @intCast(n);
        len.* += advanced;
        written += advanced;
    }
}

fn consoleLogCallbackWithColor(info: ?*const c.FunctionCallbackInfo, color: []const u8) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var buf: [LINE_MAX]u8 = undefined;
    var len: usize = 0;
    if (color.len > 0) appendChunk(&buf, &len, color);
    const argc = c.v8__FunctionCallbackInfo__Length(info);
    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        if (i > 0) appendChunk(&buf, &len, " ");
        const val = c.v8__FunctionCallbackInfo__INDEX(info, i);
        stageString(isolate, c.v8__Value__ToString(val, context), &buf, &len);
    }
    if (color.len > 0) appendChunk(&buf, &len, RESET);
    appendChunk(&buf, &len, "\n");
    flush(&buf, &len);
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

    // ---- Browser-standard aliases (map onto existing handlers) ----
    const error_fn = c.v8__Function__New__DEFAULT(context, consoleRedbalCallback);
    const error_key = c.v8__String__NewFromUtf8(isolate, "error", 0, -1);
    c.v8__Object__Set(console_obj, context, error_key, error_fn, &out);

    const std_warn_fn = c.v8__Function__New__DEFAULT(context, consoleSlopsCallback);
    const std_warn_key = c.v8__String__NewFromUtf8(isolate, "warn", 0, -1);
    c.v8__Object__Set(console_obj, context, std_warn_key, std_warn_fn, &out);

    const info_fn = c.v8__Function__New__DEFAULT(context, consoleLogCallback);
    const info_key = c.v8__String__NewFromUtf8(isolate, "info", 0, -1);
    c.v8__Object__Set(console_obj, context, info_key, info_fn, &out);

    const debug_fn = c.v8__Function__New__DEFAULT(context, consoleLogCallback);
    const debug_key = c.v8__String__NewFromUtf8(isolate, "debug", 0, -1);
    c.v8__Object__Set(console_obj, context, debug_key, debug_fn, &out);

    const console_key = c.v8__String__NewFromUtf8(isolate, "console", 0, -1);
    _ = c.v8__Object__Set(global, context, console_key, console_obj, &out);
}
