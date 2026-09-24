const std = @import("std");
const qjs = @import("../engine/quickjs_shim.zig");

const gpa = std.heap.smp_allocator;

// Structured clone over the engine's binary object format
// (JS_WriteObject / JS_ReadObject + REFERENCE, which also covers cyclic
// graphs — same flags quickjs-libc's own os.Worker postMessage uses).
// Same-process pipe transport: both ends run the same engine build, so no
// format-version handshake is needed. message_port.zig is untouched — its
// frames (u32-LE length + u8 type + bytes) are already binary-safe.
// Deliberately NOT enabled: BYTECODE (functions stay uncloneable; hostile
// bytecode on read = memory corruption) and SAB (the engine installs no
// SharedArrayBuffer functions, so SAB values cannot exist yet).
//
// Cloned as-is: objects, arrays, strings, numbers, booleans, null,
// undefined, BigInt, Date, RegExp, boxed primitives, Map, Set, all
// TypedArrays, ArrayBuffer (copied — no transfer yet).
// Rejected with TypeError: functions, WeakMap/WeakSet, Promise, symbols
// outside the registry, getter/setter properties, custom prototypes
// (class instances arrive as plain objects — same as the spec).

const MAX_FRAME: usize = 4 * 1024 * 1024; // mirrors message_port cap

// Marked plain object standing in for an Error (the engine cannot serialize
// JS_CLASS_ERROR). parse() revives it into a real Error. Key is intentionally
// distinctive; a user object with the same shape would revive too (v1,
// same-process — acceptable).
const ERROR_MARKER = "__ff_cloned_error__";

/// Engine-owned view of a serialized value. Safe while the JS buffer is
/// alive; deinit() must run on the same ctx that created it. Used for
/// synchronous postMessage (write completes before deinit).
pub const View = struct {
    ctx: ?*qjs.Context,
    ptr: [*]u8,
    len: usize,

    pub fn slice(self: View) []const u8 {
        return self.ptr[0..self.len];
    }
    pub fn deinit(self: View) void {
        qjs.js_free(self.ctx, self.ptr);
    }
};

/// Serialize into an engine-owned buffer (no Zig gpa copy).
/// On failure a TypeError is left pending — same contract as stringify.
pub fn stringifyView(ctx: ?*qjs.Context, val: qjs.Value) !View {
    var owned: ?qjs.Value = null;
    const src = if (qjs.isError(ctx, val) != 0) blk: {
        owned = errorToPlain(ctx, val) catch return error.NotSerializable;
        break :blk owned.?;
    } else val;
    defer {
        if (owned) |o| qjs.freeValue(ctx, o);
    }

    var out_len: usize = 0;
    const buf = qjs.writeObject(ctx, &out_len, src, qjs.WRITE_OBJ_REFERENCE);
    if (buf == null) {
        rethrowAsCloneError(ctx);
        return error.NotSerializable;
    }
    if (out_len == 0 or out_len > MAX_FRAME) {
        qjs.js_free(ctx, buf);
        return error.FrameTooLarge;
    }
    return .{ .ctx = ctx, .ptr = buf, .len = out_len };
}

/// Serialize a JS value into an owned Zig buffer (cross-thread lifetime,
/// e.g. Worker initial payload). Prefer stringifyView on the hot send path.
pub fn stringify(ctx: ?*qjs.Context, val: qjs.Value) ![]u8 {
    var view = stringifyView(ctx, val) catch |e| return e;
    defer view.deinit();
    return gpa.dupe(u8, view.slice()) catch return error.OutOfMemory;
}

/// Deserialize a binary buffer into an owned JS value. Marked error objects
/// are revived into real Errors (subclass preserved via the global ctor).
pub fn parse(ctx: ?*qjs.Context, blob: []const u8) !qjs.Value {
    if (blob.len == 0) return error.ParseFailed;
    const val = qjs.readObject(ctx, blob.ptr, blob.len, qjs.READ_OBJ_REFERENCE);
    if (qjs.isException(val) != 0) {
        qjs.freeValue(ctx, val);
        return error.ParseFailed;
    }
    if (isMarkedError(ctx, val)) return reviveError(ctx, val);
    return val;
}

fn rethrowAsCloneError(ctx: ?*qjs.Context) void {
    // The writer left a specific TypeError pending ("unsupported object
    // class", "only value properties are supported", ...). Fold it into a
    // browser-style message; keep the detail on stderr.
    const exc = qjs.getException(ctx); // clears the pending slot
    defer qjs.freeValue(ctx, exc);
    const m = qjs.toCString(ctx, exc);
    if (m) |s| {
        defer qjs.freeCString(ctx, s);
        std.debug.print("[worker] value could not be cloned: {s}\n", .{std.mem.span(s)});
    }
    _ = qjs.throwTypeError(ctx, "value could not be cloned");
}

fn errorToPlain(ctx: ?*qjs.Context, err: qjs.Value) !qjs.Value {
    const obj = qjs.newObject(ctx);
    if (qjs.isException(obj) != 0) return error.OutOfMemory;
    errdefer qjs.freeValue(ctx, obj);
    const marker = qjs.newInt32(ctx, 1);
    _ = qjs.definePropertyValueStr(ctx, obj, ERROR_MARKER, marker, qjs.PROP_C_W_E);
    copyStrProp(ctx, err, obj, "name", "Error");
    copyStrProp(ctx, err, obj, "message", "");
    copyStrProp(ctx, err, obj, "stack", "");
    return obj;
}

