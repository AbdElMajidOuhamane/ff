const std = @import("std");
const c = @import("../c.zig").c;
const pool_slice_mod = @import("pool_slice.zig");
const gpa = std.heap.smp_allocator;

pub var blob_class_id: c.ClassID = 0;

// ── DOD note ──
// Cold JS-bridge object, NOT hot I/O path (same reasoning as RequestData in
// request.zig:9-13). AoS per-Blob is correct — GC lifetime, created once per
// .blob()/new Blob(), consumed via getters. No SoA, no hot-loop traffic.
const PoolSlice = pool_slice_mod.PoolSlice;

pub const BlobData = struct {
    pool: std.ArrayList(u8),
    _bytes: PoolSlice,
    _type: PoolSlice,

    comptime {
        std.debug.assert(@sizeOf(PoolSlice) == 8);
        std.debug.assert(@sizeOf(BlobData) == 40);
        std.debug.assert(@alignOf(BlobData) >= 8);
    }

    pub fn init() BlobData {
        return .{ .pool = std.ArrayList(u8).empty, ._bytes = .{}, ._type = .{} };
    }
    pub fn deinit(self: *BlobData) void {
        self.pool.deinit(gpa);
    }
    pub fn bytes(self: *const BlobData) []const u8 {
        return self.pool.items[self._bytes.off .. self._bytes.off + self._bytes.len];
    }
    pub fn mimeType(self: *const BlobData) []const u8 {
        return self.pool.items[self._type.off .. self._type.off + self._type.len];
    }
    pub fn size(self: *const BlobData) usize {
        return self._bytes.len;
    }
    fn store(self: *BlobData, owned: []const u8, dst: *PoolSlice) void {
        if (owned.len == 0) {
            dst.* = .{};
            return;
        }
        const off = self.pool.items.len;
        self.pool.appendSlice(gpa, owned) catch return;
        dst.* = .{ .off = @intCast(off), .len = @intCast(owned.len) };
    }
    pub fn setBytes(self: *BlobData, s: []const u8) void {
        self.store(s, &self._bytes);
    }
    /// WHATWG normalize: strip `; params`, trim spaces, ASCII-lowercase.
    pub fn setTypeNormalized(self: *BlobData, raw: []const u8) void {
        var s = raw;
        if (std.mem.indexOfScalar(u8, s, ';')) |i| s = s[0..i];
        while (s.len > 0 and (s[0] == ' ' or s[0] == '\t')) s = s[1..];
        while (s.len > 0 and (s[s.len - 1] == ' ' or s[s.len - 1] == '\t')) s = s[0 .. s.len - 1];
        if (s.len == 0) {
            self._type = .{};
            return;
        }
        const off = self.pool.items.len;
        self.pool.ensureTotalCapacity(gpa, off + s.len) catch return;
        for (s) |ch| self.pool.appendAssumeCapacity(if (ch >= 'A' and ch <= 'Z') ch + 32 else ch);
        self._type = .{ .off = @intCast(off), .len = @intCast(s.len) };
    }
};

fn zigStringToJS(ctx: ?*c.Context, str: []const u8) c.Value {
    return c.newStringLen(ctx, str.ptr, @intCast(str.len));
}

const ExtractedStr = struct {
    slice: []const u8,
    heap: ?[:0]u8 = null,
    fn deinit(self: ExtractedStr) void {
        if (self.heap) |h| gpa.free(h);
    }
};

fn extractStringAuto(ctx: ?*c.Context, val: c.Value, stack_buf: []u8) ?ExtractedStr {
    const cstr = c.toCString(ctx, val) orelse return null;
    defer c.freeCString(ctx, cstr);
    const len = std.mem.len(cstr);
    if (len == 0) return .{ .slice = "" };
    if (len <= stack_buf.len) {
        @memcpy(stack_buf[0..len], cstr[0..len]);
        return .{ .slice = stack_buf[0..len] };
    }
    const heap_buf = gpa.allocSentinel(u8, len, 0) catch return null;
    @memcpy(heap_buf[0..len], cstr[0..len]);
    return .{ .slice = heap_buf, .heap = heap_buf };
}

