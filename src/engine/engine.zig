const std = @import("std");
const c = @import("../c.zig").c;
const mod = @import("../modules/mod.zig");
const EventLoop = @import("../event/loop.zig").EventLoop;
const TimerManager = @import("../event/timers.zig").TimerManager;
const microtasks = @import("../event/microtasks.zig");
const immediates = @import("../event/immediates.zig");
const console_api = @import("../api/console.zig");
const fs_api =@import("../api/fs.zig");
const process_api = @import("../api/process.zig");
const crypto_api=@import("../api/crypto.zig");
const url_api = @import("../api/url.zig");
const fetch_api =@import("../api/fetch.zig");
const structured_api = @import("../api/structured.zig");
const header=@import("../types/headers.zig");
const request= @import("../types/request.zig");
const response= @import("../types/response.zig");
const http = @import("../net/http.zig");
const perf_api = @import("../api/perf.zig");
const base64_api = @import("../api/base64.zig");
const text_api = @import("../api/text.zig");
const buffer_api = @import("../api/buffer.zig");
const abort_api = @import("../api/abort.zig");
const blob_api = @import("../api/blob.zig");
const formdata_api = @import("../api/formdata.zig");
const iterables = @import("../api/iterables.zig");
const streams_api = @import("../api/streams.zig");

const simd = std.simd;


const DepEntry = struct { key: [:0]const u8, src: []const u8 };
const FunctionCallback = *const fn (?*const c.FunctionCallbackInfo) callconv(.c) void;

var g_platform: ?*c.Platform = null;
var g_runtime: ?*Runtime = null;
fn initGlobal() void {
    if (g_platform != null) return;
    _ = c.unsetenv("NODE_OPTIONS");
    _ = c.unsetenv("V8_OPTIONS");
    c.v8__V8__SetFlagsFromString("--turbo-fast-api-calls", 22);
    const nproc: c_int = @intCast(std.Thread.getCpuCount() catch 4);
    g_platform = c.v8__Platform__NewDefaultPlatform(nproc, 1);
    c.v8__V8__InitializePlatform(g_platform);
    c.v8__V8__Initialize();
}
pub fn getEventLoop() ?*EventLoop {
    if (g_runtime) |rt| return rt.event_loop else return null;
}

