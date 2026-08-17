const std = @import("std");
const c = @import("../c.zig").c;
const async_fetch = @import("../net/async_fetch.zig");

const gpa = std.heap.page_allocator;
const MAX_LISTENERS = 8; // one vector lane per listener

// Backing store for an AbortSignal. Leaked for the isolate's lifetime (same
// contract as ResponseData). All fields are main-thread only — no locks.
//
// Listener store is SoA, one lane per listener (MAX_LISTENERS = a full vector):
//   globals[8]  — V8 handles            (field per lane)
//   once[8]     — {once: true} flag     (field per lane, u8 0/1 so a [8]u8 ->
//                 @Vector(8, u8) bitcast keeps 64 bits exact)
//   hashes[8]   — cached identity hash  (field per lane, SIMD scan domain)
//   count       — live prefix length (contiguous, preserves fire order)
//
// Hybrids (vector wide, then scalar per element — house style):
//   removeEventListener: wide u32 hash compare -> @bitCast bitmask -> scalar
//     Global__IsEqual confirm on candidate lanes (collision-safe).
//   dispatch once-sweep: vector compare of once lanes -> bitmask -> ctz loop.
pub const SignalData = struct {
    aborted: bool = false,
    signal_obj: c.Global = .{ .data_ptr = 0 },
    count: u8 = 0,
    globals: [MAX_LISTENERS]c.Global = [_]c.Global{.{ .data_ptr = 0 }} ** MAX_LISTENERS,
    once:    [MAX_LISTENERS]u8 = [_]u8{0} ** MAX_LISTENERS,
    hashes:  [MAX_LISTENERS]u32 = [_]u32{0} ** MAX_LISTENERS,
};

var abort_static_marker: u8 = 0; // stable address for the static .abort data slot

fn setProp(isolate: ?*c.Isolate, ctx: ?*const c.Context, obj: ?*const c.Object, comptime key: []const u8, val: ?*const c.Value) void {
    var out: c.MaybeBool = undefined;
    _ = c.v8__Object__Set(
        obj,
        ctx,
        @ptrCast(c.v8__String__NewFromUtf8(isolate, key.ptr, 0, key.len)),
        val,
        &out,
    );
}

fn strV(isolate: ?*c.Isolate, comptime s: []const u8) *const c.Value {
    return @ptrCast(c.v8__String__NewFromUtf8(isolate, s.ptr, 0, s.len));
}

// Default `reason` / rejection value: an Error whose .name is "AbortError".
fn abortReason(isolate: ?*c.Isolate, ctx: ?*const c.Context, reason_val: ?*const c.Value) *const c.Value {
    if (reason_val != null) return @ptrCast(reason_val.?);
    const err = c.v8__Exception__Error(strV(isolate, "This operation was aborted"));
    var out: c.MaybeBool = undefined;
    _ = c.v8__Object__Set(@ptrCast(err), ctx, strV(isolate, "name"), strV(isolate, "AbortError"), &out);
    return @ptrCast(err);
}

// Public: recover the backing SignalData from any object carrying our __d.
pub fn dataOf(isolate: ?*c.Isolate, ctx: ?*const c.Context, val: ?*const c.Value) ?*SignalData {
    if (val == null or !c.v8__Value__IsObject(val)) return null;
    const ext = c.v8__Object__Get(@ptrCast(val), ctx, c.v8__String__NewFromUtf8(isolate, "__d", 0, -1)) orelse return null;
    if (!c.v8__Value__IsExternal(ext)) return null;
    const p = c.v8__External__Value(@ptrCast(ext));
    return @ptrCast(@alignCast(p));
}

pub fn isAborted(sig: ?*const anyopaque) bool {
    if (sig == null) return false;
    const d: *const SignalData = @ptrCast(@alignCast(sig));
    return d.aborted;
}

// Compaction: drop lane i, shift the three SoA lanes left, keep order.
fn removeStore(data: *SignalData, i: usize) void {
    c.v8__Global__Reset(&data.globals[i]);
    var j = i;
    while (j + 1 < data.count) : (j += 1) {
        data.globals[j] = data.globals[j + 1];
        data.once[j] = data.once[j + 1];
        data.hashes[j] = data.hashes[j + 1];
    }
    data.count -= 1;
}

