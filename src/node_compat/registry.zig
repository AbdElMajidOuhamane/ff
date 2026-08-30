// Node-compat module registry: builtins + CJS file loader + node_modules via JS resolver.
// DOD: dense comptime builtin table, eval-once caches, zero-alloc cache hits.
const std = @import("std");
const c = @import("../c.zig").c;

const gpa = std.heap.smp_allocator;

const events_src = @embedFile("lib/events.js");
const path_src = @embedFile("lib/path.js");
const querystring_src = @embedFile("lib/querystring.js");
const assert_src = @embedFile("lib/assert.js");
const string_decoder_src = @embedFile("lib/string_decoder.js");
const os_src = @embedFile("lib/os.js");
const buffer_src = @embedFile("lib/buffer.js");
const util_src = @embedFile("lib/util.js");
const tty_src = @embedFile("lib/tty.js");
const stream_src = @embedFile("lib/stream.js");
const net_src = @embedFile("lib/net.js");
const crypto_src = @embedFile("lib/crypto.js");
const http_src = @embedFile("lib/http.js");
const text_encoding_src = @embedFile("lib/text_encoding.js");
const require_js_src = @embedFile("lib/require.js");
const zlib_src = @embedFile("lib/zlib.js");
const url_src = @embedFile("lib/url.js");
const fs_src = @embedFile("lib/fs.js");

const next_tick_src =
    \\if (typeof process.nextTick !== "function") {
    \\  process.nextTick = function (cb, ...args) {
    \\    Promise.resolve().then(() => cb(...args));
    \\  };
    \\}
    \\globalThis.global = globalThis;
    \\if (typeof globalThis.setImmediate !== "function") {
    \\  globalThis.setImmediate = function (cb, ...args) {
    \\    Promise.resolve().then(() => cb(...args));
    \\    return {};
    \\  };
    \\}
    \\if (!process.stderr) process.stderr = {
    \\  isTTY: false,
    \\  write: function (s) { return __stderrWrite(String(s)); }
    \\};
    \\if (typeof Error.captureStackTrace !== "function") {
    \\  Error.stackTraceLimit = 10;
    \\  Error.captureStackTrace = function (obj, ctorOpt) {
    \\    var err = new Error();
    \\    var frames = [];
    \\    var lines = String(err.stack || "").split("\n");
    \\    for (var i = 0; i < lines.length; i++) {
    \\      let m = /^\s*at\s+(.*?)\s+\((.*?):(\d+):(\d+)\)\s*$/.exec(lines[i]);
    \\      let fn, file, ln, col;
    \\      if (m) { fn = m[1]; file = m[2]; ln = +m[3]; col = +m[4]; }
    \\      else {
    \\        m = /^\s*at\s+(.*?):(\d+):(\d+)\s*$/.exec(lines[i]);
    \\        if (!m) continue;
    \\        fn = null; file = m[1]; ln = +m[2]; col = +m[3];
    \\      }
    \\      frames.push({
    \\        getFileName: function () { return file; },
    \\        getLineNumber: function () { return ln; },
    \\        getColumnNumber: function () { return col; },
    \\        getFunctionName: function () { return fn === "<anonymous>" ? null : fn; },
    \\        getTypeName: function () { return null; },
    \\        getMethodName: function () { return null; },
    \\        isEval: function () { return false; },
    \\        getEvalOrigin: function () { return undefined; },
    \\        getThis: function () { return undefined; },
    \\        getFunction: function () { return undefined; },
    \\        isNative: function () { return false; },
    \\        isToplevel: function () { return true; },
    \\        isConstructor: function () { return false; },
    \\        name: null,
    \\        toString: function () { return "at " + (this.getFunctionName() || "<anonymous>") + " (" + this.getFileName() + ":" + this.getLineNumber() + ":" + this.getColumnNumber() + ")"; }
    \\      });
    \\    }
    \\    if (frames.length > 0) frames.shift();
    \\    if (typeof Error.prepareStackTrace === "function") {
    \\      Object.defineProperty(obj, "stack", { configurable: true, enumerable: false, writable: true, value: Error.prepareStackTrace(obj, frames) });
    \\    } else {
    \\      Object.defineProperty(obj, "stack", { configurable: true, enumerable: false, writable: true, value: frames.map(function (f) { return f.toString(); }).join("\n") });
    \\    }
    \\  };
    \\}
;

const NodeModule = struct {
    name: []const u8,
    source: []const u8,
    exports: ?c.Value = null,
    initialized: bool = false,
    global_export: bool = false,
};

