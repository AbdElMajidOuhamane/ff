const std = @import("std");
const qjs = @import("quickjs_shim.zig");
const mod = @import("../modules/mod.zig");
const EventLoop = @import("../event/loop.zig").EventLoop;
const TimerManager = @import("../event/timers.zig").TimerManager;
const microtasks = @import("../event/microtasks.zig");
const console_api = @import("../api/console.zig");
const fs_api = @import("../api/fs.zig");
const process_api = @import("../api/process.zig");
const crypto_api = @import("../api/crypto.zig");
const url_api = @import("../api/url.zig");
const fetch_api = @import("../api/fetch.zig");
const header = @import("../types/headers.zig");
const request = @import("../types/request.zig");
const response = @import("../types/response.zig");
const http = @import("../net/http.zig");
const websocket_client = @import("../api/websocket_client.zig");
const http_native = @import("../net/http_native.zig");
const async_fetch = @import("../net/async_fetch.zig");
const ws_client = @import("../net/ws_client.zig");
const text_encoding = @import("../api/text_encoding.zig");




const gpa = std.heap.smp_allocator;
// DOD-FIX 9: single boot arena; runtime struct + EventLoop live inside it
// instead of being individually page_allocator-allocated.
var boot_arena: std.heap.ArenaAllocator = undefined;
var boot_inited: bool = false;

pub fn getEventLoop() ?*EventLoop {
    if (g_runtime) |rt| return rt.event_loop else return null;
}

pub fn deinitNetwork() void {
    http_native.deinit();
}

var g_runtime: ?*Runtime = null;

// ── ESM module loading (NEW) ────────────────────────────────────
// Mirrors quickjs-libc's js_module_loader: eval with
// EVAL_TYPE_MODULE | COMPILE_ONLY, harvest the JSModuleDef from the
// JSValue pointer, free the JSValue wrapper (module already referenced).
fn moduleNormalize(ctx: ?*qjs.Context, base_name: [*c]const u8, name: [*c]const u8, opaque_: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = opaque_;
    const base = std.mem.span(base_name);
    const spec = std.mem.span(name);
    const dir = std.fs.path.dirname(base) orelse ".";
    const resolved = mod.resolveSpec(gpa, dir, spec) catch return null;
    defer gpa.free(resolved);
    // no extension → append .js (sentinel-terminated for js_strdup)
    const has_ext = std.mem.lastIndexOfScalar(u8, std.fs.path.basename(resolved), '.') != null;
    var path_z: [:0]u8 = undefined;
    if (has_ext) {
        path_z = gpa.allocSentinel(u8, resolved.len, 0) catch return null;
        @memcpy(path_z[0..resolved.len], resolved);
    } else {
        path_z = gpa.allocSentinel(u8, resolved.len + 3, 0) catch return null;
        @memcpy(path_z[0..resolved.len], resolved);
        @memcpy(path_z[resolved.len..][0..3], ".js");
    }
    defer gpa.free(path_z);
    return qjs.js_strdup(ctx, path_z.ptr);
}

fn moduleLoader(ctx: ?*qjs.Context, module_name: [*c]const u8, opaque_: ?*anyopaque) callconv(.c) ?*qjs.ModuleDef {
    _ = opaque_;
    const name = std.mem.span(module_name);
    const src = mod.readFile(gpa, name) catch {
        _ = qjs.throwReferenceError(ctx, "could not load module filename '%s'", name.ptr);
        return null;
    };
    defer gpa.free(src);
    const func_val = qjs.eval(ctx, src.ptr, src.len, name.ptr, qjs.EVAL_TYPE_MODULE | qjs.EVAL_FLAG_COMPILE_ONLY);
    if (qjs.isException(func_val) != 0) return null;
    const m: *qjs.ModuleDef = @ptrCast(@alignCast(func_val.u.ptr));
    // import.meta.url (minimal js_module_set_import_meta equivalent)
    const meta = qjs.getImportMeta(ctx, m);
    if (qjs.isException(meta) == 0 and qjs.isNull(meta) == 0 and qjs.isUndefined(meta) == 0) {
        if (std.mem.indexOfScalar(u8, name, ':') == null) {
            // "file://" (7 bytes) + name + NUL — no allocPrintZ in Zig 0.16
            const us = gpa.allocSentinel(u8, name.len + 7, 0) catch null;
            if (us) |uz| {
                defer gpa.free(uz);
                @memcpy(uz[0..7], "file://");
                @memcpy(uz[7..][0..name.len], name);
                _ = qjs.definePropertyValueStr(ctx, meta, "url", qjs.newStringLen(ctx, uz.ptr, name.len + 7), qjs.PROP_C_W_E);
            }
        }
    }
    qjs.freeValue(ctx, meta);
    qjs.freeValue(ctx, func_val); // module already referenced, so free the wrapper
    return m;
}

