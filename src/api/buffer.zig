const std = @import("std");
const c = @import("../c.zig").c;
const b64 = std.base64.standard;

var g_isolate: ?*c.Isolate = null;
var g_proto: c.Global = undefined; // Buffer.prototype, chained over Uint8Array.prototype

const BufferBytes = struct { data: [*]u8, byte_count: usize };

// ---- data plane: comptime tables (single tag per batch — EoA-style) ----
const hex_digits: [16]u8 = "0123456789abcdef".*;

const hex_nibble_value: [256]u8 = blk: {
    var table: [256]u8 = [_]u8{0xff} ** 256;
    for (hex_digits, 0..) |char, index| {
        table[char] = @intCast(index);
        table[std.ascii.toUpper(char)] = @intCast(index);
    }
    break :blk table;
};

comptime {
    std.debug.assert(hex_digits.len == 16);
    std.debug.assert(hex_nibble_value['A'] == 10);
    std.debug.assert(hex_nibble_value['f'] == 15);
    std.debug.assert(hex_nibble_value['g'] == 0xff);
}

// ---- data plane: transforms (free functions, primitive args, no self) ----
fn hex_encode(source: []const u8, target: []u8) usize {
    std.debug.assert(target.len == source.len * 2);
    for (source, 0..) |byte, index| {
        target[index * 2] = hex_digits[byte >> 4];
        target[index * 2 + 1] = hex_digits[byte & 0x0f];
    }
    return target.len;
}

fn hex_decode(source: []const u8, target: []u8) usize {
    const decoded_byte_count = source.len / 2;
    std.debug.assert(target.len == decoded_byte_count);
    for (0..decoded_byte_count) |index| {
        const hi = hex_nibble_value[source[index * 2]];
        const lo = hex_nibble_value[source[index * 2 + 1]];
        target[index] = if (hi != 0xff and lo != 0xff) hi * 16 | lo else 0;
    }
    return decoded_byte_count;
}

fn b64_encoded_byte_count(source_byte_count: usize) usize {
    return b64.Encoder.calcSize(source_byte_count);
}

fn b64_encode(source: []const u8, target: []u8) usize {
    const target_byte_count = b64.Encoder.calcSize(source.len);
    std.debug.assert(target.len == target_byte_count);
    _ = b64.Encoder.encode(target, source);
    return target_byte_count;
}

fn b64_decoded_byte_count(source: []const u8) ?usize {
    return b64.Decoder.calcSizeForSlice(source) catch null;
}

fn b64_decode(source: []const u8, target: []u8) ?usize {
    const target_byte_count = b64_decoded_byte_count(source) orelse return null;
    std.debug.assert(target.len == target_byte_count);
    b64.Decoder.decode(target, source) catch return null;
    return target_byte_count;
}

fn buffer_bytes_equal(source: []const u8, target: []const u8) bool {
    if (source.len != target.len) return false;
    if (source.ptr == target.ptr) return true;
    return std.mem.eql(u8, source, target);
}

// ---- control plane: helpers ----
fn throwTypeError(isolate: ?*c.Isolate, msg: []const u8) void {
    const v8_msg = c.v8__String__NewFromUtf8(isolate, @ptrCast(msg.ptr), 0, @intCast(msg.len));
    _ = c.v8__Isolate__ThrowException(isolate, c.v8__Exception__TypeError(v8_msg));
}

fn getCtx(isolate: ?*c.Isolate) ?*c.Context {
    return c.v8__Isolate__GetCurrentContext(isolate);
}

const Encoding = struct {
    buf: [16]u8,
    len: usize,
};

fn getEncoding(isolate: ?*c.Isolate, info: ?*const c.FunctionCallbackInfo, index: c_int) Encoding {
    var enc = Encoding{ .buf = undefined, .len = 0 };
    if (c.v8__FunctionCallbackInfo__Length(info) <= index) return enc;
    const val = c.v8__FunctionCallbackInfo__INDEX(info, index);
    if (!c.v8__Value__IsString(val)) return enc;
    const str = @as(*const c.String, @ptrCast(val.?));
    const char_count: usize = @intCast(c.v8__String__Length(str));
    const cap = @min(char_count, enc.buf.len);
    c.v8__String__WriteOneByte(str, isolate, 0, @intCast(cap), &enc.buf);
    enc.len = cap;
    return enc;
}

