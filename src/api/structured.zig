const std = @import("std");
const c = @import("../c.zig").c;

const gpa = std.heap.page_allocator;

// Transfer list staged as parallel arrays (SoA, house style). The common
// case (a transferred buffer list in the wild is <= 8 entries) rides one
// @Vector(TLANES, u32) register on the stack; longer lists spill to heap
// slabs padded to a TLANES multiple so the SIMD scan never reads a ragged
// tail. Duplicate detection is the abort.zig idiom: wide hash prefilter ->
// bitmask -> scalar backing-store confirm.
const TLANES = 8; // @Vector(8, u32) compare domain

var str_transfer: c.Global = .{ .data_ptr = 0 };

fn strV(isolate: ?*c.Isolate, comptime s: []const u8) *const c.Value {
    return @ptrCast(c.v8__String__NewFromUtf8(isolate, s.ptr, 0, s.len));
}

fn throwType(isolate: ?*c.Isolate, comptime msg: []const u8) void {
    _ = c.v8__Isolate__ThrowException(isolate, @ptrCast(c.v8__Exception__TypeError(strV(isolate, msg))));
}

fn throwDataClone(isolate: ?*c.Isolate, context: ?*c.Context, comptime msg: []const u8) void {
    const err = c.v8__Exception__Error(strV(isolate, msg));
    var out: c.MaybeBool = undefined;
    _ = c.v8__Object__Set(@ptrCast(err), context, strV(isolate, "name"), strV(isolate, "DataCloneError"), &out);
    _ = c.v8__Isolate__ThrowException(isolate, @ptrCast(err));
}

// Wide prefilter over the staged hash lanes; candidates confirmed scalar by
// backing-store pointer equality. `n` is the live count; the slices are the
// PADDED arrays (length % TLANES == 0) so the 8-lane load is always in bounds.
fn hasDuplicates(hashes: []const u32, stores: []const ?*const anyopaque, n: usize) bool {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const hvec: @Vector(TLANES, u32) = @splat(hashes[i]);
        var chunk: usize = 0;
        while (chunk < i) : (chunk += TLANES) {
            const lanes: @Vector(TLANES, u32) = @bitCast(hashes[chunk..][0..TLANES].*);
            const hit: @Vector(TLANES, bool) = lanes == hvec;
            const k = @min(TLANES, i - chunk);
            const keep: u8 = @intCast((@as(u16, 1) << @as(u4, @intCast(k))) - 1);
            var mask: u8 = @as(u8, @bitCast(hit)) & keep;
            while (mask != 0) {
                const j = chunk + @as(usize, @ctz(mask));
                mask &= mask - 1;
                if (stores[j] != null and stores[j] == stores[i]) return true;
            }
        }
    }
    return false;
}

pub fn setup(isolate: ?*c.Isolate, context: ?*c.Context) void {
    var hs: c.HandleScope = undefined;
    c.v8__HandleScope__CONSTRUCT(&hs, isolate);
    defer c.v8__HandleScope__DESTRUCT(&hs);

    c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, "transfer", 0, -1)), &str_transfer);

    const global = c.v8__Context__Global(context);
    const fnval = c.v8__Function__New__DEFAULT(context, structuredCloneCb);
    var out: c.MaybeBool = undefined;
    _ = c.v8__Object__Set(global, context, strV(isolate, "structuredClone"), @ptrCast(fnval), &out);
}

