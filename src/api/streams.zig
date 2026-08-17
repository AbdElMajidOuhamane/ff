const std = @import("std");
const c = @import("../c.zig").c;

// ============================================================

//
// DOD: every stream slot is index-addressed inside fixed-capacity SoA
// arrays. Zero per-object heap allocation; the JS object carries only an
// External encoding its slot index.
//
// SIMD: 8-lane @Vector(8, usize) sweeps over `data_ptr` handles produce a
// bitmask via @bitCast; @ctz walks lanes in FIFO order. Chunk and
// pending-reader lanes are ordered bitmaps — no head/tail pointers, no
// shifts, no compaction.
// ============================================================

const MAX_STREAMS: usize = 16;
const SLOT_LANES: usize = 8;

const StreamState = enum(u8) { free = 0, readable = 1, closed = 2, errored = 3 };

// -------- SoA store -----------------------------------------------------
var states: [MAX_STREAMS]u8 = [_]u8{0} ** MAX_STREAMS;
var error_vals: [MAX_STREAMS]c.Global = [_]c.Global{.{ .data_ptr = 0 }} ** MAX_STREAMS;
var src_start: [MAX_STREAMS]c.Global = [_]c.Global{.{ .data_ptr = 0 }} ** MAX_STREAMS;
var src_cancel: [MAX_STREAMS]c.Global = [_]c.Global{.{ .data_ptr = 0 }} ** MAX_STREAMS;
var chunk_vals: [MAX_STREAMS][SLOT_LANES]c.Global =
    [_][SLOT_LANES]c.Global{[_]c.Global{.{ .data_ptr = 0 }} ** SLOT_LANES} ** MAX_STREAMS;
var pending_vals: [MAX_STREAMS][SLOT_LANES]c.Global =
    [_][SLOT_LANES]c.Global{[_]c.Global{.{ .data_ptr = 0 }} ** SLOT_LANES} ** MAX_STREAMS;
var next_free: [MAX_STREAMS]u8 = undefined;
var free_head: u8 = 0xFF;
var store_init: bool = false;

// -------- SIMD lane primitives -------------------------------------------
inline fn loadLanes(lanes: *const [SLOT_LANES]c.Global) @Vector(SLOT_LANES, usize) {
    var v: @Vector(SLOT_LANES, usize) = undefined;
    inline for (0..SLOT_LANES) |i| v[i] = lanes[i].data_ptr;
    return v;
}

inline fn occupiedMask(lanes: *const [SLOT_LANES]c.Global) u8 {
    const nonnull: @Vector(SLOT_LANES, bool) =
        loadLanes(lanes) != @as(@Vector(SLOT_LANES, usize), @splat(0));
    return @bitCast(nonnull);
}

inline fn firstLane(mask: u8) u8 {
    return @intCast(@ctz(mask));
}

inline fn freeLane(mask: u8) u8 {
    return @intCast(@ctz(~mask));
}

inline fn stateOf(slot: u8) StreamState {
    return @enumFromInt(states[slot]);
}

// -------- slot alloc -------------------------------------------------------
fn storeInit() void {
    if (store_init) return;
    for (0..MAX_STREAMS - 1) |i| next_free[i] = @intCast(i + 1);
    next_free[MAX_STREAMS - 1] = 0xFF;
    free_head = 0;
    store_init = true;
}

fn allocStream() u8 {
    storeInit();
    const slot = free_head;
    if (slot == 0xFF) return 0xFF;
    free_head = next_free[slot];
    states[slot] = @intFromEnum(StreamState.readable);
    error_vals[slot] = .{ .data_ptr = 0 };
    src_start[slot] = .{ .data_ptr = 0 };
    src_cancel[slot] = .{ .data_ptr = 0 };
    chunk_vals[slot] = [_]c.Global{.{ .data_ptr = 0 }} ** SLOT_LANES;
    pending_vals[slot] = [_]c.Global{.{ .data_ptr = 0 }} ** SLOT_LANES;
    return slot;
}