fn encEql(enc: Encoding, name: []const u8) bool {
    return std.mem.eql(u8, enc.buf[0..enc.len], name);
}

fn encIsUtf8(enc: Encoding) bool {
    return enc.len == 0 or encEql(enc, "utf8") or encEql(enc, "utf-8");
}

// Resolve any buffer-shaped value to ONE contiguous backing-store slice.
fn bytesOf(val: ?*const c.Value) ?BufferBytes {
    const value = val orelse return null;
    if (c.v8__Value__IsArrayBuffer(value)) {
        const ab: *const c.ArrayBuffer = @ptrCast(value);
        var store = c.v8__ArrayBuffer__GetBackingStore(ab);
        const backing = c.std__shared_ptr__v8__BackingStore__get(&store) orelse return null;
        const data = @as([*]u8, @ptrCast(c.v8__BackingStore__Data(backing) orelse return null));
        return .{ .data = data, .byte_count = c.v8__BackingStore__ByteLength(backing) };
    } else if (c.v8__Value__IsArrayBufferView(value)) {
        const view: *const c.ArrayBufferView = @ptrCast(value);
        const offset = c.v8__ArrayBufferView__ByteOffset(view);
        const length = c.v8__ArrayBufferView__ByteLength(view);
        const ab = c.v8__ArrayBufferView__Buffer(view);
        var store = c.v8__ArrayBuffer__GetBackingStore(ab);
        const backing = c.std__shared_ptr__v8__BackingStore__get(&store) orelse return null;
        const data = @as([*]u8, @ptrCast(c.v8__BackingStore__Data(backing) orelse return null));
        return .{ .data = data + offset, .byte_count = length };
    }
    return null;
}

// The ONLY allocations in callbacks are V8-managed output objects (GC'd).
// Returns the ArrayBuffer plus its backing slice so transforms can write
// directly into the destination — zero native allocs, zero copies.
const Backed = struct { ab: ?*const c.ArrayBuffer, data: [*]u8, byte_count: usize };

fn newBacked(isolate: ?*c.Isolate, byte_count: usize) ?Backed {
    const ab = c.v8__ArrayBuffer__New(isolate, byte_count);
    var store = c.v8__ArrayBuffer__GetBackingStore(ab);
    const backing = c.std__shared_ptr__v8__BackingStore__get(&store) orelse return null;
    const dest = c.v8__BackingStore__Data(backing) orelse return null;
    return .{ .ab = ab, .data = @ptrCast(dest), .byte_count = byte_count };
}

fn wrapBuffer(isolate: ?*c.Isolate, context: ?*c.Context, ab: ?*const c.ArrayBuffer, offset: usize, length: usize) ?*const c.Value {
    const abn = ab orelse return null;
    const ua = c.v8__Uint8Array__New(abn, offset, length);
    const proto = c.v8__Global__Get(&g_proto, isolate);
    if (proto == null) return @ptrCast(ua);
    var out: c.MaybeBool = undefined;
    c.v8__Object__SetPrototype(@ptrCast(ua), context, @ptrCast(proto.?), &out);
    return @ptrCast(ua);
}

fn wrapEmpty(isolate: ?*c.Isolate, context: ?*c.Context) ?*const c.Value {
    return wrapBuffer(isolate, context, c.v8__ArrayBuffer__New(isolate, 0), 0, 0);
}

fn setReturn(info: ?*const c.FunctionCallbackInfo, val: ?*const c.Value) void {
    var retval: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &retval);
    c.v8__ReturnValue__Set(retval, @ptrCast(val));
}

fn valToByte(_: ?*c.Isolate, context: ?*c.Context, value: ?*const c.Value) u8 {
    var maybe: c.MaybeF64 = undefined;
    c.v8__Value__NumberValue(value, context, &maybe);
    if (!maybe.has_value) return 0;
    if (maybe.value < 0) return 0;
    if (maybe.value > 255) return 255;
    return @intFromFloat(maybe.value);
}

fn createArrayBuffer(data: []const u8) *const c.Value {
    const isolate = g_isolate;
    const ab = c.v8__ArrayBuffer__New(isolate, data.len);
    var store = c.v8__ArrayBuffer__GetBackingStore(ab);
    const backing = c.std__shared_ptr__v8__BackingStore__get(&store);
    if (backing) |bs| {
        const dest = @as(?[*]u8, @ptrCast(c.v8__BackingStore__Data(bs)));
        if (dest) |d| @memcpy(d[0..data.len], data);
    }
    return @ptrCast(ab);
}

