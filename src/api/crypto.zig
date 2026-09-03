const std = @import("std");
const c = @import("../c.zig").c;

const gpa = std.heap.smp_allocator;

extern "c" fn arc4random_buf(buf: [*]u8, len: usize) void;

fn getRandomBytes(buf: []u8) void {
    switch (@import("builtin").os.tag) {
        .linux => {
            var off: usize = 0;
            while (off < buf.len) {
                const n = std.c.getrandom(buf.ptr + off, buf.len - off, 0);
                if (n < 0) {
                    if (std.posix.errno(n) == .INTR) continue;
                    std.Io.Threaded.global_single_threaded.io().random(buf[off..]);
                    return;
                }
                off += @intCast(n);
            }
        },
        else => arc4random_buf(buf.ptr, buf.len),
    }
}

const ExtractedStr = struct {
    slice: []const u8,
    heap: ?[]u8 = null,
    fn deinit(self: ExtractedStr) void {
        if (self.heap) |h| gpa.free(h);
    }
};

fn extractStringAuto(ctx: ?*c.Context, val: c.Value, stack_buf: []u8) ?ExtractedStr {
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

/// Raw bytes of an ArrayBuffer or TypedArray view.
/// JS_GetArrayBuffer throws InvalidClass on views, JS_GetUint8Array throws
/// on non-Uint8 views — each failed probe must clear its exception.
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
    var byte_size: usize = 0;
    if (c.getUint8Array(ctx, &byte_size, arg)) |p| {
        if (byte_size > 0) return p[0..byte_size];
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
    const base = c.getArrayBuffer(ctx, &size, buf_val) orelse {
        if (c.hasException(ctx)) {
            const exc = c.getException(ctx);
            c.freeValue(ctx, exc);
        }
        return null;
    };
    if (byte_offset + byte_length > size) return null;
    if (byte_length == 0) return "";
    return base[byte_offset..][0..byte_length];
}

fn getRandomValuesCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 1 or c.isObject(argv[0]) == 0) {
        _ = c.throwTypeError(ctx, "getRandomValues requires a TypedArray argument");
        return c.JS_EXCEPTION;
    }
    const len_val = c.getPropertyStr(ctx, argv[0], "length");
    if (c.isException(len_val) != 0) return len_val;
    var size: i32 = 0;
    if (c.toInt32(ctx, &size, len_val) != 0) {
        c.freeValue(ctx, len_val);
        return c.JS_EXCEPTION;
    }
    c.freeValue(ctx, len_val);
    if (size <= 0 or size > 65536) {
        _ = c.throwTypeError(ctx, "getRandomValues: max 65536 bytes");
        return c.JS_EXCEPTION;
    }
    var buf: [65536]u8 = undefined;
    getRandomBytes(buf[0..@intCast(size)]);
    var i: i32 = 0;
    while (i < size) : (i += 1) {
        const elem = c.newInt32(ctx, @intCast(buf[@intCast(i)]));
        if (c.setPropertyUint32(ctx, argv[0], @intCast(i), elem) < 0) {
            c.freeValue(ctx, elem);
            return c.JS_EXCEPTION;
        }
    }
    // argv is borrowed — must Dup before returning as owned value.
    return c.dupValue(ctx, argv[0]);
}

fn randomUUIDCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    _ = argc;
    _ = argv;
    var uuid_bytes: [16]u8 = undefined;
    getRandomBytes(&uuid_bytes);

    uuid_bytes[6] = (uuid_bytes[6] & 0x0f) | 0x40;
    uuid_bytes[8] = (uuid_bytes[8] & 0x3f) | 0x80;

    var uuid: [36]u8 = undefined;
    const hex = "0123456789abcdef";
    var i: usize = 0;
    var j: usize = 0;
    while (i < 16) : (i += 1) {
        uuid[j] = hex[uuid_bytes[i] >> 4];
        uuid[j + 1] = hex[uuid_bytes[i] & 0x0f];
        j += 2;
        if (i == 3 or i == 5 or i == 7 or i == 9) {
            uuid[j] = '-';
            j += 1;
        }
    }

    return c.newStringLen(ctx, &uuid, 36);
}

