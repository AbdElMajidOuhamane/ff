const std = @import("std");
const c = @import("../c.zig").c;
const builtin = @import("builtin");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha384 = std.crypto.hash.sha2.Sha384;
const Sha512 = std.crypto.hash.sha2.Sha512;
const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const HmacSha384 = std.crypto.auth.hmac.sha2.HmacSha384;
const HmacSha512 = std.crypto.auth.hmac.sha2.HmacSha512;

// Thread-safe general-purpose allocator: no mmap/munmap syscall pair per
// allocation (mirrors fetch.zig's rationale).
const gpa = std.heap.smp_allocator;

extern fn std__shared_ptr__v8__BackingStore__get(self: *const c.SharedPtr) callconv(.c) ?*c.BackingStore;
extern "c" fn arc4random_buf(buf: [*]u8, len: usize) void;

// ---- V8 property-key/value globals (rooted once in setup): every subtle.*
// callback used to recreate these identical strings on each call. ----
var str_name: c.Global = .{ .data_ptr = 0 };
var str_data: c.Global = .{ .data_ptr = 0 };
var str_salt: c.Global = .{ .data_ptr = 0 };
var str_type: c.Global = .{ .data_ptr = 0 };
var str_algorithm: c.Global = .{ .data_ptr = 0 };
var str_extractable: c.Global = .{ .data_ptr = 0 };
// static VALUE strings handed to property setters
var str_secret: c.Global = .{ .data_ptr = 0 };
var str_aes_gcm: c.Global = .{ .data_ptr = 0 };
var str_hmac: c.Global = .{ .data_ptr = 0 };

fn throw(isolate: ?*c.Isolate, msg: []const u8) void {
    const v8_msg = c.v8__String__NewFromUtf8(isolate, @ptrCast(msg.ptr), 0, @intCast(msg.len));
    const exc = c.v8__Exception__Error(v8_msg);
    _ = c.v8__Isolate__ThrowException(isolate, exc);
}

fn zigStringToV8(isolate: ?*c.Isolate, str: []const u8) *const c.Value {
    return @ptrCast(c.v8__String__NewFromUtf8(isolate, @ptrCast(str.ptr), 0, @intCast(str.len)));
}

/// Cached-Global accessor with an inline fallback so a missing root can
/// never turn a hot path into a null-deref.
fn globalStr(g: *c.Global, isolate: ?*c.Isolate, comptime fallback: []const u8) *const c.Value {
    return @ptrCast(c.v8__Global__Get(g, isolate) orelse zigStringToV8(isolate, fallback));
}

fn getBackingStoreData(isolate: ?*c.Isolate, val: *const c.Value) ?struct { ptr: [*]u8, len: usize } {
    _ = isolate;
    const ab = if (c.v8__Value__IsArrayBuffer(val))
        @as(?*const c.ArrayBuffer, @ptrCast(val))
    else if (c.v8__Value__IsArrayBufferView(val))
        c.v8__ArrayBufferView__Buffer(@ptrCast(val))
    else
        return null;

    var store = c.v8__ArrayBuffer__GetBackingStore(ab);
    const backing = std__shared_ptr__v8__BackingStore__get(&store) orelse return null;
    const data = @as(?[*]u8, @ptrCast(c.v8__BackingStore__Data(backing)));
    const byte_len = c.v8__BackingStore__ByteLength(backing);
    if (data == null or byte_len == 0) return null;
    return .{ .ptr = data.?, .len = byte_len };
}

fn createArrayBuffer(isolate: ?*c.Isolate, data: []const u8) *const c.Value {
    const ab = c.v8__ArrayBuffer__New(isolate, data.len);
    const store = c.v8__ArrayBuffer__GetBackingStore(ab);
    const backing = std__shared_ptr__v8__BackingStore__get(&store);
    if (backing) |bs| {
        const dest = @as(?[*]u8, @ptrCast(c.v8__BackingStore__Data(bs)));
        if (dest) |d| {
            @memcpy(d[0..data.len], data);
        }
    }
    return @ptrCast(ab);
}

fn resolvePromiseWithBuffer(isolate: ?*c.Isolate, context: ?*c.Context, resolver: *const c.PromiseResolver, data: []const u8) void {
    var out: c.MaybeBool = undefined;
    const ab_val = createArrayBuffer(isolate, data);
    c.v8__Promise__Resolver__Resolve(resolver, context, ab_val, &out);
}