// -------- helpers ------------------------------------------------------------
fn throw(isolate: ?*c.Isolate, msg: []const u8) void {
    const v8_msg = c.v8__String__NewFromUtf8(isolate, @ptrCast(msg.ptr), 0, @intCast(msg.len));
    const exc = c.v8__Exception__Error(v8_msg);
    _ = c.v8__Isolate__ThrowException(isolate, exc);
}

fn extractSlotFromThis(isolate: ?*c.Isolate, ctx: ?*c.Context, info: ?*const c.FunctionCallbackInfo) ?u8 {
    const this = c.v8__FunctionCallbackInfo__This(info) orelse return null;
    const key = c.v8__String__NewFromUtf8(isolate, "__d", 0, -1);
    const ext_val = c.v8__Object__Get(this, ctx, key) orelse return null;
    if (!c.v8__Value__IsExternal(ext_val)) return null;
    const p = c.v8__External__Value(@ptrCast(ext_val)) orelse return null;
    const idx: u8 = @intCast(@intFromPtr(p) - 1);
    return idx;
}

fn extractMethod(isolate: ?*c.Isolate, ctx: ?*c.Context, obj: ?*const c.Object, name: []const u8) ?*const c.Value {
    const key = c.v8__String__NewFromUtf8(isolate, @ptrCast(name.ptr), 0, @intCast(name.len));
    const val = c.v8__Object__Get(obj, ctx, key) orelse return null;
    if (!c.v8__Value__IsFunction(val)) return null;
    return val;
}

fn resolveResult(isolate: ?*c.Isolate, ctx: ?*c.Context, resolver: ?*const c.Value, done: bool, value: ?*const c.Value) void {
    var out: c.MaybeBool = undefined;
    const obj = c.v8__Object__New(isolate);
    _ = c.v8__Object__Set(obj, ctx, c.v8__String__NewFromUtf8(isolate, "done", 0, -1),
        @ptrCast(if (done) c.v8__True(isolate) else c.v8__False(isolate)), &out);
    _ = c.v8__Object__Set(obj, ctx, c.v8__String__NewFromUtf8(isolate, "value", 0, -1),
        @ptrCast(value orelse c.v8__Undefined(isolate)), &out);
    c.v8__Promise__Resolver__Resolve(resolver, ctx, @ptrCast(obj), &out);
}

fn flushPending(isolate: ?*c.Isolate, ctx: ?*c.Context, slot: u8, done: bool) void {
    const pend = &pending_vals[slot];
    var pmask = occupiedMask(pend);
    while (pmask != 0) {
        const lane = firstLane(pmask);
        const resolver: ?*const c.Value = @ptrCast(c.v8__Global__Get(&pend[lane], isolate));
        if (done) {
            resolveResult(isolate, ctx, resolver, true, null);
        } else {
            var out: c.MaybeBool = undefined;
            c.v8__Promise__Resolver__Reject(resolver, ctx,
                @ptrCast(c.v8__Global__Get(&error_vals[slot], isolate)), &out);
        }
        pend[lane] = .{ .data_ptr = 0 };
        pmask = occupiedMask(pend);
    }
}

fn clearChunks(slot: u8) void {
    const chunks = &chunk_vals[slot];
    var cmask = occupiedMask(chunks);
    while (cmask != 0) {
        const lane = firstLane(cmask);
        c.v8__Global__Reset(&chunks[lane]);
        chunks[lane] = .{ .data_ptr = 0 };
        cmask = occupiedMask(chunks);
    }
}

