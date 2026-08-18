const std = @import("std");
const c = @import("../c.zig").c;
const formdata = @import("./formdata.zig");
const headers_mod = @import("../types/headers.zig");
const url_api = @import("./url.zig");

// ============================================================
// Iterables — [Symbol.iterator] for host collection objects.
//
// DOD: FormData / Headers / URLSearchParams each carry a `__d`
// External (their backing SoA store). One `[Symbol.iterator]`
// factory per kind and ONE shared `next` dispatcher are rooted as
// Globals at setup; the well-known symbol key is cached once.
// Each iterator is a lean { __d, kind, pos, next } object — state
// lives in its own properties, so no slot pool whose reuse could
// silently alias two live iterators.
//
// SIMD note: every step materializes a fresh [name, value] tuple
// (construction-latency-bound), so a lane sweep buys nothing here;
// the DOD shape is what carries it. Property-name strings are
// cached Globals to keep the hot next() path allocation-free.
// ============================================================

pub const Kind = enum(u8) { formdata = 0, headers = 1, searchparams = 2 };

const MAX_KIND: u32 = 3;

var sym_iterator: c.Global = .{ .data_ptr = 0 };
var g_factory: [MAX_KIND]c.Global = [_]c.Global{.{ .data_ptr = 0 }} ** MAX_KIND;
var g_next: c.Global = .{ .data_ptr = 0 };

var str___d: c.Global = .{ .data_ptr = 0 };
var str_kind: c.Global = .{ .data_ptr = 0 };
var str_pos: c.Global = .{ .data_ptr = 0 };
var str_next: c.Global = .{ .data_ptr = 0 };
var str_done: c.Global = .{ .data_ptr = 0 };
var str_value: c.Global = .{ .data_ptr = 0 };

fn key(isolate: ?*c.Isolate, g: *const c.Global) ?*const c.Value {
    return @ptrCast(c.v8__Global__Get(g, isolate));
}

fn kindFromData(data: ?*const c.Value) ?Kind {
    if (data == null or !c.v8__Value__IsExternal(data)) return null;
    const p = c.v8__External__Value(@ptrCast(data)) orelse return null;
    const k = @intFromPtr(p);
    if (k == 0 or k > 3) return null;
    return @enumFromInt(@as(u8, @intCast(k - 1)));
}

const Pair = struct { name: []const u8, value: []const u8 };

fn countFor(owner: *anyopaque, kind: Kind) usize {
    return switch (kind) {
        .formdata => @as(*const formdata.FormDataData, @ptrCast(@alignCast(owner))).len(),
        .headers => @as(*const headers_mod.HeadersData, @ptrCast(@alignCast(owner))).len(),
        .searchparams => @as(*const url_api.URLSearchParamsData, @ptrCast(@alignCast(owner))).pairs.items.len,
    };
}

fn pairFor(owner: *anyopaque, kind: Kind, i: usize) Pair {
    return switch (kind) {
        .formdata => (blk: {
            const d: *const formdata.FormDataData = @ptrCast(@alignCast(owner));
            break :blk .{
                .name = d.names.items[i],
                .value = if (d.filenames.items[i]) |f| f else d.values.items[i],
            };
        }),
        .headers => (blk: {
            const d: *const headers_mod.HeadersData = @ptrCast(@alignCast(owner));
            const p = d.getPair(i);
            break :blk .{ .name = p.name, .value = p.value };
        }),
        .searchparams => (blk: {
            const d: *const url_api.URLSearchParamsData = @ptrCast(@alignCast(owner));
            break :blk .{ .name = d.pairs.items[i].name, .value = d.pairs.items[i].value };
        }),
    };
}

fn buildResult(isolate: ?*c.Isolate, ctx: ?*c.Context, done: bool, value: ?*const c.Value) ?*const c.Value {
    const obj = c.v8__Object__New(isolate);
    var out: c.MaybeBool = undefined;
    _ = c.v8__Object__Set(obj, ctx, key(isolate, &str_done),
        @ptrCast(if (done) c.v8__True(isolate) else c.v8__False(isolate)), &out);
    _ = c.v8__Object__Set(obj, ctx, key(isolate, &str_value),
        @ptrCast(value orelse c.v8__Undefined(isolate)), &out);
    return obj;
}

fn pairArray(isolate: ?*c.Isolate, ctx: ?*c.Context, name: []const u8, value: []const u8) ?*const c.Value {
    const arr = c.v8__Array__New(isolate, 2);
    var out: c.MaybeBool = undefined;
    _ = c.v8__Object__SetAtIndex(@ptrCast(arr), ctx, 0, @ptrCast(c.v8__String__NewFromUtf8(isolate, @ptrCast(name.ptr), 0, @intCast(name.len))), &out);
    _ = c.v8__Object__SetAtIndex(@ptrCast(arr), ctx, 1, @ptrCast(c.v8__String__NewFromUtf8(isolate, @ptrCast(value.ptr), 0, @intCast(value.len))), &out);
    return @ptrCast(arr);
}

