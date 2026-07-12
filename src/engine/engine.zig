const std = @import("std");
const c = @cImport({
    @cInclude("binding.h");
});
const RED = "\x1b[31m";
const YELLOW = "\x1b[33m";
const RESET = "\x1b[0m";
const GREEN = "\x1b[32m";
const FunctionCallback = *const fn (?*const c.FunctionCallbackInfo) callconv(.c) void;
// ============================================================
// Global V8 platform — initialized once, never disposed
// ============================================================
var g_platform: ?*c.Platform = null;
fn initGlobal() void {
    if (g_platform != null) return;
    c.v8__V8__SetFlagsFromString("--always-opt", 12);
    c.v8__V8__SetFlagsFromString("--turbo-fast-api-calls", 22);
    const nproc: c_int = @intCast(std.Thread.getCpuCount() catch 4);
    g_platform = c.v8__Platform__NewDefaultPlatform(nproc, 1);
    c.v8__V8__InitializePlatform(g_platform);
    c.v8__V8__Initialize();
}
// ============================================================
// Console callbacks
// ============================================================
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
// ============================================================
// Runtime — one per eval, platform is shared globally
// ============================================================
pub const Runtime = struct {
    isolate: ?*c.Isolate,
    params: c.CreateParams,
    handle_scope: c.HandleScope,
    context: ?*c.Context,
    pub fn init() Runtime {
        initGlobal();
        // Create isolate
        var params: c.CreateParams = undefined;
        c.v8__Isolate__CreateParams__CONSTRUCT(&params);
        params.array_buffer_allocator = c.v8__ArrayBuffer__Allocator__NewDefaultAllocator();
        const isolate = c.v8__Isolate__New(&params);
        c.v8__Isolate__Enter(isolate);
        // Handle scope
        var handle_scope: c.HandleScope = undefined;
        c.v8__HandleScope__CONSTRUCT(&handle_scope, isolate);
        // Context
        const context = c.v8__Context__New(isolate, null, null);
        c.v8__Context__Enter(context);
        // Setup console
        setupConsole(isolate, context);
        return .{
            .isolate = isolate,
            .params = params,
            .handle_scope = handle_scope,
            .context = context,
        };
    }
    fn setupConsole(isolate: ?*c.Isolate, context: ?*c.Context) void {
        const global = c.v8__Context__Global(context);
        const console_obj = c.v8__Object__New(isolate);
        // console.log
        const log_func = c.v8__Function__New__DEFAULT(context, consoleLogCallback);
        const log_key = c.v8__String__NewFromUtf8(isolate, "log", 0, -1);
        var out1: c.MaybeBool = undefined;
        c.v8__Object__Set(console_obj, context, log_key, log_func, &out1);
        // console on global
        const console_key = c.v8__String__NewFromUtf8(isolate, "console", 0, -1);
        var out2: c.MaybeBool = undefined;
        c.v8__Object__Set(global, context, console_key, console_obj, &out2);
        // console.slops
        const slops_func = c.v8__Function__New__DEFAULT(context, consoleSlopsCallback);
        const slops_key = c.v8__String__NewFromUtf8(isolate, "slops", 0, -1);
        var out3: c.MaybeBool = undefined;
        c.v8__Object__Set(console_obj, context, slops_key, slops_func, &out3);
        // console.redbal
        const warn_func = c.v8__Function__New__DEFAULT(context, consoleRedbalCallback);
        const warn_key = c.v8__String__NewFromUtf8(isolate, "redbal", 0, -1);
        var out4: c.MaybeBool = undefined;
        c.v8__Object__Set(console_obj, context, warn_key, warn_func, &out4);
        // console.detail
        const detail_func = c.v8__Function__New__DEFAULT(context, consoleDetailCallback);
        const detail_key = c.v8__String__NewFromUtf8(isolate, "detail", 0, -1);
        var out5: c.MaybeBool = undefined;
        c.v8__Object__Set(console_obj, context, detail_key, detail_func, &out5);
    }
    pub fn deinit(self: *Runtime) void {
        c.v8__Context__Exit(self.context);
        c.v8__HandleScope__DESTRUCT(&self.handle_scope);
        c.v8__Isolate__Exit(self.isolate);
        c.v8__Isolate__Dispose(self.isolate);
        c.v8__ArrayBuffer__Allocator__DELETE(self.params.array_buffer_allocator);
        // Platform is global — never dispose it
    }
    pub fn eval(self: *Runtime, source: [:0]const u8, filename: [:0]const u8) bool {
        const js_src = c.v8__String__NewFromUtf8(self.isolate, source.ptr, 0, -1);
        const js_name = c.v8__String__NewFromUtf8(self.isolate, filename.ptr, 0, -1);
        var origin: c.ScriptOrigin = undefined;
        c.v8__ScriptOrigin__CONSTRUCT(&origin, js_name);
        var try_catch_buf: [@sizeOf(c.TryCatch)]u8 align(@alignOf(c.TryCatch)) = undefined;
        c.v8__TryCatch__CONSTRUCT(@ptrCast(&try_catch_buf), self.isolate);
        defer c.v8__TryCatch__DESTRUCT(@ptrCast(&try_catch_buf));
        const try_catch: *c.TryCatch = @ptrCast(&try_catch_buf);
        const script = c.v8__Script__Compile(self.context, js_src, &origin);
        if (script == null) {
            if (c.v8__TryCatch__HasCaught(try_catch)) {
                const msg = c.v8__TryCatch__StackTrace(try_catch, self.context);
                if (msg != null) {
                    const err_str = c.v8__Value__ToString(msg, self.context);
                    if (err_str != null) {
                        const utf8_len = c.v8__String__Utf8Length(err_str, self.isolate);
                        var buf: [4096]u8 = undefined;
                        const len = @min(@as(usize, @intCast(utf8_len)), buf.len);
                        _ = c.v8__String__WriteUtf8(err_str, self.isolate, &buf, @intCast(len), 0);
                        std.debug.print("Compile error: {s}\n", .{buf[0..len]});
                    }
                }
            }
            return false;
        }
        const result = c.v8__Script__Run(script, self.context);
        if (result == null) {
            if (c.v8__TryCatch__HasCaught(try_catch)) {
                const exception = c.v8__TryCatch__Exception(try_catch);
                if (exception != null) {
                    const err_str = c.v8__Value__ToString(exception, self.context);
                    if (err_str != null) {
                        const utf8_len = c.v8__String__Utf8Length(err_str, self.isolate);
                        var buf: [4096]u8 = undefined;
                        const len = @min(@as(usize, @intCast(utf8_len)), buf.len);
                        _ = c.v8__String__WriteUtf8(err_str, self.isolate, &buf, @intCast(len), 0);
                        std.debug.print("Runtime error: {s}\n", .{buf[0..len]});
                    }
                }
            }
            return false;
        }
        return true;
    }
};