fn makeBuffer(isolate: ?*c.Isolate, context: ?*c.Context, bytes: []const u8) ?*const c.Value {
    return wrapBuffer(isolate, context, @ptrCast(createArrayBuffer(bytes)), 0, bytes.len);
}

// ---------------------------------------------------------------
// Statics
// ---------------------------------------------------------------

fn allocCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = getCtx(isolate) orelse return;
    if (c.v8__FunctionCallbackInfo__Length(info) < 1) return;
    const n = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    var maybe: c.MaybeF64 = undefined;
    c.v8__Value__NumberValue(n, context, &maybe);
    if (!maybe.has_value or maybe.value < 0) return;
    const byte_count: usize = @intFromFloat(maybe.value);
    const ab = c.v8__ArrayBuffer__New(isolate, byte_count);
    var store = c.v8__ArrayBuffer__GetBackingStore(ab);
    const backing = c.std__shared_ptr__v8__BackingStore__get(&store);
    if (backing) |bs| {
        const d = @as(?[*]u8, @ptrCast(c.v8__BackingStore__Data(bs)));
        if (d) |p| @memset(p[0..byte_count], 0);
    }
    setReturn(info, wrapBuffer(isolate, context, ab, 0, byte_count));
}

fn allocUnsafeCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = getCtx(isolate) orelse return;
    if (c.v8__FunctionCallbackInfo__Length(info) < 1) return;
    const n = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    var maybe: c.MaybeF64 = undefined;
    c.v8__Value__NumberValue(n, context, &maybe);
    if (!maybe.has_value or maybe.value < 0) return;
    const byte_count: usize = @intFromFloat(maybe.value);
    setReturn(info, wrapBuffer(isolate, context, c.v8__ArrayBuffer__New(isolate, byte_count), 0, byte_count));
}

fn fromString(isolate: ?*c.Isolate, context: ?*c.Context, str: *const c.String, enc: Encoding) ?*const c.Value {
    const utf8_byte_count: usize = @intCast(c.v8__String__Utf8Length(str, isolate));

    if (encEql(enc, "base64")) {
        const unit_count: usize = @intCast(c.v8__String__Length(str));
        if (unit_count == 0) return wrapEmpty(isolate, context);
        const squish = newBacked(isolate, unit_count) orelse return null;
        c.v8__String__WriteOneByte(str, isolate, 0, @intCast(unit_count), @ptrCast(squish.data));
        const decoded_byte_count = b64_decoded_byte_count(squish.data[0..unit_count]) orelse return null;
        if (decoded_byte_count == 0) return wrapEmpty(isolate, context);
        const decoded = newBacked(isolate, decoded_byte_count) orelse return null;
        const bytes_written = b64_decode(squish.data[0..unit_count], decoded.data[0..decoded_byte_count]) orelse return null;
        return wrapBuffer(isolate, context, decoded.ab, 0, bytes_written);
    }
    if (encEql(enc, "hex")) {
        const unit_count: usize = @intCast(c.v8__String__Length(str));
        if (unit_count == 0) return wrapEmpty(isolate, context);
        const squish = newBacked(isolate, unit_count) orelse return null;
        c.v8__String__WriteOneByte(str, isolate, 0, @intCast(unit_count), @ptrCast(squish.data));
        const decoded_byte_count = unit_count / 2;
        if (decoded_byte_count == 0) return wrapEmpty(isolate, context);
        const decoded = newBacked(isolate, decoded_byte_count) orelse return null;
        _ = hex_decode(squish.data[0..unit_count], decoded.data[0..decoded_byte_count]);
        return wrapBuffer(isolate, context, decoded.ab, 0, decoded_byte_count);
    }

    const backed = newBacked(isolate, utf8_byte_count) orelse return null;
    const bytes_written: usize = @intCast(c.v8__String__WriteUtf8(str, isolate, @ptrCast(backed.data), utf8_byte_count, 0));
    return wrapBuffer(isolate, context, backed.ab, 0, bytes_written);
}

