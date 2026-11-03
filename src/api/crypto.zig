const std = @import("std");
const c = @import("../c.zig").c;

const gpa = std.heap.smp_allocator;

var crypto_key_class_id: c.ClassID = 0;

const HashAlgo = enum(u8) {
    sha1,
    sha256,
    sha384,
    sha512,

    fn fromSlice(s: []const u8) ?HashAlgo {
        if (std.ascii.eqlIgnoreCase(s, "SHA-1")) return .sha1;
        if (std.ascii.eqlIgnoreCase(s, "SHA-256")) return .sha256;
        if (std.ascii.eqlIgnoreCase(s, "SHA-384")) return .sha384;
        if (std.ascii.eqlIgnoreCase(s, "SHA-512")) return .sha512;
        return null;
    }

    fn name(self: HashAlgo) []const u8 {
        return switch (self) {
            .sha1 => "SHA-1",
            .sha256 => "SHA-256",
            .sha384 => "SHA-384",
            .sha512 => "SHA-512",
        };
    }

    fn digestLen(self: HashAlgo) usize {
        return switch (self) {
            .sha1 => 20,
            .sha256 => 32,
            .sha384 => 48,
            .sha512 => 64,
        };
    }
};

const CryptoKeyData = struct {
    key_inline: [128]u8 = undefined,
    key_heap: ?[]u8 = null,
    key_len: usize = 0,
    hash: HashAlgo = .sha256,
    extractable: bool = false,
    can_sign: bool = false,
    can_verify: bool = false,

    fn keySlice(self: *const CryptoKeyData) []const u8 {
        if (self.key_heap) |h| return h;
        return self.key_inline[0..self.key_len];
    }

    fn deinit(self: *CryptoKeyData) void {
        if (self.key_heap) |h| {
            std.crypto.secureZero(u8, h);
            gpa.free(h);
            self.key_heap = null;
        }
        std.crypto.secureZero(u8, &self.key_inline);
    }
};

fn cryptoKeyFinalizer(_: ?*c.Runtime, val: c.Value) callconv(.c) void {
    const ptr = c.getOpaque(val, crypto_key_class_id) orelse return;
    const data: *CryptoKeyData = @ptrCast(@alignCast(ptr));
    data.deinit();
    gpa.destroy(data);
}

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
    // Fast batch path: Uint8Array — fill backing store in one call.
    var direct_size: usize = 0;
    if (c.getUint8Array(ctx, &direct_size, argv[0])) |dst| {
        if (direct_size == 0 or direct_size > 65536) {
            if (c.hasException(ctx)) {
                const exc = c.getException(ctx);
                c.freeValue(ctx, exc);
            }
            _ = c.throwTypeError(ctx, "getRandomValues: max 65536 bytes");
            return c.JS_EXCEPTION;
        }
        getRandomBytes(dst[0..direct_size]);
        return c.dupValue(ctx, argv[0]);
    }
    if (c.hasException(ctx)) {
        const exc = c.getException(ctx);
        c.freeValue(ctx, exc);
    }
    // Cold fallback: generic length-based fill (non-Uint8 views).
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
    // Stack-first chunked fill: 512B window, batched SetProperty calls,
    // no 64KB frame. Size cap keeps this loop off any hot path.
    var chunk: [512]u8 = undefined;
    var off: i32 = 0;
    while (off < size) {
        const n: usize = @min(chunk.len, @as(usize, @intCast(size - off)));
        getRandomBytes(chunk[0..n]);
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const elem = c.newInt32(ctx, chunk[k]);
            if (c.setPropertyUint32(ctx, argv[0], @intCast(off + @as(i32, @intCast(k))), elem) < 0) {
                c.freeValue(ctx, elem);
                return c.JS_EXCEPTION;
            }
        }
        off += @intCast(n);
    }
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

fn resolvePromiseWithValue(ctx: ?*c.Context, val: c.Value) c.Value {
    var cap: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &cap);
    if (c.isException(promise) != 0) {
        c.freeValue(ctx, val);
        return promise;
    }
    var args = [_]c.Value{val};
    const ret = c.call(ctx, cap[0], c.JS_UNDEFINED, 1, &args);
    c.freeValue(ctx, val);
    c.freeValue(ctx, cap[0]);
    c.freeValue(ctx, cap[1]);
    if (c.isException(ret) != 0) {
        c.freeValue(ctx, promise);
        return ret;
    }
    c.freeValue(ctx, ret);
    return promise;
}