fn intProp(isolate: ?*c.Isolate, ctx: ?*c.Context, obj: ?*const c.Object, g: *const c.Global) ?u32 {
    const v = c.v8__Object__Get(obj, ctx, key(isolate, g)) orelse return null;
    var maybe: c.MaybeI32 = undefined;
    c.v8__Value__Int32Value(v, ctx, &maybe);
    if (!maybe.has_value) return null;
    return @intCast(@max(maybe.value, 0));
}

fn iterFactory(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const ctx = c.v8__Isolate__GetCurrentContext(isolate) orelse return;
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);

    const kind = kindFromData(c.v8__FunctionCallbackInfo__Data(info)) orelse return;
    const this = c.v8__FunctionCallbackInfo__This(info) orelse return;
    const ext_val = c.v8__Object__Get(this, ctx, key(isolate, &str___d)) orelse return;
    if (!c.v8__Value__IsExternal(ext_val)) return;

    const it = c.v8__Object__New(isolate);
    var out: c.MaybeBool = undefined;
    _ = c.v8__Object__Set(it, ctx, key(isolate, &str___d), ext_val, &out);
    _ = c.v8__Object__Set(it, ctx, key(isolate, &str_kind),
        @ptrCast(c.v8__Integer__NewFromUnsigned(isolate, @intCast(@intFromEnum(kind)))), &out);
    _ = c.v8__Object__Set(it, ctx, key(isolate, &str_pos),
        @ptrCast(c.v8__Integer__NewFromUnsigned(isolate, 0)), &out);
    _ = c.v8__Object__Set(it, ctx, key(isolate, &str_next),
        @ptrCast(c.v8__Global__Get(&g_next, isolate)), &out);
    c.v8__ReturnValue__Set(ret, @ptrCast(it));
}

fn nextCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const ctx = c.v8__Isolate__GetCurrentContext(isolate) orelse return;
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);

    const this = c.v8__FunctionCallbackInfo__This(info) orelse return;
    const ext_val = c.v8__Object__Get(this, ctx, key(isolate, &str___d)) orelse return;
    if (!c.v8__Value__IsExternal(ext_val)) return;
    const owner = c.v8__External__Value(@ptrCast(ext_val)) orelse return;

    const kind_idx = intProp(isolate, ctx, this, &str_kind) orelse return;
    if (kind_idx >= MAX_KIND) return;
    const kind: Kind = @enumFromInt(@as(u8, @intCast(kind_idx)));
    const pos = intProp(isolate, ctx, this, &str_pos) orelse return;

    if (pos >= countFor(owner, kind)) {
        c.v8__ReturnValue__Set(ret, @ptrCast(buildResult(isolate, ctx, true, null)));
        return;
    }
    const pair = pairFor(owner, kind, pos);
    var out: c.MaybeBool = undefined;
    _ = c.v8__Object__Set(this, ctx, key(isolate, &str_pos),
        @ptrCast(c.v8__Integer__NewFromUnsigned(isolate, pos + 1)), &out);
    c.v8__ReturnValue__Set(ret, @ptrCast(buildResult(isolate, ctx, false, pairArray(isolate, ctx, pair.name, pair.value))));
}

pub fn attach(isolate: ?*c.Isolate, ctx: ?*c.Context, obj: ?*const c.Object, kind: Kind) void {
    var out: c.MaybeBool = undefined;
    _ = c.v8__Object__Set(obj, ctx, key(isolate, &sym_iterator),
        @ptrCast(c.v8__Global__Get(&g_factory[@intFromEnum(kind)], isolate)), &out);
}

pub fn setup(isolate: ?*c.Isolate, context: ?*c.Context) void {
    var hs: c.HandleScope = undefined;
    c.v8__HandleScope__CONSTRUCT(&hs, isolate);
    defer c.v8__HandleScope__DESTRUCT(&hs);

    c.v8__Global__New(isolate, @ptrCast(c.v8__Symbol__GetIterator(isolate)), &sym_iterator);
    c.v8__Global__New(isolate, @ptrCast(c.v8__Function__New__DEFAULT(context, nextCallback)), &g_next);

    const names = .{
        .{ "__d", &str___d }, .{ "kind", &str_kind }, .{ "pos", &str_pos },
        .{ "next", &str_next }, .{ "done", &str_done }, .{ "value", &str_value },
    };
    inline for (names) |n| {
        c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, n[0], 0, -1)), n[1]);
    }

    inline for (0..MAX_KIND) |k| {
        const ext = c.v8__External__New(isolate, @ptrFromInt(k + 1));
        const f = c.v8__Function__New__DEFAULT2(context, iterFactory, @ptrCast(ext));
        c.v8__Global__New(isolate, @ptrCast(f), &g_factory[k]);
    }
}
