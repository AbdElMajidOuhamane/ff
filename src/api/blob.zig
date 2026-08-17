const std = @import("std");
const c = @import("../c.zig").c;
const streams_api = @import("streams.zig");

const gpa = std.heap.page_allocator;

fn throw(isolate: ?*c.Isolate, msg: []const u8) void {
    const v8_msg = c.v8__String__NewFromUtf8(isolate, @ptrCast(msg.ptr), 0, @intCast(msg.len));
    const exc = c.v8__Exception__Error(v8_msg);
    _ = c.v8__Isolate__ThrowException(isolate, exc);
}

fn zigStringToV8(isolate: ?*c.Isolate, str: []const u8) *const c.Value {
    return @ptrCast(c.v8__String__NewFromUtf8(isolate, @ptrCast(str.ptr), 0, @intCast(str.len)));
}

fn extractStringFromVal(isolate: ?*c.Isolate, val: ?*const c.Value) ?[:0]const u8 {
    const v = val orelse return null;
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    const str = c.v8__Value__ToDetailString(v, context);
    if (str == null) return null;
    const utf8_len: usize = @intCast(c.v8__String__Utf8Length(str, isolate));
    const buf = gpa.allocSentinel(u8, utf8_len, 0) catch return null;
    _ = c.v8__String__WriteUtf8(str, isolate, buf.ptr, @intCast(utf8_len), 0);
    return buf;
}

pub const BlobData = struct {
    bytes: []u8, // owned, gpa
    type_buf: [64]u8 = [_]u8{0} ** 64,
    type_len: usize = 0,
    is_file: bool = false,
    filename: []const u8 = "", // owned for File
    last_modified: u64 = 0,

    pub fn getType(self: *const BlobData) []const u8 {
        return self.type_buf[0..self.type_len];
    }

    pub fn deinit(self: *BlobData) void {
        if (self.bytes.len > 0) gpa.free(self.bytes);
        if (self.filename.len > 0) gpa.free(self.filename);
    }
};

fn setType(data: *BlobData, t: []const u8) void {
    const n = @min(t.len, 64);
    @memcpy(data.type_buf[0..n], t[0..n]);
    data.type_len = n;
}

fn extractBlobData(info: ?*const c.FunctionCallbackInfo) ?*BlobData {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    const this = c.v8__FunctionCallbackInfo__This(info);
    if (this == null) return null;
    const data_key = c.v8__String__NewFromUtf8(isolate, "__d", 0, -1);
    const ext_val = c.v8__Object__Get(@ptrCast(this), context, data_key);
    if (ext_val == null or !c.v8__Value__IsExternal(ext_val)) return null;
    const ptr = c.v8__External__Value(@ptrCast(ext_val));
    return @ptrCast(@alignCast(ptr));
}

fn appendPart(buf: *std.ArrayList(u8), isolate: ?*c.Isolate, context: ?*c.Context, part: ?*const c.Value) void {
    if (part == null) return;
    if (c.v8__Value__IsArrayBuffer(part)) {
        const ab: *const c.ArrayBuffer = @ptrCast(part);
        const backing = c.v8__ArrayBuffer__GetBackingStore(ab);
        const store_ptr = c.std__shared_ptr__v8__BackingStore__get(&backing);
        if (store_ptr != null) {
            const len: usize = @intCast(c.v8__BackingStore__ByteLength(store_ptr));
            if (len > 0) {
                const src: [*]const u8 = @ptrCast(c.v8__BackingStore__Data(store_ptr));
                buf.appendSlice(gpa, src[0..len]) catch return;
            }
        }
        return;
    }
    if (c.v8__Value__IsArrayBufferView(part)) {
        const view: *const c.ArrayBufferView = @ptrCast(part);
        const buffer_val = c.v8__ArrayBufferView__Buffer(view);
        if (buffer_val != null) {
            const backing = c.v8__ArrayBuffer__GetBackingStore(buffer_val);
            const store_ptr = c.std__shared_ptr__v8__BackingStore__get(&backing);
            if (store_ptr != null) {
                const offset: usize = @intCast(c.v8__ArrayBufferView__ByteOffset(view));
                const len: usize = @intCast(c.v8__ArrayBufferView__ByteLength(view));
                if (len > 0) {
                    const base: [*]const u8 = @ptrCast(c.v8__BackingStore__Data(store_ptr));
                    buf.appendSlice(gpa, base[offset .. offset + len]) catch return;
                }
            }
        }
        return;
    }
    if (c.v8__Value__IsObject(part)) {
        const data_key = c.v8__String__NewFromUtf8(isolate, "__d", 0, -1);
        const ext_val = c.v8__Object__Get(@ptrCast(part), context, data_key);
        if (ext_val != null and c.v8__Value__IsExternal(ext_val)) {
            const src: *BlobData = @ptrCast(@alignCast(c.v8__External__Value(@ptrCast(ext_val))));
            buf.appendSlice(gpa, src.bytes) catch return;
            return;
        }
    }
    if (extractStringFromVal(isolate, part)) |owned| {
        defer gpa.free(owned);
        buf.appendSlice(gpa, owned[0..owned.len]) catch return;
    }
}