fn parseHashAlgoVal(ctx: ?*c.Context, val: c.Value) ?HashAlgo {
    var buf: [64]u8 = undefined;
    if (c.isString(val) != 0) {
        const ex = extractStringAuto(ctx, val, &buf) orelse return null;
        defer ex.deinit();
        return HashAlgo.fromSlice(ex.slice);
    }
    if (c.isObject(val) != 0) {
        const name_val = c.getPropertyStr(ctx, val, "name");
        defer c.freeValue(ctx, name_val);
        if (c.isString(name_val) == 0) return null;
        const ex = extractStringAuto(ctx, name_val, &buf) orelse return null;
        defer ex.deinit();
        return HashAlgo.fromSlice(ex.slice);
    }
    return null;
}

fn checkHmacAlgo(ctx: ?*c.Context, val: c.Value) bool {
    var buf: [64]u8 = undefined;
    if (c.isString(val) != 0) {
        const ex = extractStringAuto(ctx, val, &buf) orelse return false;
        defer ex.deinit();
        return std.ascii.eqlIgnoreCase(ex.slice, "HMAC");
    }
    if (c.isObject(val) != 0) {
        const name_val = c.getPropertyStr(ctx, val, "name");
        defer c.freeValue(ctx, name_val);
        if (c.isString(name_val) == 0) return false;
        const ex = extractStringAuto(ctx, name_val, &buf) orelse return false;
        defer ex.deinit();
        return std.ascii.eqlIgnoreCase(ex.slice, "HMAC");
    }
    return false;
}

/// When the caller passes { name: "HMAC", hash: ... }, the requested hash must
/// match the key's hash. A bare "HMAC" or {name:"HMAC"} is allowed and uses
/// the key's hash, which is what the WebCrypto normalization permits.
fn hmacAlgoHashMatches(ctx: ?*c.Context, val: c.Value, key_hash: HashAlgo) bool {
    if (c.isObject(val) == 0) return true;
    const hash_val = c.getPropertyStr(ctx, val, "hash");
    defer c.freeValue(ctx, hash_val);
    if (c.isUndefined(hash_val) != 0 or c.isNull(hash_val) != 0) return true;
    const requested = parseHashAlgoVal(ctx, hash_val) orelse return false;
    return requested == key_hash;
}

fn computeHmac(hash: HashAlgo, key: []const u8, msg: []const u8, out: *[64]u8) usize {
    switch (hash) {
        .sha1 => {
            std.crypto.auth.hmac.HmacSha1.create(out[0..20], msg, key);
            return 20;
        },
        .sha256 => {
            std.crypto.auth.hmac.sha2.HmacSha256.create(out[0..32], msg, key);
            return 32;
        },
        .sha384 => {
            std.crypto.auth.hmac.sha2.HmacSha384.create(out[0..48], msg, key);
            return 48;
        },
        .sha512 => {
            std.crypto.auth.hmac.sha2.HmacSha512.create(out[0..64], msg, key);
            return 64;
        },
    }
}

fn subtleDigestCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 2) {
        _ = c.throwTypeError(ctx, "subtle.digest requires algorithm and data");
        return c.JS_EXCEPTION;
    }
    const hash = parseHashAlgoVal(ctx, argv[0]) orelse {
        if (c.hasException(ctx)) return c.JS_EXCEPTION;
        _ = c.throwTypeError(ctx, "subtle.digest: unsupported algorithm (SHA-1/SHA-256/SHA-384/SHA-512)");
        return c.JS_EXCEPTION;
    };
    const bytes = backingBytes(ctx, argv[1]) orelse {
        _ = c.throwTypeError(ctx, "subtle.digest: data must be ArrayBuffer or TypedArray");
        return c.JS_EXCEPTION;
    };

    var digest_buf: [64]u8 = undefined;
    const digest_len = hash.digestLen();
    switch (hash) {
        .sha1 => std.crypto.hash.Sha1.hash(bytes, digest_buf[0..20], .{}),
        .sha256 => std.crypto.hash.sha2.Sha256.hash(bytes, digest_buf[0..32], .{}),
        .sha384 => std.crypto.hash.sha2.Sha384.hash(bytes, digest_buf[0..48], .{}),
        .sha512 => std.crypto.hash.sha2.Sha512.hash(bytes, digest_buf[0..64], .{}),
    }

    const ab = c.newArrayBufferCopy(ctx, digest_buf[0..digest_len].ptr, digest_len);
    if (c.isException(ab) != 0) return ab;
    return resolvePromiseWithValue(ctx, ab);
}