pub const Runtime = struct {
    ctx: *qjs.Context,
    event_loop: *EventLoop,
    timer_manager: TimerManager,

    pub fn init(args: std.process.Args) !*Runtime {
        const rt = qjs.newRuntime() orelse return error.InitFailed;
        qjs.setMaxStackSize(rt, 1024 * 1024);
        qjs.setMemoryLimit(rt, 64 * 1024 * 1024);
        // NEW: real ESM support — QuickJS resolves imports via these hooks
        qjs.setModuleLoaderFunc(rt, moduleNormalize, moduleLoader, null);

        const ctx = qjs.newContext(rt) orelse return error.InitFailed;

        console_api.setup(ctx);
        fs_api.setup(ctx);
        process_api.setup(ctx, args);
        crypto_api.setup(ctx);
        url_api.setup(ctx);
        fetch_api.setup(ctx);
        header.setup(ctx);
        request.setup(ctx);
        response.setup(ctx);
        http.setup(ctx);
        websocket_client.setup(ctx);
        text_encoding.setup(ctx);
        const global = qjs.getGlobalObject(ctx);
        defer qjs.freeValue(ctx, global);

        const setTimeout_func = qjs.newCFunction(ctx, setTimeoutCallback, "setTimeout", 2);
        const setInterval_func = qjs.newCFunction(ctx, setIntervalCallback, "setInterval", 2);
        const clearTimeout_func = qjs.newCFunction(ctx, clearTimeoutCallback, "clearTimeout", 1);
        const clearInterval_func = qjs.newCFunction(ctx, clearIntervalCallback, "clearInterval", 1);
        const queue_microtask_func = qjs.newCFunction(ctx, queueMicrotaskCallback, "queueMicrotask", 1); // NEW

        _ = qjs.definePropertyValueStr(ctx, global, "setTimeout", setTimeout_func, qjs.PROP_C_W_E);
        _ = qjs.definePropertyValueStr(ctx, global, "setInterval", setInterval_func, qjs.PROP_C_W_E);
        _ = qjs.definePropertyValueStr(ctx, global, "clearTimeout", clearTimeout_func, qjs.PROP_C_W_E);
        _ = qjs.definePropertyValueStr(ctx, global, "clearInterval", clearInterval_func, qjs.PROP_C_W_E);
        _ = qjs.definePropertyValueStr(ctx, global, "queueMicrotask", queue_microtask_func, qjs.PROP_C_W_E); // NEW

        if (!boot_inited) {
            boot_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            boot_inited = true;
        }
        const boot = boot_arena.allocator();

        const loop_ptr = try boot.create(EventLoop);
        EventLoop.initInto(loop_ptr);
        // Store the loop for lazy arming; do NOT arm here — an always-armed
        // pump keeps hasWork() true and prevents script-mode exit.
        async_fetch.setLoop(&loop_ptr.loop);
        ws_client.setLoop(&loop_ptr.loop);

        const runtime = try boot.create(Runtime);
        runtime.* = .{
            .ctx = ctx,
            .event_loop = loop_ptr,
            .timer_manager = TimerManager.init(&loop_ptr.loop),
        };
        g_runtime = runtime;
        return runtime;
    }

    fn setTimeoutCallback(ctx: ?*qjs.Context, this_val: qjs.Value, argc: c_int, argv: [*c]qjs.Value) callconv(.c) qjs.Value {
        _ = this_val;
        scheduleCallback(ctx, argc, argv, false);
        return qjs.JS_UNDEFINED;
    }

    fn setIntervalCallback(ctx: ?*qjs.Context, this_val: qjs.Value, argc: c_int, argv: [*c]qjs.Value) callconv(.c) qjs.Value {
        _ = this_val;
        scheduleCallback(ctx, argc, argv, true);
        return qjs.JS_UNDEFINED;
    }

    fn clearTimeoutCallback(ctx: ?*qjs.Context, this_val: qjs.Value, argc: c_int, argv: [*c]qjs.Value) callconv(.c) qjs.Value {
        _ = this_val;
        clearCallback(ctx, argc, argv);
        return qjs.JS_UNDEFINED;
    }

    fn clearIntervalCallback(ctx: ?*qjs.Context, this_val: qjs.Value, argc: c_int, argv: [*c]qjs.Value) callconv(.c) qjs.Value {
        _ = this_val;
        clearCallback(ctx, argc, argv);
        return qjs.JS_UNDEFINED;
    }

    fn scheduleCallback(ctx: ?*qjs.Context, argc: c_int, argv: [*c]qjs.Value, interval: bool) void {
        const rt = g_runtime orelse return;
        if (argc < 2) return;
        const fn_val = argv[0];
        const ms_val = argv[1];
        var ms: i64 = 0;
        _ = qjs.toInt64(ctx, &ms, ms_val);
        if (ms < 0) return;
        const result = if (interval)
            rt.timer_manager.setInterval(ctx.?, fn_val, @intCast(ms))
        else
            rt.timer_manager.setTimeout(ctx.?, fn_val, @intCast(ms));
        _ = result catch return;
    }

    fn clearCallback(ctx: ?*qjs.Context, argc: c_int, argv: [*c]qjs.Value) void {
        const rt = g_runtime orelse return;
        if (argc < 1) return;
        var id: i32 = 0;
        _ = qjs.toInt32(ctx, &id, argv[0]);
        if (id >= 0) rt.timer_manager.clear(@intCast(id));
    }

    // ── queueMicrotask (NEW) — zero alloc: JS_EnqueueJob dups argv ──
    fn microtaskJob(ctx: ?*qjs.Context, argc: c_int, argv: [*c]qjs.Value) callconv(.c) qjs.Value {
        _ = argc;
        const ret = qjs.call(ctx, argv[0], qjs.JS_UNDEFINED, 0, null);
        if (qjs.isException(ret) != 0) {
            // swallow: keep the shared job queue clean, report to stderr
            const exc = qjs.getException(ctx);
            defer qjs.freeValue(ctx, exc);
            const msg = qjs.toCString(ctx, exc);
            if (msg) |m| {
                defer qjs.freeCString(ctx, m);
                std.debug.print("queueMicrotask error: {s}\n", .{m});
            }
            return qjs.JS_UNDEFINED;
        }
        return ret;
    }

    fn queueMicrotaskCallback(ctx: ?*qjs.Context, this_val: qjs.Value, argc: c_int, argv: [*c]qjs.Value) callconv(.c) qjs.Value {
        _ = this_val;
        if (argc < 1 or qjs.isFunction(ctx, argv[0]) == 0) {
            _ = qjs.throwTypeError(ctx, "queueMicrotask requires a function argument");
            return qjs.JS_EXCEPTION;
        }
        if (qjs.enqueueJob(ctx, microtaskJob, 1, argv) != 0) return qjs.JS_EXCEPTION;
        return qjs.JS_UNDEFINED;
    }

    pub fn deinit(self: *Runtime) void {
        fetch_api.deinitClient();
        self.timer_manager.cancelAll();
        const rt = qjs.getRuntime(self.ctx);
        qjs.freeContext(self.ctx);
        qjs.freeRuntime(rt);
        // Boot arena is the sole owner of `self` and the EventLoop.
        // Free it LAST so all references stay valid above.
        if (boot_inited) {
            boot_arena.deinit();
            boot_inited = false;
        }
    }

    pub fn eval(self: *Runtime, source: [:0]const u8, filename: [:0]const u8) bool {
        const result = qjs.eval(
            self.ctx,
            source.ptr,
            source.len,
            filename.ptr,
            qjs.EVAL_TYPE_GLOBAL,
        );
        defer qjs.freeValue(self.ctx, result);
        if (qjs.isException(result) != 0) {
            const exc = qjs.getException(self.ctx);
            defer qjs.freeValue(self.ctx, exc);
            const msg = qjs.toCString(self.ctx, exc);
            if (msg) |m| {
                defer qjs.freeCString(self.ctx, m);
                std.debug.print("Error: {s}\n", .{m});
            }
            return false;
        }
        microtasks.pumpMicrotasks(self.ctx);
        return true;
    }

    pub fn evalModule(self: *Runtime, source: []const u8, filename: [:0]const u8) bool {
        // CHANGED: real module eval — imports resolve via moduleLoader
        const flags: c_int = if (qjs.detectModule(source.ptr, source.len) != 0)
            qjs.EVAL_TYPE_MODULE
        else
            qjs.EVAL_TYPE_GLOBAL;
        const result = qjs.eval(
            self.ctx,
            source.ptr,
            source.len,
            filename.ptr,
            flags,
        );
        defer qjs.freeValue(self.ctx, result);
        if (qjs.isException(result) != 0) {
            const exc = qjs.getException(self.ctx);
            defer qjs.freeValue(self.ctx, exc);
            const msg = qjs.toCString(self.ctx, exc);
            if (msg) |m| {
                defer qjs.freeCString(self.ctx, m);
                std.debug.print("Error: {s}\n", .{m});
            }
            return false;
        }
        microtasks.pumpMicrotasks(self.ctx);
        return true;
    }
};