fn extractBlobData(ctx: ?*c.Context, this_val: c.Value) ?*BlobData {
    const ptr = c.getOpaque2(ctx, this_val, blob_class_id) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

/// Public for request.zig / response.zig nested-part detection.
pub fn dataFromJS(ctx: ?*c.Context, val: c.Value) ?*BlobData {
    if (c.isObject(val) == 0) return null;
    const ptr = c.getOpaque2(ctx, val, blob_class_id) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

/// Raw bytes of an ArrayBuffer or any TypedArray view.
/// Mirrors crypto.zig:51-93 — each failed probe clears its exception.
/// NOTE: JS_HasException returns bool (not c_int like the JS_Is* wrappers,
// so no `!= 0` comparison — cf. crypto.zig:57).
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

/// Append one blob-part: string | Blob | ArrayBuffer | TypedArray.
/// Non-objects fall through; objects try Blob → bytes → toString coercion.
fn appendPart(ctx: ?*c.Context, data: *BlobData, part: c.Value) void {
    if (c.isString(part) != 0) {
        var stack: [512]u8 = undefined;
        if (extractStringAuto(ctx, part, &stack)) |s| {
            defer s.deinit();
            if (s.slice.len == 0) return;
            const off = data.pool.items.len;
            data.pool.appendSlice(gpa, s.slice) catch return;
            const old = data._bytes;
            data._bytes = .{ .off = old.off, .len = old.len + @as(u32, @intCast(s.slice.len)) };
            if (old.len == 0) data._bytes.off = @intCast(off);
        }
        return;
    }
    if (c.isObject(part) == 0) return;
    if (dataFromJS(ctx, part)) |nested| {
        const nb = nested.bytes();
        if (nb.len == 0) return;
        const off = data.pool.items.len;
        data.pool.appendSlice(gpa, nb) catch return;
        const old = data._bytes;
        data._bytes = .{ .off = old.off, .len = old.len + @as(u32, @intCast(nb.len)) };
        if (old.len == 0) data._bytes.off = @intCast(off);
        return;
    }
    if (backingBytes(ctx, part)) |b| {
        if (b.len == 0) return;
        const off = data.pool.items.len;
        data.pool.appendSlice(gpa, b) catch return;
        const old = data._bytes;
        data._bytes = .{ .off = old.off, .len = old.len + @as(u32, @intCast(b.len)) };
        if (old.len == 0) data._bytes.off = @intCast(off);
        return;
    }
    const str_val = c.toString(ctx, part);
    if (c.getTag(str_val) == c.TAG_EXCEPTION) return;
    defer c.freeValue(ctx, str_val);
    var stack: [512]u8 = undefined;
    if (extractStringAuto(ctx, str_val, &stack)) |s| {
        defer s.deinit();
        if (s.slice.len == 0) return;
        const off = data.pool.items.len;
        data.pool.appendSlice(gpa, s.slice) catch return;
        const old = data._bytes;
        data._bytes = .{ .off = old.off, .len = old.len + @as(u32, @intCast(s.slice.len)) };
        if (old.len == 0) data._bytes.off = @intCast(off);
    }
}

fn setBlobProps(ctx: ?*c.Context, obj: c.Value, data: *BlobData) void {
    // Blob is immutable → snapshot size/type at creation, same style as
    // setRequestProps (request.zig:414) snapshotting url/method.
    _ = c.definePropertyValueStr(ctx, obj, "size", c.newInt32(ctx, @intCast(data.size())), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "type", zigStringToJS(ctx, data.mimeType()), c.PROP_C_W_E);
}

pub fn buildBlobJSObject(ctx: ?*c.Context, data: *BlobData) c.Value {
    const obj = c.newObjectClass(ctx, @intCast(blob_class_id));
    c.setOpaque(obj, data);
    setBlobProps(ctx, obj, data);
    return obj;
}

fn blobFinalizer(rt: ?*c.Runtime, val: c.Value) callconv(.c) void {
    _ = rt;
    if (c.getOpaque(val, blob_class_id)) |ptr| {
        const data: *BlobData = @ptrCast(@alignCast(ptr));
        data.deinit();
        gpa.destroy(data);
    }
}

fn blobConstructor(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    const data = gpa.create(BlobData) catch return c.throwOutOfMemory(ctx);
    data.* = BlobData.init();
    errdefer {
        data.deinit();
        gpa.destroy(data);
    }

    if (argc > 0 and c.isUndefined(argv[0]) == 0 and c.isNull(argv[0]) == 0) {
        if (c.isArray(ctx, argv[0]) != 0) {
            const len_val = c.getPropertyStr(ctx, argv[0], "length");
            defer c.freeValue(ctx, len_val);
            var len: c_int = 0;
            _ = c.toInt32(ctx, &len, len_val);
            var i: c_uint = 0;
            while (i < @as(c_uint, @intCast(@max(len, 0)))) : (i += 1) {
                const part = c.getPropertyUint32(ctx, argv[0], i);
                defer c.freeValue(ctx, part);
                appendPart(ctx, data, part);
            }
        } else {
            appendPart(ctx, data, argv[0]);
        }
    }
    if (argc > 1 and c.isObject(argv[1]) != 0) {
        const type_val = c.getPropertyStr(ctx, argv[1], "type");
        defer c.freeValue(ctx, type_val);
        if (c.isString(type_val) != 0) {
            var stack: [256]u8 = undefined;
            if (extractStringAuto(ctx, type_val, &stack)) |t| {
                defer t.deinit();
                data.setTypeNormalized(t.slice);
            }
        }
    }
    return buildBlobJSObject(ctx, data);
}

fn clampSliceIndex(v: i64, len: i64) i64 {
    if (v < 0) return @max(len + v, 0);
    return @min(v, len);
}

fn blobSlice(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const data = extractBlobData(ctx, this_val) orelse return c.JS_EXCEPTION;
    const src = data.bytes();
    const len: i64 = @intCast(src.len);
    var start: i64 = 0;
    var end: i64 = len;
    if (argc > 0 and (c.isUndefined(argv[0]) == 0 and c.isNull(argv[0]) == 0)) {
        var v: c_int = 0;
        _ = c.toInt32(ctx, &v, argv[0]);
        start = clampSliceIndex(v, len);
    }
    if (argc > 1 and (c.isUndefined(argv[1]) == 0 and c.isNull(argv[1]) == 0)) {
        var v: c_int = 0;
        _ = c.toInt32(ctx, &v, argv[1]);
        end = clampSliceIndex(v, len);
    }
    const s: usize = @intCast(@max(start, 0));
    const e: usize = @intCast(@max(end, 0));
    const from = @min(s, src.len);
    const to = @min(e, src.len);
    const sub = if (to > from) src[from..to] else "";
    const out = gpa.create(BlobData) catch return c.throwOutOfMemory(ctx);
    out.* = BlobData.init();
    errdefer {
        out.deinit();
        gpa.destroy(out);
    }
    out.setBytes(sub);
    if (argc > 2 and c.isString(argv[2]) != 0) {
        var stack: [256]u8 = undefined;
        if (extractStringAuto(ctx, argv[2], &stack)) |t| {
            defer t.deinit();
            out.setTypeNormalized(t.slice);
        }
    }
    return buildBlobJSObject(ctx, out);
}

fn blobArrayBuffer(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const data = extractBlobData(ctx, this_val) orelse return c.JS_EXCEPTION;
    const b = data.bytes();
    var cap: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &cap);
    var ab = if (b.len > 0) c.newArrayBufferCopy(ctx, b.ptr, b.len) else c.newArrayBufferCopy(ctx, "", 0);
    _ = c.call(ctx, cap[0], c.JS_UNDEFINED, 1, &ab);
    return promise;
}

fn blobText(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const data = extractBlobData(ctx, this_val) orelse return c.JS_EXCEPTION;
    const b = data.bytes();
    var cap: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &cap);
    var result = zigStringToJS(ctx, b);
    _ = c.call(ctx, cap[0], c.JS_UNDEFINED, 1, &result);
    return promise;
}