fn subtleImportKeyCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 5) {
        _ = c.throwTypeError(ctx, "subtle.importKey requires (format, keyData, algorithm, extractable, keyUsages)");
        return c.JS_EXCEPTION;
    }
    var fmt_buf: [32]u8 = undefined;
    if (c.isString(argv[0]) == 0) {
        _ = c.throwTypeError(ctx, "subtle.importKey: format must be 'raw'");
        return c.JS_EXCEPTION;
    }
    const fmt_ex = extractStringAuto(ctx, argv[0], &fmt_buf) orelse return c.JS_EXCEPTION;
    defer fmt_ex.deinit();
    if (!std.mem.eql(u8, fmt_ex.slice, "raw")) {
        _ = c.throwTypeError(ctx, "subtle.importKey: only 'raw' format is supported");
        return c.JS_EXCEPTION;
    }

    const key_bytes = backingBytes(ctx, argv[1]) orelse {
        _ = c.throwTypeError(ctx, "subtle.importKey: keyData must be ArrayBuffer or TypedArray");
        return c.JS_EXCEPTION;
    };
    if (key_bytes.len == 0) {
        _ = c.throwTypeError(ctx, "subtle.importKey: keyData must not be empty");
        return c.JS_EXCEPTION;
    }

    if (!checkHmacAlgo(ctx, argv[2])) {
        _ = c.throwTypeError(ctx, "subtle.importKey: algorithm must be 'HMAC' or { name: 'HMAC', hash: 'SHA-...' }");
        return c.JS_EXCEPTION;
    }
    const hash: HashAlgo = if (c.isObject(argv[2]) != 0) blk: {
        const hash_prop = c.getPropertyStr(ctx, argv[2], "hash");
        defer c.freeValue(ctx, hash_prop);
        if (c.isUndefined(hash_prop) != 0) break :blk .sha256;
        break :blk parseHashAlgoVal(ctx, hash_prop) orelse {
            _ = c.throwTypeError(ctx, "subtle.importKey: unsupported HMAC hash (SHA-1/SHA-256/SHA-384/SHA-512)");
            return c.JS_EXCEPTION;
        };
    } else .sha256;

    const extractable = c.toBool(ctx, argv[3]) > 0;

    if (c.isArray(ctx, argv[4]) == 0) {
        _ = c.throwTypeError(ctx, "subtle.importKey: keyUsages must be an array");
        return c.JS_EXCEPTION;
    }
    const len_val = c.getPropertyStr(ctx, argv[4], "length");
    defer c.freeValue(ctx, len_val);
    var usages_len: i32 = 0;
    if (c.toInt32(ctx, &usages_len, len_val) != 0 or usages_len <= 0 or usages_len > 16) {
        _ = c.throwTypeError(ctx, "subtle.importKey: keyUsages must be a non-empty array");
        return c.JS_EXCEPTION;
    }

    var can_sign = false;
    var can_verify = false;
    var u_idx: u32 = 0;
    while (u_idx < @as(u32, @intCast(usages_len))) : (u_idx += 1) {
        const u_val = c.getPropertyUint32(ctx, argv[4], u_idx);
        defer c.freeValue(ctx, u_val);
        if (c.isString(u_val) == 0) {
            _ = c.throwTypeError(ctx, "subtle.importKey: invalid key usage");
            return c.JS_EXCEPTION;
        }
        var u_buf: [32]u8 = undefined;
        const u_ex = extractStringAuto(ctx, u_val, &u_buf) orelse return c.JS_EXCEPTION;
        defer u_ex.deinit();
        if (std.mem.eql(u8, u_ex.slice, "sign")) {
            can_sign = true;
        } else if (std.mem.eql(u8, u_ex.slice, "verify")) {
            can_verify = true;
        } else {
            _ = c.throwTypeError(ctx, "subtle.importKey: HMAC only supports 'sign' and 'verify' usages");
            return c.JS_EXCEPTION;
        }
    }

    const key_data = gpa.create(CryptoKeyData) catch return c.throwOutOfMemory(ctx);
    key_data.* = .{
        .key_len = key_bytes.len,
        .hash = hash,
        .extractable = extractable,
        .can_sign = can_sign,
        .can_verify = can_verify,
    };
    if (key_bytes.len <= key_data.key_inline.len) {
        @memcpy(key_data.key_inline[0..key_bytes.len], key_bytes);
    } else {
        key_data.key_heap = gpa.dupe(u8, key_bytes) catch {
            gpa.destroy(key_data);
            return c.throwOutOfMemory(ctx);
        };
    }

    const key_obj = c.newObjectClass(ctx, @intCast(crypto_key_class_id));
    if (c.isException(key_obj) != 0) {
        key_data.deinit();
        gpa.destroy(key_data);
        return key_obj;
    }
    c.setOpaque(key_obj, key_data);

    _ = c.definePropertyValueStr(ctx, key_obj, "type", c.newStringLen(ctx, "secret", 6), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, key_obj, "extractable", if (extractable) c.JS_TRUE else c.JS_FALSE, c.PROP_C_W_E);

    const algo_obj = c.newObject(ctx);
    _ = c.definePropertyValueStr(ctx, algo_obj, "name", c.newStringLen(ctx, "HMAC", 4), c.PROP_C_W_E);
    const hash_obj = c.newObject(ctx);
    const hname = hash.name();
    _ = c.definePropertyValueStr(ctx, hash_obj, "name", c.newStringLen(ctx, hname.ptr, hname.len), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, algo_obj, "hash", hash_obj, c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, algo_obj, "length", c.newInt64(ctx, @intCast(key_bytes.len * 8)), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, key_obj, "algorithm", algo_obj, c.PROP_C_W_E);

    const usages_arr = c.newArray(ctx);
    var out_idx: u32 = 0;
    if (can_sign) {
        _ = c.definePropertyValueUint32(ctx, usages_arr, out_idx, c.newStringLen(ctx, "sign", 4), c.PROP_C_W_E);
        out_idx += 1;
    }
    if (can_verify) {
        _ = c.definePropertyValueUint32(ctx, usages_arr, out_idx, c.newStringLen(ctx, "verify", 6), c.PROP_C_W_E);
    }
    _ = c.definePropertyValueStr(ctx, key_obj, "usages", usages_arr, c.PROP_C_W_E);

    return resolvePromiseWithValue(ctx, key_obj);
}

