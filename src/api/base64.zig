const std = @import("std");
const c = @import("../c.zig").c;

const b64 = std.base64.standard;

// ---- data plane: transforms (free functions, primitive args, no self) ----

fn b64_encoded_byte_count(source_byte_count: usize) usize {
    std.debug.assert(source_byte_count < std.math.maxInt(usize) - 2);
    return b64.Encoder.calcSize(source_byte_count);
}

fn b64_encode(source: []const u8, target: []u8) usize {
    const target_byte_count = b64.Encoder.calcSize(source.len);
    std.debug.assert(target.len == target_byte_count);
    std.debug.assert(target_byte_count % 4 == 0);
    _ = b64.Encoder.encode(target, source);
    return target_byte_count;
}

fn b64_decoded_byte_count(source: []const u8) ?usize {
    std.debug.assert(source.len == 0 or source.len % 4 != 1);
    return b64.Decoder.calcSizeForSlice(source) catch null;
}

fn b64_decode(source: []const u8, target: []u8) ?usize {
    const target_byte_count = b64_decoded_byte_count(source) orelse return null;
    std.debug.assert(target.len == target_byte_count);
    b64.Decoder.decode(target, source) catch return null;
    return target_byte_count;
}

// ---- control plane: helpers ----

fn throwTypeError(isolate: ?*c.Isolate, msg: []const u8) void {
    const v8_msg = c.v8__String__NewFromUtf8(isolate, @ptrCast(msg.ptr), 0, @intCast(msg.len));
    _ = c.v8__Isolate__ThrowException(isolate, c.v8__Exception__TypeError(v8_msg));
}

// THE ONLY allocations here are V8-managed ArrayBuffers (GC'd) — zero native allocs.
const Backed = struct { data: [*]u8, byte_count: usize };

fn newBacked(isolate: ?*c.Isolate, byte_count: usize) ?Backed {
    const ab = c.v8__ArrayBuffer__New(isolate, byte_count);
    var store = c.v8__ArrayBuffer__GetBackingStore(ab);
    const backing = c.std__shared_ptr__v8__BackingStore__get(&store) orelse return null;
    const dest = c.v8__BackingStore__Data(backing) orelse return null;
    return .{ .data = @ptrCast(dest), .byte_count = byte_count };
}

fn setReturn(info: ?*const c.FunctionCallbackInfo, val: ?*const c.Value) void {
    var retval: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &retval);
    c.v8__ReturnValue__Set(retval, @ptrCast(val));
}

fn stringBytes(isolate: ?*c.Isolate, str: *const c.String, unit_count: usize) ?[]u8 {
    const backed = newBacked(isolate, unit_count) orelse return null;
    c.v8__String__WriteOneByte(str, isolate, 0, @intCast(unit_count), backed.data);
    return backed.data[0..unit_count];
}

fn btoaCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const val = c.v8__FunctionCallbackInfo__INDEX(info, 0) orelse return;
    if (!c.v8__Value__IsString(val)) return;
    const str = @as(*const c.String, @ptrCast(val));

    if (!c.v8__String__ContainsOnlyOneByte(str)) {
        throwTypeError(isolate, "btoa: string contains characters outside Latin-1");
        return;
    }
    const unit_count: usize = @intCast(c.v8__String__Length(str));
    if (unit_count == 0) {
        setReturn(info, @ptrCast(c.v8__String__NewFromUtf8(isolate, "", 0, 0)));
        return;
    }
    std.debug.assert(unit_count <= std.math.maxInt(u32));

    const bytes = stringBytes(isolate, str, unit_count) orelse return;
    const target_len = b64_encoded_byte_count(unit_count);
    const encoded = newBacked(isolate, target_len) orelse return;
    const bytes_written = b64_encode(bytes, encoded.data[0..target_len]);
    std.debug.assert(bytes_written == target_len);

    const out = c.v8__String__NewFromUtf8(isolate, @ptrCast(encoded.data), 0, @intCast(target_len));
    setReturn(info, @ptrCast(out));
}

fn atobCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const val = c.v8__FunctionCallbackInfo__INDEX(info, 0) orelse return;
    if (!c.v8__Value__IsString(val)) return;
    const str = @as(*const c.String, @ptrCast(val));
    const unit_count: usize = @intCast(c.v8__String__Length(str));
    if (unit_count == 0) {
        setReturn(info, @ptrCast(c.v8__String__NewFromOneByte(isolate, "", 0, 0)));
        return;
    }
    std.debug.assert(unit_count <= std.math.maxInt(u32));

    const bytes = stringBytes(isolate, str, unit_count) orelse return;
    const decoded_len = b64_decoded_byte_count(bytes) orelse {
        throwTypeError(isolate, "atob: invalid base64");
        return;
    };
    const decoded = newBacked(isolate, decoded_len) orelse return;
    const bytes_written = b64_decode(bytes, decoded.data[0..decoded_len]) orelse {
        throwTypeError(isolate, "atob: invalid base64");
        return;
    };
    std.debug.assert(bytes_written == decoded_len);

    const out = c.v8__String__NewFromOneByte(isolate, @ptrCast(decoded.data), 0, @intCast(bytes_written));
    setReturn(info, @ptrCast(out));
}

pub fn setup(isolate: ?*c.Isolate, context: ?*c.Context) void {
    var hs: c.HandleScope = undefined;
    c.v8__HandleScope__CONSTRUCT(&hs, isolate);
    defer c.v8__HandleScope__DESTRUCT(&hs);
    const global = c.v8__Context__Global(context);
    var out: c.MaybeBool = undefined;

    const btoa_fn = c.v8__Function__New__DEFAULT(context, btoaCallback);
    _ = c.v8__Object__Set(global, context, c.v8__String__NewFromUtf8(isolate, "btoa", 0, -1), btoa_fn, &out);
    const atob_fn = c.v8__Function__New__DEFAULT(context, atobCallback);
    _ = c.v8__Object__Set(global, context, c.v8__String__NewFromUtf8(isolate, "atob", 0, -1), atob_fn, &out);
}