fn rejectPromiseWithError(isolate: ?*c.Isolate, context: ?*c.Context, resolver: *const c.PromiseResolver, msg: []const u8) void {
    var out: c.MaybeBool = undefined;
    const err_val = zigStringToV8(isolate, msg);
    c.v8__Promise__Resolver__Reject(resolver, context, err_val, &out);
}

/// Reject-and-return-the-promise epilogue shared by subtle.* early-exit
/// paths (replaces seven repeated 5-line blocks).
fn rejectAndReturn(info: ?*const c.FunctionCallbackInfo, isolate: ?*c.Isolate, context: ?*c.Context, resolver: *const c.PromiseResolver, msg: []const u8) void {
    rejectPromiseWithError(isolate, context, resolver, msg);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Promise__Resolver__GetPromise(resolver)));
}

/// Extracts an algorithm/format NAME into the CALLER-provided buffer and
/// returns a borrowed slice — zero heap allocations. Names are short spec
/// tokens ("SHA-256", "AES-GCM", "raw"); anything longer than the buffer
/// simply fails the downstream equality checks and is rejected.
fn extractStrBuf(isolate: ?*c.Isolate, val: *const c.Value, buf: []u8) ?[]const u8 {
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    const str = c.v8__Value__ToDetailString(val, context);
    if (str == null) return null;
    const utf8_len: usize = @intCast(c.v8__String__Utf8Length(str, isolate));
    const len = @min(utf8_len, buf.len);
    _ = c.v8__String__WriteUtf8(str, isolate, buf.ptr, @intCast(len), 0);
    return buf[0..len];
}

fn getAlgoName(isolate: ?*c.Isolate, algo_val: *const c.Value, buf: []u8) ?[]const u8 {
    if (c.v8__Value__IsString(algo_val)) {
        return extractStrBuf(isolate, algo_val, buf);
    }
    if (c.v8__Value__IsObject(algo_val)) {
        const context = c.v8__Isolate__GetCurrentContext(isolate);
        const name_val = c.v8__Object__Get(@ptrCast(algo_val), context, globalStr(&str_name, isolate, "name"));
        if (name_val != null and c.v8__Value__IsString(name_val)) {
            return extractStrBuf(isolate, name_val.?, buf);
        }
    }
    return null;
}

fn getRandomBytes(buf: []u8) void {
    switch (builtin.os.tag) {
        .linux => {
            var off: usize = 0;
            while (off < buf.len) {
                const n = std.c.getrandom(buf.ptr + off, buf.len - off, 0);
                if (n < 0) {
                    // Retry only on EINTR; anything else falls back once to
                    // the CSPRNG instead of spinning forever.
                    if (std.posix.errno(n) == .INTR) continue;
                    std.crypto.random.bytes(buf[off..]);
                    return;
                }
                off += @intCast(n);
            }
        },
        else => arc4random_buf(buf.ptr, buf.len),
    }
}

fn getRandomValuesCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    if (c.v8__FunctionCallbackInfo__Length(info) < 1) {
        throw(isolate, "getRandomValues requires a TypedArray argument");
        return;
    }
    const val = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    if (!c.v8__Value__IsArrayBufferView(val)) {
        throw(isolate, "argument must be a TypedArray");
        return;
    }

    const view = @as(*const c.ArrayBufferView, @ptrCast(val));
    const byte_len = c.v8__ArrayBufferView__ByteLength(view);
    const ab = c.v8__ArrayBufferView__Buffer(view);
    const store = c.v8__ArrayBuffer__GetBackingStore(ab);
    const backing = std__shared_ptr__v8__BackingStore__get(&store);
    if (backing) |bs| {
        const data = @as(?[*]u8, @ptrCast(c.v8__BackingStore__Data(bs)));
        if (data) |d| {
            getRandomBytes(d[0..byte_len]);
        }
    }

    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, val);
}

fn randomUUIDCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
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

    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, zigStringToV8(isolate, &uuid));
}

/// Shared CryptoKey-object builder for generateKey/importKey/deriveKey:
/// attaches rooted strings in one place (was: five inline recreations per
/// branch). Pass algo_value=null for deriveKey's bare secret key.
fn buildCryptoKeyObject(
    isolate: ?*c.Isolate,
    context: ?*c.Context,
    algo_value: ?*const c.Value,
) ?*const c.Value {
    const key_obj = c.v8__Object__New(isolate) orelse return null;
    var out: c.MaybeBool = undefined;
    c.v8__Object__Set(key_obj, context, globalStr(&str_type, isolate, "type"), globalStr(&str_secret, isolate, "secret"), &out);
    if (algo_value) |av| {
        const algo_obj = c.v8__Object__New(isolate) orelse return null;
        c.v8__Object__Set(algo_obj, context, globalStr(&str_name, isolate, "name"), av, &out);
        c.v8__Object__Set(key_obj, context, globalStr(&str_algorithm, isolate, "algorithm"), algo_obj, &out);
    }
    c.v8__Object__Set(key_obj, context, globalStr(&str_extractable, isolate, "extractable"), @ptrCast(c.v8__True(isolate)), &out);
    return key_obj;
}