var modules = [_]NodeModule{
    .{ .name = "events", .source = events_src },
    .{ .name = "path", .source = path_src },
    .{ .name = "querystring", .source = querystring_src },
    .{ .name = "assert", .source = assert_src },
    .{ .name = "string_decoder", .source = string_decoder_src },
    .{ .name = "os", .source = os_src },
    .{ .name = "buffer", .source = buffer_src, .global_export = true },
    .{ .name = "util", .source = util_src },
    .{ .name = "tty", .source = tty_src },
    .{ .name = "stream", .source = stream_src },
    .{ .name = "net", .source = net_src },
    .{ .name = "crypto", .source = crypto_src },
    .{ .name = "http", .source = http_src },
    .{ .name = "zlib", .source = zlib_src },
    .{ .name = "url", .source = url_src },
    .{ .name = "fs", .source = fs_src },
};

comptime {
    std.debug.assert(modules.len <= 32);
}

var require_func_val: ?c.Value = null;

// File-module cache: absolute path -> module.exports (runtime lifetime).
var file_cache: ?std.StringHashMap(c.Value) = null;

const CJS_PREFIX = "(function (exports, require, module, __filename, __dirname) {\n";
const CJS_SUFFIX = "\n});";

fn getIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

// ── C natives exposed to the JS require layer ───────────────

fn builtinRequireFn(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 1 or c.isString(argv[0]) == 0) return c.JS_UNDEFINED;
    const name_ptr = c.toCString(ctx, argv[0]) orelse return c.JS_EXCEPTION;
    defer c.freeCString(ctx, name_ptr);
    const name = std.mem.span(name_ptr);
    for (&modules) |*m| {
        if (std.mem.eql(u8, m.name, name)) {
            if (!m.initialized) {
                if (!initBuiltinModule(ctx, m, name)) return c.JS_EXCEPTION;
            }
            return c.dupValue(ctx, m.exports.?);
        }
    }
    return c.JS_UNDEFINED; // not a builtin — the JS layer resolves files
}

fn fsExistsFn(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 1 or c.isString(argv[0]) == 0) return c.JS_FALSE;
    const p = c.toCString(ctx, argv[0]) orelse return c.JS_EXCEPTION;
    defer c.freeCString(ctx, p);
    const io = getIo();
    const dir = std.Io.Dir.cwd();
    const found = if (dir.access(io, std.mem.span(p), .{})) true else |_| false;
    return if (found) c.JS_TRUE else c.JS_FALSE;
}

fn fsReadFileFn(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 1 or c.isString(argv[0]) == 0) {
        _ = c.throwTypeError(ctx, "__fsReadFile: path must be a string");
        return c.JS_EXCEPTION;
    }
    const p = c.toCString(ctx, argv[0]) orelse return c.JS_EXCEPTION;
    defer c.freeCString(ctx, p);
    const io = getIo();
    const content = std.Io.Dir.cwd().readFileAlloc(io, std.mem.span(p), gpa, .limited(16 * 1024 * 1024)) catch {
        _ = c.throwTypeError(ctx, "__fsReadFile: cannot read file");
        return c.JS_EXCEPTION;
    };
    defer gpa.free(content);
    return c.newStringLen(ctx, content.ptr, content.len);
}

fn stderrWriteFn(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 1 or c.isString(argv[0]) == 0) return c.JS_FALSE;
    const s = c.toCStringLen2(ctx, null, argv[0], 0) orelse return c.JS_FALSE;
    defer c.freeCString(ctx, s);
    const bytes = std.mem.span(s);
    const written = std.c.write(2, bytes.ptr, bytes.len);
    if (written < 0) return c.JS_FALSE;
    return c.JS_TRUE;
}

// ── CJS file-module evaluation (path-keyed cache) ───────────