fn fromCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = getCtx(isolate) orelse return;
    if (c.v8__FunctionCallbackInfo__Length(info) < 1) return;
    const val = c.v8__FunctionCallbackInfo__INDEX(info, 0).?;
    const enc = getEncoding(isolate, info, 1);

    if (c.v8__Value__IsString(val)) {
        setReturn(info, fromString(isolate, context, @ptrCast(val), enc));
        return;
    }
    if (c.v8__Value__IsArrayBufferView(val) or c.v8__Value__IsArrayBuffer(val)) {
        const b = bytesOf(@ptrCast(val)) orelse return;
        setReturn(info, makeBuffer(isolate, context, b.data[0..b.byte_count]));
        return;
    }
    if (c.v8__Value__IsArray(val)) {
        const arr: *const c.Array = @ptrCast(val);
        const count: usize = c.v8__Array__Length(arr);
        if (count == 0) {
            setReturn(info, wrapEmpty(isolate, context));
            return;
        }
        const backed = newBacked(isolate, count) orelse return;
        for (0..count) |index| {
            const el = c.v8__Object__GetIndex(@ptrCast(arr), context, @intCast(index));
            backed.data[index] = valToByte(isolate, context, el);
        }
        setReturn(info, wrapBuffer(isolate, context, backed.ab, 0, count));
    }
}

fn byteLengthCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    if (c.v8__FunctionCallbackInfo__Length(info) < 1) return;
    const val = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    if (!c.v8__Value__IsString(val)) {
        const b = bytesOf(val) orelse return;
        setReturn(info, c.v8__Number__New(isolate, @floatFromInt(@as(i64, @intCast(b.byte_count)))));
        return;
    }
    const str = @as(*const c.String, @ptrCast(val.?));
    const enc = getEncoding(isolate, info, 1);
    var byte_count: usize = 0;
    if (encIsUtf8(enc)) {
        byte_count = @intCast(c.v8__String__Utf8Length(str, isolate));
    } else if (encEql(enc, "ascii") or encEql(enc, "latin1")) {
        byte_count = @intCast(c.v8__String__Length(str));
    } else if (encEql(enc, "base64")) {
        const unit_count: usize = @intCast(c.v8__String__Length(str));
        if (unit_count > 0) {
            const squish = newBacked(isolate, unit_count) orelse return;
            c.v8__String__WriteOneByte(str, isolate, 0, @intCast(unit_count), @ptrCast(squish.data));
            byte_count = b64_decoded_byte_count(squish.data[0..unit_count]) orelse 0;
        }
    } else if (encEql(enc, "hex")) {
        byte_count = @as(usize, @intCast(c.v8__String__Length(str))) / 2;
    }
    setReturn(info, c.v8__Number__New(isolate, @floatFromInt(@as(i64, @intCast(byte_count)))));
}

fn isBufferCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const val = c.v8__FunctionCallbackInfo__INDEX(info, 0) orelse return;
    var is_buffer = false;
    if (c.v8__Value__IsUint8Array(val)) {
        const proto = c.v8__Global__Get(&g_proto, isolate);
        const actual = c.v8__Object__GetPrototype(@ptrCast(val));
        if (proto != null and actual != null) {
            is_buffer = c.v8__Object__GetIdentityHash(@ptrCast(proto.?)) == c.v8__Object__GetIdentityHash(@ptrCast(actual));
        }
    }
    setReturn(info, c.v8__Boolean__New(isolate, is_buffer));
}

fn isViewCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const val = c.v8__FunctionCallbackInfo__INDEX(info, 0) orelse return;
    setReturn(info, c.v8__Boolean__New(isolate, c.v8__Value__IsArrayBufferView(val)));
}

// Two passes into a single contiguous destination: measure total, then one
// memcpy chain directly into the output backing store. No intermediate array.
fn concatCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = getCtx(isolate) orelse return;
    if (c.v8__FunctionCallbackInfo__Length(info) < 1) return;
    const list = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    if (!c.v8__Value__IsArray(list)) return;
    const arr: *const c.Array = @ptrCast(list.?);
    const count: usize = c.v8__Array__Length(arr);

    var total_byte_count: usize = 0;
    for (0..count) |index| {
        const el = c.v8__Object__GetIndex(@ptrCast(arr), context, @intCast(index));
        if (bytesOf(el)) |b| total_byte_count += b.byte_count;
    }
    if (total_byte_count == 0) {
        setReturn(info, wrapEmpty(isolate, context));
        return;
    }

    const backed = newBacked(isolate, total_byte_count) orelse return;
    var offset: usize = 0;
    for (0..count) |index| {
        const el = c.v8__Object__GetIndex(@ptrCast(arr), context, @intCast(index));
        if (bytesOf(el)) |b| {
            @memcpy(backed.data[offset .. offset + b.byte_count], b.data[0..b.byte_count]);
            offset += b.byte_count;
        }
    }
    std.debug.assert(offset == total_byte_count);
    setReturn(info, wrapBuffer(isolate, context, backed.ab, 0, total_byte_count));
}