fn subtleDigestCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);

    if (c.v8__FunctionCallbackInfo__Length(info) < 2) {
        throw(isolate, "subtle.digest requires algorithm and data");
        return;
    }

    const algo_val = c.v8__FunctionCallbackInfo__INDEX(info, 0).?;
    const data_val = c.v8__FunctionCallbackInfo__INDEX(info, 1).?;

    var name_buf: [64]u8 = undefined;
    const algo_name = getAlgoName(isolate, algo_val, &name_buf) orelse {
        throw(isolate, "invalid algorithm");
        return;
    };

    const bs = getBackingStoreData(isolate, data_val) orelse {
        throw(isolate, "invalid data");
        return;
    };

    const resolver = c.v8__Promise__Resolver__New(context).?;

    if (std.mem.eql(u8, algo_name, "SHA-256")) {
        var out: [32]u8 = undefined;
        Sha256.hash(bs.ptr[0..bs.len], &out, .{});
        resolvePromiseWithBuffer(isolate, context, resolver, &out);
    } else if (std.mem.eql(u8, algo_name, "SHA-384")) {
        var out: [48]u8 = undefined;
        Sha384.hash(bs.ptr[0..bs.len], &out, .{});
        resolvePromiseWithBuffer(isolate, context, resolver, &out);
    } else if (std.mem.eql(u8, algo_name, "SHA-512")) {
        var out: [64]u8 = undefined;
        Sha512.hash(bs.ptr[0..bs.len], &out, .{});
        resolvePromiseWithBuffer(isolate, context, resolver, &out);
    } else {
        rejectPromiseWithError(isolate, context, resolver, "unsupported hash algorithm");
    }

    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Promise__Resolver__GetPromise(resolver)));
}

fn subtleGenerateKeyCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);

    if (c.v8__FunctionCallbackInfo__Length(info) < 1) {
        throw(isolate, "generateKey requires an algorithm");
        return;
    }

    const algo_val = c.v8__FunctionCallbackInfo__INDEX(info, 0).?;

    var name_buf: [64]u8 = undefined;
    const algo_name = getAlgoName(isolate, algo_val, &name_buf) orelse {
        throw(isolate, "invalid algorithm");
        return;
    };

    const resolver = c.v8__Promise__Resolver__New(context).?;

    if (std.mem.eql(u8, algo_name, "AES-GCM") or std.mem.eql(u8, algo_name, "HMAC")) {
        var key_data: [32]u8 = undefined;
        getRandomBytes(&key_data);
        const ab_val = createArrayBuffer(isolate, &key_data);

        const algo_value: *const c.Value = if (algo_name[0] == 'A')
            globalStr(&str_aes_gcm, isolate, "AES-GCM")
        else
            globalStr(&str_hmac, isolate, "HMAC");

        const key_obj = buildCryptoKeyObject(isolate, context, algo_value) orelse {
            rejectAndReturn(info, isolate, context, resolver, "allocation failed");
            return;
        };
        var out: c.MaybeBool = undefined;
        c.v8__Object__Set(key_obj, context, globalStr(&str_data, isolate, "data"), ab_val, &out);
        c.v8__Promise__Resolver__Resolve(resolver, context, key_obj, &out);
    } else {
        rejectPromiseWithError(isolate, context, resolver, "unsupported algorithm for generateKey");
    }

    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Promise__Resolver__GetPromise(resolver)));
}