fn buildStreamJSObject(isolate: ?*c.Isolate, ctx: ?*c.Context, slot: u8) ?*const c.Object {
    const obj = c.v8__Object__New(isolate);
    var out: c.MaybeBool = undefined;
   const ext = c.v8__External__New(isolate, @ptrFromInt(@as(usize, slot) + 1));
    _ = c.v8__Object__Set(obj, ctx, c.v8__String__NewFromUtf8(isolate, "__d", 0, -1), ext, &out);
    _ = c.v8__Object__Set(obj, ctx, c.v8__String__NewFromUtf8(isolate, "getReader", 0, -1),
        c.v8__Function__New__DEFAULT(ctx, stream_getReader), &out);
    _ = c.v8__Object__Set(obj, ctx, c.v8__String__NewFromUtf8(isolate, "cancel", 0, -1),
        c.v8__Function__New__DEFAULT(ctx, stream_cancel), &out);
    return obj;
}

fn buildControllerJSObject(isolate: ?*c.Isolate, ctx: ?*c.Context, slot: u8) ?*const c.Object {
    const obj = c.v8__Object__New(isolate);
    var out: c.MaybeBool = undefined;
    const ext = c.v8__External__New(isolate, @ptrFromInt(@as(usize, slot) + 1));
    _ = c.v8__Object__Set(obj, ctx, c.v8__String__NewFromUtf8(isolate, "__d", 0, -1), ext, &out);
    _ = c.v8__Object__Set(obj, ctx, c.v8__String__NewFromUtf8(isolate, "desiredSize", 0, -1),
        c.v8__Integer__New(isolate, 0), &out);
    _ = c.v8__Object__Set(obj, ctx, c.v8__String__NewFromUtf8(isolate, "enqueue", 0, -1),
        c.v8__Function__New__DEFAULT(ctx, controller_enqueue), &out);
    _ = c.v8__Object__Set(obj, ctx, c.v8__String__NewFromUtf8(isolate, "close", 0, -1),
        c.v8__Function__New__DEFAULT(ctx, controller_close), &out);
    _ = c.v8__Object__Set(obj, ctx, c.v8__String__NewFromUtf8(isolate, "error", 0, -1),
        c.v8__Function__New__DEFAULT(ctx, controller_error), &out);
    return obj;
}

// -------- stream callbacks ----------------------------------------------------
fn streamConstructor(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const ctx = c.v8__Isolate__GetCurrentContext(isolate) orelse return;
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);

    const slot = allocStream();
    if (slot == 0xFF) {
        throw(isolate, "too many ReadableStreams");
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));
        return;
    }

    const src = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    if (src) |s| {
        if (c.v8__Value__IsObject(s)) {
            const obj: ?*const c.Object = @ptrCast(s);
            if (extractMethod(isolate, ctx, obj, "start")) |fnv| {
                c.v8__Global__New(isolate, @ptrCast(fnv), &src_start[slot]);
            }
            if (extractMethod(isolate, ctx, obj, "cancel")) |fnv| {
                c.v8__Global__New(isolate, @ptrCast(fnv), &src_cancel[slot]);
            }
        }
    }

    const stream_obj = buildStreamJSObject(isolate, ctx, slot);
    const ctrl = buildControllerJSObject(isolate, ctx, slot);
    if (stream_obj == null or ctrl == null) {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));
        return;
    }
    if (src_start[slot].data_ptr != 0) {
        const argv = [_]?*const c.Value{@ptrCast(ctrl)};
        _ = c.v8__Function__Call(
            @ptrCast(c.v8__Global__Get(&src_start[slot], isolate)),
            ctx,
            @ptrCast(c.v8__Undefined(isolate)),
            1,
            &argv,
        );
    }
    c.v8__ReturnValue__Set(ret, @ptrCast(stream_obj));
}

