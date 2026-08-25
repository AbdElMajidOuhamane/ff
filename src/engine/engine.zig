const std = @import("std");
const c = @import("../c.zig").c;
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
const simd = std.simd;
// Dependency work item: registry key plus a handle to the already-parsed,
// cache-owned Module. No duplicate source copy, no second parse pass.
const DepEntry = struct {
    key: [:0]const u8,
    module: *mod.Module,
};
const FunctionCallback = *const fn (?*const c.FunctionCallbackInfo) callconv(.c) void;
var g_platform: ?*c.Platform = null;
var g_runtime: ?*Runtime = null;
fn initGlobal() void {
    if (g_platform != null) return;
    _ = c.unsetenv("NODE_OPTIONS");
    _ = c.unsetenv("V8_OPTIONS");
    const v8_flags = "--turbo-fast-api-calls";
    c.v8__V8__SetFlagsFromString(v8_flags, @intCast(v8_flags.len));
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
        c.v8__Isolate__Enter(isolate);
        var handle_scope: c.HandleScope = undefined;
        c.v8__HandleScope__CONSTRUCT(&handle_scope, isolate);
        const context = c.v8__Context__New(isolate, null, null);
        c.v8__Context__Enter(context);
        console_api.setup(isolate, context);
        fs_api.setup(isolate, context);
        process_api.setup(isolate, context, args);
        crypto_api.setup(isolate, context);
        url_api.setup(isolate, context);
        fetch_api.setup(isolate, context);
        header.setup(isolate, context);
        request.setup(isolate, context);
        response.setup(isolate, context);
        http.setup(isolate, context);
        websocket_client.setup(isolate, context);
        const setTimeout_func = c.v8__Function__New__DEFAULT(context, setTimeoutCallback);
        const setInterval_func = c.v8__Function__New__DEFAULT(context, setIntervalCallback);
        const clearTimeout_func = c.v8__Function__New__DEFAULT(context, clearTimeoutCallback);
        const clearInterval_func = c.v8__Function__New__DEFAULT(context, clearIntervalCallback);
        const global = c.v8__Context__Global(context);
        var out: c.MaybeBool = undefined;
        _ = c.v8__Object__Set(global, context, c.v8__String__NewFromUtf8(isolate, "setTimeout", 0, -1), setTimeout_func, &out);
        _ = c.v8__Object__Set(global, context, c.v8__String__NewFromUtf8(isolate, "setInterval", 0, -1), setInterval_func, &out);
        _ = c.v8__Object__Set(global, context, c.v8__String__NewFromUtf8(isolate, "clearTimeout", 0, -1), clearTimeout_func, &out);
        _ = c.v8__Object__Set(global, context, c.v8__String__NewFromUtf8(isolate, "clearInterval", 0, -1), clearInterval_func, &out);
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
        const result = if (interval)
            rt.timer_manager.setInterval(isolate, fn_val, ms)
        else
            rt.timer_manager.setTimeout(isolate, fn_val, ms);
        const id = result catch return;
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
        rt.timer_manager.clear(@intCast(maybe.value));
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
    pub fn deinit(self: *Runtime) void {
        fetch_api.deinitClient();
        self.module_cache.deinit();
        self.timer_manager.cancelAll();
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
    // Batch pipeline: collect the full dependency graph once (parse each
    // module exactly once, cache it), then evaluate all wrappers in reverse
    // dependency order reusing the cached parse results.
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
        microtasks.pumpMicrotasks(self.isolate);
        return result;
    }
    // Scratch allocator is used only for per-call transient state. Cached
    // modules (source text, parsed Import/Export lists, Module structs) are
    // allocated from page_allocator because module_cache outlives this call.
    // Cache map keys are persistent zero-resolved paths for the same reason.
    fn collectDeps(
        self: *Runtime,
        scratch: std.mem.Allocator,
        source: []const u8,
        filename: [:0]const u8,
        out: *std.ArrayList(DepEntry),
    ) !void {
        const persist = std.heap.page_allocator;
        const dir = std.fs.path.dirname(filename) orelse ".";
        try out.ensureTotalCapacity(scratch, 16);
        var m = mod.Module.init(scratch, source, filename, dir);
        defer m.deinit();
        m.parseImports() catch return;
        for (m.imports.items) |imp| {
            const resolved = mod.resolveSpec(scratch, dir, imp.specifier) catch continue;
            defer scratch.free(resolved);
            if (self.module_cache.get(resolved) != null) continue;
            const dep_source = mod.readFile(persist, resolved) catch continue;
            const path_z = persist.dupeZ(u8, resolved) catch {
                persist.free(dep_source);
                continue;
            };
            const dep_dir = std.fs.path.dirname(path_z) orelse ".";
            var dep = mod.Module.init(persist, dep_source, path_z, dep_dir);
            dep.parseImports() catch {
                persist.free(dep_source);
                persist.free(path_z);
                continue;
            };
            dep.parseExports() catch {
                persist.free(dep_source);
                persist.free(path_z);
                continue;
            };
            const dep_ptr = persist.create(mod.Module) catch {
                persist.free(dep_source);
                persist.free(path_z);
                continue;
            };
            dep_ptr.* = dep;
            self.module_cache.put(path_z, dep_ptr) catch {
                dep_ptr.deinit();
                persist.destroy(dep_ptr);
                persist.free(dep_source);
                persist.free(path_z);
                continue;
            };
            const key_z = scratch.dupeZ(u8, imp.specifier) catch continue;
            out.append(scratch, .{ .key = key_z, .module = dep_ptr }) catch continue;
            self.collectDeps(scratch, dep_source, path_z, out) catch {};
        }
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
    // Vectorized line-kind classifier: full-vector path decides every line
    // wide enough to hold a literal; scalar startsWith fallback runs only
    // for short lines.
    fn classifyLineStart(trimmed: []const u8) LineKind {
        const N = simd.suggestVectorLength(u8) orelse 16;
        if (trimmed.len >= N) {
            const v: @Vector(N, u8) = trimmed[0..N].*;
            if (vecHasPrefix(N, v, "import ")) return .import_statement;
            if (vecHasPrefix(N, v, "export default ")) return .export_default;
            if (vecHasPrefix(N, v, "export ")) return .export_statement;
            return .body;
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
    fn wrapModule(self: *Runtime, gpa: std.mem.Allocator, source: []const u8, registry_key: [:0]const u8, m: *mod.Module) ![:0]const u8 {
        _ = self;
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(gpa);
        // Preallocate: worst case is source passthrough plus import/export
        // boilerplate; typical modules never realloc after this.
        try buf.ensureTotalCapacity(gpa, source.len + source.len / 8 + 512);
        try buf.appendSlice(gpa, "(function (__modules) {\n" ++
            "var __exports = {};\n");
        for (m.imports.items) |imp| {
            try buf.appendSlice(gpa, "var ");
            try buf.appendSlice(gpa, imp.local_name);
            try buf.appendSlice(gpa, " = (__modules['");
            try buf.appendSlice(gpa, imp.specifier);
            switch (imp.import_type) {
                .namespace => try buf.appendSlice(gpa, "'] || {});\n"),
                .default => try buf.appendSlice(gpa, "'] || {}).default;\n"),
                .named => {
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
            try buf.appendSlice(gpa, "__exports['");
            try buf.appendSlice(gpa, exp.name);
            try buf.appendSlice(gpa, "'] = ");
            try buf.appendSlice(gpa, exp.local_name);
            try buf.appendSlice(gpa, ";\n");
        }
        try buf.appendSlice(gpa, "__modules['");
        try buf.appendSlice(gpa, registry_key);
        try buf.appendSlice(gpa, "'] = __exports;\n})(__modules);\n");
        return try buf.toOwnedSliceSentinel(gpa, 0);
    }
};