fn subtleImportKeyCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);

    if (c.v8__FunctionCallbackInfo__Length(info) < 3) {
        throw(isolate, "importKey requires format, keyData, and algorithm");
        return;
    }

    const format_val = c.v8__FunctionCallbackInfo__INDEX(info, 0).?;
    const key_data_val = c.v8__FunctionCallbackInfo__INDEX(info, 1).?;
    const algo_val = c.v8__FunctionCallbackInfo__INDEX(info, 2).?;

    // Format and algorithm are live simultaneously -> two buffers.
    var fmt_buf: [64]u8 = undefined;
    var name_buf: [64]u8 = undefined;
    const format = extractStrBuf(isolate, format_val, &fmt_buf) orelse {
        throw(isolate, "invalid format");
        return;
    };
    const algo_name = getAlgoName(isolate, algo_val, &name_buf) orelse {
        throw(isolate, "invalid algorithm");
        return;
    };

    const bs = getBackingStoreData(isolate, key_data_val) orelse {
        throw(isolate, "invalid keyData");
        return;
    };

    const resolver = c.v8__Promise__Resolver__New(context).?;

    if ((std.mem.eql(u8, algo_name, "HMAC") or std.mem.eql(u8, algo_name, "AES-GCM")) and std.mem.eql(u8, format, "raw")) {
        const algo_value: *const c.Value = if (algo_name[0] == 'A')
            globalStr(&str_aes_gcm, isolate, "AES-GCM")
        else
            globalStr(&str_hmac, isolate, "HMAC");

        const key_obj = buildCryptoKeyObject(isolate, context, algo_value) orelse {
            rejectAndReturn(info, isolate, context, resolver, "allocation failed");
            return;
        };
        var out: c.MaybeBool = undefined;
        const ab_val = createArrayBuffer(isolate, bs.ptr[0..bs.len]);
        c.v8__Object__Set(key_obj, context, globalStr(&str_data, isolate, "data"), ab_val, &out);
        c.v8__Promise__Resolver__Resolve(resolver, context, key_obj, &out);
    } else {
        rejectPromiseWithError(isolate, context, resolver, "unsupported algorithm/format for importKey");
    }

    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Promise__Resolver__GetPromise(resolver)));
}

fn subtleExportKeyCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);

    if (c.v8__FunctionCallbackInfo__Length(info) < 1) {
        throw(isolate, "exportKey requires a key");
        return;
    }

    const key_val = c.v8__FunctionCallbackInfo__INDEX(info, 0).?;
    const resolver = c.v8__Promise__Resolver__New(context).?;

    if (!c.v8__Value__IsObject(key_val)) {
        rejectAndReturn(info, isolate, context, resolver, "argument must be a CryptoKey object");
        return;
    }

    const data_val = c.v8__Object__Get(@ptrCast(key_val), context, globalStr(&str_data, isolate, "data"));

    if (data_val != null and c.v8__Value__IsArrayBuffer(data_val)) {
        const bstore = getBackingStoreData(isolate, data_val.?);
        if (bstore) |b| {
            resolvePromiseWithBuffer(isolate, context, resolver, b.ptr[0..b.len]);
        } else {
            rejectPromiseWithError(isolate, context, resolver, "key has no backing store data");
        }
    } else {
        rejectPromiseWithError(isolate, context, resolver, "key has no data property");
    }

    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Promise__Resolver__GetPromise(resolver)));
}

fn subtleEncryptCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);

    if (c.v8__FunctionCallbackInfo__Length(info) < 3) {
        throw(isolate, "encrypt requires algorithm, key, and data");
        return;
    }

    const algo_val = c.v8__FunctionCallbackInfo__INDEX(info, 0).?;
    const key_val = c.v8__FunctionCallbackInfo__INDEX(info, 1).?;
    const data_val = c.v8__FunctionCallbackInfo__INDEX(info, 2).?;

    var name_buf: [64]u8 = undefined;
    const algo_name = getAlgoName(isolate, algo_val, &name_buf) orelse {
        throw(isolate, "invalid algorithm");
        return;
    };

    const data_bs = getBackingStoreData(isolate, data_val) orelse {
        throw(isolate, "invalid data");
        return;
    };

    const resolver = c.v8__Promise__Resolver__New(context).?;

    if (std.mem.eql(u8, algo_name, "AES-GCM")) {
        const key_data_val = c.v8__Object__Get(@ptrCast(key_val), context, globalStr(&str_data, isolate, "data")) orelse {
            rejectAndReturn(info, isolate, context, resolver, "key has no data property");
            return;
        };
        const key_bs = getBackingStoreData(isolate, key_data_val) orelse {
            rejectAndReturn(info, isolate, context, resolver, "invalid key");
            return;
        };

        const key_bytes = key_bs.ptr[0..key_bs.len];
        if (key_bytes.len != 16 and key_bytes.len != 32) {
            rejectAndReturn(info, isolate, context, resolver, "invalid AES key length");
            return;
        }

        var nonce: [12]u8 = undefined;
        getRandomBytes(&nonce);

        // Single output allocation: nonce | ciphertext | tag, written
        // straight into the ArrayBuffer backing store — no intermediates,
        // no extra copies. The resolved value IS this buffer.
        const out_len = 12 + data_bs.len + 16;
        const ab = c.v8__ArrayBuffer__New(isolate, out_len);
        const store = c.v8__ArrayBuffer__GetBackingStore(ab);
        const backing_o = std__shared_ptr__v8__BackingStore__get(&store);
        if (backing_o == null or c.v8__BackingStore__Data(backing_o.?) == null) {
            rejectAndReturn(info, isolate, context, resolver, "allocation failed");
            return;
        }
        const out: [*]u8 = @ptrCast(c.v8__BackingStore__Data(backing_o.?).?);
        @memcpy(out[0..12], &nonce); // ship the nonce we actually encrypted with
        const tag: *[16]u8 = @ptrCast(out + out_len - 16);
        const ciphertext = out[12 .. 12 + data_bs.len];

        if (key_bytes.len == 16) {
            Aes128Gcm.encrypt(ciphertext, tag, data_bs.ptr[0..data_bs.len], "", nonce, key_bytes[0..16].*);
        } else {
            Aes256Gcm.encrypt(ciphertext, tag, data_bs.ptr[0..data_bs.len], "", nonce, key_bytes[0..32].*);
        }

        var out_b: c.MaybeBool = undefined;
        c.v8__Promise__Resolver__Resolve(resolver, context, @ptrCast(ab), &out_b);
    } else {
        rejectPromiseWithError(isolate, context, resolver, "unsupported algorithm for encrypt");
    }

    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Promise__Resolver__GetPromise(resolver)));
}