fn evalCJSFn(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 3) {
        _ = c.throwTypeError(ctx, "__evalCJS requires (path, source, requireFn)");
        return c.JS_EXCEPTION;
    }
    const path_ptr = c.toCString(ctx, argv[0]) orelse return c.JS_EXCEPTION;
    defer c.freeCString(ctx, path_ptr);
    const path = std.mem.span(path_ptr);

    if (file_cache == null) file_cache = std.StringHashMap(c.Value).init(gpa);
    if (file_cache.?.get(path)) |cached| return c.dupValue(ctx, cached);

    const exports_obj = c.newObject(ctx);
    if (c.isException(exports_obj) != 0) return c.JS_EXCEPTION;
    const module_obj = c.newObject(ctx);
    if (c.isException(module_obj) != 0) {
        c.freeValue(ctx, exports_obj);
        return c.JS_EXCEPTION;
    }

    const exports_arg = c.dupValue(ctx, exports_obj);
    _ = c.definePropertyValueStr(ctx, module_obj, "exports", exports_obj, c.PROP_C_W_E);

    const source = c.toCString(ctx, argv[1]) orelse {
        c.freeValue(ctx, exports_arg);
        c.freeValue(ctx, module_obj);
        return c.JS_EXCEPTION;
    };
    defer c.freeCString(ctx, source);
    const src = std.mem.span(source);

    const wrapped = gpa.allocSentinel(u8, CJS_PREFIX.len + src.len + CJS_SUFFIX.len, 0) catch {
        c.freeValue(ctx, exports_arg);
        c.freeValue(ctx, module_obj);
        return c.JS_EXCEPTION;
    };
    defer gpa.free(wrapped);
    @memcpy(wrapped[0..CJS_PREFIX.len], CJS_PREFIX);
    @memcpy(wrapped[CJS_PREFIX.len..][0..src.len], src);
    @memcpy(wrapped[CJS_PREFIX.len + src.len ..][0..CJS_SUFFIX.len], CJS_SUFFIX);

    const func = c.eval(ctx, wrapped.ptr, wrapped.len, path_ptr, c.EVAL_TYPE_GLOBAL);
    if (c.isException(func) != 0) {
        c.freeValue(ctx, exports_arg);
        c.freeValue(ctx, module_obj);
        return c.JS_EXCEPTION;
    }

    const dirname = std.fs.path.dirname(path) orelse ".";
    const dirname_val = c.newStringLen(ctx, dirname.ptr, dirname.len);
    var call_args = [_]c.Value{ exports_arg, argv[2], module_obj, argv[0], dirname_val };
    const result = c.call(ctx, func, c.JS_UNDEFINED, 5, &call_args);

    const call_failed = c.isException(result) != 0;
    var final: c.Value = c.JS_UNDEFINED;
    var got_final = false;
    if (!call_failed) {
        final = c.getPropertyStr(ctx, module_obj, "exports");
        got_final = c.isException(final) == 0;
        if (!got_final) c.freeValue(ctx, final);
    }

    c.freeValue(ctx, result);
    c.freeValue(ctx, func);
    c.freeValue(ctx, exports_arg);
    c.freeValue(ctx, module_obj);
    c.freeValue(ctx, dirname_val);

    if (call_failed or !got_final) return c.JS_EXCEPTION;

    const key = gpa.dupeZ(u8, path) catch return c.JS_EXCEPTION;
    file_cache.?.put(key, final) catch return c.JS_EXCEPTION;
    return c.dupValue(ctx, final);
}

// ── builtin module evaluation (comptime table) ──────────────

fn initBuiltinModule(ctx: ?*c.Context, m: *NodeModule, name: []const u8) bool {
    m.initialized = true; // circular requires see partial exports (Node-like)

    const exports_obj = c.newObject(ctx);
    if (c.isException(exports_obj) != 0) return false;
    const module_obj = c.newObject(ctx);
    if (c.isException(module_obj) != 0) {
        c.freeValue(ctx, exports_obj);
        return false;
    }

    const exports_arg = c.dupValue(ctx, exports_obj);
        _ = c.definePropertyValueStr(ctx, module_obj, "exports", exports_obj, c.PROP_C_W_E);

    const filename_z = gpa.dupeZ(u8, name) catch {
        c.freeValue(ctx, exports_arg);
        c.freeValue(ctx, module_obj);
        return false;
    };
    defer gpa.free(filename_z);
    const filename_val = c.newStringLen(ctx, filename_z.ptr, filename_z.len);
    const dirname_val = c.newStringLen(ctx, "node:", 5);

    const wrapped = gpa.allocSentinel(u8, CJS_PREFIX.len + m.source.len + CJS_SUFFIX.len, 0) catch {
        c.freeValue(ctx, exports_arg);
        c.freeValue(ctx, module_obj);
        c.freeValue(ctx, filename_val);
        c.freeValue(ctx, dirname_val);
        return false;
    };
    defer gpa.free(wrapped);
    @memcpy(wrapped[0..CJS_PREFIX.len], CJS_PREFIX);
    @memcpy(wrapped[CJS_PREFIX.len..][0..m.source.len], m.source);
    @memcpy(wrapped[CJS_PREFIX.len + m.source.len ..][0..CJS_SUFFIX.len], CJS_SUFFIX);

    const eval_name = gpa.allocSentinel(u8, 5 + name.len, 0) catch {
        c.freeValue(ctx, exports_arg);
        c.freeValue(ctx, module_obj);
        c.freeValue(ctx, filename_val);
        c.freeValue(ctx, dirname_val);
        return false;
    };
    defer gpa.free(eval_name);
    @memcpy(eval_name[0..5], "node:");
    @memcpy(eval_name[5..][0..name.len], name);

    const func = c.eval(ctx, wrapped.ptr, wrapped.len, eval_name.ptr, c.EVAL_TYPE_GLOBAL);
    if (c.isException(func) != 0) {
        c.freeValue(ctx, exports_arg);
        c.freeValue(ctx, module_obj);
        c.freeValue(ctx, filename_val);
        c.freeValue(ctx, dirname_val);
        return false;
    }

    const req_val = require_func_val orelse c.JS_UNDEFINED;
    var call_args = [_]c.Value{ exports_arg, req_val, module_obj, filename_val, dirname_val };
    const result = c.call(ctx, func, c.JS_UNDEFINED, 5, &call_args);

    const call_failed = c.isException(result) != 0;
    var final: c.Value = c.JS_UNDEFINED;
    var got_final = false;
    if (!call_failed) {
        final = c.getPropertyStr(ctx, module_obj, "exports");
        got_final = c.isException(final) == 0;
        if (!got_final) c.freeValue(ctx, final);
    }

    c.freeValue(ctx, result);
    c.freeValue(ctx, func);
    c.freeValue(ctx, exports_arg);
    c.freeValue(ctx, module_obj);
    c.freeValue(ctx, filename_val);
    c.freeValue(ctx, dirname_val);

    if (call_failed or !got_final) return false;
    m.exports = final;
    return true;
}