fn arrayBufferFromBytes(isolate: ?*c.Isolate, bytes: []const u8) ?*const c.ArrayBuffer {
    const ab = c.v8__ArrayBuffer__New(isolate, bytes.len);
    if (bytes.len > 0) {
        const backing = c.v8__ArrayBuffer__GetBackingStore(ab);
        const store_ptr = c.std__shared_ptr__v8__BackingStore__get(&backing);
        if (store_ptr != null) {
            const data_ptr: [*]u8 = @ptrCast(@alignCast(c.v8__BackingStore__Data(store_ptr)));
            @memcpy(data_ptr[0..bytes.len], bytes);
        }
    }
    return ab;
}

pub fn makeBlobObject(isolate: ?*c.Isolate, context: ?*c.Context, bytes: []const u8, blob_type: []const u8) ?*const c.Object {
    const data = gpa.create(BlobData) catch {
        throw(isolate, "out of memory");
        return c.v8__Object__New(isolate);
    };
    data.* = .{ .bytes = gpa.dupe(u8, bytes) catch &.{} };
    setType(data, blob_type);
    return buildBlobJSObject(isolate, context, data);
}

fn buildBlobJSObject(isolate: ?*c.Isolate, context: ?*c.Context, data: *BlobData) ?*const c.Object {
    const obj = c.v8__Object__New(isolate);
    const ext = c.v8__External__New(isolate, @ptrCast(data));
    var out: c.MaybeBool = undefined;
    _ = c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, "__d", 0, -1), ext, &out);
    _ = c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, "size", 0, -1), @ptrCast(c.v8__Integer__New(isolate, @intCast(data.bytes.len))), &out);
    _ = c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, "type", 0, -1), @ptrCast(zigStringToV8(isolate, data.getType())), &out);
    if (data.is_file) {
        _ = c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, "name", 0, -1), @ptrCast(zigStringToV8(isolate, data.filename)), &out);
        _ = c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, "lastModified", 0, -1), @ptrCast(c.v8__Integer__New(isolate, @intCast(data.last_modified))), &out);
    }
    const fns = .{
        .{ "arrayBuffer", blobArrayBuffer },
        .{ "bytes", blobBytes },
        .{ "text", blobText },
        .{ "slice", blobSlice },
        .{ "stream", blobStream },
    };
    inline for (fns) |e| {
        const fn_val = c.v8__Function__New__DEFAULT(context, e[1]);
        _ = c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, e[0], 0, -1), fn_val, &out);
    }
    return obj;
}

fn gatherParts(buf: *std.ArrayList(u8), isolate: ?*c.Isolate, context: ?*c.Context, info: ?*const c.FunctionCallbackInfo) void {
    if (c.v8__FunctionCallbackInfo__Length(info) < 1) return;
    const parts = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    if (parts == null or !c.v8__Value__IsArray(parts)) return;
    const len: usize = @intCast(c.v8__Array__Length(parts));
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const idx = c.v8__Integer__NewFromUnsigned(isolate, @intCast(i));
        const part = c.v8__Object__Get(@ptrCast(parts), context, idx);
        if (part == null) continue;
        appendPart(buf, isolate, context, part);
    }
}