fn subtleDecryptCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);

    if (c.v8__FunctionCallbackInfo__Length(info) < 3) {
        throw(isolate, "decrypt requires algorithm, key, and data");
        return;
    }

    const algo_val = c.v8__FunctionCallbackInfo__INDEX(info, 0).?;
    const key_val = c.v8__FunctionCallbackInfo__INDEX(info, 1).?;
    const data_val = c.v8__FunctionCallbackInfo__INDEX(info, 2).?;

    var name_buf: [64]u8 = undefined;
    const algo_name = getAlgoName(isolate, algo_val, &name_buf) orelse {
        throw(isolate, "invalid algorithm");
        return;
    };

    const data_bs = getBackingStoreData(isolate, data_val) orelse {
        throw(isolate, "invalid data");
        return;
    };

    const resolver = c.v8__Promise__Resolver__New(context).?;

    if (std.mem.eql(u8, algo_name, "AES-GCM")) {
        const key_data_val = c.v8__Object__Get(@ptrCast(key_val), context, globalStr(&str_data, isolate, "data")) orelse {
            rejectAndReturn(info, isolate, context, resolver, "key has no data property");
            return;
        };
        const key_bs = getBackingStoreData(isolate, key_data_val) orelse {
            rejectAndReturn(info, isolate, context, resolver, "invalid key");
            return;
        };

        const key_bytes = key_bs.ptr[0..key_bs.len];
        const all_data = data_bs.ptr[0..data_bs.len];

        if (all_data.len < 28) {
            rejectAndReturn(info, isolate, context, resolver, "ciphertext too short");
            return;
        }

        const nonce = all_data[0..12];
        const tag_slice = all_data[all_data.len - 16 ..];
        const ciphertext = all_data[12 .. all_data.len - 16];
        var tag_val: [16]u8 = undefined;
        @memcpy(&tag_val, tag_slice);

        // Plaintext decrypts straight into the returned ArrayBuffer.
        const ab = c.v8__ArrayBuffer__New(isolate, ciphertext.len);
        const store = c.v8__ArrayBuffer__GetBackingStore(ab);
        const backing_o = std__shared_ptr__v8__BackingStore__get(&store);
        if (backing_o == null or c.v8__BackingStore__Data(backing_o.?) == null) {
            rejectAndReturn(info, isolate, context, resolver, "allocation failed");
            return;
        }
        const out: [*]u8 = @ptrCast(c.v8__BackingStore__Data(backing_o.?).?);
        const plaintext = out[0..ciphertext.len];

        if (key_bytes.len == 16) {
            Aes128Gcm.decrypt(plaintext, ciphertext, tag_val, "", nonce.*, key_bytes[0..16].*) catch {
                rejectAndReturn(info, isolate, context, resolver, "decryption failed");
                return;
            };
        } else if (key_bytes.len == 32) {
            Aes256Gcm.decrypt(plaintext, ciphertext, tag_val, "", nonce.*, key_bytes[0..32].*) catch {
                rejectAndReturn(info, isolate, context, resolver, "decryption failed");
                return;
            };
        } else {
            rejectAndReturn(info, isolate, context, resolver, "invalid AES key length");
            return;
        }

        var out_b: c.MaybeBool = undefined;
        c.v8__Promise__Resolver__Resolve(resolver, context, @ptrCast(ab), &out_b);
    } else {
        rejectPromiseWithError(isolate, context, resolver, "unsupported algorithm for decrypt");
    }

    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Promise__Resolver__GetPromise(resolver)));
}