fn stream_getReader(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const ctx = c.v8__Isolate__GetCurrentContext(isolate) orelse return;
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const slot = extractSlotFromThis(isolate, ctx, info) orelse return;

    const reader = c.v8__Object__New(isolate);
    var out: c.MaybeBool = undefined;
    const ext = c.v8__External__New(isolate, @ptrFromInt(@as(usize, slot) + 1));
    _ = c.v8__Object__Set(reader, ctx, c.v8__String__NewFromUtf8(isolate, "__d", 0, -1), ext, &out);
    _ = c.v8__Object__Set(reader, ctx, c.v8__String__NewFromUtf8(isolate, "read", 0, -1),
        c.v8__Function__New__DEFAULT(ctx, reader_read), &out);
    _ = c.v8__Object__Set(reader, ctx, c.v8__String__NewFromUtf8(isolate, "releaseLock", 0, -1),
        c.v8__Function__New__DEFAULT(ctx, reader_releaseLock), &out);
    _ = c.v8__Object__Set(reader, ctx, c.v8__String__NewFromUtf8(isolate, "cancel", 0, -1),
        c.v8__Function__New__DEFAULT(ctx, reader_cancel), &out);
    c.v8__ReturnValue__Set(ret, @ptrCast(reader));
}

fn stream_cancel(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const ctx = c.v8__Isolate__GetCurrentContext(isolate) orelse return;
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const slot = extractSlotFromThis(isolate, ctx, info) orelse return;
    const reason = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    doCancel(isolate, ctx, slot, reason);
    c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));
}

// -------- reader callbacks -------------------------------------------------------
fn reader_read(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const ctx = c.v8__Isolate__GetCurrentContext(isolate) orelse return;
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const slot = extractSlotFromThis(isolate, ctx, info) orelse return;

    const resolver = c.v8__Promise__Resolver__New(ctx) orelse return;
    const promise = c.v8__Promise__Resolver__GetPromise(resolver) orelse return;

    const chunks = &chunk_vals[slot];
    const cmask = occupiedMask(chunks);
    if (cmask != 0) {
        const lane = firstLane(cmask);
        const chunk: ?*const c.Value = @ptrCast(c.v8__Global__Get(&chunks[lane], isolate));
        resolveResult(isolate, ctx, resolver, false, chunk);
        c.v8__Global__Reset(&chunks[lane]);
        chunks[lane] = .{ .data_ptr = 0 };
        c.v8__ReturnValue__Set(ret, @ptrCast(promise));
        return;
    }
    switch (stateOf(slot)) {
        .closed => {
            resolveResult(isolate, ctx, resolver, true, null);
            c.v8__ReturnValue__Set(ret, @ptrCast(promise));
        },
        .errored => {
            var out: c.MaybeBool = undefined;
            c.v8__Promise__Resolver__Reject(resolver, ctx,
                @ptrCast(c.v8__Global__Get(&error_vals[slot], isolate)), &out);
            c.v8__ReturnValue__Set(ret, @ptrCast(promise));
        },
        .readable => {
            const pend = &pending_vals[slot];
            const pmask = occupiedMask(pend);
            if (pmask == 0xFF) {
                var out: c.MaybeBool = undefined;
                c.v8__Promise__Resolver__Reject(resolver, ctx,
                    @ptrCast(c.v8__String__NewFromUtf8(isolate, "too many pending reads", 0, -1)), &out);
            } else {
                c.v8__Global__New(isolate, @ptrCast(resolver), &pend[freeLane(pmask)]);
            }
            c.v8__ReturnValue__Set(ret, @ptrCast(promise));
        },
        .free => unreachable,
    }
}

fn reader_releaseLock(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));
}

fn reader_cancel(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const ctx = c.v8__Isolate__GetCurrentContext(isolate) orelse return;
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const slot = extractSlotFromThis(isolate, ctx, info) orelse return;
    const reason = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    doCancel(isolate, ctx, slot, reason);
    c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));
}