fn gatherOptionsType(data: *BlobData, isolate: ?*c.Isolate, context: ?*c.Context, info: ?*const c.FunctionCallbackInfo) void {
    if (c.v8__FunctionCallbackInfo__Length(info) < 2) return;
    const opt = c.v8__FunctionCallbackInfo__INDEX(info, 1);
    if (opt == null or !c.v8__Value__IsObject(opt)) return;
    const type_key = c.v8__String__NewFromUtf8(isolate, "type", 0, -1);
    const type_val = c.v8__Object__Get(@ptrCast(opt), context, type_key);
    if (type_val != null and !c.v8__Value__IsUndefined(type_val)) {
        if (extractStringFromVal(isolate, type_val)) |owned| {
            defer gpa.free(owned);
            setType(data, owned[0..owned.len]);
        }
    }
}

fn jsNumberArg(context: ?*c.Context, info: ?*const c.FunctionCallbackInfo, i: c_int) ?f64 {
    if (c.v8__FunctionCallbackInfo__Length(info) <= i) return null;
    const val = c.v8__FunctionCallbackInfo__INDEX(info, i);
    if (val == null or c.v8__Value__IsUndefined(val)) return null;
    var out: c.MaybeF64 = undefined;
    c.v8__Value__NumberValue(val, context, &out);
    if (!out.has_value) return null;
    return out.value;
}

fn blobConstructor(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);

    const data = gpa.create(BlobData) catch {
        throw(isolate, "out of memory");
        return;
    };
    data.* = .{ .bytes = &.{} };
    var buf = std.ArrayList(u8).empty;
    gatherParts(&buf, isolate, context, info);
    data.bytes = buf.toOwnedSlice(gpa) catch &.{};
    gatherOptionsType(data, isolate, context, info);

    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(buildBlobJSObject(isolate, context, data)));
}

fn fileConstructor(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);

    const data = gpa.create(BlobData) catch {
        throw(isolate, "out of memory");
        return;
    };
    data.* = .{ .bytes = &.{}, .is_file = true };
    var buf = std.ArrayList(u8).empty;
    gatherParts(&buf, isolate, context, info);
    data.bytes = buf.toOwnedSlice(gpa) catch &.{};

    if (c.v8__FunctionCallbackInfo__Length(info) >= 2) {
        const name_val = c.v8__FunctionCallbackInfo__INDEX(info, 1);
        if (name_val != null and !c.v8__Value__IsUndefined(name_val)) {
            if (extractStringFromVal(isolate, name_val)) |owned| {
                data.filename = gpa.dupe(u8, owned[0..owned.len]) catch "";
                gpa.free(owned);
            }
        }
    }
    if (c.v8__FunctionCallbackInfo__Length(info) >= 3) {
        const opt = c.v8__FunctionCallbackInfo__INDEX(info, 2);
        if (opt != null and c.v8__Value__IsObject(opt)) {
            const lm_key = c.v8__String__NewFromUtf8(isolate, "lastModified", 0, -1);
            const lm_val = c.v8__Object__Get(@ptrCast(opt), context, lm_key);
            if (lm_val != null and !c.v8__Value__IsUndefined(lm_val)) {
                var out: c.MaybeF64 = undefined;
                c.v8__Value__NumberValue(lm_val, context, &out);
                if (out.has_value and out.value > 0) data.last_modified = @intFromFloat(out.value);
            }
            const type_key = c.v8__String__NewFromUtf8(isolate, "type", 0, -1);
            const type_val = c.v8__Object__Get(@ptrCast(opt), context, type_key);
            if (type_val != null and !c.v8__Value__IsUndefined(type_val)) {
                if (extractStringFromVal(isolate, type_val)) |owned| {
                    defer gpa.free(owned);
                    setType(data, owned[0..owned.len]);
                }
            }
        }
    }

    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(buildBlobJSObject(isolate, context, data)));
}

