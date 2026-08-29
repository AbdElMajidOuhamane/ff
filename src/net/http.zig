const std = @import("std");
const c = @import("../c.zig").c;
const http_native = @import("http_native.zig");
const engine = @import("../engine/engine.zig");
const api_ws = @import("../api/websocket.zig");

pub var server_running = std.atomic.Value(bool).init(false);

fn throwTypeError(ctx: ?*c.Context, msg: []const u8) void {
    _ = c.throwTypeError(ctx, "http.serve: %s", @as([*c]const u8, @ptrCast(msg.ptr)));
}

fn extractIntFromVal(ctx: ?*c.Context, val: c.Value, default: u16) u16 {
    if (c.isUndefined(val) != 0 or c.isNull(val) != 0) return default;
    var out: i32 = 0;
    if (c.toInt32(ctx, &out, val) == -1) return default;
    return @intCast(out);
}

fn serveCallback(ctx: ?*c.Context, _: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    if (argc < 2) {
        throwTypeError(ctx, "http.serve requires (options, handler)");
        return c.JS_EXCEPTION;
    }

    const opts_val = argv[0];
    var port: u16 = 3000;

    if (c.isObject(opts_val) != 0) {
        const port_val = c.getPropertyStr(ctx, opts_val, "port");
        port = extractIntFromVal(ctx, port_val, 3000);

        const ws_obj_val = c.getPropertyStr(ctx, opts_val, "websocket");
        if (c.isObject(ws_obj_val) != 0) {
            http_native.ws_enabled = true;
            const open_val = c.getPropertyStr(ctx, ws_obj_val, "open");
            if (c.isFunction(ctx, open_val) != 0) {
                http_native.ws_on_open = c.dupValue(ctx, open_val);
            }
            const msg_val = c.getPropertyStr(ctx, ws_obj_val, "message");
            if (c.isFunction(ctx, msg_val) != 0) {
                http_native.ws_on_message = c.dupValue(ctx, msg_val);
            }
            const close_val = c.getPropertyStr(ctx, ws_obj_val, "close");
            if (c.isFunction(ctx, close_val) != 0) {
                http_native.ws_on_close = c.dupValue(ctx, close_val);
            }
        }
    } else if (c.isNumber(opts_val) != 0) {
        port = extractIntFromVal(ctx, opts_val, 3000);
    }

    const handler_val = argv[1];
    if (c.isFunction(ctx, handler_val) == 0) {
        throwTypeError(ctx, "http.serve: handler must be a function");
        return c.JS_EXCEPTION;
    }

    http_native.handler_fn = c.dupValue(ctx, handler_val);
    http_native.handler_ctx = ctx;

    const loop_ptr = engine.getEventLoop() orelse {
        throwTypeError(ctx, "http.serve: no event loop");
        return c.JS_EXCEPTION;
    };

    http_native.init(&loop_ptr.loop, port) catch |err| {
        std.debug.print("[http] FAILED: {}\n", .{err});
        return c.JS_EXCEPTION;
    };

    server_running.store(true, .release);

    return c.JS_UNDEFINED;
}

pub fn setup(ctx: ?*c.Context) void {
    http_native.setupStrings(ctx);
    api_ws.setup(ctx);

    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);

    const http_obj = c.newObject(ctx);
    const serve_func = c.newCFunction(ctx, &serveCallback, "serve", 2);
    _ = c.definePropertyValueStr(ctx, http_obj, "serve", serve_func, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
    _ = c.definePropertyValueStr(ctx, global, "http", http_obj, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
}