fn subtleSignCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 3) {
        _ = c.throwTypeError(ctx, "subtle.sign requires (algorithm, key, data)");
        return c.JS_EXCEPTION;
    }
    if (!checkHmacAlgo(ctx, argv[0])) {
        _ = c.throwTypeError(ctx, "subtle.sign: unsupported algorithm (expected HMAC)");
        return c.JS_EXCEPTION;
    }
    const ptr = c.getOpaque2(ctx, argv[1], crypto_key_class_id) orelse {
        _ = c.throwTypeError(ctx, "subtle.sign: key must be a CryptoKey");
        return c.JS_EXCEPTION;
    };
    const key_data: *CryptoKeyData = @ptrCast(@alignCast(ptr));
    if (!key_data.can_sign) {
        _ = c.throwTypeError(ctx, "subtle.sign: key does not support 'sign' usage");
        return c.JS_EXCEPTION;
    }
    if (!hmacAlgoHashMatches(ctx, argv[0], key_data.hash)) {
        _ = c.throwTypeError(ctx, "subtle.sign: algorithm hash does not match key");
        return c.JS_EXCEPTION;
    }
    const bytes = backingBytes(ctx, argv[2]) orelse {
        _ = c.throwTypeError(ctx, "subtle.sign: data must be ArrayBuffer or TypedArray");
        return c.JS_EXCEPTION;
    };

    var mac_buf: [64]u8 = undefined;
    const mac_len = computeHmac(key_data.hash, key_data.keySlice(), bytes, &mac_buf);
    const ab = c.newArrayBufferCopy(ctx, mac_buf[0..mac_len].ptr, mac_len);
    if (c.isException(ab) != 0) return ab;
    return resolvePromiseWithValue(ctx, ab);
}