fn blobBytes(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const data = extractBlobData(ctx, this_val) orelse return c.JS_EXCEPTION;
    const b = data.bytes();
    var cap: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &cap);
    // 3-arg TypedArray form — argv[1..2] (offset/len) are mandatory,
    // same as http_native.zig:835-840.
    const ab = if (b.len > 0) c.newArrayBufferCopy(ctx, b.ptr, b.len) else c.newArrayBufferCopy(ctx, "", 0);
    if (c.getTag(ab) == c.TAG_EXCEPTION) {
        var exc = c.getException(ctx);
        _ = c.call(ctx, cap[1], c.JS_UNDEFINED, 1, &exc);
        return promise;
    }
    defer c.freeValue(ctx, ab);
    var targv = [_]c.Value{ ab, c.newInt32(ctx, 0), c.newInt32(ctx, @intCast(b.len)) };
    var u8arr = c.newTypedArray(ctx, 3, &targv, c.JS_TYPED_ARRAY_UINT8);
    _ = c.call(ctx, cap[0], c.JS_UNDEFINED, 1, &u8arr);
    return promise;
}

pub fn setup(ctx: ?*c.Context) void {
    var class_def = c.ClassDef{
        .class_name = "Blob",
        .finalizer = blobFinalizer,
    };
    _ = c.newClassID(c.getRuntime(ctx), &blob_class_id);
    _ = c.newClass(c.getRuntime(ctx), blob_class_id, &class_def);

    const proto = c.newObject(ctx);
    const methods = [_]struct { name: [*:0]const u8, func: *const c.CFunction, len: c_int }{
        .{ .name = "slice", .func = &blobSlice, .len = 3 },
        .{ .name = "arrayBuffer", .func = &blobArrayBuffer, .len = 0 },
        .{ .name = "text", .func = &blobText, .len = 0 },
        .{ .name = "bytes", .func = &blobBytes, .len = 0 },
    };
    for (methods) |m| {
        const fn_val = c.newCFunction(ctx, m.func, m.name, m.len);
        _ = c.definePropertyValueStr(ctx, proto, m.name, fn_val, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
    }
    c.setClassProto(ctx, blob_class_id, proto);
    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);
    const ctor = c.newCFunction2(ctx, &blobConstructor, "Blob", 2, c.JS_CFUNC_constructor, 0);
    _ = c.definePropertyValueStr(ctx, global, "Blob", ctor, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
}
