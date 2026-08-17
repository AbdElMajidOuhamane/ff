const std = @import("std");
const c = @import("../c.zig").c;

// One contiguous pass: exact-size ArrayBuffer, WriteUtf8 straight into its
// backing store, then wrap as a bare Uint8Array (no Buffer prototype). The
// view length is the ACTUAL byte count written, not the precomputed length.
fn encodeCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    if (c.v8__FunctionCallbackInfo__Length(info) < 1) return;
    const val = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    if (!c.v8__Value__IsString(val)) return;

    const str = @as(*const c.String, @ptrCast(val.?));
    const utf8_len: usize = @intCast(c.v8__String__Utf8Length(str, isolate));
    const ab = c.v8__ArrayBuffer__New(isolate, utf8_len);
    var store = c.v8__ArrayBuffer__GetBackingStore(ab);
    const bs = c.std__shared_ptr__v8__BackingStore__get(&store) orelse return;
    const dest = @as(?[*]u8, @ptrCast(c.v8__BackingStore__Data(bs))) orelse return;
    const written: usize = @intCast(c.v8__String__WriteUtf8(str, isolate, @ptrCast(dest), utf8_len, 0));

    const ua = c.v8__Uint8Array__New(ab, 0, written);
    var retval: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &retval);
    c.v8__ReturnValue__Set(retval, @ptrCast(ua));
}

// Decode: pure-ASCII input short-circuits to NewFromUtf8 on the read bytes
// (identical to buffer.zig's proven toString utf8 path, no intermediate copy).
// Non-ASCII: copy valid runs as-is, replace invalid bytes with U+FFFD; the
// result is ALWAYS built from the arena copy (stable memory for NewFromUtf8).
fn utf8ToV8(isolate: ?*c.Isolate, bytes: []const u8) ?*const c.Value {
    var all_ascii = true;
    for (bytes) |b| {
        if (b >= 0x80) {
            all_ascii = false;
            break;
        }
    }
    if (all_ascii) return @ptrCast(c.v8__String__NewFromUtf8(isolate, @ptrCast(bytes.ptr), 0, @intCast(bytes.len)));

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var i: usize = 0;
    var buf = std.ArrayList(u8).empty;
    buf.ensureTotalCapacity(a, bytes.len * 3) catch return null;
    while (i < bytes.len) {
        if (std.unicode.utf8Decode(bytes[i..])) |cp| {
            const n: usize = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 1;
            if (n > 1 and cp > 0x7f) {
                var tmp: [4]u8 = undefined;
                const m = std.unicode.utf8Encode(cp, &tmp) catch n;
                buf.appendSlice(a, tmp[0..m]) catch return null;
            } else {
                buf.appendSlice(a, bytes[i .. i + n]) catch return null;
            }
            i += n;
        } else |_| {
            buf.appendSlice(a, "\xEF\xBF\xBD") catch return null;
            i += 1;
        }
    }
    const out = c.v8__String__NewFromUtf8(isolate, @ptrCast(buf.items.ptr), 0, @intCast(buf.items.len));
    return @ptrCast(out);
}

// Coerce an element value to a byte: null-safe, clamped (mirrors buffer.zig's
// valToByte). Elements are 0-255 for Uint8Array/Buffer; ignored otherwise.
fn elemByte(context: ?*c.Context, el: ?*const c.Value) u8 {
    if (el == null) return 0;
    var maybe: c.MaybeF64 = undefined;
    c.v8__Value__NumberValue(el, context, &maybe);
    if (!maybe.has_value) return 0;
    if (maybe.value < 0) return 0;
    if (maybe.value > 255) return 255;
    return @intFromFloat(maybe.value);
}

fn decodeCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    if (c.v8__FunctionCallbackInfo__Length(info) < 1) return;
    const val = c.v8__FunctionCallbackInfo__INDEX(info, 0);

    if (c.v8__Value__IsString(val)) {
        var retval: c.ReturnValue = undefined;
        c.v8__FunctionCallbackInfo__GetReturnValue(info, &retval);
        c.v8__ReturnValue__Set(retval, @ptrCast(val));
        return;
    }

    var hs: c.HandleScope = undefined;
    c.v8__HandleScope__CONSTRUCT(&hs, isolate);
    defer c.v8__HandleScope__DESTRUCT(&hs);

    var slab: ?[]u8 = null;
    defer if (slab) |s| std.heap.page_allocator.free(s);

    var bytes: []const u8 = &.{};
    if (c.v8__Value__IsArrayBufferView(val)) {
        const context = c.v8__Isolate__GetCurrentContext(isolate) orelse return;
        const view: *const c.ArrayBufferView = @ptrCast(val.?);
        const len = c.v8__ArrayBufferView__ByteLength(view);
        if (len > 0) {
            const mem = std.heap.page_allocator.alloc(u8, len) catch return;
            slab = mem;
            for (0..len) |i| {
                mem[i] = elemByte(context, c.v8__Object__GetIndex(@ptrCast(view), context, @intCast(i)));
            }
            bytes = mem;
        }
    } else if (c.v8__Value__IsArrayBuffer(val)) {
        const ab: *const c.ArrayBuffer = @ptrCast(val.?);
        var store = c.v8__ArrayBuffer__GetBackingStore(ab);
        const bs = c.std__shared_ptr__v8__BackingStore__get(&store) orelse return;
        const data = @as([*]u8, @ptrCast(c.v8__BackingStore__Data(bs) orelse return));
        bytes = data[0..c.v8__BackingStore__ByteLength(bs)];
    }

    const out = utf8ToV8(isolate, bytes) orelse return;
    var retval: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &retval);
    c.v8__ReturnValue__Set(retval, @ptrCast(out));
}

fn attachMethod(isolate: ?*c.Isolate, context: ?*c.Context, fn_obj: ?*const c.Value, name: [:0]const u8, cb: anytype) void {
    var out: c.MaybeBool = undefined;
    const m = c.v8__Function__New__DEFAULT(context, cb);
    _ = c.v8__Object__Set(@ptrCast(fn_obj), context, c.v8__String__NewFromUtf8(isolate, name.ptr, 0, -1), m, &out);
}

pub fn setup(isolate: ?*c.Isolate, context: ?*c.Context) void {
    var hs: c.HandleScope = undefined;
    c.v8__HandleScope__CONSTRUCT(&hs, isolate);
    defer c.v8__HandleScope__DESTRUCT(&hs);
    const global = c.v8__Context__Global(context);
    var out: c.MaybeBool = undefined;

    const enc = c.v8__Function__New__DEFAULT(context, encodeCallback);
    const enc_proto = c.v8__Object__Get(@ptrCast(enc), context, c.v8__String__NewFromUtf8(isolate, "prototype", 0, -1));
    attachMethod(isolate, context, enc_proto, "encode", encodeCallback);
    _ = c.v8__Object__Set(global, context, c.v8__String__NewFromUtf8(isolate, "TextEncoder", 0, -1), enc, &out);

    const dec = c.v8__Function__New__DEFAULT(context, decodeCallback);
    const dec_proto = c.v8__Object__Get(@ptrCast(dec), context, c.v8__String__NewFromUtf8(isolate, "prototype", 0, -1));
    attachMethod(isolate, context, dec_proto, "decode", decodeCallback);
    _ = c.v8__Object__Set(global, context, c.v8__String__NewFromUtf8(isolate, "TextDecoder", 0, -1), dec, &out);
}