pub const Runtime = struct {
    isolate: ?*c.Isolate,
    params: c.CreateParams,
    context: ?*c.Context,
    module_cache: mod.ModuleCache,
    modules_initialized: bool,
    event_loop: *EventLoop,
    timer_manager: TimerManager,

    pub fn init(args: std.process.Args) !*Runtime {
        initGlobal();
        var params: c.CreateParams = undefined;
        c.v8__Isolate__CreateParams__CONSTRUCT(&params);
        params.array_buffer_allocator = c.v8__ArrayBuffer__Allocator__NewDefaultAllocator();

        var constraints: c.ResourceConstraints = undefined;
        c.v8__ResourceConstraints__ConfigureDefaultsFromHeapSize(&constraints, 0, 256 * 1024 * 1024);
        params.constraints = constraints;

        const isolate = c.v8__Isolate__New(&params);
        c.v8__Isolate__SetPromiseRejectCallback(isolate, promiseRejectCallback);
        c.v8__Isolate__Enter(isolate);
        var handle_scope: c.HandleScope = undefined;
        c.v8__HandleScope__CONSTRUCT(&handle_scope, isolate);

        const context = c.v8__Context__New(isolate, null, null);
        c.v8__Context__Enter(context);

        console_api.setup(isolate, context);
        fs_api.setup(isolate, context);
        process_api.setup(isolate, context,args);
        crypto_api.setup(isolate, context);
        perf_api.setup(isolate, context);
        base64_api.setup(isolate, context);
        text_api.setup(isolate, context);
        buffer_api.setup(isolate, context);
        url_api.setup(isolate, context);
        abort_api.setup(isolate, context);
        blob_api.setup(isolate, context);
        formdata_api.setup(isolate, context);
        streams_api.setup(isolate, context);
        structured_api.setup(isolate, context);
        fetch_api.setup(isolate, context);
        iterables.setup(isolate, context);

        header.setup(isolate, context);
        request.setup(isolate, context);
        response.setup(isolate, context);
        http.setup(isolate, context);
        const setTimeout_func = c.v8__Function__New__DEFAULT(context, setTimeoutCallback);
        const setInterval_func = c.v8__Function__New__DEFAULT(context, setIntervalCallback);
        const clearTimeout_func = c.v8__Function__New__DEFAULT(context, clearTimeoutCallback);
        const clearInterval_func = c.v8__Function__New__DEFAULT(context, clearIntervalCallback);
        const queueMicrotask_func = c.v8__Function__New__DEFAULT(context, queueMicrotaskCallback);
        const setImmediate_func = c.v8__Function__New__DEFAULT(context, setImmediateCallback);
        const clearImmediate_func = c.v8__Function__New__DEFAULT(context, clearImmediateCallback);
        const global = c.v8__Context__Global(context);
        var out: c.MaybeBool = undefined;
        _ = c.v8__Object__Set(global, context, c.v8__String__NewFromUtf8(isolate, "setTimeout", 0, -1), setTimeout_func, &out);
        _ = c.v8__Object__Set(global, context, c.v8__String__NewFromUtf8(isolate, "setInterval", 0, -1), setInterval_func, &out);
        _ = c.v8__Object__Set(global, context, c.v8__String__NewFromUtf8(isolate, "clearTimeout", 0, -1), clearTimeout_func, &out);
        _ = c.v8__Object__Set(global, context, c.v8__String__NewFromUtf8(isolate, "clearInterval", 0, -1), clearInterval_func, &out);
        _ = c.v8__Object__Set(global, context, c.v8__String__NewFromUtf8(isolate, "queueMicrotask", 0, -1), queueMicrotask_func, &out);
        _ = c.v8__Object__Set(global, context, c.v8__String__NewFromUtf8(isolate, "setImmediate", 0, -1), setImmediate_func, &out);
        _ = c.v8__Object__Set(global, context, c.v8__String__NewFromUtf8(isolate, "clearImmediate", 0, -1), clearImmediate_func, &out);

        const loop_ptr = try EventLoop.initHeap(std.heap.page_allocator);

        const runtime = try std.heap.page_allocator.create(Runtime);
        runtime.* = .{
            .isolate = isolate,
            .params = params,
            .context = context,
            .module_cache = mod.ModuleCache.init(std.heap.page_allocator),
            .modules_initialized = false,
            .event_loop = loop_ptr,
            .timer_manager = TimerManager.init(&loop_ptr.loop),
        };
        g_runtime = runtime;
        fetch_api.setTimerManager(&runtime.timer_manager);
        immediates.init();
        return runtime;
    }

    fn scheduleCallback(info: ?*const c.FunctionCallbackInfo, interval: bool) void {
        const rt = g_runtime orelse return;
        const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
        const argc = c.v8__FunctionCallbackInfo__Length(info);
        if (argc < 2) return;
        const fn_val = c.v8__FunctionCallbackInfo__INDEX(info, 0);
        const ms_val = c.v8__FunctionCallbackInfo__INDEX(info, 1);
        const context = c.v8__Isolate__GetCurrentContext(isolate);
        var maybe: c.MaybeF64 = undefined;
        c.v8__Value__NumberValue(ms_val, context, &maybe);
        if (!maybe.has_value) return;
        const ms: u64 = @intFromFloat(maybe.value);

        // setTimeout(fn, 0) joins the in-process immediate queue (no kernel
        // timer); setInterval and positive-delay setTimeout stay on xev timers.
        const id: usize = if (interval) blk: {
            break :blk rt.timer_manager.setInterval(isolate, fn_val, ms) catch return;
        } else if (ms > 0) blk: {
            break :blk rt.timer_manager.setTimeout(isolate, fn_val, ms) catch return;
        } else immediates.set(isolate, fn_val) catch return;

        var retval: c.ReturnValue = undefined;
        c.v8__FunctionCallbackInfo__GetReturnValue(info, &retval);
        const num = c.v8__Number__New(isolate, @floatFromInt(@as(i64, @intCast(id))));
        c.v8__ReturnValue__Set(retval, @ptrCast(num));
    }

    fn clearCallback(info: ?*const c.FunctionCallbackInfo) void {
        const rt = g_runtime orelse return;
        const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
        if (c.v8__FunctionCallbackInfo__Length(info) < 1) return;
        const id_val = c.v8__FunctionCallbackInfo__INDEX(info, 0) orelse return;
        const context = c.v8__Isolate__GetCurrentContext(isolate);
        var maybe: c.MaybeI32 = undefined;
        c.v8__Value__Int32Value(id_val, context, &maybe);
        if (!maybe.has_value or maybe.value < 0) return;
        // Immediate ids live at ID_OFFSET.., timer ids below; ranges are
        // disjoint so every clear* routes to the right manager.
        if (maybe.value >= immediates.ID_OFFSET) {
            immediates.clear(@intCast(maybe.value));
        } else {
            rt.timer_manager.clear(@intCast(maybe.value));
        }
    }

    fn setTimeoutCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
        scheduleCallback(info, false);
    }
    fn setIntervalCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
        scheduleCallback(info, true);
    }
    fn clearTimeoutCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
        clearCallback(info);
    }
    fn clearIntervalCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
        clearCallback(info);
    }

    // clearImmediate(id): drop a queued immediate (or a 0ms timeout id)
    fn clearImmediateCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
        clearCallback(info);
    }

    // setImmediate(fn): in-process queue, flushed on the next tick
    fn setImmediateCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
        const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
        if (c.v8__FunctionCallbackInfo__Length(info) < 1) return;
        const fn_val = c.v8__FunctionCallbackInfo__INDEX(info, 0);
        if (!c.v8__Value__IsFunction(fn_val)) return;
        const id = immediates.set(isolate, fn_val) catch return;
        var retval: c.ReturnValue = undefined;
        c.v8__FunctionCallbackInfo__GetReturnValue(info, &retval);
        const num = c.v8__Number__New(isolate, @floatFromInt(@as(i64, @intCast(id))));
        c.v8__ReturnValue__Set(retval, @ptrCast(num));
    }

    // queueMicrotask(fn): enqueue into V8's microtask queue
    fn queueMicrotaskCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
        const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
        if (c.v8__FunctionCallbackInfo__Length(info) < 1) return;
        const val = c.v8__FunctionCallbackInfo__INDEX(info, 0);
        if (!c.v8__Value__IsFunction(val)) return;
        c.v8__Isolate__EnqueueMicrotaskFunc(isolate, @ptrCast(val));
    }

    // Unhandled promise rejection reporting
    fn promiseRejectCallback(msg: c.PromiseRejectMessage) callconv(.c) void {
        if (c.v8__PromiseRejectMessage__GetEvent(&msg) != c.kPromiseRejectWithNoHandler) return;
        const isolate = c.v8__Isolate__GetCurrent();
        if (isolate == null) return;
        const val = c.v8__PromiseRejectMessage__GetValue(&msg);
        if (val == null) return;
        var handle_scope: c.HandleScope = undefined;
        c.v8__HandleScope__CONSTRUCT(&handle_scope, isolate);
        defer c.v8__HandleScope__DESTRUCT(&handle_scope);
        const context = c.v8__Isolate__GetCurrentContext(isolate);
        const err_str = c.v8__Value__ToString(val, context);
        if (err_str == null) return;
        const utf8_len = c.v8__String__Utf8Length(err_str, isolate);
        var buf: [4096]u8 = undefined;
        const len = @min(@as(usize, @intCast(utf8_len)), buf.len);
        _ = c.v8__String__WriteUtf8(err_str, isolate, &buf, @intCast(len), 0);
        std.debug.print("Unhandled promise rejection: {s}\n", .{buf[0..len]});
    }

    pub fn deinit(self: *Runtime) void {
        fetch_api.deinitClient();
        self.module_cache.deinit();
        self.timer_manager.cancelAll();
        immediates.cancelAll();
        c.v8__Context__Exit(self.context);
        c.v8__Isolate__Exit(self.isolate);
        c.v8__Isolate__Dispose(self.isolate);
        c.v8__ArrayBuffer__Allocator__DELETE(self.params.array_buffer_allocator);
    }

    pub fn eval(self: *Runtime, source: [:0]const u8, filename: [:0]const u8) bool {
        var handle_scope: c.HandleScope = undefined;
        c.v8__HandleScope__CONSTRUCT(&handle_scope, self.isolate);
        defer c.v8__HandleScope__DESTRUCT(&handle_scope);
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
        microtasks.pumpMicrotasks(self.isolate);
        return true;
    }

    pub fn evalModule(self: *Runtime, source: []const u8, filename: [:0]const u8) bool {
        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const allocator = arena_state.allocator();
        defer arena_state.deinit();

        var sources = std.ArrayList(DepEntry).empty;
        sources.ensureTotalCapacity(allocator, 16) catch return false;

        self.collectDeps(allocator, source, filename, &sources) catch return false;

        self.setupModuleRegistry() catch return false;

        std.mem.reverse(DepEntry, sources.items);

        for (sources.items) |s| {
            var m = mod.Module.init(allocator, s.src, s.key, ".");
            m.parseImports() catch continue;
            m.parseExports() catch continue;
            const wrapped = self.wrapModule(s.src, s.key, &m) catch continue;
            defer std.heap.page_allocator.free(wrapped);
            _ = self.eval(wrapped, s.key);
            m.deinit();
        }

        var m = mod.Module.init(allocator, source, filename, std.fs.path.dirname(filename) orelse ".");
        defer m.deinit();
        m.parseImports() catch return false;
        m.parseExports() catch return false;
        const wrapped = self.wrapModule(source, filename, &m) catch return false;
        defer std.heap.page_allocator.free(wrapped);
        const result = self.eval(wrapped, filename);
        microtasks.pumpMicrotasks(self.isolate);
        return result;
    }

    fn collectDeps(
        self: *Runtime,
        allocator: std.mem.Allocator,
        source: []const u8,
        filename: [:0]const u8,
        out: *std.ArrayList(DepEntry),
    ) !void {
        const dir = std.fs.path.dirname(filename) orelse ".";
        try out.ensureTotalCapacity(allocator, 16);
        var m = mod.Module.init(allocator, source, filename, dir);
        defer m.deinit();
        m.parseImports() catch return;

        for (m.imports.items) |imp| {
            const resolved = mod.resolveSpec(allocator, dir, imp.specifier) catch continue;
            defer allocator.free(resolved);
            if (self.module_cache.get(resolved) != null) continue;
            const dep_source = mod.readFile(allocator, resolved) catch continue;
            const dep_dir = std.fs.path.dirname(resolved) orelse ".";
            var dep = mod.Module.init(allocator, dep_source, resolved, dep_dir);
            dep.parseImports() catch {
                allocator.free(dep_source);
                continue;
            };
            dep.parseExports() catch {
                allocator.free(dep_source);
                continue;
            };
            const dep_ptr = allocator.create(mod.Module) catch {
                allocator.free(dep_source);
                continue;
            };
            dep_ptr.* = dep;
            self.module_cache.put(resolved, dep_ptr) catch {
                allocator.free(dep_source);
                continue;
            };

            const key_z = allocator.dupeZ(u8, imp.specifier) catch continue;
            const src_z = allocator.dupe(u8, dep_source) catch {
                allocator.free(key_z);
                continue;
            };
            try out.append(allocator, .{ .key = key_z, .src = src_z });

            const resolved_z = allocator.dupeZ(u8, resolved) catch continue;
            self.collectDeps(allocator, dep_source, resolved_z, out) catch {
                allocator.free(resolved_z);
                continue;
            };
            allocator.free(resolved_z);
        }
    }

    fn evalModuleKey(self: *Runtime, source: []const u8, filename: [:0]const u8, registry_key: [:0]const u8) bool {
        const dir = std.fs.path.dirname(filename) orelse ".";
        var m = mod.Module.init(std.heap.page_allocator, source, filename, dir);
        defer m.deinit();
        m.parseImports() catch return false;
        m.parseExports() catch return false;

        self.setupModuleRegistry() catch return false;

        var dep_keys = std.ArrayList([:0]const u8).empty;
        dep_keys.ensureTotalCapacity(std.heap.page_allocator, 16) catch return false;
        defer {
            for (dep_keys.items) |k| std.heap.page_allocator.free(k);
            dep_keys.deinit(std.heap.page_allocator);
        }

        for (m.imports.items) |imp| {
            const resolved = mod.resolveSpec(std.heap.page_allocator, dir, imp.specifier) catch continue;
            defer std.heap.page_allocator.free(resolved);
            if (self.module_cache.get(resolved) == null) {
                const dep_source = mod.readFile(std.heap.page_allocator, resolved) catch continue;
                const dep_dir = std.fs.path.dirname(resolved) orelse ".";
                var dep = mod.Module.init(std.heap.page_allocator, dep_source, resolved, dep_dir);
                dep.parseImports() catch {
                    std.heap.page_allocator.free(dep_source);
                    continue;
                };
                dep.parseExports() catch {
                    std.heap.page_allocator.free(dep_source);
                    continue;
                };
                const dep_ptr = std.heap.page_allocator.create(mod.Module) catch {
                    std.heap.page_allocator.free(dep_source);
                    continue;
                };
                dep_ptr.* = dep;
                self.module_cache.put(resolved, dep_ptr) catch {
                    std.heap.page_allocator.free(dep_source);
                    continue;
                };

                const dep_z = std.heap.page_allocator.dupeZ(u8, resolved) catch continue;
                defer std.heap.page_allocator.free(dep_z);
                const key_z = std.heap.page_allocator.dupeZ(u8, imp.specifier) catch continue;
                dep_keys.append(std.heap.page_allocator, key_z) catch continue;

                _ = self.evalModuleKey(dep_source, dep_z, key_z);
            } else {
                const key_z = std.heap.page_allocator.dupeZ(u8, imp.specifier) catch continue;
                dep_keys.append(std.heap.page_allocator, key_z) catch continue;
            }
        }

        const wrapped = self.wrapModule(source, registry_key, &m) catch return false;
        defer std.heap.page_allocator.free(wrapped);
        return self.eval(wrapped, filename);
    }

    fn setupModuleRegistry(self: *Runtime) !void {
        if (self.modules_initialized) return;
        self.modules_initialized = true;
        var handle_scope: c.HandleScope = undefined;
        c.v8__HandleScope__CONSTRUCT(&handle_scope, self.isolate);
        defer c.v8__HandleScope__DESTRUCT(&handle_scope);
        const global = c.v8__Context__Global(self.context);
        const registry = c.v8__Object__New(self.isolate);
        const key = c.v8__String__NewFromUtf8(self.isolate, "__modules", 0, -1);
        var out: c.MaybeBool = undefined;
        c.v8__Object__Set(global, self.context, key, registry, &out);
    }