fn doCancel(isolate: ?*c.Isolate, ctx: ?*c.Context, slot: u8, reason: ?*const c.Value) void {
    if (src_cancel[slot].data_ptr != 0) {
        const argv = [_]?*const c.Value{reason orelse @ptrCast(c.v8__Undefined(isolate))};
        _ = c.v8__Function__Call(
            @ptrCast(c.v8__Global__Get(&src_cancel[slot], isolate)),
            ctx,
            @ptrCast(c.v8__Undefined(isolate)),
            1,
            &argv,
        );
    }
    states[slot] = @intFromEnum(StreamState.closed);
    flushPending(isolate, ctx, slot, true);
    clearChunks(slot);
}

// -------- controller callbacks -----------------------------------------------------
fn controller_enqueue(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const ctx = c.v8__Isolate__GetCurrentContext(isolate) orelse return;
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const slot = extractSlotFromThis(isolate, ctx, info) orelse return;
    const val = c.v8__FunctionCallbackInfo__INDEX(info, 0);

    const pend = &pending_vals[slot];
    const pmask = occupiedMask(pend);
    if (pmask != 0) {
        const lane = firstLane(pmask);
        const resolver: ?*const c.Value = @ptrCast(c.v8__Global__Get(&pend[lane], isolate));
        resolveResult(isolate, ctx, resolver, false, val);
        c.v8__Global__Reset(&pend[lane]);
        pend[lane] = .{ .data_ptr = 0 };
    } else {
        const chunks = &chunk_vals[slot];
        const cmask = occupiedMask(chunks);
        if (cmask != 0xFF) {
            c.v8__Global__New(isolate, @ptrCast(val), &chunks[freeLane(cmask)]);
        } // else chunk queue full: drop (documented limitation)
    }
    c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));
}

fn controller_close(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const ctx = c.v8__Isolate__GetCurrentContext(isolate) orelse return;
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const slot = extractSlotFromThis(isolate, ctx, info) orelse return;
    states[slot] = @intFromEnum(StreamState.closed);
    flushPending(isolate, ctx, slot, true);
    c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));
}

fn controller_error(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const ctx = c.v8__Isolate__GetCurrentContext(isolate) orelse return;
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const slot = extractSlotFromThis(isolate, ctx, info) orelse return;
    const s = stateOf(slot);
    if (s == .errored or s == .closed) return;
    const err = c.v8__FunctionCallbackInfo__INDEX(info, 0) orelse c.v8__Undefined(isolate);
    states[slot] = @intFromEnum(StreamState.errored);
    c.v8__Global__New(isolate, @ptrCast(err), &error_vals[slot]);
    flushPending(isolate, ctx, slot, false);
    clearChunks(slot);
    c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));
}

// -------- public API ---------------------------------------------------------------
pub fn makeByteStream(isolate: ?*c.Isolate, context: ?*c.Context, bytes: []const u8) ?*const c.Object {
    const slot = allocStream();
    if (slot == 0xFF) return null;

    const ab = c.v8__ArrayBuffer__New(isolate, bytes.len);
    if (bytes.len > 0) {
        const backing = c.v8__ArrayBuffer__GetBackingStore(ab);
        const store_ptr = c.std__shared_ptr__v8__BackingStore__get(&backing);
        if (store_ptr != null) {
            const data_ptr: [*]u8 = @ptrCast(@alignCast(c.v8__BackingStore__Data(store_ptr)));
            @memcpy(data_ptr[0..bytes.len], bytes);
        }
    }
    c.v8__Global__New(isolate, @ptrCast(c.v8__Uint8Array__New(ab, 0, bytes.len)), &chunk_vals[slot][0]);
    states[slot] = @intFromEnum(StreamState.closed);
    return buildStreamJSObject(isolate, context, slot);
}

pub fn setup(isolate: ?*c.Isolate, context: ?*c.Context) void {
    storeInit();
    var out: c.MaybeBool = undefined;
    const global = c.v8__Context__Global(context);
    _ = c.v8__Object__Set(global, context, c.v8__String__NewFromUtf8(isolate, "ReadableStream", 0, -1),
        c.v8__Function__New__DEFAULT(context, streamConstructor), &out);
}