fn dispatch(data: *SignalData, isolate: ?*c.Isolate, ctx: ?*const c.Context) void {
    const signal = c.v8__Global__Get(&data.signal_obj, isolate);
    var i: usize = 0;
    while (i < data.count) : (i += 1) {
        if (c.v8__Global__Get(&data.globals[i], isolate)) |f| {
            _ = c.v8__Function__Call(@ptrCast(f), ctx, @ptrCast(signal), 0, null);
        }
    }
    if (signal) |sig| {
        const onabort = c.v8__Object__Get(@ptrCast(sig), ctx, c.v8__String__NewFromUtf8(isolate, "onabort", 0, -1));
        if (onabort != null and c.v8__Value__IsFunction(onabort)) {
            _ = c.v8__Function__Call(@ptrCast(onabort), ctx, @ptrCast(sig), 0, null);
        }
    }
    // Vectorized once-sweep: single compare over all lanes -> bitmask. Pad
    // lanes are 0 (never set), so no count mask is needed.
    const onc: @Vector(MAX_LISTENERS, u8) = @bitCast(data.once);
    const eq: @Vector(MAX_LISTENERS, bool) = onc == @as(@Vector(MAX_LISTENERS, u8), @splat(1));
    var m: u8 = @bitCast(eq);
    while (m != 0) {
        const idx: usize = @ctz(m);
        m &= m - 1;
        removeStore(data, idx);
    }
}

fn makeSignal(isolate: ?*c.Isolate, ctx: ?*const c.Context, pre_aborted: bool, reason_val: ?*const c.Value, out: *?*SignalData) ?*const c.Object {
    const data = gpa.create(SignalData) catch return null;
    data.* = .{};
    data.aborted = pre_aborted;
    out.* = data;

    const obj = c.v8__Object__New(isolate) orelse return null;
    c.v8__Global__New(isolate, @ptrCast(obj), &data.signal_obj);
    setProp(isolate, ctx, obj, "aborted", @ptrCast(if (pre_aborted) c.v8__True(isolate) else c.v8__False(isolate)));
    setProp(isolate, ctx, obj, "reason", abortReason(isolate, ctx, reason_val));

    const ext = c.v8__External__New(isolate, @ptrCast(data));
    const add = c.v8__Function__New__DEFAULT2(ctx, addEventListenerCb, @ptrCast(ext)) orelse return null;
    setProp(isolate, ctx, obj, "addEventListener", @ptrCast(add));
    const rem = c.v8__Function__New__DEFAULT2(ctx, removeEventListenerCb, @ptrCast(ext)) orelse return null;
    setProp(isolate, ctx, obj, "removeEventListener", @ptrCast(rem));
    const th = c.v8__Function__New__DEFAULT2(ctx, throwIfAbortedCb, @ptrCast(ext)) orelse return null;
    setProp(isolate, ctx, obj, "throwIfAborted", @ptrCast(th));
    setProp(isolate, ctx, obj, "__d", @ptrCast(c.v8__External__New(isolate, @ptrCast(data))));
    return obj;
}

fn makeController(isolate: ?*c.Isolate, ctx: ?*const c.Context) ?*const c.Object {
    var data: ?*SignalData = null;
    const signal = makeSignal(isolate, ctx, false, null, &data) orelse return null;
    const controller = c.v8__Object__New(isolate) orelse return null;
    setProp(isolate, ctx, controller, "signal", @ptrCast(signal));
    const ext = c.v8__External__New(isolate, @ptrCast(data.?));
    const abort = c.v8__Function__New__DEFAULT2(ctx, abortCb, @ptrCast(ext)) orelse return null;
    setProp(isolate, ctx, controller, "abort", @ptrCast(abort));
    return controller;
}

// ---- callbacks ----

fn abortControllerCb(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const ctx = c.v8__Isolate__GetCurrentContext(isolate) orelse return;
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(makeController(isolate, ctx) orelse c.v8__Undefined(isolate)));
}

fn abortSignalCb(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const ctx = c.v8__Isolate__GetCurrentContext(isolate) orelse return;
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    var data: ?*SignalData = null;
    c.v8__ReturnValue__Set(ret, @ptrCast(makeSignal(isolate, ctx, false, null, &data) orelse c.v8__Undefined(isolate)));
}

fn abortStaticCb(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__Isolate__GetCurrent() orelse return;
    const ctx = c.v8__Isolate__GetCurrentContext(isolate) orelse return;
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const reason = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    var data: ?*SignalData = null;
    c.v8__ReturnValue__Set(ret, @ptrCast(makeSignal(isolate, ctx, true, reason, &data) orelse c.v8__Undefined(isolate)));
}

fn abortCb(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const ctx = c.v8__Isolate__GetCurrentContext(isolate) orelse return;
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));

    const dv = c.v8__FunctionCallbackInfo__Data(info) orelse return;
    const data: *SignalData = @ptrCast(@alignCast(c.v8__External__Value(@ptrCast(dv))));
    const reason = if (c.v8__FunctionCallbackInfo__Length(info) >= 1) c.v8__FunctionCallbackInfo__INDEX(info, 0) else null;

    data.aborted = true;
    if (c.v8__Global__Get(&data.signal_obj, isolate)) |sig| {
        setProp(isolate, ctx, @ptrCast(sig), "aborted", @ptrCast(c.v8__True(isolate)));
        setProp(isolate, ctx, @ptrCast(sig), "reason", abortReason(isolate, ctx, reason));
    }
    dispatch(data, isolate, ctx);
    async_fetch.abortWalk(@ptrCast(data));
}