// new Buffer(n | str | arr): under `new`, `this` is a plain object, so give it
// Buffer.prototype + indexed props + a real Uint8Array sidecar.
fn constructorCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = getCtx(isolate) orelse return;
    if (c.v8__FunctionCallbackInfo__Length(info) < 1) return;
    const val = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    if (c.v8__Value__IsString(val)) {
        const src = fromString(isolate, context, @ptrCast(val.?), Encoding{ .buf = undefined, .len = 0 }) orelse return;
        const bytes = bytesOf(src) orelse return;
        copyIntoThis(isolate, context, info, bytes.data[0..bytes.byte_count]);
        return;
    }
    var maybe: c.MaybeF64 = undefined;
    c.v8__Value__NumberValue(val, context, &maybe);
    if (!maybe.has_value or maybe.value < 0) return;
    const byte_count: usize = @intFromFloat(maybe.value);
    if (byte_count == 0) {
        copyIntoThis(isolate, context, info, &.{});
        return;
    }
    const backed = newBacked(isolate, byte_count) orelse return;
    @memset(backed.data[0..byte_count], 0);
    copyIntoThis(isolate, context, info, backed.data[0..byte_count]);
}

fn copyIntoThis(isolate: ?*c.Isolate, context: ?*c.Context, info: ?*const c.FunctionCallbackInfo, bytes: []const u8) void {
    const this = c.v8__FunctionCallbackInfo__This(info) orelse return;
    var out: c.MaybeBool = undefined;
    const proto = c.v8__Global__Get(&g_proto, isolate);
    if (proto != null) c.v8__Object__SetPrototype(this, context, @ptrCast(proto.?), &out);

    _ = c.v8__Object__Set(this, context, c.v8__String__NewFromUtf8(isolate, "length", 0, -1), c.v8__Number__New(isolate, @floatFromInt(@as(i64, @intCast(bytes.len)))), &out);

    const sidecar = makeBuffer(isolate, context, bytes) orelse return;
    _ = c.v8__Object__Set(this, context, c.v8__String__NewFromUtf8(isolate, "_u8", 0, -1), sidecar, &out);

    for (bytes, 0..) |byte, index| {
        var key_buf: [16]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{d}", .{index}) catch break;
        _ = c.v8__Object__Set(this, context, c.v8__String__NewFromUtf8(isolate, key.ptr, 0, -1), c.v8__Number__New(isolate, @floatFromInt(byte)), &out);
    }
}

// ---------------------------------------------------------------
// Prototype methods
// ---------------------------------------------------------------

fn instanceBytes(info: ?*const c.FunctionCallbackInfo) ?BufferBytes {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = getCtx(isolate) orelse return null;
    const this = c.v8__FunctionCallbackInfo__This(info) orelse return null;
    if (bytesOf(this)) |b| return b;
    const su = c.v8__Object__Get(this, context, c.v8__String__NewFromUtf8(isolate, "_u8", 0, -1));
    return bytesOf(su);
}

fn toStringCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const b = instanceBytes(info) orelse return;
    const enc = getEncoding(isolate, info, 0);
    const bytes = b.data[0..b.byte_count];

    if (encIsUtf8(enc)) {
        setReturn(info, @ptrCast(c.v8__String__NewFromUtf8(isolate, @ptrCast(bytes.ptr), 0, @intCast(bytes.len))));
        return;
    }
    if (encEql(enc, "base64")) {
        if (bytes.len == 0) {
            setReturn(info, @ptrCast(c.v8__String__NewFromUtf8(isolate, "", 0, 0)));
            return;
        }
        const encoded_byte_count = b64_encoded_byte_count(bytes.len);
        const backed = newBacked(isolate, encoded_byte_count) orelse return;
        _ = b64_encode(bytes, backed.data[0..encoded_byte_count]);
        setReturn(info, @ptrCast(c.v8__String__NewFromUtf8(isolate, @ptrCast(backed.data), 0, @intCast(encoded_byte_count))));
        return;
    }
    if (encEql(enc, "hex")) {
        if (bytes.len == 0) {
            setReturn(info, @ptrCast(c.v8__String__NewFromUtf8(isolate, "", 0, 0)));
            return;
        }
        const encoded_byte_count = bytes.len * 2;
        const backed = newBacked(isolate, encoded_byte_count) orelse return;
        _ = hex_encode(bytes, backed.data[0..encoded_byte_count]);
        setReturn(info, @ptrCast(c.v8__String__NewFromUtf8(isolate, @ptrCast(backed.data), 0, @intCast(encoded_byte_count))));
        return;
    }
    setReturn(info, @ptrCast(c.v8__String__NewFromOneByte(isolate, @ptrCast(bytes.ptr), 0, @intCast(bytes.len))));
}

