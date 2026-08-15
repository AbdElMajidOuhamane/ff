const std = @import("std");
const c = @import("../c.zig").c;
const http_native = @import("http_native.zig");
const engine = @import("../engine/engine.zig");
const api_ws = @import("../api/websocket.zig");

pub var server_running = std.atomic.Value(bool).init(false);

fn throwTypeError(isolate: ?*c.Isolate, msg: []const u8) void {
    const v8_msg = c.v8__String__NewFromUtf8(isolate, @ptrCast(msg.ptr), 0, @intCast(msg.len));
    const exc = c.v8__Exception__TypeError(v8_msg);
    _ = c.v8__Isolate__ThrowException(isolate, exc);
}

fn extractIntFromVal(isolate: ?*c.Isolate, context: ?*c.Context, val: ?*const c.Value, default: u16) u16 {
    _ = isolate;
    const v = val orelse return default;
    if (c.v8__Value__IsUndefined(v) or c.v8__Value__IsNull(v)) return default;
    var out: c.MaybeI32 = undefined;
    c.v8__Value__Int32Value(v, context, &out);
    return @intCast(out.value);
}

fn serveCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);

    if (c.v8__FunctionCallbackInfo__Length(info) < 2) {
        throwTypeError(isolate, "http.serve requires (options, handler)");
        return;
    }

    const opts_val = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    var port: u16 = 3000;

    if (c.v8__Value__IsObject(opts_val)) {
        const port_val = c.v8__Object__Get(@ptrCast(opts_val), context, c.v8__String__NewFromUtf8(isolate, "port", 0, -1));
        port = extractIntFromVal(isolate, context, port_val, 3000);

        const ws_obj_val = c.v8__Object__Get(@ptrCast(opts_val), context, c.v8__String__NewFromUtf8(isolate, "websocket", 0, -1));
        if (ws_obj_val != null and c.v8__Value__IsObject(ws_obj_val)) {
            http_native.ws_enabled = true;
            if (c.v8__Object__Get(@ptrCast(ws_obj_val), context, c.v8__String__NewFromUtf8(isolate, "open", 0, -1))) |v| {
                if (c.v8__Value__IsFunction(v)) c.v8__Global__New(isolate, @ptrCast(v), &http_native.ws_on_open);
            }
            if (c.v8__Object__Get(@ptrCast(ws_obj_val), context, c.v8__String__NewFromUtf8(isolate, "message", 0, -1))) |v| {
                if (c.v8__Value__IsFunction(v)) c.v8__Global__New(isolate, @ptrCast(v), &http_native.ws_on_message);
            }
            if (c.v8__Object__Get(@ptrCast(ws_obj_val), context, c.v8__String__NewFromUtf8(isolate, "close", 0, -1))) |v| {
                if (c.v8__Value__IsFunction(v)) c.v8__Global__New(isolate, @ptrCast(v), &http_native.ws_on_close);
            }
        }
    } else if (c.v8__Value__IsNumber(opts_val)) {
        port = extractIntFromVal(isolate, context, opts_val, 3000);
    }

    const handler_val = c.v8__FunctionCallbackInfo__INDEX(info, 1);
    if (!c.v8__Value__IsFunction(handler_val)) {
        throwTypeError(isolate, "http.serve: handler must be a function");
        return;
    }

    c.v8__Global__New(isolate, @ptrCast(handler_val), &http_native.handler_fn_global);
    c.v8__Global__New(isolate, @ptrCast(context), &http_native.handler_context_global);
    http_native.handler_isolate = isolate;

    const loop_ptr = engine.getEventLoop() orelse {
        throwTypeError(isolate, "http.serve: no event loop");
        return;
    };

    http_native.init(&loop_ptr.loop, port) catch |err| {
        std.debug.print("[http] FAILED: {}\n", .{err});
        return;
    };

    server_running.store(true, .release);

    c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));
}

pub fn setup(isolate: ?*c.Isolate, context: ?*c.Context) void {
    http_native.setupStrings(isolate);
    api_ws.setupStrings(isolate);

    var hs: c.HandleScope = undefined;
    c.v8__HandleScope__CONSTRUCT(&hs, isolate);
    defer c.v8__HandleScope__DESTRUCT(&hs);

    const global = c.v8__Context__Global(context);
    var out: c.MaybeBool = undefined;

    const http_obj = c.v8__Object__New(isolate);
    const serve_func = c.v8__Function__New__DEFAULT(context, serveCallback);
    _ = c.v8__Object__Set(http_obj, context, c.v8__String__NewFromUtf8(isolate, "serve", 0, -1), serve_func, &out);
    _ = c.v8__Object__Set(global, context, c.v8__String__NewFromUtf8(isolate, "http", 0, -1), http_obj, &out);
}