fn subtleSignCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);

    if (c.v8__FunctionCallbackInfo__Length(info) < 3) {
        throw(isolate, "sign requires algorithm, key, and data");
        return;
    }

    const algo_val = c.v8__FunctionCallbackInfo__INDEX(info, 0).?;
    const key_val = c.v8__FunctionCallbackInfo__INDEX(info, 1).?;
    const data_val = c.v8__FunctionCallbackInfo__INDEX(info, 2).?;

    var name_buf: [64]u8 = undefined;
    const algo_name = getAlgoName(isolate, algo_val, &name_buf) orelse {
        throw(isolate, "invalid algorithm");
        return;
    };

    const data_bs = getBackingStoreData(isolate, data_val) orelse {
        throw(isolate, "invalid data");
        return;
    };

    const resolver = c.v8__Promise__Resolver__New(context).?;

    if (std.mem.eql(u8, algo_name, "HMAC")) {
        const key_data_val = c.v8__Object__Get(@ptrCast(key_val), context, globalStr(&str_data, isolate, "data")) orelse {
            rejectAndReturn(info, isolate, context, resolver, "key has no data property");
            return;
        };
        const key_bs = getBackingStoreData(isolate, key_data_val) orelse {
            rejectAndReturn(info, isolate, context, resolver, "invalid key");
            return;
        };

        const key_bytes = key_bs.ptr[0..key_bs.len];
        var mac: [32]u8 = undefined;
        HmacSha256.create(&mac, data_bs.ptr[0..data_bs.len], key_bytes);
        resolvePromiseWithBuffer(isolate, context, resolver, &mac);
    } else {
        rejectPromiseWithError(isolate, context, resolver, "unsupported algorithm for sign");
    }

    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Promise__Resolver__GetPromise(resolver)));
}

fn subtleVerifyCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);

    if (c.v8__FunctionCallbackInfo__Length(info) < 4) {
        throw(isolate, "verify requires algorithm, key, signature, and data");
        return;
    }

    const algo_val = c.v8__FunctionCallbackInfo__INDEX(info, 0).?;
    const key_val = c.v8__FunctionCallbackInfo__INDEX(info, 1).?;
    const sig_val = c.v8__FunctionCallbackInfo__INDEX(info, 2).?;
    const data_val = c.v8__FunctionCallbackInfo__INDEX(info, 3).?;

    var name_buf: [64]u8 = undefined;
    const algo_name = getAlgoName(isolate, algo_val, &name_buf) orelse {
        throw(isolate, "invalid algorithm");
        return;
    };

    const data_bs = getBackingStoreData(isolate, data_val) orelse {
        throw(isolate, "invalid data");
        return;
    };

    const sig_bs = getBackingStoreData(isolate, sig_val) orelse {
        throw(isolate, "invalid signature");
        return;
    };

    const resolver = c.v8__Promise__Resolver__New(context).?;

    if (std.mem.eql(u8, algo_name, "HMAC")) {
        const key_data_val = c.v8__Object__Get(@ptrCast(key_val), context, globalStr(&str_data, isolate, "data")) orelse {
            rejectAndReturn(info, isolate, context, resolver, "key has no data property");
            return;
        };
        const key_bs = getBackingStoreData(isolate, key_data_val) orelse {
            rejectAndReturn(info, isolate, context, resolver, "invalid key");
            return;
        };

        const key_bytes = key_bs.ptr[0..key_bs.len];
        var mac: [32]u8 = undefined;
        HmacSha256.create(&mac, data_bs.ptr[0..data_bs.len], key_bytes);

        var resolve_out: c.MaybeBool = undefined;
        if (sig_bs.len == 32) {
            var sig_buf: [32]u8 = undefined;
            @memcpy(&sig_buf, sig_bs.ptr[0..32]);
            const valid = std.crypto.timing_safe.eql([32]u8, mac, sig_buf);
            c.v8__Promise__Resolver__Resolve(resolver, context, if (valid) @ptrCast(c.v8__True(isolate)) else @ptrCast(c.v8__False(isolate)), &resolve_out);
        } else {
            c.v8__Promise__Resolver__Resolve(resolver, context, @ptrCast(c.v8__False(isolate)), &resolve_out);
        }
    } else {
        rejectPromiseWithError(isolate, context, resolver, "unsupported algorithm for verify");
    }

    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Promise__Resolver__GetPromise(resolver)));
}

