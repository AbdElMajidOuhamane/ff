const std = @import("std");
const c = @import("../c.zig").c;
const http_native = @import("http_native.zig");
const tls_server = @import("tls_server.zig");
const tls = @import("tls.zig");
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

/// Copy a JS string into a page_allocator-owned Zig slice (caller frees).
fn dupeJsString(ctx: ?*c.Context, val: c.Value) ?[]u8 {
    const cstr = c.toCString(ctx, val) orelse return null;
    defer c.freeCString(ctx, cstr);
    return std.heap.page_allocator.dupe(u8, cstr[0..std.mem.len(cstr)]) catch null;
}

/// TLS input auto-detection: "-----BEGIN..." is PEM content (returned as-is),
/// anything else is a file path read from cwd (fresh allocation).
/// Caller frees the result unless it is the same pointer as `owned`.
fn resolvePem(owned: []u8) ?[]u8 {
    if (std.mem.startsWith(u8, owned, "-----BEGIN ")) return owned;
    const io = tls.client().io;
    return std.Io.Dir.cwd().readFileAlloc(io, owned, std.heap.page_allocator, .limited(512 * 1024)) catch {
        std.debug.print("[https] could not read TLS file '{s}'\n", .{owned});
        return null;
    };
}

/// Apply `http.serve({ tls: { cert, key } })`: load the cert chain + key into
/// the BearSSL server config and arm TLS before the listener starts.
/// Returns false (with a JS exception thrown) on any failure.
fn loadTlsFromOptions(ctx: ?*c.Context, opts_val: c.Value) bool {
    // Cheap probe first so the no-tls path stays allocation-free.
    const probe = c.getPropertyStr(ctx, opts_val, "tls");
    if (c.isObject(probe) == 0) return true; // no tls requested — plain http
    if (!tls_server.available) {
        throwTypeError(ctx, "built without TLS (rebuild without -Dbearssl=false)");
        return false;
    }

    const cert_val = c.getPropertyStr(ctx, probe, "cert");
    const key_val = c.getPropertyStr(ctx, probe, "key");
    if (c.isString(cert_val) == 0 or c.isString(key_val) == 0) {
        throwTypeError(ctx, "tls.cert and tls.key must be strings (PEM content or file path)");
        return false;
    }

    const cert_str = dupeJsString(ctx, cert_val) orelse {
        throwTypeError(ctx, "out of memory reading tls.cert");
        return false;
    };
    defer std.heap.page_allocator.free(cert_str);
    const key_str = dupeJsString(ctx, key_val) orelse {
        throwTypeError(ctx, "out of memory reading tls.key");
        return false;
    };
    defer std.heap.page_allocator.free(key_str);

    const cert_pem = resolvePem(cert_str) orelse {
        throwTypeError(ctx, "could not read tls.cert");
        return false;
    };
    defer if (cert_pem.ptr != cert_str.ptr) std.heap.page_allocator.free(cert_pem);
    const key_pem = resolvePem(key_str) orelse {
        throwTypeError(ctx, "could not read tls.key");
        return false;
    };
    defer if (key_pem.ptr != key_str.ptr) std.heap.page_allocator.free(key_pem);

    tls_server.initServer(cert_pem, key_pem) catch |e| {
        std.debug.print("[https] TLS init failed: {s}\n", .{@errorName(e)});
        throwTypeError(ctx, "TLS init failed");
        return false;
    };

    // Best-effort: when the cert came from a path, also make the runtime's own
    // fetch/wss client trust it (same as --cert). Process-lifetime by design.
    // (Skipped for inline PEM content.)
    if (cert_pem.ptr != cert_str.ptr and tls.ca_file == null) {
        tls.ca_file = std.heap.page_allocator.dupe(u8, cert_str) catch null;
    }

    http_native.enableTls();
    return true;
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
        throwTypeError(ctx, "handler must be a function");
        return c.JS_EXCEPTION;
    }

    http_native.handler_fn = c.dupValue(ctx, handler_val);
    http_native.handler_ctx = ctx;

    // TLS must be fully configured before the listener starts accepting.
    if (!loadTlsFromOptions(ctx, opts_val)) {
        return c.JS_EXCEPTION;
    }

    const loop_ptr = engine.getEventLoop() orelse {
        throwTypeError(ctx, "no event loop");
        return c.JS_EXCEPTION;
    };

        http_native.init(&loop_ptr.loop, port) catch |err| {
        std.debug.print("[http] FAILED: {}\n", .{err});
        throwTypeError(ctx, "failed to start server (is the port in use?)");
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