fn subtleVerifyCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 4) {
        _ = c.throwTypeError(ctx, "subtle.verify requires (algorithm, key, signature, data)");
        return c.JS_EXCEPTION;
    }
    if (!checkHmacAlgo(ctx, argv[0])) {
        _ = c.throwTypeError(ctx, "subtle.verify: unsupported algorithm (expected HMAC)");
        return c.JS_EXCEPTION;
    }
    const ptr = c.getOpaque2(ctx, argv[1], crypto_key_class_id) orelse {
        _ = c.throwTypeError(ctx, "subtle.verify: key must be a CryptoKey");
        return c.JS_EXCEPTION;
    };
    const key_data: *CryptoKeyData = @ptrCast(@alignCast(ptr));
    if (!key_data.can_verify) {
        _ = c.throwTypeError(ctx, "subtle.verify: key does not support 'verify' usage");
        return c.JS_EXCEPTION;
    }
    if (!hmacAlgoHashMatches(ctx, argv[0], key_data.hash)) {
        _ = c.throwTypeError(ctx, "subtle.verify: algorithm hash does not match key");
        return c.JS_EXCEPTION;
    }
    const sig_bytes = backingBytes(ctx, argv[2]) orelse {
        _ = c.throwTypeError(ctx, "subtle.verify: signature must be ArrayBuffer or TypedArray");
        return c.JS_EXCEPTION;
    };
    const data_bytes = backingBytes(ctx, argv[3]) orelse {
        _ = c.throwTypeError(ctx, "subtle.verify: data must be ArrayBuffer or TypedArray");
        return c.JS_EXCEPTION;
    };

    var mac_buf: [64]u8 = undefined;
    _ = computeHmac(key_data.hash, key_data.keySlice(), data_bytes, &mac_buf);
    const valid = switch (key_data.hash) {
        .sha1 => sig_bytes.len == 20 and std.crypto.timing_safe.eql([20]u8, mac_buf[0..20].*, sig_bytes[0..20].*),
        .sha256 => sig_bytes.len == 32 and std.crypto.timing_safe.eql([32]u8, mac_buf[0..32].*, sig_bytes[0..32].*),
        .sha384 => sig_bytes.len == 48 and std.crypto.timing_safe.eql([48]u8, mac_buf[0..48].*, sig_bytes[0..48].*),
        .sha512 => sig_bytes.len == 64 and std.crypto.timing_safe.eql([64]u8, mac_buf[0..64].*, sig_bytes[0..64].*),
    };
    return resolvePromiseWithValue(ctx, if (valid) c.JS_TRUE else c.JS_FALSE);
}

fn subtleExportKeyCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 2) {
        _ = c.throwTypeError(ctx, "subtle.exportKey requires (format, key)");
        return c.JS_EXCEPTION;
    }
    var fmt_buf: [32]u8 = undefined;
    if (c.isString(argv[0]) == 0) {
        _ = c.throwTypeError(ctx, "subtle.exportKey: format must be 'raw'");
        return c.JS_EXCEPTION;
    }
    const fmt_ex = extractStringAuto(ctx, argv[0], &fmt_buf) orelse return c.JS_EXCEPTION;
    defer fmt_ex.deinit();
    if (!std.mem.eql(u8, fmt_ex.slice, "raw")) {
        _ = c.throwTypeError(ctx, "subtle.exportKey: only 'raw' format is supported");
        return c.JS_EXCEPTION;
    }
    const ptr = c.getOpaque2(ctx, argv[1], crypto_key_class_id) orelse {
        _ = c.throwTypeError(ctx, "subtle.exportKey: key must be a CryptoKey");
        return c.JS_EXCEPTION;
    };
    const key_data: *CryptoKeyData = @ptrCast(@alignCast(ptr));
    if (!key_data.extractable) {
        _ = c.throwTypeError(ctx, "subtle.exportKey: key is not extractable");
        return c.JS_EXCEPTION;
    }
    const raw = key_data.keySlice();
    const ab = c.newArrayBufferCopy(ctx, raw.ptr, raw.len);
    if (c.isException(ab) != 0) return ab;
    return resolvePromiseWithValue(ctx, ab);
}