fn addEventListenerCb(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const dv = c.v8__FunctionCallbackInfo__Data(info) orelse return;
    const data: *SignalData = @ptrCast(@alignCast(c.v8__External__Value(@ptrCast(dv))));
    if (c.v8__FunctionCallbackInfo__Length(info) < 2) return;
    const handler = c.v8__FunctionCallbackInfo__INDEX(info, 1) orelse return;
    if (!c.v8__Value__IsFunction(handler)) return;
    if (data.count >= MAX_LISTENERS) return;
    var once = false;
    const opts = c.v8__FunctionCallbackInfo__INDEX(info, 2);
    if (opts != null and c.v8__Value__IsObject(opts)) {
        const ctx = c.v8__Isolate__GetCurrentContext(isolate);
        const o = c.v8__Object__Get(@ptrCast(opts), ctx, c.v8__String__NewFromUtf8(isolate, "once", 0, -1));
        if (o != null and c.v8__Value__BooleanValue(o, isolate)) once = true;
    }
    const i: usize = data.count;
    c.v8__Global__New(isolate, @ptrCast(handler), &data.globals[i]);
    data.once[i] = @intFromBool(once);
    data.hashes[i] = @intCast(c.v8__Object__GetIdentityHash(@ptrCast(handler)));
    data.count += 1;
}

fn removeEventListenerCb(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const dv = c.v8__FunctionCallbackInfo__Data(info) orelse return;
    const data: *SignalData = @ptrCast(@alignCast(c.v8__External__Value(@ptrCast(dv))));
    if (c.v8__FunctionCallbackInfo__Length(info) < 2) return;
    const handler = c.v8__FunctionCallbackInfo__INDEX(info, 1) orelse return;

    // SIMD prefilter: one vector compare of all 8 hash lanes -> candidate
    // bitmask. Identity is then confirmed per candidate with Global__IsEqual,
    // which handles the (rare) hash collision correctly. Local-handle `==` is
    // meaningless, so this never compares handles.
    const h: u32 = @intCast(c.v8__Object__GetIdentityHash(@ptrCast(handler)));
    const hv: @Vector(MAX_LISTENERS, u32) = @bitCast(data.hashes);
    const eq: @Vector(MAX_LISTENERS, bool) = hv == @as(@Vector(MAX_LISTENERS, u32), @splat(h));
    var m: u8 = @bitCast(eq);
    while (m != 0) {
        const idx: usize = @ctz(m);
        m &= m - 1;
        if (idx >= data.count) continue;
        if (c.v8__Global__IsEqual(&data.globals[idx], @ptrCast(handler))) {
            removeStore(data, idx);
            return;
        }
    }
}

fn throwIfAbortedCb(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const ctx = c.v8__Isolate__GetCurrentContext(isolate) orelse return;
    const dv = c.v8__FunctionCallbackInfo__Data(info) orelse return;
    const data: *SignalData = @ptrCast(@alignCast(c.v8__External__Value(@ptrCast(dv))));
    if (!data.aborted) return;
    var reason = abortReason(isolate, ctx, null);
    if (c.v8__Global__Get(&data.signal_obj, isolate)) |sig| {
        const r = c.v8__Object__Get(@ptrCast(sig), ctx, c.v8__String__NewFromUtf8(isolate, "reason", 0, -1));
        if (r != null and !c.v8__Value__IsUndefined(r)) reason = @ptrCast(r);
    }
    _ = c.v8__Isolate__ThrowException(isolate, reason);
}

pub fn setup(isolate: ?*c.Isolate, context: ?*c.Context) void {
    var hs: c.HandleScope = undefined;
    c.v8__HandleScope__CONSTRUCT(&hs, isolate);
    defer c.v8__HandleScope__DESTRUCT(&hs);

    const global = c.v8__Context__Global(context);
    var out: c.MaybeBool = undefined;

    const ctrl = c.v8__Function__New__DEFAULT(context, abortControllerCb);
    _ = c.v8__Object__Set(global, context, strV(isolate, "AbortController"), @ptrCast(ctrl), &out);

    const sig_fn = c.v8__Function__New__DEFAULT(context, abortSignalCb);
    _ = c.v8__Object__Set(global, context, strV(isolate, "AbortSignal"), @ptrCast(sig_fn), &out);

    const st = c.v8__Function__New__DEFAULT2(context, abortStaticCb, @ptrCast(c.v8__External__New(isolate, @ptrCast(&abort_static_marker))));
    setProp(isolate, context, @ptrCast(sig_fn), "abort", @ptrCast(st));
}