fn writeCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = getCtx(isolate) orelse return;
    if (c.v8__FunctionCallbackInfo__Length(info) < 1) return;
    const str_val = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    if (!c.v8__Value__IsString(str_val)) return;
    const str = @as(*const c.String, @ptrCast(str_val.?));

    var offset: usize = 0;
    if (c.v8__FunctionCallbackInfo__Length(info) > 1) {
        var off_maybe: c.MaybeF64 = undefined;
        c.v8__Value__NumberValue(c.v8__FunctionCallbackInfo__INDEX(info, 1), context, &off_maybe);
        if (off_maybe.has_value and off_maybe.value > 0) offset = @intFromFloat(off_maybe.value);
    }

    const this_bytes = instanceBytes(info) orelse return;
    if (offset >= this_bytes.byte_count) return;
    const remaining_bytes = this_bytes.byte_count - offset;
    const utf8_byte_count: usize = @intCast(c.v8__String__Utf8Length(str, isolate));
    const bytes_written_max = @min(remaining_bytes, utf8_byte_count);
    std.debug.assert(offset + bytes_written_max <= this_bytes.byte_count);
    const bytes_written: usize = @intCast(c.v8__String__WriteUtf8(str, isolate, @ptrCast(this_bytes.data + offset), bytes_written_max, 0));
    setReturn(info, c.v8__Number__New(isolate, @floatFromInt(@as(i64, @intCast(bytes_written)))));
}

fn subarrayCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = getCtx(isolate) orelse return;
    const this = c.v8__FunctionCallbackInfo__This(info) orelse return;
    const b = bytesOf(this) orelse return;
    const ab = c.v8__ArrayBufferView__Buffer(@ptrCast(this));
    if (ab == null) return;
    const base_off = if (c.v8__Value__IsArrayBufferView(this)) c.v8__ArrayBufferView__ByteOffset(@ptrCast(this)) else 0;

    var start: usize = 0;
    var end: usize = b.byte_count;
    if (c.v8__FunctionCallbackInfo__Length(info) > 0) {
        var m: c.MaybeF64 = undefined;
        c.v8__Value__NumberValue(c.v8__FunctionCallbackInfo__INDEX(info, 0), context, &m);
        if (m.has_value and m.value > 0) start = @intFromFloat(m.value);
    }
    if (c.v8__FunctionCallbackInfo__Length(info) > 1) {
        var m: c.MaybeF64 = undefined;
        c.v8__Value__NumberValue(c.v8__FunctionCallbackInfo__INDEX(info, 1), context, &m);
        if (m.has_value and m.value < @as(f64, @floatFromInt(end))) end = @intFromFloat(m.value);
    }
    if (start > end) start = end;
    std.debug.assert(start <= end and end <= b.byte_count);
    setReturn(info, wrapBuffer(isolate, context, @ptrCast(ab), base_off + start, end - start));
}

fn sliceCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = getCtx(isolate) orelse return;
    const b = instanceBytes(info) orelse return;
    var start: usize = 0;
    var end: usize = b.byte_count;
    if (c.v8__FunctionCallbackInfo__Length(info) > 0) {
        var m: c.MaybeF64 = undefined;
        c.v8__Value__NumberValue(c.v8__FunctionCallbackInfo__INDEX(info, 0), context, &m);
        if (m.has_value and m.value > 0) start = @min(@as(usize, @intFromFloat(m.value)), end);
    }
    if (c.v8__FunctionCallbackInfo__Length(info) > 1) {
        var m: c.MaybeF64 = undefined;
        c.v8__Value__NumberValue(c.v8__FunctionCallbackInfo__INDEX(info, 1), context, &m);
        if (m.has_value and m.value < @as(f64, @floatFromInt(end))) end = @intFromFloat(m.value);
    }
    if (start > end) start = end;
    std.debug.assert(start <= end and end <= b.byte_count);
    setReturn(info, makeBuffer(isolate, context, b.data[start..end]));
}

