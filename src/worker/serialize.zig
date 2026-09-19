const std = @import("std");
const qjs = @import("../engine/quickjs_shim.zig");

const gpa = std.heap.smp_allocator;

/// JSON stringify a JS value into an owned byte buffer.
/// Rejects undefined/functions (JSON.stringify yields undefined for those).
pub fn stringify(ctx: ?*qjs.Context, val: qjs.Value) ![]u8 {
    const json_val = qjs.jsonStringify(ctx, val, qjs.JS_UNDEFINED, qjs.JS_UNDEFINED);
    if (qjs.isException(json_val) != 0) {
        qjs.freeValue(ctx, json_val);
        return error.NotSerializable;
    }
    defer qjs.freeValue(ctx, json_val);
    if (qjs.isUndefined(json_val) != 0) return error.NotSerializable;
    var out_len: usize = 0;
    const ptr = qjs.toCStringLen(ctx, &out_len, json_val) orelse return error.SerializeFailed;
    defer qjs.freeCString(ctx, ptr);
    return gpa.dupe(u8, ptr[0..out_len]) catch return error.OutOfMemory;
}

/// Parse a JSON byte buffer into an owned JS value.
/// (JS_ParseJSON requires buf[buf_len] == '\0', hence the dupeZ.)
pub fn parse(ctx: ?*qjs.Context, json: []const u8) !qjs.Value {
    const z = gpa.dupeZ(u8, json) catch return error.OutOfMemory;
    defer gpa.free(z);
    const val = qjs.parseJSON(ctx, z.ptr, json.len, "<worker-message>");
    if (qjs.isException(val) != 0) {
        qjs.freeValue(ctx, val);
        return error.ParseFailed;
    }
    return val;
}