fn subtleDeriveBitsCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);

    if (c.v8__FunctionCallbackInfo__Length(info) < 3) {
        throw(isolate, "deriveBits requires algorithm, baseKey, and length");
        return;
    }

    const algo_val = c.v8__FunctionCallbackInfo__INDEX(info, 0).?;
    const key_val = c.v8__FunctionCallbackInfo__INDEX(info, 1).?;
    const len_val = c.v8__FunctionCallbackInfo__INDEX(info, 2).?;

    var name_buf: [64]u8 = undefined;
    const algo_name = getAlgoName(isolate, algo_val, &name_buf) orelse {
        throw(isolate, "invalid algorithm");
        return;
    };

    var maybe_len: c.MaybeF64 = undefined;
    c.v8__Value__NumberValue(len_val, context, &maybe_len);
    if (!maybe_len.has_value) {
        throw(isolate, "invalid length");
        return;
    }
    const bit_len: u32 = @intFromFloat(maybe_len.value);
    const byte_len = bit_len / 8;

    const resolver = c.v8__Promise__Resolver__New(context).?;

    if (std.mem.eql(u8, algo_name, "PBKDF2")) {
        const key_bs = getBackingStoreData(isolate, key_val) orelse {
            rejectAndReturn(info, isolate, context, resolver, "invalid key");
            return;
        };

        const context_obj = if (c.v8__Value__IsObject(algo_val))
            @as(*const c.Object, @ptrCast(algo_val))
        else
            null;

        var salt: [16]u8 = undefined;

        if (context_obj) |obj| {
            const ctx2 = c.v8__Isolate__GetCurrentContext(isolate);
            const salt_val = c.v8__Object__Get(@ptrCast(obj), ctx2, globalStr(&str_salt, isolate, "salt"));
            if (salt_val != null) {
                const salt_bs = getBackingStoreData(isolate, salt_val.?);
                if (salt_bs) |sb| {
                    const copy_len = @min(sb.len, 16);
                    @memcpy(salt[0..copy_len], sb.ptr[0..copy_len]);
                }
            }
        }

        // Derived bits expand straight into the returned ArrayBuffer.
        // (Also fixes the old silent `catch return`, which left the promise
        // pending forever on derivation failure.)
        const ab = c.v8__ArrayBuffer__New(isolate, byte_len);
        const store = c.v8__ArrayBuffer__GetBackingStore(ab);
        const backing_o = std__shared_ptr__v8__BackingStore__get(&store);
        if (backing_o == null or c.v8__BackingStore__Data(backing_o.?) == null) {
            rejectAndReturn(info, isolate, context, resolver, "allocation failed");
            return;
        }
        const derived = @as([*]u8, @ptrCast(c.v8__BackingStore__Data(backing_o.?).?))[0..byte_len];

        std.crypto.pwhash.pbkdf2(derived, key_bs.ptr[0..key_bs.len], &salt, 100000, HmacSha256) catch {
            rejectAndReturn(info, isolate, context, resolver, "derivation failed");
            return;
        };

        var out_b: c.MaybeBool = undefined;
        c.v8__Promise__Resolver__Resolve(resolver, context, @ptrCast(ab), &out_b);
    } else {
        rejectPromiseWithError(isolate, context, resolver, "unsupported algorithm for deriveBits");
    }

    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Promise__Resolver__GetPromise(resolver)));
}

fn subtleDeriveKeyCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);

    if (c.v8__FunctionCallbackInfo__Length(info) < 3) {
        throw(isolate, "deriveKey requires algorithm, baseKey, and derivedKeyType");
        return;
    }

    const resolver = c.v8__Promise__Resolver__New(context).?;
    const key_obj = buildCryptoKeyObject(isolate, context, null) orelse {
        rejectAndReturn(info, isolate, context, resolver, "allocation failed");
        return;
    };
    var out: c.MaybeBool = undefined;
    c.v8__Promise__Resolver__Resolve(resolver, context, key_obj, &out);

    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Promise__Resolver__GetPromise(resolver)));
}