fn copyStrProp(ctx: ?*qjs.Context, from: qjs.Value, to: qjs.Value, key: [*c]const u8, fallback: []const u8) void {
    const v = qjs.getPropertyStr(ctx, from, key);
    defer qjs.freeValue(ctx, v);
    if (qjs.isException(v) == 0 and qjs.isUndefined(v) == 0) {
        var len: usize = 0;
        const p = qjs.toCStringLen(ctx, &len, v);
        if (p) |s| {
            defer qjs.freeCString(ctx, s);
            const out = qjs.newStringLen(ctx, s, len);
            _ = qjs.definePropertyValueStr(ctx, to, key, out, qjs.PROP_C_W_E);
            return;
        }
    }
    const d = qjs.newStringLen(ctx, fallback.ptr, fallback.len);
    _ = qjs.definePropertyValueStr(ctx, to, key, d, qjs.PROP_C_W_E);
}

fn isMarkedError(ctx: ?*qjs.Context, val: qjs.Value) bool {
    if (qjs.isObject(val) == 0) return false;
    const m = qjs.getPropertyStr(ctx, val, ERROR_MARKER);
    defer qjs.freeValue(ctx, m);
    if (qjs.isException(m) != 0) return false;
    var n: i32 = 0;
    if (qjs.toInt32(ctx, &n, m) != 0) return false;
    return n == 1;
}

fn getStrProp(ctx: ?*qjs.Context, obj: qjs.Value, key: [*c]const u8) ?[]u8 {
    const v = qjs.getPropertyStr(ctx, obj, key);
    defer qjs.freeValue(ctx, v);
    if (qjs.isException(v) != 0 or qjs.isUndefined(v) != 0) return null;
    var len: usize = 0;
    const p = qjs.toCStringLen(ctx, &len, v) orelse return null;
    defer qjs.freeCString(ctx, p);
    return gpa.dupe(u8, p[0..len]) catch null;
}

fn reviveError(ctx: ?*qjs.Context, marked: qjs.Value) qjs.Value {
    defer qjs.freeValue(ctx, marked);
    const msg = getStrProp(ctx, marked, "message");
    defer {
        if (msg) |s| gpa.free(s);
    }
    const name = getStrProp(ctx, marked, "name");
    defer {
        if (name) |s| gpa.free(s);
    }
    const stack = getStrProp(ctx, marked, "stack");
    defer {
        if (stack) |s| gpa.free(s);
    }

    // Preserve subclass (TypeError, RangeError, ...): construct via the
    // global ctor of the same name; fall back to plain Error.
    const global = qjs.getGlobalObject(ctx);
    defer qjs.freeValue(ctx, global);
    const name_z = if (name) |n| gpa.dupeZ(u8, n) catch null else null;
    defer {
        if (name_z) |z| gpa.free(z);
    }
    const name_key: [*c]const u8 = if (name_z) |z| z.ptr else "Error";
    var ctor = qjs.getPropertyStr(ctx, global, name_key);
    if (qjs.isException(ctor) != 0 or qjs.isFunction(ctx, ctor) == 0) {
        qjs.freeValue(ctx, ctor);
        ctor = qjs.getPropertyStr(ctx, global, "Error");
    }
    defer qjs.freeValue(ctx, ctor);

    const msg_val = if (msg) |m| qjs.newStringLen(ctx, m.ptr, m.len) else qjs.JS_UNDEFINED;
    var args = [_]qjs.Value{msg_val};
    var err = qjs.call(ctx, ctor, qjs.JS_UNDEFINED, 1, &args[0]);
    qjs.freeValue(ctx, msg_val);
    if (qjs.isException(err) != 0 or qjs.isError(ctx, err) == 0) {
        // Exotic name resolved to a non-Error ctor: retry as plain Error.
        qjs.freeValue(ctx, err);
        const ector = qjs.getPropertyStr(ctx, global, "Error");
        defer qjs.freeValue(ctx, ector);
        const m2 = if (msg) |m| qjs.newStringLen(ctx, m.ptr, m.len) else qjs.JS_UNDEFINED;
        var args2 = [_]qjs.Value{m2};
        err = qjs.call(ctx, ector, qjs.JS_UNDEFINED, 1, &args2[0]);
        qjs.freeValue(ctx, m2);
        if (qjs.isException(err) != 0) {
            qjs.freeValue(ctx, err);
            return qjs.newError(ctx); // practically unreachable
        }
    }
    if (name) |n| {
        const nv = qjs.newStringLen(ctx, n.ptr, n.len);
        _ = qjs.definePropertyValueStr(ctx, err, "name", nv, qjs.PROP_C_W_E);
    }
    if (stack) |s| {
        // Own-prop shadows the accessor: preserves the origin stack.
        const sv = qjs.newStringLen(ctx, s.ptr, s.len);
        _ = qjs.definePropertyValueStr(ctx, err, "stack", sv, qjs.PROP_C_W_E);
    }
    return err;
}