fn subtleDigestCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 2) {
        _ = c.throwTypeError(ctx, "subtle.digest requires algorithm and data");
        return c.JS_EXCEPTION;
    }
    var algo_buf: [64]u8 = undefined;
    const algo_ex = extractStringAuto(ctx, argv[0], &algo_buf) orelse {
        _ = c.throwTypeError(ctx, "subtle.digest: invalid algorithm");
        return c.JS_EXCEPTION;
    };
    defer algo_ex.deinit();
    const bytes = backingBytes(ctx, argv[1]) orelse {
        _ = c.throwTypeError(ctx, "subtle.digest: data must be ArrayBuffer or TypedArray");
        return c.JS_EXCEPTION;
    };

    var digest_buf: [64]u8 = undefined;
    var digest_len: usize = 0;
    if (std.ascii.eqlIgnoreCase(algo_ex.slice, "SHA-1")) {
        std.crypto.hash.Sha1.hash(bytes, digest_buf[0..20], .{});
        digest_len = 20;
    } else if (std.ascii.eqlIgnoreCase(algo_ex.slice, "SHA-256")) {
        std.crypto.hash.sha2.Sha256.hash(bytes, digest_buf[0..32], .{});
        digest_len = 32;
    } else if (std.ascii.eqlIgnoreCase(algo_ex.slice, "SHA-384")) {
        std.crypto.hash.sha2.Sha384.hash(bytes, digest_buf[0..48], .{});
        digest_len = 48;
    } else if (std.ascii.eqlIgnoreCase(algo_ex.slice, "SHA-512")) {
        std.crypto.hash.sha2.Sha512.hash(bytes, digest_buf[0..64], .{});
        digest_len = 64;
    } else {
        _ = c.throwTypeError(ctx, "subtle.digest: unsupported algorithm (SHA-1/SHA-256/SHA-384/SHA-512)");
        return c.JS_EXCEPTION;
    }

    var cap: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &cap);
    if (c.isException(promise) != 0) return promise;
    const ab = c.newArrayBufferCopy(ctx, digest_buf[0..digest_len].ptr, digest_len);
    if (c.isException(ab) != 0) {
        c.freeValue(ctx, cap[0]);
        c.freeValue(ctx, cap[1]);
        c.freeValue(ctx, promise);
        return ab;
    }
    var args = [_]c.Value{ab};
    const ret = c.call(ctx, cap[0], c.JS_UNDEFINED, 1, &args);
    if (c.isException(ret) != 0) {
        c.freeValue(ctx, ab);
        c.freeValue(ctx, cap[0]);
        c.freeValue(ctx, cap[1]);
        c.freeValue(ctx, promise);
        return ret;
    }
    c.freeValue(ctx, ret);
    c.freeValue(ctx, ab);
    c.freeValue(ctx, cap[0]);
    c.freeValue(ctx, cap[1]);
    return promise;
}

fn btoaCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    var buf: [512]u8 = undefined;
    const input = extractStringAuto(ctx, if (argc > 0) argv[0] else c.JS_UNDEFINED, &buf) orelse return c.JS_EXCEPTION;
    defer input.deinit();
    const enc = std.base64.standard.Encoder;
    const out_len = enc.calcSize(input.slice.len);
    const out = gpa.alloc(u8, out_len) catch return c.throwOutOfMemory(ctx);
    defer gpa.free(out);
    _ = enc.encode(out, input.slice);
    return c.newStringLen(ctx, out.ptr, out_len);
}

fn atobCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    var buf: [512]u8 = undefined;
    const input = extractStringAuto(ctx, if (argc > 0) argv[0] else c.JS_UNDEFINED, &buf) orelse return c.JS_EXCEPTION;
    defer input.deinit();
    const dec = std.base64.standard.Decoder;
    const out_len = dec.calcSizeForSlice(input.slice) catch {
        _ = c.throwTypeError(ctx, "atob: invalid base64 input");
        return c.JS_EXCEPTION;
    };
    const out = gpa.alloc(u8, out_len) catch return c.throwOutOfMemory(ctx);
    defer gpa.free(out);
    dec.decode(out, input.slice) catch {
        _ = c.throwTypeError(ctx, "atob: invalid base64 input");
        return c.JS_EXCEPTION;
    };
    return c.newStringLen(ctx, out.ptr, out_len);
}

pub fn setup(ctx: *c.Context) void {
    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);
    const crypto_obj = c.newObject(ctx);

    const getRandomValues_fn = c.newCFunction(ctx, getRandomValuesCallback, "getRandomValues", 1);
    _ = c.definePropertyValueStr(ctx, crypto_obj, "getRandomValues", getRandomValues_fn, c.PROP_C_W_E);

    const randomUUID_fn = c.newCFunction(ctx, randomUUIDCallback, "randomUUID", 0);
    _ = c.definePropertyValueStr(ctx, crypto_obj, "randomUUID", randomUUID_fn, c.PROP_C_W_E);

    const subtle_obj = c.newObject(ctx);
    const digest_fn = c.newCFunction(ctx, subtleDigestCallback, "digest", 2);
    _ = c.definePropertyValueStr(ctx, subtle_obj, "digest", digest_fn, c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, crypto_obj, "subtle", subtle_obj, c.PROP_C_W_E);

    const btoa_fn = c.newCFunction(ctx, btoaCallback, "btoa", 1);
    _ = c.definePropertyValueStr(ctx, global, "btoa", btoa_fn, c.PROP_C_W_E);

    const atob_fn = c.newCFunction(ctx, atobCallback, "atob", 1);
    _ = c.definePropertyValueStr(ctx, global, "atob", atob_fn, c.PROP_C_W_E);

    _ = c.definePropertyValueStr(ctx, global, "crypto", crypto_obj, c.PROP_C_W_E);
}
