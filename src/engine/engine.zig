const std = @import("std");
const builtin = @import("builtin");
const qjs = @import("quickjs_shim.zig");
const mod = @import("../modules/mod.zig");
const EventLoop = @import("../event/loop.zig").EventLoop;
const loop_mod = @import("../event/loop.zig");
const TimerManager = @import("../event/timers.zig").TimerManager;
const microtasks = @import("../event/microtasks.zig");
const console_api = @import("../api/console.zig");
const fs_api = @import("../api/fs.zig");
const process_api = @import("../api/process.zig");
const permissions_api = @import("../api/permissions.zig");
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
const formdata = @import("../types/formdata.zig");
const blob = @import("../types/blob.zig");
const sqlite_api = @import("../api/sqlite.zig");
const worker_mod = @import("../worker/worker.zig");
const sql_api = @import("../api/sql.zig");
const pg_client = @import("../net/pg_client.zig");
const ffi_api = @import("../api/ffi.zig");
const udp_api = @import("../api/udp.zig");
const child_process_api = @import("../api/child_process.zig");

const gpa = std.heap.smp_allocator;
var boot_arena: std.heap.ArenaAllocator = undefined;
var boot_inited: bool = false;

pub fn getEventLoop() ?*EventLoop {
    if (g_runtime) |rt| return rt.event_loop else return null;
}

pub fn deinitNetwork() void {
    http_native.deinit();
    ws_client.deinit();
    worker_mod.deinit();
    sql_api.deinit();
}

var g_runtime: ?*Runtime = null;

var timeout_class_id: qjs.ClassID = 0;

// F2: no TimeoutData heap node. The timer slot (u8, max 128) is encoded
// directly in the opaque pointer as (slot + 1); +1 keeps slot 0 distinct
// from NULL. Type safety is preserved: getOpaque2 still NULL-guards on the
// Timeout class id, so a forged integer can never be misread from a
// non-Timeout object. Zero heap allocation per setTimeout/setInterval and
// no pointer chase on ref/unref/refresh/hasRef/clear.
fn slotFromOpaque(ptr: *anyopaque) ?u8 {
    const v: usize = @intFromPtr(ptr);
    if (v == 0 or v > 128) return null;
    return @intCast(v - 1);
}

fn timeoutFinalizer(rt: ?*qjs.Runtime, val: qjs.Value) callconv(.c) void {
    _ = rt;
    _ = val;
    // No-op: the opaque is a tagged slot index, not a heap pointer.
}

fn timeoutSlotFromThis(ctx: ?*qjs.Context, this_val: qjs.Value) ?u8 {
    const data_ptr = qjs.getOpaque2(ctx, this_val, timeout_class_id) orelse return null;
    return slotFromOpaque(data_ptr);
}

fn makeTimeout(ctx: ?*qjs.Context, id: usize) ?qjs.Value {
    const obj = qjs.newObjectClass(ctx, @intCast(timeout_class_id));
    qjs.setOpaque(obj, @ptrFromInt(id + 1));
    return obj;
}

