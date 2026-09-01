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
// CHANGED: pump modules armed at init so server mode drains completions
const async_fetch = @import("../net/async_fetch.zig");
const ws_client = @import("../net/ws_client.zig");

const DepEntry = struct {
    key: [:0]const u8,
    module: *mod.Module,
};

// DOD-FIX 9: single boot arena; runtime struct + EventLoop + module cache
// live inside it instead of being individually page_allocator-allocated.
var boot_arena: std.heap.ArenaAllocator = undefined;
var boot_inited: bool = false;

pub fn getEventLoop() ?*EventLoop {
    if (g_runtime) |rt| return rt.event_loop else return null;
}

pub fn deinitNetwork() void {
    http_native.deinit();
}

var g_runtime: ?*Runtime = null;

pub const Runtime = struct {
    ctx: *qjs.Context,
    module_cache: *mod.ModuleCache,
    modules_initialized: bool,
    event_loop: *EventLoop,
    timer_manager: TimerManager,

    pub fn init(args: std.process.Args) !*Runtime {
        const rt = qjs.newRuntime() orelse return error.InitFailed;
        qjs.setMaxStackSize(rt, 1024 * 1024);
        qjs.setMemoryLimit(rt, 64 * 1024 * 1024);

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

        const global = qjs.getGlobalObject(ctx);
        defer qjs.freeValue(ctx, global);

        const setTimeout_func = qjs.newCFunction(ctx, setTimeoutCallback, "setTimeout", 2);
        const setInterval_func = qjs.newCFunction(ctx, setIntervalCallback, "setInterval", 2);
        const clearTimeout_func = qjs.newCFunction(ctx, clearTimeoutCallback, "clearTimeout", 1);
        const clearInterval_func = qjs.newCFunction(ctx, clearIntervalCallback, "clearInterval", 1);

        _ = qjs.definePropertyValueStr(ctx, global, "setTimeout", setTimeout_func, qjs.PROP_C_W_E);
        _ = qjs.definePropertyValueStr(ctx, global, "setInterval", setInterval_func, qjs.PROP_C_W_E);
        _ = qjs.definePropertyValueStr(ctx, global, "clearTimeout", clearTimeout_func, qjs.PROP_C_W_E);
        _ = qjs.definePropertyValueStr(ctx, global, "clearInterval", clearInterval_func, qjs.PROP_C_W_E);

        if (!boot_inited) {
            boot_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            boot_inited = true;
        }
        const boot = boot_arena.allocator();

        const loop_ptr = try boot.create(EventLoop);
        EventLoop.initInto(loop_ptr);
        // CHANGED: arm completion pumps before any user code runs so
        // `ff start` (.until_done mode, no polling) drains fetch/ws results.
        // Idempotent; runWithMicrotasks re-arms as needed in file mode.
        async_fetch.setLoop(&loop_ptr.loop);
        ws_client.setLoop(&loop_ptr.loop);
        const cache_ptr = try boot.create(mod.ModuleCache);
        cache_ptr.* = mod.ModuleCache.init(boot);

        const runtime = try boot.create(Runtime);
        runtime.* = .{
            .ctx = ctx,
            .module_cache = cache_ptr,
            .modules_initialized = false,
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

    pub fn deinit(self: *Runtime) void {
        fetch_api.deinitClient();
        self.module_cache.deinit();
        self.timer_manager.cancelAll();
        const rt = qjs.getRuntime(self.ctx);
        qjs.freeContext(self.ctx);
        qjs.freeRuntime(rt);
        // Boot arena is the sole owner of `self`, the EventLoop, and the
        // ModuleCache. Free it LAST so all references stay valid above.
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
        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const scratch = arena_state.allocator();
        defer arena_state.deinit();
        var sources = std.ArrayList(DepEntry).empty;
        sources.ensureTotalCapacity(scratch, 16) catch return false;
        self.collectDeps(scratch, source, filename, &sources) catch return false;
        self.setupModuleRegistry() catch return false;
        std.mem.reverse(DepEntry, sources.items);
        for (sources.items) |s| {
              const wrapped = self.wrapModule(scratch, s.module.source, s.key, s.module) catch continue;
            _ = self.eval(wrapped, s.key);
        }
        var m = mod.Module.init(scratch, source, filename, std.fs.path.dirname(filename) orelse ".");
        defer m.deinit();
        m.parseImports() catch return false;
        m.parseExports() catch return false;
        const wrapped = self.wrapModule(scratch, source, filename, &m) catch return false;
        const result = self.eval(wrapped, filename);
        microtasks.pumpMicrotasks(self.ctx);
        return result;
    }

    fn collectDeps(
        self: *Runtime,
        scratch: std.mem.Allocator,
        source: []const u8,
        filename: [:0]const u8,
        out: *std.ArrayList(DepEntry),
    ) !void {
        const dir = std.fs.path.dirname(filename) orelse ".";
        try out.ensureTotalCapacity(scratch, 16);
        var m = mod.Module.init(scratch, source, filename, dir);
        defer m.deinit();
        m.parseImports() catch return;
        for (m.imports.items) |imp| {
            const resolved = mod.resolveSpec(scratch, dir, m.sliceAt(imp.specifier)) catch continue;
            defer scratch.free(resolved);
            // Cache is StringHashMap keyed by resolved path (DOD-FIX 8 reverted).
            if (self.module_cache.get(resolved) != null) continue;
            const dep_source = mod.readFile(scratch, resolved) catch continue;
            const path_z = scratch.dupeZ(u8, resolved) catch {
                continue;
            };
            const dep_dir = std.fs.path.dirname(path_z) orelse ".";
            var dep = mod.Module.init(scratch, dep_source, path_z, dep_dir);
            dep.parseImports() catch {
                continue;
            };
            dep.parseExports() catch {
                continue;
            };
            const dep_ptr = scratch.create(mod.Module) catch {
                continue;
            };
            dep_ptr.* = dep;
            self.module_cache.put(path_z, dep_ptr) catch {
                dep_ptr.deinit();
                continue;
            };
            const key_z = scratch.dupeZ(u8, dep_ptr.path) catch continue;
            out.append(scratch, .{ .key = key_z, .module = dep_ptr }) catch continue;
            self.collectDeps(scratch, dep_source, path_z, out) catch {};
        }
    }

    fn setupModuleRegistry(self: *Runtime) !void {
        if (self.modules_initialized) return;
        self.modules_initialized = true;
        const global = qjs.getGlobalObject(self.ctx);
        defer qjs.freeValue(self.ctx, global);
        const registry = qjs.newObject(self.ctx);
        _ = qjs.definePropertyValueStr(self.ctx, global, "__modules", registry, qjs.PROP_C_W_E);
    }

    fn wrapModule(
        self: *Runtime,
        scratch: std.mem.Allocator,
        source: []const u8,
        filename: [:0]const u8,
        m: *mod.Module,
    ) ![:0]const u8 {
        _ = self;
        _ = filename;
        _ = m;
        return scratch.dupeZ(u8, source) catch return error.OutOfMemory;
    }
};