pub fn setup(isolate: ?*c.Isolate, context: ?*c.Context) void {
    var hs: c.HandleScope = undefined;
    c.v8__HandleScope__CONSTRUCT(&hs, isolate);
    defer c.v8__HandleScope__DESTRUCT(&hs);

    const global = c.v8__Context__Global(context);
    const crypto_obj = c.v8__Object__New(isolate);
    var out: c.MaybeBool = undefined;

    // Root the per-call constant strings once.
    inline for (.{
        .{ "name", &str_name },
        .{ "data", &str_data },
        .{ "salt", &str_salt },
        .{ "type", &str_type },
        .{ "algorithm", &str_algorithm },
        .{ "extractable", &str_extractable },
        .{ "secret", &str_secret },
        .{ "AES-GCM", &str_aes_gcm },
        .{ "HMAC", &str_hmac },
    }) |entry| {
        c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, entry[0], 0, -1)), entry[1]);
    }

    const getRandomValues_fn = c.v8__Function__New__DEFAULT(context, getRandomValuesCallback);
    c.v8__Object__Set(crypto_obj, context, c.v8__String__NewFromUtf8(isolate, "getRandomValues", 0, -1), getRandomValues_fn, &out);

    const randomUUID_fn = c.v8__Function__New__DEFAULT(context, randomUUIDCallback);
    c.v8__Object__Set(crypto_obj, context, c.v8__String__NewFromUtf8(isolate, "randomUUID", 0, -1), randomUUID_fn, &out);

    const subtle_obj = c.v8__Object__New(isolate);

    const digest_fn = c.v8__Function__New__DEFAULT(context, subtleDigestCallback);
    c.v8__Object__Set(subtle_obj, context, c.v8__String__NewFromUtf8(isolate, "digest", 0, -1), digest_fn, &out);

    const generateKey_fn = c.v8__Function__New__DEFAULT(context, subtleGenerateKeyCallback);
    c.v8__Object__Set(subtle_obj, context, c.v8__String__NewFromUtf8(isolate, "generateKey", 0, -1), generateKey_fn, &out);

    const importKey_fn = c.v8__Function__New__DEFAULT(context, subtleImportKeyCallback);
    c.v8__Object__Set(subtle_obj, context, c.v8__String__NewFromUtf8(isolate, "importKey", 0, -1), importKey_fn, &out);

    const exportKey_fn = c.v8__Function__New__DEFAULT(context, subtleExportKeyCallback);
    c.v8__Object__Set(subtle_obj, context, c.v8__String__NewFromUtf8(isolate, "exportKey", 0, -1), exportKey_fn, &out);

    const encrypt_fn = c.v8__Function__New__DEFAULT(context, subtleEncryptCallback);
    c.v8__Object__Set(subtle_obj, context, c.v8__String__NewFromUtf8(isolate, "encrypt", 0, -1), encrypt_fn, &out);

    const decrypt_fn = c.v8__Function__New__DEFAULT(context, subtleDecryptCallback);
    c.v8__Object__Set(subtle_obj, context, c.v8__String__NewFromUtf8(isolate, "decrypt", 0, -1), decrypt_fn, &out);

    const sign_fn = c.v8__Function__New__DEFAULT(context, subtleSignCallback);
    c.v8__Object__Set(subtle_obj, context, c.v8__String__NewFromUtf8(isolate, "sign", 0, -1), sign_fn, &out);

    const verify_fn = c.v8__Function__New__DEFAULT(context, subtleVerifyCallback);
    c.v8__Object__Set(subtle_obj, context, c.v8__String__NewFromUtf8(isolate, "verify", 0, -1), verify_fn, &out);

    const deriveBits_fn = c.v8__Function__New__DEFAULT(context, subtleDeriveBitsCallback);
    c.v8__Object__Set(subtle_obj, context, c.v8__String__NewFromUtf8(isolate, "deriveBits", 0, -1), deriveBits_fn, &out);

    const deriveKey_fn = c.v8__Function__New__DEFAULT(context, subtleDeriveKeyCallback);
    c.v8__Object__Set(subtle_obj, context, c.v8__String__NewFromUtf8(isolate, "deriveKey", 0, -1), deriveKey_fn, &out);

    c.v8__Object__Set(crypto_obj, context, c.v8__String__NewFromUtf8(isolate, "subtle", 0, -1), subtle_obj, &out);

    const crypto_key = c.v8__String__NewFromUtf8(isolate, "crypto", 0, -1);
    _ = c.v8__Object__Set(global, context, crypto_key, crypto_obj, &out);
}