fn moduleNormalize(ctx: ?*qjs.Context, base_name: [*c]const u8, name: [*c]const u8, opaque_: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = opaque_;
    const base = std.mem.span(base_name);
    const spec = std.mem.span(name);
    const dir = std.fs.path.dirname(base) orelse ".";
    const resolved = mod.resolveSpec(gpa, dir, spec) catch return null;
    defer gpa.free(resolved);
    const has_ext = std.mem.lastIndexOfScalar(u8, std.fs.path.basename(resolved), '.') != null;
    var path_z: [:0]u8 = undefined;
    if (has_ext) {
        path_z = gpa.allocSentinel(u8, resolved.len, 0) catch return null;
        @memcpy(path_z[0..resolved.len], resolved);
    } else {
        // Extensionless import: try P.js, then P/index.js (directory import).
        // Fall back to P.js so the loader error names a concrete file.
        const js_path = std.fmt.allocPrint(gpa, "{s}.js", .{resolved}) catch return null;
        defer gpa.free(js_path);
        const idx_path = std.fmt.allocPrint(gpa, "{s}/index.js", .{resolved}) catch return null;
        defer gpa.free(idx_path);
        const chosen: []const u8 = if (mod.pathExists(gpa, js_path))
            js_path
        else if (mod.pathExists(gpa, idx_path))
            idx_path
        else
            js_path;
        path_z = gpa.allocSentinel(u8, chosen.len, 0) catch return null;
        @memcpy(path_z[0..chosen.len], chosen);
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
    // QuickJS requires input[input_len] == '\0' (quickjs.h:1034).
    // readFile returns a non-sentinel buffer, so dupeZ it — same
    // pattern as start.zig uses for the entry file.
    const src_z = gpa.dupeZ(u8, src) catch {
        _ = qjs.throwReferenceError(ctx, "out of memory loading module '%s'", name.ptr);
        return null;
    };
    defer gpa.free(src_z);
    // FIX: blocking stdout write on every module load is Debug-only.
    // In release it stalls the loader path for zero user benefit.
    if (builtin.mode == .Debug) {
        std.debug.print("load {s} ({d} bytes) head=[{s}] tail=[{s}]\n", .{
            name,
            src.len,
            if (src.len >= 16) src[0..16] else src,
            if (src.len >= 16) src[src.len - 16 ..] else src,
        });
    }
    const func_val = qjs.eval(ctx, src_z.ptr, src.len, name.ptr, qjs.EVAL_TYPE_MODULE | qjs.EVAL_FLAG_COMPILE_ONLY);
    if (qjs.isException(func_val) != 0) return null;
    const m: *qjs.ModuleDef = @ptrCast(@alignCast(func_val.u.ptr));
    const meta = qjs.getImportMeta(ctx, m);
    if (qjs.isException(meta) == 0 and qjs.isNull(meta) == 0 and qjs.isUndefined(meta) == 0) {
        if (std.mem.indexOfScalar(u8, name, ':') == null) {
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
    qjs.freeValue(ctx, func_val);
    return m;
}

// Print an exception value (message, then stack if present) and mark the
// run as failed. Takes ownership of `exc` — the caller must not free it.
// Shared by eval() and evalModule().
fn reportAndFail(self: *Runtime, exc: qjs.Value) void {
    defer qjs.freeValue(self.ctx, exc);
    microtasks.had_error = true;
    const msg = qjs.toCString(self.ctx, exc);
    if (msg) |m| {
        defer qjs.freeCString(self.ctx, m);
        std.debug.print("Error: {s}\n", .{m});
    }
    const stack_val = qjs.getPropertyStr(self.ctx, exc, "stack");
    defer qjs.freeValue(self.ctx, stack_val);
    if (qjs.isException(stack_val) == 0 and qjs.isUndefined(stack_val) == 0) {
        const smsg = qjs.toCString(self.ctx, stack_val);
        if (smsg) |sm| {
            defer qjs.freeCString(self.ctx, sm);
            std.debug.print("{s}\n", .{sm});
        }
    }
}

pub const Runtime = struct {
    ctx: *qjs.Context,
    event_loop: *EventLoop,
    timer_manager: TimerManager,

    pub fn init(args: std.process.Args) !*Runtime {
        const rt = qjs.newRuntime() orelse return error.InitFailed;
        qjs.setMaxStackSize(rt, 1024 * 1024);
        qjs.setMemoryLimit(rt, 64 * 1024 * 1024);
        qjs.setModuleLoaderFunc(rt, moduleNormalize, moduleLoader, null);

        const ctx = qjs.newContext(rt) orelse return error.InitFailed;

        console_api.setup(ctx);
        fs_api.setup(ctx);
        process_api.setup(ctx, args);
        permissions_api.setup(ctx);
        crypto_api.setup(ctx);
        url_api.setup(ctx);
        fetch_api.setup(ctx);
        header.setup(ctx);
        blob.setup(ctx);
        formdata.setup(ctx);
        request.setup(ctx);
        response.setup(ctx);
        http.setup(ctx);
        udp_api.setup(ctx);
        websocket_client.setup(ctx);
        text_encoding.setup(ctx);
        sqlite_api.setup(ctx);
        sql_api.setup(ctx);
        worker_mod.setup(ctx);
        ffi_api.setup(ctx);
        child_process_api.setup(ctx);
        {
            var timeout_def = qjs.ClassDef{
                .class_name = "Timeout",
                .finalizer = timeoutFinalizer,
            };
            _ = qjs.newClassID(qjs.getRuntime(ctx), &timeout_class_id);
            _ = qjs.newClass(qjs.getRuntime(ctx), timeout_class_id, &timeout_def);
            const timeout_proto = qjs.newObject(ctx);
            const unref_fn = qjs.newCFunction(ctx, timeoutUnref, "unref", 0);
            _ = qjs.definePropertyValueStr(ctx, timeout_proto, "unref", unref_fn, qjs.PROP_C_W_E);
            const ref_fn = qjs.newCFunction(ctx, timeoutRef, "ref", 0);
            _ = qjs.definePropertyValueStr(ctx, timeout_proto, "ref", ref_fn, qjs.PROP_C_W_E);
            const refresh_fn = qjs.newCFunction(ctx, timeoutRefresh, "refresh", 0);
            _ = qjs.definePropertyValueStr(ctx, timeout_proto, "refresh", refresh_fn, qjs.PROP_C_W_E);
            const has_ref_fn = qjs.newCFunction(ctx, timeoutHasRef, "hasRef", 0);
            _ = qjs.definePropertyValueStr(ctx, timeout_proto, "hasRef", has_ref_fn, qjs.PROP_C_W_E);
            qjs.setClassProto(ctx, timeout_class_id, timeout_proto);
        }
        const global = qjs.getGlobalObject(ctx);
        defer qjs.freeValue(ctx, global);

        const setTimeout_func = qjs.newCFunction(ctx, setTimeoutCallback, "setTimeout", 2);
        const setInterval_func = qjs.newCFunction(ctx, setIntervalCallback, "setInterval", 2);
        const clearTimeout_func = qjs.newCFunction(ctx, clearTimeoutCallback, "clearTimeout", 1);
        const clearInterval_func = qjs.newCFunction(ctx, clearIntervalCallback, "clearInterval", 1);
        const queue_microtask_func = qjs.newCFunction(ctx, queueMicrotaskCallback, "queueMicrotask", 1);

        _ = qjs.definePropertyValueStr(ctx, global, "setTimeout", setTimeout_func, qjs.PROP_C_W_E);
        _ = qjs.definePropertyValueStr(ctx, global, "setInterval", setInterval_func, qjs.PROP_C_W_E);
        _ = qjs.definePropertyValueStr(ctx, global, "clearTimeout", clearTimeout_func, qjs.PROP_C_W_E);
        _ = qjs.definePropertyValueStr(ctx, global, "clearInterval", clearInterval_func, qjs.PROP_C_W_E);
        _ = qjs.definePropertyValueStr(ctx, global, "queueMicrotask", queue_microtask_func, qjs.PROP_C_W_E);
        setupPerformance(ctx);

        if (!boot_inited) {
            boot_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            boot_inited = true;
        }
        const boot = boot_arena.allocator();

        const loop_ptr = try boot.create(EventLoop);
        EventLoop.initInto(loop_ptr);
        async_fetch.setLoop(&loop_ptr.loop);
        ws_client.setLoop(&loop_ptr.loop);
        pg_client.setLoop(&loop_ptr.loop);
        ffi_api.setLoop(&loop_ptr.loop);
        fs_api.setLoop(&loop_ptr.loop);
        child_process_api.setLoop(&loop_ptr.loop);
        process_api.setLoop(&loop_ptr.loop);
        worker_mod.setLoop(&loop_ptr.loop);

        const runtime = try boot.create(Runtime);
        runtime.* = .{
            .ctx = ctx,
            .event_loop = loop_ptr,
            .timer_manager = TimerManager.init(&loop_ptr.loop),
        };
        loop_mod.timer_mgr = &runtime.timer_manager;
        g_runtime = runtime;
        return runtime;
    }

    fn setTimeoutCallback(ctx: ?*qjs.Context, this_val: qjs.Value, argc: c_int, argv: [*c]qjs.Value) callconv(.c) qjs.Value {
        _ = this_val;
        return scheduleTimeout(ctx, argc, argv, false, true);
    }

    fn setIntervalCallback(ctx: ?*qjs.Context, this_val: qjs.Value, argc: c_int, argv: [*c]qjs.Value) callconv(.c) qjs.Value {
        _ = this_val;
        return scheduleTimeout(ctx, argc, argv, true, true);
    }

    // Numeric-id variants for worker runtimes (no Timeout class there:
    // class IDs are parent-runtime globals). Workers phase consumes these.
    fn wSetTimeoutCallback(ctx: ?*qjs.Context, this_val: qjs.Value, argc: c_int, argv: [*c]qjs.Value) callconv(.c) qjs.Value {
        _ = this_val;
        return scheduleTimeout(ctx, argc, argv, false, false);
    }

    fn wSetIntervalCallback(ctx: ?*qjs.Context, this_val: qjs.Value, argc: c_int, argv: [*c]qjs.Value) callconv(.c) qjs.Value {
        _ = this_val;
        return scheduleTimeout(ctx, argc, argv, true, false);
    }

    pub fn setupWorkerTimers(ctx: ?*qjs.Context) void {
        const global = qjs.getGlobalObject(ctx);
        defer qjs.freeValue(ctx, global);
        const st = qjs.newCFunction(ctx, wSetTimeoutCallback, "setTimeout", 2);
        _ = qjs.definePropertyValueStr(ctx, global, "setTimeout", st, qjs.PROP_C_W_E);
        const si = qjs.newCFunction(ctx, wSetIntervalCallback, "setInterval", 2);
        _ = qjs.definePropertyValueStr(ctx, global, "setInterval", si, qjs.PROP_C_W_E);
        const ct = qjs.newCFunction(ctx, clearTimeoutCallback, "clearTimeout", 1);
        _ = qjs.definePropertyValueStr(ctx, global, "clearTimeout", ct, qjs.PROP_C_W_E);
        const ci = qjs.newCFunction(ctx, clearIntervalCallback, "clearInterval", 1);
        _ = qjs.definePropertyValueStr(ctx, global, "clearInterval", ci, qjs.PROP_C_W_E);
        const qm = qjs.newCFunction(ctx, queueMicrotaskCallback, "queueMicrotask", 1);
        _ = qjs.definePropertyValueStr(ctx, global, "queueMicrotask", qm, qjs.PROP_C_W_E);
        setupPerformance(ctx);
    }

    fn scheduleTimeout(ctx: ?*qjs.Context, argc: c_int, argv: [*c]qjs.Value, interval: bool, as_object: bool) qjs.Value {
        if (argc < 1 or qjs.isFunction(ctx, argv[0]) == 0) {
            _ = qjs.throwTypeError(ctx, "setTimeout requires a function as first argument");
            return qjs.JS_EXCEPTION;
        }
        var ms: i64 = 0;
        if (argc >= 2) _ = qjs.toInt64(ctx, &ms, argv[1]);
        if (ms < 0) ms = 0; // clamp: browsers/Node never drop, they defer
        var nargs: usize = 0;
        if (argc > 2) {
            nargs = @intCast(argc - 2);
            if (nargs > 8) {
                _ = qjs.throwTypeError(ctx, "setTimeout accepts at most 8 callback arguments");
                return qjs.JS_EXCEPTION;
            }
        }
        const rt = g_runtime orelse return qjs.JS_UNDEFINED;
        var sig_val: qjs.Value = qjs.JS_UNDEFINED;
        var sig_owned = false;
        if (argc >= 3 and qjs.isObject(argv[2]) != 0) {
            if (fetch_api.getAbortSignalData(ctx, argv[2]) != null) {
                sig_val = argv[2];
            } else {
                const prop = qjs.getPropertyStr(ctx, argv[2], "signal");
                if (fetch_api.getAbortSignalData(ctx, prop) != null) {
                    sig_val = prop;
                    sig_owned = true;
                } else {
                    qjs.freeValue(ctx, prop);
                }
            }
        }
        defer if (sig_owned) qjs.freeValue(ctx, sig_val);

        if (fetch_api.getAbortSignalData(ctx, sig_val)) |sd| {
            if (sd.aborted) {
                if (as_object) {
                    return makeTimeout(ctx, 128) orelse qjs.throwOutOfMemory(ctx);
                }
                return qjs.newInt32(ctx, -1);
            }
        }

        const args_slice: []const qjs.Value = if (nargs > 0) argv[2..][0..nargs] else &.{};
        const id = if (interval)
            rt.timer_manager.setInterval(ctx.?, argv[0], @intCast(ms), args_slice)
        else
            rt.timer_manager.setTimeout(ctx.?, argv[0], @intCast(ms), args_slice);
        const slot = id catch {
            // TypeError, not RangeError: only throwTypeError is verified in-tree.
            _ = qjs.throwTypeError(ctx, "too many timers (max 128)");
            return qjs.JS_EXCEPTION;
        };
        _ = fetch_api.attachTimerToSignal(ctx, sig_val, slot);
        if (as_object) {
            return makeTimeout(ctx, slot) orelse qjs.throwOutOfMemory(ctx);
        }
        return qjs.newInt32(ctx, @intCast(slot));
    }

    fn extractTimeoutId(ctx: ?*qjs.Context, val: qjs.Value) ?usize {
        // Timeout object or bare numeric id (back-compat + worker numerics).
        if (qjs.getOpaque2(ctx, val, timeout_class_id)) |ptr| {
            const slot = slotFromOpaque(ptr) orelse return null;
            return @intCast(slot);
        }
        var id: i32 = 0;
        _ = qjs.toInt32(ctx, &id, val);
        if (id < 0 or id >= 128) return null;
        return @intCast(id);
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

    fn clearCallback(ctx: ?*qjs.Context, argc: c_int, argv: [*c]qjs.Value) void {
        const rt = g_runtime orelse return;
        if (argc < 1) return;
        const id = extractTimeoutId(ctx, argv[0]) orelse return;
        rt.timer_manager.clear(id);
    }

    fn timeoutUnref(ctx: ?*qjs.Context, this_val: qjs.Value, argc: c_int, argv: [*c]qjs.Value) callconv(.c) qjs.Value {
        _ = argc;
        _ = argv;
        const rt = g_runtime orelse return qjs.JS_UNDEFINED;
        const id = timeoutSlotFromThis(ctx, this_val) orelse return qjs.JS_UNDEFINED;
        rt.timer_manager.unrefSlot(id);
        return qjs.dupValue(ctx, this_val);
    }

    fn timeoutRef(ctx: ?*qjs.Context, this_val: qjs.Value, argc: c_int, argv: [*c]qjs.Value) callconv(.c) qjs.Value {
        _ = argc;
        _ = argv;
        const rt = g_runtime orelse return qjs.JS_UNDEFINED;
        const id = timeoutSlotFromThis(ctx, this_val) orelse return qjs.JS_UNDEFINED;
        rt.timer_manager.refSlot(id);
        return qjs.dupValue(ctx, this_val);
    }

    fn timeoutRefresh(ctx: ?*qjs.Context, this_val: qjs.Value, argc: c_int, argv: [*c]qjs.Value) callconv(.c) qjs.Value {
        _ = argc;
        _ = argv;
        const rt = g_runtime orelse return qjs.JS_UNDEFINED;
        const id = timeoutSlotFromThis(ctx, this_val) orelse return qjs.JS_UNDEFINED;
        rt.timer_manager.refreshSlot(id);
        return qjs.dupValue(ctx, this_val);
    }

    fn timeoutHasRef(ctx: ?*qjs.Context, this_val: qjs.Value, argc: c_int, argv: [*c]qjs.Value) callconv(.c) qjs.Value {
        _ = argc;
        _ = argv;
        const rt = g_runtime orelse return qjs.JS_FALSE;
        const id = timeoutSlotFromThis(ctx, this_val) orelse return qjs.JS_FALSE;
        if (id >= 128) return qjs.JS_FALSE;
        return if (rt.timer_manager.isReferenced(id)) qjs.JS_TRUE else qjs.JS_FALSE;
    }

    var perf_origin_ns: i96 = 0;

    fn performanceNow(ctx: ?*qjs.Context, this_val: qjs.Value, argc: c_int, argv: [*c]qjs.Value) callconv(.c) qjs.Value {
        _ = this_val;
        _ = argc;
        _ = argv;
        // Same Io spelling as fs.zig's getIo(); .awake = monotonic
        // (CLOCK_MONOTONIC / UPTIME_RAW), the correct performance.now basis.
        const io = std.Io.Threaded.global_single_threaded.io();
        const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        if (perf_origin_ns == 0) perf_origin_ns = now_ns;
        const ms: f64 = @as(f64, @floatFromInt(now_ns - perf_origin_ns)) / 1e6;
        return qjs.newFloat64(ctx, ms);
    }

    fn setupPerformance(ctx: ?*qjs.Context) void {
        const global = qjs.getGlobalObject(ctx);
        defer qjs.freeValue(ctx, global);
        const perf = qjs.newObject(ctx);
        const now_fn = qjs.newCFunction(ctx, performanceNow, "now", 0);
        _ = qjs.definePropertyValueStr(ctx, perf, "now", now_fn, qjs.PROP_C_W_E);
        _ = qjs.definePropertyValueStr(ctx, global, "performance", perf, qjs.PROP_C_W_E);
    }

    fn microtaskJob(ctx: ?*qjs.Context, argc: c_int, argv: [*c]qjs.Value) callconv(.c) qjs.Value {
        _ = argc;
        const ret = qjs.call(ctx, argv[0], qjs.JS_UNDEFINED, 0, null);
        if (qjs.isException(ret) != 0) {
            // ctx is optional at the ABI boundary; reportUncaught needs a
            // non-null one. QuickJS never hands us null here, but guard so a
            // null can never panic the runtime.
            if (ctx) |jc| microtasks.reportUncaught(jc, "queueMicrotask error");
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
        process_api.deinit(self.ctx);
        self.timer_manager.cancelAll();
        const rt = qjs.getRuntime(self.ctx);
        qjs.freeContext(self.ctx);
        qjs.freeRuntime(rt);
        loop_mod.timer_mgr = null;
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
            reportAndFail(self, qjs.getException(self.ctx));
            return false;
        }
        microtasks.pumpMicrotasks(self.ctx);
        return true;
    }

    // Script-first parse probe: a plain script keeps script semantics
    // (top-level `this`, sloppy mode, globals). Module mode is only tried when
    // script parsing fails — import/export cannot parse as a script. The cost
    // is one extra parse for modules, zero for scripts, and only at startup.
    pub fn evalModule(self: *Runtime, source: []const u8, filename: [:0]const u8) bool {
        const forced_module = std.mem.endsWith(u8, filename, ".mjs");
        var is_module = forced_module;
        var flags: c_int = if (forced_module) qjs.EVAL_TYPE_MODULE else qjs.EVAL_TYPE_GLOBAL;

        var fun = qjs.eval(
            self.ctx,
            source.ptr,
            source.len,
            filename.ptr,
            flags | qjs.EVAL_FLAG_COMPILE_ONLY,
        );

        if (!forced_module and qjs.isException(fun) != 0) {
            qjs.freeValue(self.ctx, fun);
            const script_exc = qjs.getException(self.ctx); // clears current_exception
            flags = qjs.EVAL_TYPE_MODULE;
            fun = qjs.eval(
                self.ctx,
                source.ptr,
                source.len,
                filename.ptr,
                flags | qjs.EVAL_FLAG_COMPILE_ONLY,
            );
            if (qjs.isException(fun) != 0) {
                qjs.freeValue(self.ctx, script_exc);
                reportAndFail(self, qjs.getException(self.ctx));
                return false;
            }
            qjs.freeValue(self.ctx, script_exc);
            is_module = true;
        }

        if (qjs.isException(fun) != 0) {
            reportAndFail(self, qjs.getException(self.ctx));
            return false;
        }

        // JS_EvalFunction takes ownership of `fun` (quickjs.c:38085).
        // Do not free `fun` after this call.
        const result = qjs.evalFunction(self.ctx, fun);
        defer qjs.freeValue(self.ctx, result);

        if (qjs.isException(result) != 0) {
            reportAndFail(self, qjs.getException(self.ctx));
            return false;
        }

        // A module's top-level throw is routed into the module promise rather
        // than into JS_EXCEPTION. Inspect it directly.
        if (is_module) {
            const ps = qjs.promiseState(self.ctx, result);
            if (ps == 2) { // JS_PROMISE_REJECTED
                const pr = qjs.promiseResult(self.ctx, result);
                reportAndFail(self, qjs.dupValue(self.ctx, pr));
                return false;
            }
        }

        microtasks.pumpMicrotasks(self.ctx);
        return true;
    }
};