fn blobArrayBuffer(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const resolver = c.v8__Promise__Resolver__New(context);
    if (resolver == null) {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));
        return;
    }
    const promise = c.v8__Promise__Resolver__GetPromise(resolver);
    var out: c.MaybeBool = undefined;
    if (extractBlobData(info)) |data| {
        _ = c.v8__Promise__Resolver__Resolve(resolver, context, @ptrCast(arrayBufferFromBytes(isolate, data.bytes)), &out);
    } else {
        _ = c.v8__Promise__Resolver__Resolve(resolver, context, @ptrCast(c.v8__Null(isolate)), &out);
    }
    c.v8__ReturnValue__Set(ret, @ptrCast(promise));
}

fn blobBytes(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const resolver = c.v8__Promise__Resolver__New(context);
    if (resolver == null) {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));
        return;
    }
    const promise = c.v8__Promise__Resolver__GetPromise(resolver);
    var out: c.MaybeBool = undefined;
    if (extractBlobData(info)) |data| {
        const ab = arrayBufferFromBytes(isolate, data.bytes);
        const u8arr = c.v8__Uint8Array__New(@ptrCast(ab), 0, data.bytes.len);
        _ = c.v8__Promise__Resolver__Resolve(resolver, context, @ptrCast(u8arr), &out);
    } else {
        _ = c.v8__Promise__Resolver__Resolve(resolver, context, @ptrCast(c.v8__Null(isolate)), &out);
    }
    c.v8__ReturnValue__Set(ret, @ptrCast(promise));
}

fn blobText(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const resolver = c.v8__Promise__Resolver__New(context);
    if (resolver == null) {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));
        return;
    }
    const promise = c.v8__Promise__Resolver__GetPromise(resolver);
    var out: c.MaybeBool = undefined;
    if (extractBlobData(info)) |data| {
        _ = c.v8__Promise__Resolver__Resolve(resolver, context, @ptrCast(zigStringToV8(isolate, data.bytes)), &out);
    } else {
        _ = c.v8__Promise__Resolver__Resolve(resolver, context, @ptrCast(zigStringToV8(isolate, "")), &out);
    }
    c.v8__ReturnValue__Set(ret, @ptrCast(promise));
}

fn blobSlice(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractBlobData(info) orelse return;
    const size = data.bytes.len;

    const clampLen = struct {
        fn len(max_len: usize, n: f64) usize {
            if (n < 0) {
                const neg: usize = @intFromFloat(@max(-n, 0.0));
                return if (neg >= max_len) 0 else max_len - neg;
            }
            return @min(@as(usize, @intFromFloat(n)), max_len);
        }
    }.len;

    var start = clampLen(size, 0);
    var end = size;
    if (jsNumberArg(context, info, 0)) |sn| start = clampLen(size, sn);
    if (jsNumberArg(context, info, 1)) |en| end = clampLen(size, en);
    if (start > end) end = start;

    c.v8__ReturnValue__Set(ret, @ptrCast(makeBlobObject(isolate, context, data.bytes[start..end], data.getType())));
}

fn blobStream(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate) orelse return;
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractBlobData(info) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));
        return;
    };
    const stream_obj = streams_api.makeByteStream(isolate, context, data.bytes) orelse c.v8__Object__New(isolate);
    c.v8__ReturnValue__Set(ret, @ptrCast(stream_obj));
}

pub fn setup(isolate: ?*c.Isolate, context: ?*c.Context) void {
    var hs: c.HandleScope = undefined;
    c.v8__HandleScope__CONSTRUCT(&hs, isolate);
    defer c.v8__HandleScope__DESTRUCT(&hs);

    const global = c.v8__Context__Global(context);
    var out: c.MaybeBool = undefined;
    _ = c.v8__Object__Set(global, context, c.v8__String__NewFromUtf8(isolate, "Blob", 0, -1), c.v8__Function__New__DEFAULT(context, blobConstructor), &out);
    _ = c.v8__Object__Set(global, context, c.v8__String__NewFromUtf8(isolate, "File", 0, -1), c.v8__Function__New__DEFAULT(context, fileConstructor), &out);
}