// structuredClone(value[, { transfer }]) = one ValueSerializer round-trip in
// the same isolate. V8 owns deep-clone semantics (cycles, Date, Map/Set,
// RegExp, typed arrays, BigInt). We add only the transfer-list stage (SoA +
// SIMD dup prefilter) and the two pre-checks V8's serializer does not enforce
// in this build (callables and symbols).
//
// Transfer deviation: the binding has no v8__ArrayBuffer__Detach, so the
// deserializer side registers a freshly-COPIED ArrayBuffer per transfer id.
// Observable result matches node/bun/deno (clone gets a NEW object with the
// data; every reference resolves to it), except the source buffer is NOT
// detached after the call.
fn structuredCloneCb(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate) orelse return;
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));

    const argc = c.v8__FunctionCallbackInfo__Length(info);
    const value = c.v8__FunctionCallbackInfo__INDEX(info, 0); // null -> clone undefined
    const vval: ?*const c.Value = value orelse @ptrCast(c.v8__Undefined(isolate));

    // Uncloneable pre-checks (this fork's serializer does not reject them).
    if (c.v8__Value__IsFunction(vval) or c.v8__Value__IsSymbol(vval)) {
        throwDataClone(isolate, context, "structuredClone: functions and symbols cannot be cloned");
        return;
    }

    // ---- stage the transfer list (SoA, vectors on the stack by default) ----
    var lanes_h: [TLANES]u32 = undefined;
    var lanes_s: [TLANES]?*const anyopaque = undefined;
    var lanes_b: [TLANES]?*const c.ArrayBuffer = undefined;
    var heap_h: []u32 = &.{};
    var heap_s: []?*const anyopaque = &.{};
    var heap_b: []?*const c.ArrayBuffer = &.{};
    defer if (heap_h.len != 0) gpa.free(heap_h);
    defer if (heap_s.len != 0) gpa.free(heap_s);
    defer if (heap_b.len != 0) gpa.free(heap_b);

    var hashes: []u32 = undefined;
    var stores: []?*const anyopaque = undefined;
    var slots: []?*const c.ArrayBuffer = undefined;
    var n: usize = 0;

    if (argc >= 2) {
        const options = c.v8__FunctionCallbackInfo__INDEX(info, 1);
        if (options != null and c.v8__Value__IsObject(options)) {
            const transfer = c.v8__Object__Get(
                @ptrCast(options),
                context,
                @ptrCast(c.v8__Global__Get(&str_transfer, isolate)),
            );
            if (transfer != null and !c.v8__Value__IsUndefined(transfer)) {
                if (!c.v8__Value__IsArray(transfer)) {
                    throwType(isolate, "structuredClone: transfer must be an Array");
                    return;
                }
                const total: usize = @intCast(c.v8__Array__Length(@ptrCast(transfer)));
                if (total > 0) {
                    if (total <= TLANES) {
                        hashes = lanes_h[0..TLANES];
                        stores = lanes_s[0..TLANES];
                        slots = lanes_b[0..TLANES];
                    } else {
                        const cap = std.mem.alignForward(usize, total, TLANES);
                        heap_h = gpa.alloc(u32, cap) catch return;
                        heap_s = gpa.alloc(?*const anyopaque, cap) catch return;
                        heap_b = gpa.alloc(?*const c.ArrayBuffer, cap) catch return;
                        hashes = heap_h;
                        stores = heap_s;
                        slots = heap_b;
                    }
                    var i: usize = 0;
                    while (i < total) : (i += 1) {
                        const key: ?*const c.Value = @ptrCast(c.v8__Integer__NewFromUnsigned(isolate, @intCast(i)));
                        const el = c.v8__Object__Get(@ptrCast(transfer), context, key) orelse {
                            throwDataClone(isolate, context, "structuredClone: transfer list must contain only ArrayBuffer");
                            return;
                        };
                        if (!c.v8__Value__IsArrayBuffer(el)) {
                            throwDataClone(isolate, context, "structuredClone: transfer list must contain only ArrayBuffer");
                            return;
                        }
                        const ab: ?*const c.ArrayBuffer = @ptrCast(el);
                        var store = c.v8__ArrayBuffer__GetBackingStore(ab);
                        const backing = c.std__shared_ptr__v8__BackingStore__get(&store) orelse return;
                        slots[i] = ab;
                        hashes[i] = @intCast(c.v8__Object__GetIdentityHash(@ptrCast(el)));
                        stores[i] = if (c.v8__BackingStore__Data(backing)) |d|
                            @as(?*const anyopaque, @ptrCast(d))
                        else
                            null;
                    }
                    n = total;
                    if (hasDuplicates(hashes, stores, n)) {
                        throwDataClone(isolate, context, "structuredClone: ArrayBuffer appears more than once in the transfer list");
                        return;
                    }
                }
            }
        }
    }

    // ---- serialize: transfer ids pre-registered with the SOURCE stores ----
    var ser_delegate: c.ValueSerializerDelegateCallbacks = .{};
    const ser = c.v8__ValueSerializer__New(isolate, &ser_delegate) orelse return;
    defer c.v8__ValueSerializer__DELETE(ser);
    c.v8__ValueSerializer__WriteHeader(ser);
    for (0..n) |i| {
        if (slots[i]) |ab| _ = c.v8__ValueSerializer__TransferArrayBuffer(ser, @intCast(i), ab);
    }
    var ok: c.MaybeBool = undefined;
    c.v8__ValueSerializer__WriteValue(ser, context, vval, &ok);
    if (!ok.has_value or !ok.value) return; // V8 threw; do not clobber with a return value

    var size: usize = 0;
    const wire = c.v8__ValueSerializer__Release(ser, &size);
    if (wire == null or size == 0) return;
    defer c.v8__ValueSerializer__FreeBuffer(wire);

    // ---- deserialize: transferred ids resolve to fresh COPIES of the data ----
    var des_delegate: c.ValueDeserializerDelegateCallbacks = .{};
    const des = c.v8__ValueDeserializer__New(isolate, wire, size, &des_delegate) orelse return;
    defer c.v8__ValueDeserializer__DELETE(des);
    ok = undefined;
    c.v8__ValueDeserializer__ReadHeader(des, context, &ok);
    if (!ok.has_value or !ok.value) return;
    for (0..n) |i| {
        const src = slots[i] orelse continue;
        const srclen = c.v8__ArrayBuffer__ByteLength(src);
        const copy = c.v8__ArrayBuffer__New(isolate, srclen) orelse continue;
        var cstore = c.v8__ArrayBuffer__GetBackingStore(copy);
        const cbacking = c.std__shared_ptr__v8__BackingStore__get(&cstore) orelse continue;
        const cdst: [*]u8 = @ptrCast(@alignCast(c.v8__BackingStore__Data(cbacking) orelse continue));
        var sstore = c.v8__ArrayBuffer__GetBackingStore(src);
        const sbacking = c.std__shared_ptr__v8__BackingStore__get(&sstore) orelse continue;
        const sdat: [*]const u8 = @ptrCast(@alignCast(c.v8__BackingStore__Data(sbacking) orelse continue));
        @memcpy(cdst[0..srclen], sdat[0..srclen]);
        _ = c.v8__ValueDeserializer__TransferArrayBuffer(des, @intCast(i), copy);
    }
    if (c.v8__ValueDeserializer__ReadValue(des, context)) |cloned| {
        c.v8__ReturnValue__Set(ret, cloned);
    }
}