fn btoaCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    var buf: [512]u8 = undefined;
    const input = extractStringAuto(ctx, if (argc > 0) argv[0] else c.JS_UNDEFINED, &buf) orelse return c.JS_EXCEPTION;
    defer input.deinit();
    const enc = std.base64.standard.Encoder;
    const out_len = enc.calcSize(input.slice.len);
    // FIX (DOD §7): stack-first output. A 512B stack input encodes to at
    // most 684B, so any input that fit the stack input buffer also fits the
    // 1024B stack output; heap input spills to a heap output as before.
    var stack_out: [1024]u8 = undefined;
    if (out_len <= stack_out.len) {
        _ = enc.encode(stack_out[0..out_len], input.slice);
        return c.newStringLen(ctx, stack_out[0..out_len].ptr, out_len);
    }
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
    // FIX (DOD §7): stack-first output. Decoded output is always shorter
    // than its base64 input, so any stack-fit input decodes into the stack.
    var stack_out: [512]u8 = undefined;
    if (out_len <= stack_out.len) {
        dec.decode(stack_out[0..out_len], input.slice) catch {
            _ = c.throwTypeError(ctx, "atob: invalid base64 input");
            return c.JS_EXCEPTION;
        };
        return c.newStringLen(ctx, stack_out[0..out_len].ptr, out_len);
    }
    const out = gpa.alloc(u8, out_len) catch return c.throwOutOfMemory(ctx);
    defer gpa.free(out);
    dec.decode(out, input.slice) catch {
        _ = c.throwTypeError(ctx, "atob: invalid base64 input");
        return c.JS_EXCEPTION;
    };
    return c.newStringLen(ctx, out.ptr, out_len);
}

pub fn setup(ctx: *c.Context) void {
    const rt = c.getRuntime(ctx);
    var key_def = c.ClassDef{
        .class_name = "CryptoKey",
        .finalizer = cryptoKeyFinalizer,
    };
    _ = c.newClassID(rt, &crypto_key_class_id);
    _ = c.newClass(rt, crypto_key_class_id, &key_def);

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
    const importKey_fn = c.newCFunction(ctx, subtleImportKeyCallback, "importKey", 5);
    _ = c.definePropertyValueStr(ctx, subtle_obj, "importKey", importKey_fn, c.PROP_C_W_E);
    const sign_fn = c.newCFunction(ctx, subtleSignCallback, "sign", 3);
    _ = c.definePropertyValueStr(ctx, subtle_obj, "sign", sign_fn, c.PROP_C_W_E);
    const verify_fn = c.newCFunction(ctx, subtleVerifyCallback, "verify", 4);
    _ = c.definePropertyValueStr(ctx, subtle_obj, "verify", verify_fn, c.PROP_C_W_E);
    const exportKey_fn = c.newCFunction(ctx, subtleExportKeyCallback, "exportKey", 2);
    _ = c.definePropertyValueStr(ctx, subtle_obj, "exportKey", exportKey_fn, c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, crypto_obj, "subtle", subtle_obj, c.PROP_C_W_E);

    const btoa_fn = c.newCFunction(ctx, btoaCallback, "btoa", 1);
    _ = c.definePropertyValueStr(ctx, global, "btoa", btoa_fn, c.PROP_C_W_E);

    const atob_fn = c.newCFunction(ctx, atobCallback, "atob", c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, global, "atob", atob_fn, c.PROP_C_W_E);

    _ = c.definePropertyValueStr(ctx, global, "crypto", crypto_obj, c.PROP_C_W_E);
}