fn toJSONCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = getCtx(isolate) orelse return;
    const b = instanceBytes(info) orelse return;
    const arr = c.v8__Array__New(isolate, 0);
    var out: c.MaybeBool = undefined;
    for (b.data[0..b.byte_count], 0..) |byte, index| {
        c.v8__Object__SetAtIndex(arr, context, @intCast(index), c.v8__Number__New(isolate, @floatFromInt(byte)), &out);
    }
    const obj = c.v8__Object__New(isolate);
    _ = c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, "type", 0, -1), c.v8__String__NewFromUtf8(isolate, "Buffer", 0, -1), &out);
    _ = c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, "data", 0, -1), @ptrCast(arr), &out);
    setReturn(info, @ptrCast(obj));
}

fn equalsCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const a = instanceBytes(info) orelse return;
    const b = bytesOf(c.v8__FunctionCallbackInfo__INDEX(info, 0)) orelse return;
    const equal = buffer_bytes_equal(a.data[0..a.byte_count], b.data[0..b.byte_count]);
    setReturn(info, c.v8__Boolean__New(isolate, equal));
}

pub fn setup(isolate: ?*c.Isolate, context: ?*c.Context) void {
    g_isolate = isolate;
    var hs: c.HandleScope = undefined;
    c.v8__HandleScope__CONSTRUCT(&hs, isolate);
    defer c.v8__HandleScope__DESTRUCT(&hs);
    const global = c.v8__Context__Global(context);
    var out: c.MaybeBool = undefined;

    const FunctionCb = *const fn (?*const c.FunctionCallbackInfo) callconv(.c) void;

    const dummy_ab: *const c.ArrayBuffer = @ptrCast(c.v8__ArrayBuffer__New(isolate, 0));
    const dummy_ua = c.v8__Uint8Array__New(dummy_ab, 0, 0);
    const uint8_proto = c.v8__Object__GetPrototype(@ptrCast(dummy_ua));

    const buf_proto = c.v8__Object__New(isolate);
    c.v8__Object__SetPrototype(buf_proto, context, @ptrCast(uint8_proto), &out);

    const buf_fn = c.v8__Function__New__DEFAULT(context, constructorCallback);
    _ = c.v8__Object__Set(buf_fn, context, c.v8__String__NewFromUtf8(isolate, "prototype", 0, -1), buf_proto, &out);
    c.v8__Global__New(isolate, @ptrCast(buf_proto), &g_proto);

    const methods = [_]struct { name: [:0]const u8, cb: FunctionCb }{
        .{ .name = "toString", .cb = &toStringCallback },
        .{ .name = "write", .cb = &writeCallback },
        .{ .name = "subarray", .cb = &subarrayCallback },
        .{ .name = "slice", .cb = &sliceCallback },
        .{ .name = "toJSON", .cb = &toJSONCallback },
        .{ .name = "equals", .cb = &equalsCallback },
    };
    for (methods) |m| {
        const fn_val = c.v8__Function__New__DEFAULT(context, m.cb);
        _ = c.v8__Object__Set(buf_proto, context, c.v8__String__NewFromUtf8(isolate, m.name.ptr, 0, -1), fn_val, &out);
    }

    const statics = [_]struct { name: [:0]const u8, cb: FunctionCb }{
        .{ .name = "alloc", .cb = &allocCallback },
        .{ .name = "allocUnsafe", .cb = &allocUnsafeCallback },
        .{ .name = "from", .cb = &fromCallback },
        .{ .name = "byteLength", .cb = &byteLengthCallback },
        .{ .name = "isBuffer", .cb = &isBufferCallback },
        .{ .name = "isView", .cb = &isViewCallback },
        .{ .name = "concat", .cb = &concatCallback },
    };
    for (statics) |s| {
        const fn_val = c.v8__Function__New__DEFAULT(context, s.cb);
        _ = c.v8__Object__Set(buf_fn, context, c.v8__String__NewFromUtf8(isolate, s.name.ptr, 0, -1), fn_val, &out);
    }

    _ = c.v8__Object__Set(global, context, c.v8__String__NewFromUtf8(isolate, "Buffer", 0, -1), buf_fn, &out);
}