fn evalGlobalSource(ctx: ?*c.Context, source: []const u8, filename: [:0]const u8) bool {
    const src = gpa.dupeZ(u8, source) catch return false;
    defer gpa.free(src);
    const result = c.eval(ctx, src.ptr, src.len, filename.ptr, c.EVAL_TYPE_GLOBAL);
    defer c.freeValue(ctx, result);
    if (c.isException(result) != 0) {
        const exc = c.getException(ctx);
        defer c.freeValue(ctx, exc);
        const msg = c.toCString(ctx, exc);
        if (msg) |m| {
            defer c.freeCString(ctx, m);
            std.debug.print("node_compat: {s}: {s}\n", .{ filename, m });
        }
        return false;
    }
    return true;
}

pub fn setup(ctx: *c.Context) void {
    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);

    // 1. C natives for the JS require layer
    const builtin_req = c.newCFunction(ctx, builtinRequireFn, "__builtinRequire", 1);
    _ = c.definePropertyValueStr(ctx, global, "__builtinRequire", builtin_req, c.PROP_C_W_E);
    const eval_cjs = c.newCFunction(ctx, evalCJSFn, "__evalCJS", 3);
    _ = c.definePropertyValueStr(ctx, global, "__evalCJS", eval_cjs, c.PROP_C_W_E);
    const fs_exists = c.newCFunction(ctx, fsExistsFn, "__fsExists", 1);
    _ = c.definePropertyValueStr(ctx, global, "__fsExists", fs_exists, c.PROP_C_W_E);
    const fs_read = c.newCFunction(ctx, fsReadFileFn, "__fsReadFile", 1);
    _ = c.definePropertyValueStr(ctx, global, "__fsReadFile", fs_read, c.PROP_C_W_E);
    const stderr_write = c.newCFunction(ctx, stderrWriteFn, "__stderrWrite", 1);
    _ = c.definePropertyValueStr(ctx, global, "__stderrWrite", stderr_write, c.PROP_C_W_E);

    // 2. Globals: TextEncoder/TextDecoder, nextTick, setImmediate, stderr stub, captureStackTrace
    _ = evalGlobalSource(ctx, text_encoding_src, "node:text_encoding");
    _ = evalGlobalSource(ctx, next_tick_src, "node:next_tick");

    // 3. JS require layer (defines globalThis.require — builtins + file resolution)
    _ = evalGlobalSource(ctx, require_js_src, "node:require");

    // 4. Cache the global require for builtin wrapper args
    require_func_val = c.getPropertyStr(ctx, global, "require");
    if (c.isException(require_func_val.?) != 0) require_func_val = null;

    // 5. Pre-initialize global_export modules (Buffer as a global)
    for (&modules) |*m| {
        if (m.global_export and !m.initialized) {
            if (!initBuiltinModule(ctx, m, m.name)) continue;
            const name_z = gpa.dupeZ(u8, m.name) catch continue;
            if (m.exports) |exp| {
                _ = c.definePropertyValueStr(ctx, global, name_z, c.dupValue(ctx, exp), c.PROP_C_W_E);
            }
        }
    }
}
