const std = @import("std");
const c = @import("../c.zig").c;
const gpa = std.heap.smp_allocator;

const ExtractedStr = struct {
    slice: []const u8,
    heap: ?[]u8 = null,
    fn deinit(self: ExtractedStr) void {
        if (self.heap) |h| gpa.free(h);
    }
};

fn extractStr(ctx: ?*c.Context, val: c.Value, stack_buf: []u8) ?ExtractedStr {
    var len: usize = 0;
    const cstr = c.toCStringLen(ctx, &len, val) orelse return null;
    defer c.freeCString(ctx, cstr);
    if (len == 0) return .{ .slice = "" };
    if (len <= stack_buf.len) {
        @memcpy(stack_buf[0..len], cstr[0..len]);
        return .{ .slice = stack_buf[0..len] };
    }
    const heap_buf = gpa.alloc(u8, len) catch return null;
    @memcpy(heap_buf[0..len], cstr[0..len]);
    return .{ .slice = heap_buf, .heap = heap_buf };
}

fn backingBytes(ctx: ?*c.Context, arg: c.Value) ?[]const u8 {
    var size: usize = 0;
    if (c.getArrayBuffer(ctx, &size, arg)) |p| {
        if (size > 0) return p[0..size];
        return "";
    }
    if (c.hasException(ctx)) {
        const exc = c.getException(ctx);
        c.freeValue(ctx, exc);
    }
    var byte_offset: usize = 0;
    var byte_length: usize = 0;
    var bpe: usize = 0;
    const buf_val = c.getTypedArrayBuffer(ctx, arg, &byte_offset, &byte_length, &bpe);
    if (c.getTag(buf_val) == c.TAG_EXCEPTION) {
        if (c.hasException(ctx)) {
            const exc = c.getException(ctx);
            c.freeValue(ctx, exc);
        }
        return null;
    }
    defer c.freeValue(ctx, buf_val);
    if (c.isNull(buf_val) != 0 or c.isUndefined(buf_val) != 0) return null;
    const p = c.getArrayBuffer(ctx, &size, buf_val) orelse {
        if (c.hasException(ctx)) {
            const exc = c.getException(ctx);
            c.freeValue(ctx, exc);
        }
        return null;
    };
    if (byte_offset + byte_length > size) return null;
    if (byte_length == 0) return "";
    return p[byte_offset..][0..byte_length];
}

fn textEncoderCtor(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    _ = argc;
    _ = argv;
    const obj = c.newObject(ctx);
    const enc = c.newStringLen(ctx, "utf-8", 5);
    _ = c.definePropertyValueStr(ctx, obj, "encoding", enc, c.PROP_C_W_E);
    const encode_fn = c.newCFunction(ctx, &encoderEncode, "encode", 1);
    _ = c.definePropertyValueStr(ctx, obj, "encode", encode_fn, c.PROP_C_W_E);
    return obj;
}

fn encoderEncode(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    var buf: [512]u8 = undefined;
    const input = extractStr(ctx, if (argc > 0) argv[0] else c.JS_UNDEFINED, &buf) orelse return c.JS_EXCEPTION;
    defer input.deinit();
    if (input.slice.len == 0) {
        const empty_ab = c.newArrayBufferCopy(ctx, "", 0);
        if (c.isException(empty_ab) != 0) return empty_ab;
        defer c.freeValue(ctx, empty_ab);
        const off = c.newInt32(ctx, 0);
        const len = c.newInt32(ctx, 0);
        defer c.freeValue(ctx, off);
        defer c.freeValue(ctx, len);
        var eargv = [_]c.Value{ empty_ab, off, len };
        return c.newTypedArray(ctx, 3, &eargv[0], c.JS_TYPED_ARRAY_UINT8);
    }
    const ab = c.newArrayBufferCopy(ctx, input.slice.ptr, input.slice.len);
    if (c.isException(ab) != 0) return ab;
    defer c.freeValue(ctx, ab);
    const off = c.newInt32(ctx, 0);
    const len = c.newInt32(ctx, @intCast(input.slice.len));
    defer c.freeValue(ctx, off);
    defer c.freeValue(ctx, len);
    var view_argv = [_]c.Value{ ab, off, len };
    const view = c.newTypedArray(ctx, 3, &view_argv[0], c.JS_TYPED_ARRAY_UINT8);
    if (c.isException(view) != 0) return view;
    return view;
}

fn textDecoderCtor(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    _ = argc;
    _ = argv;
    const obj = c.newObject(ctx);
    const enc = c.newStringLen(ctx, "utf-8", 5);
    _ = c.definePropertyValueStr(ctx, obj, "encoding", enc, c.PROP_C_W_E);
    const decode_fn = c.newCFunction(ctx, &decoderDecode, "decode", 1);
    _ = c.definePropertyValueStr(ctx, obj, "decode", decode_fn, c.PROP_C_W_E);
    return obj;
}

fn decoderDecode(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 1) return c.newStringLen(ctx, "", 0);
    const bytes = backingBytes(ctx, argv[0]) orelse {
        _ = c.throwTypeError(ctx, "TextDecoder.decode requires ArrayBuffer or TypedArray input");
        return c.JS_EXCEPTION;
    };
    if (bytes.len == 0) return c.newStringLen(ctx, "", 0);
    if (std.unicode.utf8ValidateSlice(bytes)) {
        return c.newStringLen(ctx, bytes.ptr, bytes.len);
    }
    const out = gpa.alloc(u8, bytes.len * 3) catch return c.throwOutOfMemory(ctx);
    var n: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            out[n] = 0xef;
            out[n + 1] = 0xbf;
            out[n + 2] = 0xbd;
            n += 3;
            i += 1;
            continue;
        };
        if (i + seq_len > bytes.len or !std.unicode.utf8ValidateSlice(bytes[i..][0..seq_len])) {
            out[n] = 0xef;
            out[n + 1] = 0xbf;
            out[n + 2] = 0xbd;
            n += 3;
            i += 1;
            continue;
        }
        @memcpy(out[n..][0..seq_len], bytes[i..][0..seq_len]);
        n += seq_len;
        i += seq_len;
    }
    defer gpa.free(out);
    return c.newStringLen(ctx, out.ptr, n);
}

pub fn setup(ctx: *c.Context) void {
    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);
    const te_ctor = c.newCFunction2(ctx, &textEncoderCtor, "TextEncoder", 0, c.JS_CFUNC_constructor, 0);
    _ = c.definePropertyValueStr(ctx, global, "TextEncoder", te_ctor, c.PROP_C_W_E);
    const td_ctor = c.newCFunction2(ctx, &textDecoderCtor, "TextDecoder", 0, c.JS_CFUNC_constructor, 0);
    _ = c.definePropertyValueStr(ctx, global, "TextDecoder", td_ctor, c.PROP_C_W_E);
}