const LineKind = enum { import_statement, export_default, export_statement, body };

// Comptime-padded literal prefix as a vector. Pad lanes are never inspected —
// only the first lit.len lanes are compared.
fn packedPrefix(comptime n: usize, comptime lit: []const u8) @Vector(n, u8) {
    const arr: [n]u8 = comptime blk: {
        var a: [n]u8 = [_]u8{0x00} ** n;
        @memcpy(a[0..lit.len], lit);
        break :blk a;
    };
    return arr;
}

// Single vector compare of a literal prefix starting at lane 0. Masked to the
// first lit.len lanes via @bitCast -> integer mask (TigerBeetle style); the
// pad lanes are masked off so they never affect the match.
fn vecHasPrefix(comptime n: usize, v: @Vector(n, u8), comptime lit: []const u8) bool {
    const M = std.meta.Int(.unsigned, n);
    const raw: M = @bitCast(v == packedPrefix(n, lit));
    const m: M = (@as(M, 1) << @intCast(lit.len)) - 1;
    return (raw & m) == m;
}

// Vectorized line-kind classifier: full-vector path for lines wide enough to
// hold a literal, scalar startsWith fallback for ragged/short lines.
fn classifyLineStart(trimmed: []const u8) LineKind {
    const N = simd.suggestVectorLength(u8) orelse 16;
    if (trimmed.len >= N) {
        const v: @Vector(N, u8) = trimmed[0..N].*;
        if (vecHasPrefix(N, v, "import ")) return .import_statement;
        if (vecHasPrefix(N, v, "export default ")) return .export_default;
        if (vecHasPrefix(N, v, "export ")) return .export_statement;
    }
    if (std.mem.startsWith(u8, trimmed, "import ")) return .import_statement;
    if (std.mem.startsWith(u8, trimmed, "export default ")) return .export_default;
    if (std.mem.startsWith(u8, trimmed, "export ")) return .export_statement;
    return .body;
}

// Vectorized leading-' ' / '\t' count: per-chunk lane mask -> @bitCast integer
// bitset, first clear lane is the trim width; scalar tail for leftover bytes.
fn trimStartWidth(line: []const u8) usize {
    const N = simd.suggestVectorLength(u8) orelse 16;
    const V = @Vector(N, u8);
    const M = std.meta.Int(.unsigned, N);
    const spl_space: V = @splat(' ');
    const spl_tab: V = @splat('\t');
    var i: usize = 0;
    const tail = line.len % N;
    const main_end = line.len - tail;
    while (i < main_end) : (i += N) {
        const v: V = line[i..][0..N].*;
        const ws: M = @bitCast((v == spl_space) | (v == spl_tab));
        if (ws != ~@as(M, 0)) return i + @ctz(~ws);
    }
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return i;
}

fn wrapModule(self: *Runtime, source: []const u8, registry_key: [:0]const u8, m: *mod.Module) ![:0]const u8 {
    _ = self;
    const gpa = std.heap.page_allocator;
    var buf = std.ArrayList(u8).empty;
    try buf.appendSlice(gpa, "(function (__modules) {\n");
    try buf.appendSlice(gpa, "var __exports = {};\n");
    for (m.imports.items) |imp| {
        try buf.appendSlice(gpa, "var ");
        try buf.appendSlice(gpa, imp.local_name);
        switch (imp.import_type) {
            .namespace => {
                try buf.appendSlice(gpa, " = (__modules['");
                try buf.appendSlice(gpa, imp.specifier);
                try buf.appendSlice(gpa, "'] || {});\n");
            },
            .default => {
                try buf.appendSlice(gpa, " = (__modules['");
                try buf.appendSlice(gpa, imp.specifier);
                try buf.appendSlice(gpa, "'] || {}).default;\n");
            },
            .named => {
                try buf.appendSlice(gpa, " = (__modules['");
                try buf.appendSlice(gpa, imp.specifier);
                try buf.appendSlice(gpa, "'] || {}).");
                try buf.appendSlice(gpa, imp.export_name);
                try buf.appendSlice(gpa, ";\n");
            },
        }
    }
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const off = trimStartWidth(line);
        switch (classifyLineStart(line[off..])) {
            .import_statement, .export_default => continue,
            .export_statement => {
                try buf.appendSlice(gpa, line[0..off]);
                try buf.appendSlice(gpa, line[off + 7 ..]);
                try buf.append(gpa, '\n');
            },
            .body => {
                try buf.appendSlice(gpa, line);
                try buf.append(gpa, '\n');
            },
        }
    }
    for (m.exports.items) |exp| {
        if (exp.export_type == .named) {
            try buf.appendSlice(gpa, "__exports['");
            try buf.appendSlice(gpa, exp.name);
            try buf.appendSlice(gpa, "'] = ");
            try buf.appendSlice(gpa, exp.local_name);
            try buf.appendSlice(gpa, ";\n");
        } else if (exp.export_type == .default) {
            try buf.appendSlice(gpa, "__exports['");
            try buf.appendSlice(gpa, exp.name);
            try buf.appendSlice(gpa, "'] = ");
            try buf.appendSlice(gpa, exp.local_name);
            try buf.appendSlice(gpa, ";\n");
        }
    }
    try buf.appendSlice(gpa, "__modules['");
    try buf.appendSlice(gpa, registry_key);
    try buf.appendSlice(gpa, "'] = __exports;\n");
    try buf.appendSlice(gpa, "})(__modules);\n");
    return try buf.toOwnedSliceSentinel(gpa, 0);
}
};
