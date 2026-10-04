//! FFI: dlopen a shared library and call its C-ABI symbols.
//! Hand-written externs over system libffi (same pattern as net/nghttp2_c.zig).
//! Requires --allow-ffi: native code runs outside every runtime guarantee.
//! Phase 2a: memory read/write (`ffi.read/write/copyBytes`, `FfiPtr`
//! view getters) + struct-by-value (`ffi.struct`, byte-image params,
//! Uint8Array results incl. nested struct fields.
//! Phase 2b.1: JS→C callbacks (`ffi.callback` → libffi closures).
//! Phase 2b.2: `nonblocking: true` symbols → Promise + worker-thread call.
//! Phase 2b.3: JS→C callbacks from foreign threads (bridge: copy args,
//! enqueue, block; JS runs on the JS thread).
//! Phase 2c: `ffi.union` — C unions (all members overlay at offset 0;
//! size = max member size aligned; byte-image passing like structs).
//!
//! DOD notes (zig-data-oriented-design):
//! - Prepared work is hoisted: `ffi_prep_cif` + struct `ffi_type` element
//!   arrays are built ONCE per symbol at dlopen; closures prepared ONCE
//!   at ffi.callback(). Zero setup per call.
//! - Call hot path is allocation-free: fixed stack arenas (`store`,
//!   `rstore`), struct images passed by reference to caller memory,
//!   pointers written straight into slots. Only JS value construction
//!   (strings/Uint8Array copies) allocates, inherently.
//! - Fixed capacities: MAX_ARGS params, MAX_STRUCT struct size,
//!   MAX_STRUCT_DEPTH nesting — bounded, no heap growth mid-call.
//! - Async path: fixed MAX_JOBS slot pool, no per-call heap except
//!   buffer/cstring/struct copies (inherent). Zero JS on worker threads.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig").c;
const xev = @import("xev");
const microtasks = @import("../event/microtasks.zig");

const gpa = std.heap.smp_allocator;

// ── libffi surface (stable C ABI) ──

const FfiType = extern struct {
    size: usize,
    alignment: u16,
    ty: u16,
    elements: ?[*]?*FfiType,
};

const FfiCif = extern struct {
    abi: c_int,
    nargs: c_uint,
    arg_types: [*]?*FfiType,
    rtype: ?*FfiType,
    bytes: c_uint,
    flags: c_uint,
};

extern fn ffi_prep_cif(cif: *FfiCif, abi: c_int, nargs: c_uint, rtype: *FfiType, atypes: [*]?*FfiType) c_int;
extern fn ffi_call(cif: *FfiCif, fun: *const anyopaque, rvalue: *anyopaque, avalue: [*]*anyopaque) void;
extern fn ffi_closure_alloc(size: usize, code: [*c]?*anyopaque) ?*anyopaque;
extern fn ffi_closure_free(p: ?*anyopaque) void;
extern fn ffi_prep_closure_loc(
    closure: ?*anyopaque,
    cif: *FfiCif,
    fun: ?*const fn (?*FfiCif, ?*anyopaque, [*c]?*anyopaque, ?*anyopaque) callconv(.c) void,
    user_data: ?*anyopaque,
    codeloc: ?*anyopaque,
) c_int;

extern var ffi_type_void: FfiType;
extern var ffi_type_sint8: FfiType;
extern var ffi_type_uint8: FfiType;
extern var ffi_type_sint16: FfiType;
extern var ffi_type_uint16: FfiType;
extern var ffi_type_sint32: FfiType;
extern var ffi_type_uint32: FfiType;
extern var ffi_type_sint64: FfiType;
extern var ffi_type_uint64: FfiType;
extern var ffi_type_float: FfiType;
extern var ffi_type_double: FfiType;
extern var ffi_type_pointer: FfiType;

// ffitarget_arm64.h: FFI_FIRST_ABI = 0, FFI_SYSV = 1.
// ffitarget_x86.h: FFI_FIRST_ABI = 1, FFI_UNIX64 = 2.
const FFI_DEFAULT_ABI: c_int = switch (builtin.cpu.arch) {
    .aarch64 => 1,
    .x86_64 => 2,
    else => 1,
};

const FFI_TYPE_STRUCT: u16 = 13;

extern fn dlopen(path: [*:0]const u8, flags: c_int) ?*anyopaque;
extern fn dlsym(handle: *anyopaque, symbol: [*:0]const u8) ?*anyopaque;
extern fn dlclose(handle: *anyopaque) c_int;
extern fn dlerror() ?[*:0]const u8;

const RTLD_NOW: c_int = 2;

// ── Native type registry ──

const FfiKind = enum {
    i8_, u8_, i16_, u16_, i32_, u32_, i64_, u64_,
    isize_, usize_, f32_, f64_, void_, pointer, buffer, cstring,
    struct_, function_,
};

fn parseType(name: []const u8) ?FfiKind {
    const pairs = [_]struct { []const u8, FfiKind }{
        .{ "i8", .i8_ },        .{ "u8", .u8_ },
        .{ "i16", .i16_ },      .{ "u16", .u16_ },
        .{ "i32", .i32_ },      .{ "u32", .u32_ },
        .{ "i64", .i64_ },      .{ "u64", .u64_ },
        .{ "isize", .isize_ },  .{ "usize", .usize_ },
        .{ "f32", .f32_ },      .{ "f64", .f64_ },
        .{ "void", .void_ },    .{ "pointer", .pointer },
        .{ "buffer", .buffer }, .{ "cstring", .cstring },
        .{ "function", .function_ },
    };
    for (pairs) |p| {
        if (std.mem.eql(u8, name, p[0])) return p[1];
    }
    return null;
}

fn ffiTypeOf(k: FfiKind) *FfiType {
    return switch (k) {
        .i8_ => &ffi_type_sint8,
        .u8_ => &ffi_type_uint8,
        .i16_ => &ffi_type_sint16,
        .u16_ => &ffi_type_uint16,
        .i32_ => &ffi_type_sint32,
        .u32_ => &ffi_type_uint32,
        .i64_ => &ffi_type_sint64,
        .u64_ => &ffi_type_uint64,
        .isize_ => &ffi_type_sint64,
        .usize_ => &ffi_type_uint64,
        .f32_ => &ffi_type_float,
        .f64_ => &ffi_type_double,
        .pointer, .buffer, .cstring, .function_ => &ffi_type_pointer,
        .void_ => &ffi_type_void,
        .struct_ => unreachable, // use ArgSpec / StructDesc.ffi_type
    };
}

fn kindSize(k: FfiKind) usize {
    return switch (k) {
        .i8_, .u8_ => 1,
        .i16_, .u16_ => 2,
        .i32_, .u32_, .f32_ => 4,
        .void_ => 0,
        else => 8,
    };
}

fn kindAlign(k: FfiKind) usize {
    return switch (k) {
        .i8_, .u8_ => 1,
        .i16_, .u16_ => 2,
        .i32_, .u32_, .f32_ => 4,
        .void_ => 1,
        else => 8,
    };
}

fn alignForward(off: usize, a: usize) usize {
    return (off + a - 1) / a * a;
}

// ── Struct specs (incl. nesting) + unions (phase 2c) ──
//
// Struct layout follows C rules, applied recursively: each field — scalar
// or nested spec — contributes its own natural alignment and size. libffi
// receives the composed `ffi_type` tree and flattens per the platform
// ABI. Field lists are scalar-only at the leaves: nested structs are
// whole specs, never constructed field-by-field inline except via the
// same parser (parseStructArray).
//
// Unions (is_union = true): every member overlays at offset 0;
// size = max member size aligned to max member alignment. libffi gets a
// fill-type FFI_TYPE_STRUCT (enough u64/u32/u8 elements to cover the
// size) for correct by-value passing. Unions reuse StructDesc + the
// struct byte-image paths, so no marshaling code changes.

const MAX_STRUCT_DEPTH: u32 = 8; // nested-struct recursion cap
const SpecError = error{
    BadSpec,
    BadStructField,
    OutOfMemory,
    StructTooLarge,
};

const StructDesc = struct {
    fields: []ArgSpec,
    offsets: []usize,
    names: [][:0]u8,
    elems: []?*FfiType,
    size: usize,
    alignment: usize,
    ffi_type: FfiType,
    is_union: bool = false,
};

fn freeStructDesc(d: *StructDesc) void {
    for (d.fields) |f| {
        if (f.spec) |nd| freeStructDesc(nd);
    }
    gpa.free(d.fields);
    for (d.names) |n| gpa.free(n);
    gpa.free(d.names);
    gpa.free(d.offsets);
    gpa.free(d.elems);
    gpa.destroy(d);
}

/// Owns `specs` (and any nested descs) on success AND on every error
/// path. `names` is borrowed — duped internally. Layout = C rules,
/// applied recursively (nested desc contributes its own size/alignment).
/// With is_union = true: all offsets are 0, size = max member size
/// aligned to max member alignment, ffi_type = fill-type struct.
fn makeStructDesc(names: []const []const u8, specs: []ArgSpec, is_union: bool) !*StructDesc {
    const d = gpa.create(StructDesc) catch {
        for (specs) |sp| if (sp.spec) |nd| freeStructDesc(nd);
        gpa.free(specs);
        return error.OutOfMemory;
    };
    d.* = .{
        .fields = specs,
        .offsets = &.{}, .names = &.{}, .elems = &.{},
        .size = 0, .alignment = 1, .ffi_type = undefined,
        .is_union = is_union,
    };
    errdefer freeStructDesc(d);

    for (specs) |sp| {
        if (sp.kind == .void_ or (sp.kind == .struct_ and sp.spec == null)) return error.BadStructField;
    }

    d.offsets = try gpa.alloc(usize, specs.len);
    d.names = try gpa.alloc([:0]u8, specs.len);
    for (d.names) |*nm| nm.* = @constCast(&[_:0]u8{});

    var off: usize = 0;
    var max_align: usize = 1;
    for (specs, 0..) |sp, i| {
        const a = if (sp.kind == .struct_) sp.spec.?.alignment else kindAlign(sp.kind);
        const sz = if (sp.kind == .struct_) sp.spec.?.size else kindSize(sp.kind);
        if (a > max_align) max_align = a;
        if (is_union) {
            d.offsets[i] = 0;
            if (sz > off) off = sz;
        } else {
            off = alignForward(off, a);
            d.offsets[i] = off;
            off += sz;
        }
        d.names[i] = try gpa.dupeZ(u8, names[i]);
    }
    d.size = alignForward(off, max_align);
    d.alignment = max_align;
    if (d.size > MAX_STRUCT) return error.StructTooLarge;

    if (is_union) {
        // Fill-type elements for correct by-value ABI classification.
        const fill_kind: FfiKind = switch (max_align) {
            8 => .u64_,
            4 => .u32_,
            2 => .u16_,
            else => .u8_,
        };
        const n_fill = d.size / kindSize(fill_kind);
        d.elems = try gpa.alloc(?*FfiType, n_fill + 1);
        for (0..n_fill) |i| d.elems[i] = ffiTypeOf(fill_kind);
        d.elems[n_fill] = null;
    } else {
        d.elems = try gpa.alloc(?*FfiType, specs.len + 1);
        for (specs, 0..) |sp, i| d.elems[i] = sp.ffiType();
        d.elems[specs.len] = null;
    }

    d.ffi_type = .{
        .size = d.size,
        .alignment = @intCast(d.alignment),
        .ty = FFI_TYPE_STRUCT,
        .elements = d.elems.ptr,
    };
    return d;
}

/// Deep clone — nested descs too (per-symbol ownership, GC-order safe).
fn cloneStructDesc(src: *StructDesc) !*StructDesc {
    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(gpa);
    for (src.names) |n| try names.append(gpa, n);
    const specs = gpa.alloc(ArgSpec, src.fields.len) catch return error.OutOfMemory;
    var count: usize = 0;
    var transferred = false;
    errdefer if (!transferred) {
        for (specs[0..count]) |sp| if (sp.spec) |nd| freeStructDesc(nd);
        gpa.free(specs);
    };
    for (src.fields, 0..) |f, i| {
        specs[i] = if (f.spec) |nd| .{ .kind = .struct_, .spec = try cloneStructDesc(nd) } else f;
        count += 1;
    }
    transferred = true;
    return makeStructDesc(names.items, specs, src.is_union);
}

// A parameter/result slot: scalar kind, or struct_ + its desc.
const ArgSpec = struct {
    kind: FfiKind,
    spec: ?*StructDesc = null,

    fn ffiType(self: ArgSpec) *FfiType {
        return if (self.kind == .struct_) &self.spec.?.ffi_type else ffiTypeOf(self.kind);
    }
};

// ── Native state ──

const MAX_ARGS: usize = 32;
const MAX_STRUCT: usize = 512; // fixed return arena; larger → error at dlopen

var allow: bool = false;

pub fn setAllow(v: bool) void {
    allow = v;
}

var lib_class_id: c.ClassID = 0;
var ptr_class_id: c.ClassID = 0;
var struct_class_id: c.ClassID = 0;
var callback_class_id: c.ClassID = 0;
var union_class_id: c.ClassID = 0;

const SymbolDesc = struct {
    lib: *Lib,
    name_z: [:0]u8,
    params: []ArgSpec,
    result: ArgSpec,
    atypes: []?*FfiType,
    cif: FfiCif,
    fn_ptr: ?*anyopaque,
    nonblocking: bool = false,
};

const Lib = struct {
    handle: ?*anyopaque,
    closed: bool = false,
    symbols: std.ArrayList(*SymbolDesc),
};

fn jsBool(ctx: ?*c.Context, v: bool) c.Value {
    return c.dupValue(ctx, if (v) c.JS_TRUE else c.JS_FALSE);
}

fn opaqueAs(comptime T: type, p: ?*anyopaque) ?*T {
    const raw = p orelse return null;
    return @ptrCast(@alignCast(raw));
}

// toCString/atomToCString/toCStringLen2 return [*c] (nullable in practice);
// wrap them so call sites use plain optionals.
fn strOf(ctx: ?*c.Context, v: c.Value) ?[*c]const u8 {
    const s = c.toCString(ctx, v);
    if (s == null) return null;
    return s;
}

fn cstrLenOf(ctx: ?*c.Context, v: c.Value) ?[*c]const u8 {
    const s = c.toCStringLen2(ctx, null, v, false);
    if (s == null) return null;
    return s;
}

fn atomStrOf(ctx: ?*c.Context, a: c.Atom) ?[*c]const u8 {
    const s = c.atomToCString(ctx, a);
    if (s == null) return null;
    return s;
}

// ── Buffer/pointer helpers ──

/// Data pointer of a TypedArray (view-adjusted) or plain ArrayBuffer.
/// `out_len` gets the view/segment byte length.
fn bufferData2(ctx: ?*c.Context, v: c.Value, out_len: *usize) ?*anyopaque {
    var off: usize = 0;
    var len: usize = 0;
    var bpe: usize = 0;
    const ab = c.getTypedArrayBuffer(ctx, v, &off, &len, &bpe);
    if (c.isException(ab) == 0) {
        defer c.freeValue(ctx, ab);
        var sz: usize = 0;
        const base = c.getArrayBuffer(ctx, &sz, ab) orelse return null;
        out_len.* = len;
        return @ptrFromInt(@intFromPtr(base) + off);
    }
    const exc = c.getException(ctx);
    c.freeValue(ctx, exc);
    var sz: usize = 0;
    const base = c.getArrayBuffer(ctx, &sz, v) orelse return null;
    out_len.* = sz;
    return base;
}

fn bufferData(ctx: ?*c.Context, v: c.Value) ?*anyopaque {
    var len: usize = 0;
    return bufferData2(ctx, v, &len);
}

fn makePtr(ctx: ?*c.Context, addr: usize) c.Value {
    const obj = c.newObjectClass(ctx, ptr_class_id);
    if (c.isException(obj) != 0) return obj;
    c.setOpaque(obj, @ptrFromInt(addr));
    return obj;
}

// ── Library class ──

fn freeLib(lib: *Lib) void {
    for (lib.symbols.items) |sym| {
        for (sym.params) |p| {
            if (p.spec) |s| freeStructDesc(s);
        }
        if (sym.result.spec) |s| freeStructDesc(s);
        gpa.free(sym.name_z);
        gpa.free(sym.params);
        gpa.free(sym.atypes);
        gpa.destroy(sym);
    }
    lib.symbols.deinit(gpa);
    if (!lib.closed) {
        if (lib.handle) |h| _ = dlclose(h);
    }
    gpa.destroy(lib);
}

fn libFinalizer(rt: ?*c.Runtime, val: c.Value) callconv(.c) void {
    _ = rt;
    const p = c.getOpaque(val, lib_class_id) orelse return;
    freeLib(@ptrCast(@alignCast(p)));
}

fn closeCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const lib = opaqueAs(Lib, c.getOpaque2(ctx, this_val, lib_class_id)) orelse {
        _ = c.throwTypeError(ctx, "FfiLibrary.close: not a library");
        return c.JS_EXCEPTION;
    };
    if (!lib.closed) {
        lib.closed = true;
        if (lib.handle) |h| _ = dlclose(h);
        lib.handle = null;
    }
    return c.JS_UNDEFINED;
}

// ── Symbol call wrapper ──
//
// Bound with JS_NewCFunctionData: func_data[0] = library object (GC pin),
// magic = symbol index. Hot path allocation-free except `cstring`
// args, which are freed right after the call.

fn symCall(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value, magic: c_int, func_data: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    const lib = opaqueAs(Lib, c.getOpaque2(ctx, func_data[0], lib_class_id)) orelse {
        _ = c.throwTypeError(ctx, "ffi: library handle lost");
        return c.JS_EXCEPTION;
    };
    if (lib.closed) {
        _ = c.throwTypeError(ctx, "ffi: library is closed");
        return c.JS_EXCEPTION;
    }
    const sym = lib.symbols.items[@intCast(magic)];
    const need: c_int = @intCast(sym.params.len);
    if (argc < need) {
        _ = c.throwTypeError(ctx, "ffi: '%s' expects %d arguments, got %d", sym.name_z.ptr, need, argc);
        return c.JS_EXCEPTION;
    }
    if (sym.nonblocking) return symCallAsync(ctx, sym, argc, argv);

    var store: [MAX_ARGS]u128 align(16) = undefined;
    var avals: [MAX_ARGS]*anyopaque = undefined;
    var tmp_strs: [MAX_ARGS][*c]const u8 = undefined;
    var tmp_n: usize = 0;

    for (sym.params, 0..) |p, i| {
        const arg = argv[i];
        const slot: *u128 = &store[i];
        var arg_ptr: *anyopaque = @ptrCast(slot);
        switch (p.kind) {
            .i8_ => @as(*i8, @ptrCast(slot)).* = @truncate(intArg(ctx, arg, i) orelse return failArgs(ctx, tmp_strs[0..tmp_n])),
            .u8_ => @as(*u8, @ptrCast(slot)).* = @truncate(uintArg(ctx, arg, i) orelse return failArgs(ctx, tmp_strs[0..tmp_n])),
            .i16_ => @as(*i16, @ptrCast(slot)).* = @truncate(intArg(ctx, arg, i) orelse return failArgs(ctx, tmp_strs[0..tmp_n])),
            .u16_ => @as(*u16, @ptrCast(slot)).* = @truncate(uintArg(ctx, arg, i) orelse return failArgs(ctx, tmp_strs[0..tmp_n])),
            .i32_ => @as(*i32, @ptrCast(slot)).* = @truncate(intArg(ctx, arg, i) orelse return failArgs(ctx, tmp_strs[0..tmp_n])),
            .u32_ => @as(*u32, @ptrCast(slot)).* = @truncate(uintArg(ctx, arg, i) orelse return failArgs(ctx, tmp_strs[0..tmp_n])),
            .i64_, .isize_ => @as(*i64, @ptrCast(slot)).* = intArg(ctx, arg, i) orelse return failArgs(ctx, tmp_strs[0..tmp_n]),
            .u64_, .usize_ => @as(*u64, @ptrCast(slot)).* = uintArg(ctx, arg, i) orelse return failArgs(ctx, tmp_strs[0..tmp_n]),
            .f32_ => {
                var f: f64 = 0;
                if (c.toFloat64(ctx, &f, arg) != 0) return failArgs(ctx, tmp_strs[0..tmp_n]);
                @as(*f32, @ptrCast(slot)).* = @floatCast(f);
            },
            .f64_ => {
                var f: f64 = 0;
                if (c.toFloat64(ctx, &f, arg) != 0) return failArgs(ctx, tmp_strs[0..tmp_n]);
                @as(*f64, @ptrCast(slot)).* = f;
            },
            .pointer, .buffer, .function_ => {
                const addr = ptrArg(ctx, arg, p.kind) orelse return failArgs(ctx, tmp_strs[0..tmp_n]);
                @as(*usize, @ptrCast(slot)).* = addr;
            },
            .cstring => {
                if (c.isNull(arg) != 0 or c.isUndefined(arg) != 0) {
                    @as(*usize, @ptrCast(slot)).* = 0;
                } else {
                    const s = cstrLenOf(ctx, arg) orelse return failArgs(ctx, tmp_strs[0..tmp_n]);
                    tmp_strs[tmp_n] = s;
                    tmp_n += 1;
                    @as(*usize, @ptrCast(slot)).* = @intFromPtr(s);
                }
            },
            .struct_ => {
                // Byte image: pointer to the caller's TypedArray data.
                // libffi reads the aggregate bytes AT *avalue: point it at
                // the image itself (no copy), not at a slot holding the
                // image's address.
                const spec = p.spec.?;
                if (c.isObject(arg) == 0) {
                    _ = c.throwTypeError(ctx, "ffi: struct argument %d: expected a TypedArray image", @as(c_int, @intCast(i)));
                    return failArgs(ctx, tmp_strs[0..tmp_n]);
                }
                var ilen: usize = 0;
                const base = bufferData2(ctx, arg, &ilen) orelse {
                    _ = c.throwTypeError(ctx, "ffi: struct argument %d: expected a TypedArray image", @as(c_int, @intCast(i)));
                    return failArgs(ctx, tmp_strs[0..tmp_n]);
                };
                if (ilen < spec.size) {
                    _ = c.throwTypeError(ctx, "ffi: struct argument %d: image is %d bytes, needs %d", @as(c_int, @intCast(i)), @as(c_int, @intCast(ilen)), @as(c_int, @intCast(spec.size)));
                    return failArgs(ctx, tmp_strs[0..tmp_n]);
                }
                arg_ptr = base;
            },
            .void_ => {
                _ = c.throwTypeError(ctx, "ffi: 'void' is not a parameter type");
                return failArgs(ctx, tmp_strs[0..tmp_n]);
            },
        }
        avals[i] = arg_ptr;
    }

    // Fixed return arena: scalars read back in place; struct results are
    // copied out to a Uint8Array (Deno semantics).
    var rstore: [MAX_STRUCT]u8 align(16) = undefined;
    ffi_call(&sym.cif, sym.fn_ptr.?, @ptrCast(&rstore), @ptrCast(&avals));

    for (tmp_strs[0..tmp_n]) |s| c.freeCString(ctx, s);

    if (callback_err) |e| {
        callback_err = null;
        _ = c.throw(ctx, e);
        return c.JS_EXCEPTION;
    }
    return wrapResult(ctx, sym, &rstore);
}

fn symCallAsync(ctx: ?*c.Context, sym: *SymbolDesc, argc: c_int, argv: [*c]c.Value) c.Value {
    const need: c_int = @intCast(sym.params.len);
    if (argc < need) {
        _ = c.throwTypeError(ctx, "ffi: '%s' expects %d arguments, got %d", sym.name_z.ptr, need, argc);
        return c.JS_EXCEPTION;
    }
    var cap: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &cap);
    if (c.isException(promise) != 0) return promise;
    const job = acquireJob() orelse {
        c.freeValue(ctx, cap[0]);
        c.freeValue(ctx, cap[1]);
        c.freeValue(ctx, promise);
        return c.throwOutOfMemory(ctx);
    };
    job.sym = sym;
    if (!marshalJobArgs(ctx, job, argv)) {
        freeJobArgs(ctx, job);
        job.used = false;
        c.freeValue(ctx, cap[0]);
        c.freeValue(ctx, cap[1]);
        c.freeValue(ctx, promise);
        return c.JS_EXCEPTION;
    }
    job.resolve = c.dupValue(ctx, cap[0]);
    job.reject = c.dupValue(ctx, cap[1]);
    c.freeValue(ctx, cap[0]);
    c.freeValue(ctx, cap[1]);
    _ = pending.fetchAdd(1, .acq_rel);
    ensureArmed();
    poolRef().schedule(.from(&job.task));
    return promise;
}

var ffi_pool: xev.ThreadPool = undefined;
var ffi_pool_up = false;

fn poolRef() *xev.ThreadPool {
    if (!ffi_pool_up) {
        ffi_pool = xev.ThreadPool.init(.{ .max_threads = 4 });
        ffi_pool_up = true;
    }
    return &ffi_pool;
}

fn failArgs(ctx: ?*c.Context, tmp: [][*c]const u8) c.Value {
    for (tmp) |s| c.freeCString(ctx, s);
    return c.JS_EXCEPTION;
}

fn coerceInt(ctx: ?*c.Context, v: c.Value) ?i64 {
    const t = v.tag;
    var out: i64 = 0;
    if (t == c.TAG_BIG_INT or t == c.TAG_SHORT_BIG_INT) {
        if (c.toBigInt64(ctx, &out, v) != 0) return null;
    } else {
        if (c.toInt64(ctx, &out, v) != 0) return null;
    }
    return out;
}

fn intArg(ctx: ?*c.Context, v: c.Value, i: usize) ?i64 {
    const out = coerceInt(ctx, v) orelse {
        _ = c.throwTypeError(ctx, "ffi: argument %d is not an integer", @as(c_int, @intCast(i)));
        return null;
    };
    return out;
}

fn uintArg(ctx: ?*c.Context, v: c.Value, i: usize) ?u64 {
    return @bitCast(intArg(ctx, v, i) orelse return null);
}

fn ptrArg(ctx: ?*c.Context, v: c.Value, kind: FfiKind) ?usize {
    if (c.isNull(v) != 0 or c.isUndefined(v) != 0) return 0;
    if (opaqueAs(u8, c.getOpaque2(ctx, v, ptr_class_id))) |p| return @intFromPtr(p);
    const t = v.tag;
    if (t == c.TAG_BIG_INT or t == c.TAG_SHORT_BIG_INT) {
        var out: i64 = 0;
        if (c.toBigInt64(ctx, &out, v) != 0) return null;
        return @bitCast(out);
    }
    if (kind == .buffer and c.isObject(v) != 0) {
        const p = bufferData(ctx, v) orelse {
            _ = c.throwTypeError(ctx, "ffi: expected a TypedArray or ArrayBuffer");
            return null;
        };
        return @intFromPtr(p);
    }
    _ = c.throwTypeError(ctx, "ffi: expected pointer, bigint, or buffer");
    return null;
}

fn wrapResult(ctx: ?*c.Context, sym: *SymbolDesc, rstore: *align(16) [MAX_STRUCT]u8) c.Value {
    const kind = sym.result.kind;
    return switch (kind) {
        .void_ => c.JS_UNDEFINED,
        .i8_ => c.newInt32(ctx, @as(*const i8, @ptrCast(rstore)).*),
        .u8_ => c.newUint32(ctx, @as(*const u8, @ptrCast(rstore)).*),
        .i16_ => c.newInt32(ctx, @as(*const i16, @ptrCast(rstore)).*),
        .u16_ => c.newUint32(ctx, @as(*const u16, @ptrCast(rstore)).*),
        .i32_ => c.newInt32(ctx, @as(*const i32, @ptrCast(rstore)).*),
        .u32_ => c.newUint32(ctx, @as(*const u32, @ptrCast(rstore)).*),
        .i64_, .isize_ => c.newBigInt64(ctx, @as(*const i64, @ptrCast(rstore)).*),
        .u64_, .usize_ => c.newBigUint64(ctx, @as(*const u64, @ptrCast(rstore)).*),
        .f32_ => c.newFloat64(ctx, @as(*const f32, @ptrCast(rstore)).*),
        .f64_ => c.newFloat64(ctx, @as(*const f64, @ptrCast(rstore)).*),
        .pointer, .buffer, .function_ => blk: {
            const addr = @as(*const usize, @ptrCast(rstore)).*;
            break :blk if (addr == 0) c.JS_NULL else makePtr(ctx, addr);
        },
        .cstring => blk: {
            const addr = @as(*const usize, @ptrCast(rstore)).*;
            if (addr == 0) break :blk c.JS_NULL;
            const s: [*:0]const u8 = @ptrFromInt(addr);
            break :blk c.newStringLen(ctx, s, std.mem.len(s));
        },
        .struct_ => c.newUint8ArrayCopy(ctx, @as([*]const u8, rstore), sym.result.spec.?.size),
    };
}
// ── Nonblocking calls (2b.2) + cross-thread callback bridge (2b.3) ──
//
// nonblocking: true → symCall returns a Promise; ffi_call runs on a worker
// (xev.ThreadPool, one job pool, no heap churn on the call path). Nothing
// on that thread touches JS. Args are marshaled on the JS thread first —
// copy-in for buffer/cstring/struct so JS cannot race the worker — and the
// result is wrapped at settle on the JS thread. `buffer` out-params are
// copied back at settle, so mutation is only visible after the Promise
// settles. `pointer` args are passed by value (caller keeps them alive).
//
// Cross-thread callbacks: QuickJS is not thread-safe, so the trampoline
// never enters JS off-thread. It copies the raw arg bytes into a
// BridgeCall, enqueues it, wakes the loop (xev.Async), and blocks until the
// JS thread services it. A callback error rejects the enclosing
// nonblocking Promise (`job.err`), or is reported as an uncaught error when
// no job is in flight (C's own thread). Contract: never invoke a JS
// callback from a thread spawned by a SYNCHRONOUS ffi call — the JS thread
// is blocked inside ffi_call and cannot service the bridge (deadlock).
// Same rule as Deno's UnsafeCallback.
//
// Error attribution (bridge_job): a callback invoked from a thread C owns
// has no TLS link to the job, so nonblocking marshal records the job on
// the callback itself (code → desc registry). Exact for one flight per
// callback; shared-across-concurrent-flights attributes to the latest.

const MAX_JOBS: usize = 32;

const CallJob = struct {
    task: xev.ThreadPool.Task = .{ .callback = jobRun },
    sym: *SymbolDesc = undefined,
    resolve: c.Value = c.JS_UNDEFINED,
    reject: c.Value = c.JS_UNDEFINED,
    store: [MAX_ARGS]u128 align(16) = undefined,
    avals: [MAX_ARGS]*anyopaque = undefined,
    owned: [MAX_ARGS]?[]u8 = .{null} ** MAX_ARGS,
    back: [MAX_ARGS]?c.Value = .{null} ** MAX_ARGS,
    back_len: [MAX_ARGS]usize = .{0} ** MAX_ARGS,
    rstore: [MAX_STRUCT]u8 align(16) = undefined,
    err: ?c.Value = null,
    done: std.atomic.Value(bool) = .{ .raw = false },
    used: bool = false,
    cb: [MAX_ARGS]?*ClosureDesc = .{null} ** MAX_ARGS,
};

var jobs: [MAX_JOBS]CallJob = [_]CallJob{.{}} ** MAX_JOBS;

// Cross-thread wake: one xev.Async shared by job completion and bridge
// calls. notify() is thread-safe; wait()/arm is JS-thread-only.
var g_loop: ?*xev.Loop = null;
var g_ctx: ?*c.Context = null;
var js_thread: std.Thread.Id = undefined;
threadlocal var tls_job: ?*CallJob = null;

const AsyncT = xev.Async;
var async_h: AsyncT = undefined;
var async_comp: xev.Completion = .{};
var async_armed = false;
var async_ready = false;

pub var pending: std.atomic.Value(u64) = .{ .raw = 0 };
pub var bridge_pending: std.atomic.Value(u64) = .{ .raw = 0 };
var late_err: ?c.Value = null;

pub fn setLoop(l: *xev.Loop) void {
    g_loop = l;
    if (!async_ready) {
        async_h = AsyncT.init() catch return;
        async_ready = true;
    }
}

fn notifyAsync() void {
    if (async_ready) async_h.notify() catch {};
}

pub fn ensureArmed() void {
    if (async_armed) return;
    const l = g_loop orelse return;
    async_armed = true;
    async_h.wait(l, &async_comp, void, null, asyncCb);
}

fn asyncCb(ud: ?*void, l: *xev.Loop, comp: *xev.Completion, r: AsyncT.WaitError!void) xev.CallbackAction {
    _ = ud;
    _ = comp;
    _ = r catch return .disarm;
    if (g_ctx) |ctx| {
        drainCompleted(ctx);
        microtasks.pumpMicrotasks(ctx);
    }
    if (pending.load(.acquire) > 0 or bridge_pending.load(.acquire) > 0) {
        async_armed = true;
        async_h.wait(l, &async_comp, void, null, asyncCb);
    } else async_armed = false;
    return .disarm;
}

/// JS thread: report a callback error that had no enclosing job.
fn flushLateErr(ctx: *c.Context) void {
    const e = late_err orelse return;
    late_err = null;
    _ = c.throw(ctx, e);
    microtasks.reportUncaught(ctx, "Uncaught (in ffi callback)");
}

pub fn drainCompleted(ctx: ?*c.Context) void {
    drainBridge(ctx);
    drainJobs(ctx);
    if (ctx) |cx| flushLateErr(cx);
}

// ── Job pool (JS-thread-owned bookkeeping; only `done` is cross-thread) ──

fn acquireJob() ?*CallJob {
    for (&jobs) |*j| {
        if (j.used) continue;
        j.* = .{};
        j.used = true;
        return j;
    }
    return null;
}

fn jobRun(task: *xev.ThreadPool.Task) void {
    const job: *CallJob = @alignCast(@fieldParentPtr("task", task));
    tls_job = job;
    defer tls_job = null;
    ffi_call(&job.sym.cif, job.sym.fn_ptr.?, @ptrCast(&job.rstore), @ptrCast(&job.avals));
    job.done.store(true, .release);
    notifyAsync();
}

fn freeJobArgs(ctx: ?*c.Context, job: *CallJob) void {
    for (job.owned) |o| if (o) |b| gpa.free(b);
    job.owned = .{null} ** MAX_ARGS;
    for (job.back) |b| if (b) |v| c.freeValue(ctx, v);
    job.back = .{null} ** MAX_ARGS;
}

/// JS thread: JS args → job arena. Copy-in for buffer/cstring/struct.
/// Throws + returns false on bad input (nothing scheduled).
fn marshalJobArgs(ctx: ?*c.Context, job: *CallJob, argv: [*c]c.Value) bool {
    for (job.sym.params, 0..) |p, i| {
        const arg = argv[i];
        const slot: *u128 = &job.store[i];
        switch (p.kind) {
            .i8_ => @as(*i8, @ptrCast(slot)).* = @truncate(intArg(ctx, arg, i) orelse return false),
            .u8_ => @as(*u8, @ptrCast(slot)).* = @truncate(uintArg(ctx, arg, i) orelse return false),
            .i16_ => @as(*i16, @ptrCast(slot)).* = @truncate(intArg(ctx, arg, i) orelse return false),
            .u16_ => @as(*u16, @ptrCast(slot)).* = @truncate(uintArg(ctx, arg, i) orelse return false),
            .i32_ => @as(*i32, @ptrCast(slot)).* = @truncate(intArg(ctx, arg, i) orelse return false),
            .u32_ => @as(*u32, @ptrCast(slot)).* = @truncate(uintArg(ctx, arg, i) orelse return false),
            .i64_, .isize_ => @as(*i64, @ptrCast(slot)).* = intArg(ctx, arg, i) orelse return false,
            .u64_, .usize_ => @as(*u64, @ptrCast(slot)).* = uintArg(ctx, arg, i) orelse return false,
            .f32_ => {
                var f: f64 = 0;
                if (c.toFloat64(ctx, &f, arg) != 0) return false;
                @as(*f32, @ptrCast(slot)).* = @floatCast(f);
            },
            .f64_ => {
                var f: f64 = 0;
                if (c.toFloat64(ctx, &f, arg) != 0) return false;
                @as(*f64, @ptrCast(slot)).* = f;
            },
            .pointer => {
                const addr = ptrArg(ctx, arg, p.kind) orelse return false;
                @as(*usize, @ptrCast(slot)).* = addr;
            },
            .function_ => {
                const addr = ptrArg(ctx, arg, p.kind) orelse return false;
                @as(*usize, @ptrCast(slot)).* = addr;
                if (addr != 0) {
                    if (cbMap().get(addr)) |d| {
                        if (d.closed) {
                            _ = c.throwTypeError(ctx, "ffi: argument %d: callback is closed", @as(c_int, @intCast(i)));
                            return false;
                        }
                        d.bridge_job.store(@intFromPtr(job), .release);
                        job.cb[i] = d;
                    }
                }
            },
            .buffer => {
                if (c.isNull(arg) != 0 or c.isUndefined(arg) != 0) {
                    @as(*usize, @ptrCast(slot)).* = 0;
                } else {
                    var len: usize = 0;
                    const base = bufferData2(ctx, arg, &len) orelse {
                        _ = c.throwTypeError(ctx, "ffi: expected a TypedArray or ArrayBuffer");
                        return false;
                    };
                    const copy = gpa.alloc(u8, len) catch {
                        _ = c.throwOutOfMemory(ctx);
                        return false;
                    };
                    @memcpy(copy, @as([*]const u8, @ptrFromInt(@intFromPtr(base)))[0..len]);
                    job.owned[i] = copy;
                    @as(*usize, @ptrCast(slot)).* = @intFromPtr(copy.ptr);
                    job.back[i] = c.dupValue(ctx, arg);
                    job.back_len[i] = len;
                }
            },
            .cstring => {
                if (c.isNull(arg) != 0 or c.isUndefined(arg) != 0) {
                    @as(*usize, @ptrCast(slot)).* = 0;
                } else {
                    const s = cstrLenOf(ctx, arg) orelse return false;
                    const copy = gpa.dupeZ(u8, std.mem.span(s)) catch {
                        c.freeCString(ctx, s);
                        _ = c.throwOutOfMemory(ctx);
                        return false;
                    };
                    c.freeCString(ctx, s);
                    job.owned[i] = copy;
                    @as(*usize, @ptrCast(slot)).* = @intFromPtr(copy.ptr);
                }
            },
            .struct_ => {
                const spec = p.spec.?;
                if (c.isObject(arg) == 0) {
                    _ = c.throwTypeError(ctx, "ffi: struct argument %d: expected a TypedArray image", @as(c_int, @intCast(i)));
                    return false;
                }
                var ilen: usize = 0;
                const base = bufferData2(ctx, arg, &ilen) orelse {
                    _ = c.throwTypeError(ctx, "ffi: struct argument %d: expected a TypedArray image", @as(c_int, @intCast(i)));
                    return false;
                };
                if (ilen < spec.size) {
                    _ = c.throwTypeError(ctx, "ffi: struct argument %d: image is %d bytes, needs %d", @as(c_int, @intCast(i)), @as(c_int, @intCast(ilen)), @as(c_int, @intCast(spec.size)));
                    return false;
                }
                const copy = gpa.alloc(u8, spec.size) catch {
                    _ = c.throwOutOfMemory(ctx);
                    return false;
                };
                @memcpy(copy, @as([*]const u8, @ptrFromInt(@intFromPtr(base)))[0..spec.size]);
                job.owned[i] = copy;
                job.avals[i] = @ptrCast(copy.ptr);
                continue;
            },
            .void_ => {
                _ = c.throwTypeError(ctx, "ffi: 'void' is not a parameter type");
                return false;
            },
        }
        job.avals[i] = @ptrCast(slot);
    }
    return true;
}

fn settleJob(ctx: ?*c.Context, job: *CallJob) void {
    for (job.sym.params, 0..) |p, i| {
        if (p.kind != .buffer) continue;
        const ref = job.back[i] orelse continue;
        const src = job.owned[i] orelse continue;
        var len: usize = 0;
        const base = bufferData2(ctx, ref, &len) orelse continue;
        const n = @min(@min(len, job.back_len[i]), src.len);
        if (n > 0) @memcpy(@as([*]u8, @ptrFromInt(@intFromPtr(base)))[0..n], src[0..n]);
    }
    if (job.err) |e| {
        job.err = null;
        var args = [_]c.Value{e};
        const ret = c.call(ctx, job.reject, c.JS_UNDEFINED, 1, &args);
        if (c.isException(ret) != 0) {
            if (ctx) |cx| microtasks.reportUncaught(cx, "Uncaught (in promise)");
        } else c.freeValue(ctx, ret);
        c.freeValue(ctx, e);
    } else {
        const v = wrapResult(ctx, job.sym, &job.rstore);
        if (c.isException(v) != 0) {
            const e = c.getException(ctx);
            var args = [_]c.Value{e};
            const ret = c.call(ctx, job.reject, c.JS_UNDEFINED, 1, &args);
            if (c.isException(ret) != 0) {
                if (ctx) |cx| microtasks.reportUncaught(cx, "Uncaught (in promise)");
            } else c.freeValue(ctx, ret);
            c.freeValue(ctx, e);
        } else {
            var args = [_]c.Value{v};
            const ret = c.call(ctx, job.resolve, c.JS_UNDEFINED, 1, &args);
            if (c.isException(ret) != 0) {
                if (ctx) |cx| microtasks.reportUncaught(cx, "Uncaught (in promise)");
            } else c.freeValue(ctx, ret);
            c.freeValue(ctx, v);
        }
    }
    c.freeValue(ctx, job.resolve);
    c.freeValue(ctx, job.reject);
    job.resolve = c.JS_UNDEFINED;
    job.reject = c.JS_UNDEFINED;
    freeJobArgs(ctx, job);
    for (job.cb) |cbd| {
        const dd = cbd orelse continue;
        _ = dd.bridge_job.cmpxchgStrong(@intFromPtr(job), 0, .acq_rel, .acquire);
    }
    job.used = false;
    _ = pending.fetchSub(1, .release);
}

fn drainJobs(ctx: ?*c.Context) void {
    for (&jobs) |*j| {
        if (!j.used) continue;
        if (!j.done.load(.acquire)) continue;
        settleJob(ctx, j);
    }
}

// ── Callback bridge: foreign thread → JS thread ──

const BridgeCall = struct {
    d: *ClosureDesc,
    job: ?*CallJob,
    argc: usize,
    arg_off: [MAX_ARGS]usize,
    arg_len: [MAX_ARGS]usize,
    argbuf: []u8,
    rvalue: ?*anyopaque,
    err: ?c.Value = null,
    done: bool = false,
    next: ?*BridgeCall = null,
};

var bridge_mu: std.Io.Mutex = .init;
var bridge_cv: std.Io.Condition = .init;
var bridge_head: ?*BridgeCall = null;
var bridge_tail: ?*BridgeCall = null;

var cb_by_code: std.AutoHashMap(usize, *ClosureDesc) = undefined;
var cb_map_up = false;

fn cbMap() *std.AutoHashMap(usize, *ClosureDesc) {
    if (!cb_map_up) {
        cb_by_code = std.AutoHashMap(usize, *ClosureDesc).init(gpa);
        cb_map_up = true;
    }
    return &cb_by_code;
}

fn bridgeJobOf(d: *ClosureDesc) ?*CallJob {
    const a = d.bridge_job.load(.acquire);
    if (a == 0) return null;
    return @ptrFromInt(a);
}

inline fn thIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn enqueueBridge(bc: *BridgeCall) void {
    bridge_mu.lockUncancelable(thIo());
    bc.err = null;
    bc.done = false;
    bc.next = null;
    if (bridge_tail) |t| t.next = bc else bridge_head = bc;
    bridge_tail = bc;
    bridge_mu.unlock(thIo());
}

fn popBridge() ?*BridgeCall {
    bridge_mu.lockUncancelable(thIo());
    defer bridge_mu.unlock(thIo());
    const bc = bridge_head orelse return null;
    bridge_head = bc.next;
    if (bridge_head == null) bridge_tail = null;
    return bc;
}

fn zeroResult(d: *ClosureDesc, rvalue: ?*anyopaque) void {
    const rsz: usize = if (d.result.kind == .struct_) d.result.spec.?.size else kindSize(d.result.kind);
    const dst = rvalue orelse return;
    if (rsz > 0) @memset(@as([*]u8, @ptrCast(dst))[0..rsz], 0);
}

fn drainBridge(ctx: ?*c.Context) void {
    while (popBridge()) |bc| serviceBridge(ctx, bc);
}

/// JS thread: run the JS function for a foreign-thread trampoline.
fn serviceBridge(ctx: ?*c.Context, bc: *BridgeCall) void {
    const d = bc.d;
    var argv: [MAX_ARGS]c.Value = undefined;
    var argc: usize = 0;
    for (0..bc.argc) |i| {
        const v = argToJs(ctx, d.params[i], @intFromPtr(bc.argbuf.ptr) + bc.arg_off[i]);
        if (c.isException(v) != 0) break;
        argv[i] = v;
        argc = i + 1;
    }
    if (argc == bc.argc) {
        const ret = c.call(ctx, d.js_fn, c.JS_UNDEFINED, @intCast(bc.argc), &argv);
        if (c.isException(ret) != 0) {
            bc.err = c.getException(ctx);
        } else {
            if (!jsToRet(ctx, d.result, ret, bc.rvalue)) bc.err = c.getException(ctx);
            c.freeValue(ctx, ret);
        }
    } else {
        bc.err = c.getException(ctx);
    }
    for (argv[0..argc]) |v| c.freeValue(ctx, v);
    if (bc.err != null) zeroResult(d, bc.rvalue);
    if (bc.err) |e| {
        bc.err = null;
        const live = if (bc.job) |j| (if (j.used) j else null) else null;
        if (live) |j| {
            if (j.err == null) {
                j.err = e;
            } else {
                c.freeValue(ctx, e);
            }
        } else late_err = e;
    }
    bridge_mu.lockUncancelable(thIo());
    bc.done = true;
    bridge_cv.signal(thIo());
    bridge_mu.unlock(thIo());
}

// ── Memory read/write (phase 2a) — shared by ffi.read and view getters ──

fn readAt(ctx: ?*c.Context, addr: usize, kind: FfiKind) c.Value {
    return switch (kind) {
        .i8_ => c.newInt32(ctx, @as(*align(1) const i8, @ptrFromInt(addr)).*),
        .u8_ => c.newUint32(ctx, @as(*align(1) const u8, @ptrFromInt(addr)).*),
        .i16_ => c.newInt32(ctx, @as(*align(1) const i16, @ptrFromInt(addr)).*),
        .u16_ => c.newUint32(ctx, @as(*align(1) const u16, @ptrFromInt(addr)).*),
        .i32_ => c.newInt32(ctx, @as(*align(1) const i32, @ptrFromInt(addr)).*),
        .u32_ => c.newUint32(ctx, @as(*align(1) const u32, @ptrFromInt(addr)).*),
        .i64_, .isize_ => c.newBigInt64(ctx, @as(*align(1) const i64, @ptrFromInt(addr)).*),
        .u64_, .usize_ => c.newBigUint64(ctx, @as(*align(1) const u64, @ptrFromInt(addr)).*),
        .f32_ => c.newFloat64(ctx, @as(*align(1) const f32, @ptrFromInt(addr)).*),
        .f64_ => c.newFloat64(ctx, @as(*align(1) const f64, @ptrFromInt(addr)).*),
        .pointer, .buffer, .function_ => blk: {
            const p = @as(*align(1) const usize, @ptrFromInt(addr)).*;
            break :blk if (p == 0) c.JS_NULL else makePtr(ctx, p);
        },
        else => c.JS_NULL, // void/struct/cstring: not readable this way
    };
}

/// Write one value at a native address. Throws via ctx on bad input.
fn writeAt(ctx: ?*c.Context, addr: usize, kind: FfiKind, v: c.Value) bool {
    switch (kind) {
        .i8_ => @as(*align(1) i8, @ptrFromInt(addr)).* = @truncate(coerceInt(ctx, v) orelse return false),
        .u8_ => @as(*align(1) u8, @ptrFromInt(addr)).* = @truncate(@as(u64, @bitCast(coerceInt(ctx, v) orelse return false))),
        .i16_ => @as(*align(1) i16, @ptrFromInt(addr)).* = @truncate(coerceInt(ctx, v) orelse return false),
        .u16_ => @as(*align(1) u16, @ptrFromInt(addr)).* = @truncate(@as(u64, @bitCast(coerceInt(ctx, v) orelse return false))),
        .i32_ => @as(*align(1) i32, @ptrFromInt(addr)).* = @truncate(coerceInt(ctx, v) orelse return false),
        .u32_ => @as(*align(1) u32, @ptrFromInt(addr)).* = @truncate(@as(u64, @bitCast(coerceInt(ctx, v) orelse return false))),
        .i64_, .isize_ => @as(*align(1) i64, @ptrFromInt(addr)).* = coerceInt(ctx, v) orelse return false,
        .u64_, .usize_ => @as(*align(1) u64, @ptrFromInt(addr)).* = @bitCast(coerceInt(ctx, v) orelse return false),
        .f32_ => {
            var f: f64 = 0;
            if (c.toFloat64(ctx, &f, v) != 0) return false;
            @as(*align(1) f32, @ptrFromInt(addr)).* = @floatCast(f);
        },
        .f64_ => {
            var f: f64 = 0;
            if (c.toFloat64(ctx, &f, v) != 0) return false;
            @as(*align(1) f64, @ptrFromInt(addr)).* = f;
        },
        .pointer, .buffer, .function_ => {
            const p = ptrArg(ctx, v, kind) orelse return false;
            @as(*align(1) usize, @ptrFromInt(addr)).* = p;
        },
        else => {
            _ = c.throwTypeError(ctx, "ffi.write: unsupported type");
            return false;
        },
    }
    return true;
}

/// Copy `len` native bytes into a fresh ArrayBuffer.
fn copyBytesAt(ctx: ?*c.Context, addr: usize, len: usize) c.Value {
    return c.newArrayBufferCopy(ctx, @ptrFromInt(addr), len);
}

/// Copy a TypedArray's bytes into native memory. Returns false + TypeError
/// when the value is not a buffer.
fn writeBytesAt(ctx: ?*c.Context, addr: usize, v: c.Value) bool {
    var len: usize = 0;
    const base = bufferData2(ctx, v, &len) orelse {
        _ = c.throwTypeError(ctx, "ffi: expected a TypedArray or ArrayBuffer");
        return false;
    };
    const src: [*]const u8 = @ptrFromInt(@intFromPtr(base));
    const dst: [*]u8 = @ptrFromInt(addr);
    @memcpy(dst[0..len], src[0..len]);
    return true;
}

// ── JS→C callbacks (P2b.1 + P2b.3 bridge) ──
//
// ffi.callback(spec, jsFn) → FfiCallback { .pointer, .close() }. The
// trampoline runs on the calling thread: on the JS thread it calls through
// directly (same-thread path); on any other thread it bridges (2b.3).
// Keep the FfiCallback object referenced while native code holds the
// pointer; close() frees the closure (finalizer is a backstop; freeing
// under a live native pointer crashes, same contract as Deno's
// UnsafeCallback). close() refuses while a bridged call is in flight.

const ClosureDesc = struct {
    params: []ArgSpec,
    result: ArgSpec,
    atypes: []?*FfiType,
    cif: FfiCif,
    closure: ?*anyopaque,
    code: ?*anyopaque,
    js_fn: c.Value, // dup'd; freed on close/finalize
    ctx: ?*c.Context,
    closed: bool = false,
    in_flight: std.atomic.Value(u32) = .{ .raw = 0 },
    bridge_job: std.atomic.Value(usize) = .{ .raw = 0 },
};

// Set by the same-thread trampoline when the JS side fails; re-raised by
// symCall after ffi_call returns. Main-thread-only (bridge errors travel
// in BridgeCall.err → job.err / late_err instead).
var callback_err: ?c.Value = null;

fn freeClosureDesc(d: *ClosureDesc, rt: ?*c.Runtime) void {
    if (d.code) |co| _ = cbMap().remove(@intFromPtr(co));
    if (!d.closed) {
        if (d.closure) |cl| ffi_closure_free(cl);
        if (rt) |r| c.freeValueRT(r, d.js_fn);
    }
    for (d.params) |p| {
        if (p.spec) |s| freeStructDesc(s);
    }
    if (d.result.spec) |s| freeStructDesc(s);
    gpa.free(d.params);
    gpa.free(d.atypes);
    gpa.destroy(d);
}

/// Argument bytes → JS value (inverse of the symCall marshaling).
fn argToJs(ctx: ?*c.Context, p: ArgSpec, addr: usize) c.Value {
    return switch (p.kind) {
        .cstring => blk: {
            // `addr` is the slot holding the char* (libffi hands out
            // pointers to each argument value) — deref before reading.
            const sp = @as(*align(1) const usize, @ptrFromInt(addr)).*;
            if (sp == 0) break :blk c.JS_NULL;
            const s: [*:0]const u8 = @ptrFromInt(sp);
            break :blk c.newStringLen(ctx, s, std.mem.len(s));
        },
        .struct_ => c.newUint8ArrayCopy(ctx, @ptrFromInt(addr), p.spec.?.size),
        else => readAt(ctx, addr, p.kind),
    };
}

/// JS result → the rvalue bytes libffi hands back to C. Returns false
/// (with a JS error pending) on bad input. cstring results unsupported v1.
fn jsToRet(ctx: ?*c.Context, p: ArgSpec, v: c.Value, rvalue: ?*anyopaque) bool {
    if (p.kind == .void_) return true;
    const dst = rvalue orelse return true;
    if (p.kind == .struct_) {
        const sz = p.spec.?.size;
        var len: usize = 0;
        const src = bufferData2(ctx, v, &len) orelse {
            _ = c.throwTypeError(ctx, "ffi callback: struct result needs a TypedArray image");
            return false;
        };
        if (len < sz) {
            _ = c.throwTypeError(ctx, "ffi callback: struct result needs %d bytes, got %d", @as(c_int, @intCast(sz)), @as(c_int, @intCast(len)));
            return false;
        }
        const d: [*]u8 = @ptrCast(dst);
        const s: [*]const u8 = @ptrFromInt(@intFromPtr(src));
        @memcpy(d[0..sz], s[0..sz]);
        return true;
    }
    if (p.kind == .cstring) {
        _ = c.throwTypeError(ctx, "ffi callback: cstring results are not supported (v1)");
        return false;
    }
    const k: FfiKind = if (p.kind == .function_) .pointer else p.kind;
    if (!writeAt(ctx, @intFromPtr(dst), k, v)) {
        _ = c.throwTypeError(ctx, "ffi callback: bad result value");
        return false;
    }
    return true;
}

fn closureTrampoline(cif: ?*FfiCif, rvalue: ?*anyopaque, avalue: [*c]?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    _ = cif;
    const d = opaqueAs(ClosureDesc, user_data) orelse return;
    if (d.closed) return;
    if (std.Thread.getCurrentId() == js_thread) {
        trampolineSameThread(d, rvalue, avalue);
        return;
    }
    trampolineForeign(d, rvalue, avalue);
}

fn trampolineSameThread(d: *ClosureDesc, rvalue: ?*anyopaque, avalue: [*c]?*anyopaque) void {
    const ctx = d.ctx;
    var argv: [MAX_ARGS]c.Value = undefined;
    var argc: c_int = 0;
    for (d.params, 0..) |p, i| {
        const raw = avalue[i];
        const addr = if (raw) |r| @intFromPtr(r) else 0;
        argv[i] = argToJs(ctx, p, addr);
        if (c.isException(argv[i]) != 0) {
            callback_err = c.getException(ctx);
            zeroResult(d, rvalue);
            for (argv[0..@as(usize, @intCast(argc))]) |v| c.freeValue(ctx, v);
            return;
        }
        argc += 1;
    }

    const ret = c.call(ctx, d.js_fn, c.JS_UNDEFINED, argc, &argv);
    if (c.isException(ret) != 0) {
        callback_err = c.getException(ctx);
    } else {
        if (!jsToRet(ctx, d.result, ret, rvalue)) {
            callback_err = c.getException(ctx);
        }
        c.freeValue(ctx, ret);
    }
    for (argv[0..@as(usize, @intCast(argc))]) |v| c.freeValue(ctx, v);
    if (callback_err != null) zeroResult(d, rvalue);
}

/// Foreign thread: never touches JS. Copies the raw arg bytes (still
/// alive — the C caller is blocked in this trampoline), enqueues, wakes
/// the loop, and blocks until the JS thread services the call.
fn trampolineForeign(d: *ClosureDesc, rvalue: ?*anyopaque, avalue: [*c]?*anyopaque) void {
    var off: [MAX_ARGS]usize = undefined;
    var len: [MAX_ARGS]usize = undefined;
    var total: usize = 0;
    for (d.params, 0..) |p, i| {
        const sz: usize = switch (p.kind) {
            .void_ => 0,
            .struct_ => p.spec.?.size,
            else => kindSize(p.kind),
        };
        off[i] = total;
        len[i] = sz;
        total += sz;
    }
    const argbuf = gpa.alloc(u8, if (total == 0) 1 else total) catch {
        zeroResult(d, rvalue);
        return;
    };
    for (d.params, 0..) |_, i| {
        if (len[i] == 0) continue;
        const raw = avalue[i];
        const slot = if (raw) |r| @intFromPtr(r) else 0;
        if (slot == 0) {
            @memset(argbuf[off[i]..][0..len[i]], 0);
            continue;
        }
        @memcpy(argbuf[off[i]..][0..len[i]], @as([*]const u8, @ptrFromInt(slot))[0..len[i]]);
    }
    const bc = gpa.create(BridgeCall) catch {
        gpa.free(argbuf);
        zeroResult(d, rvalue);
        return;
    };
    bc.* = .{
        .d = d,
        .job = tls_job orelse bridgeJobOf(d),
        .argc = d.params.len,
        .arg_off = off,
        .arg_len = len,
        .argbuf = argbuf,
        .rvalue = rvalue,
    };
    _ = d.in_flight.fetchAdd(1, .acq_rel);
    _ = bridge_pending.fetchAdd(1, .acq_rel);
    enqueueBridge(bc);
    notifyAsync();
    bridge_mu.lockUncancelable(thIo());
    while (!bc.done) bridge_cv.waitUncancelable(thIo(), &bridge_mu);
    bridge_mu.unlock(thIo());
    _ = d.in_flight.fetchSub(1, .acq_rel);
    _ = bridge_pending.fetchSub(1, .release);
    gpa.free(argbuf);
    gpa.destroy(bc);
}
// ── Spec parsing: type string | {struct: [...]} | FfiStruct instance ──

/// Parse one parameter/result/field spec: type string | {struct: [...]} |
/// {union: [...]} | FfiStruct/FfiUnion instance. Owns any nested desc it
/// returns. `depth` caps struct-in-struct recursion.
fn parseSpec(ctx: ?*c.Context, v: c.Value, sym_name: []const u8, depth: u32) SpecError!ArgSpec {
    if (c.isObject(v) != 0) {
        if (c.getOpaque(v, struct_class_id)) |p| {
            const src: *StructDesc = @ptrCast(@alignCast(p));
            return .{ .kind = .struct_, .spec = try cloneStructDesc(src) };
        }
        if (c.getOpaque(v, union_class_id)) |p| {
            const src: *StructDesc = @ptrCast(@alignCast(p));
            return .{ .kind = .struct_, .spec = try cloneStructDesc(src) };
        }
        const uv = c.getPropertyStr(ctx, v, "union");
        defer c.freeValue(ctx, uv);
        if (c.isNull(uv) == 0 and c.isUndefined(uv) == 0) {
            return .{ .kind = .struct_, .spec = try parseStructArray(ctx, uv, sym_name, depth, true) };
        }
        const sv = c.getPropertyStr(ctx, v, "struct");
        defer c.freeValue(ctx, sv);
        if (c.isNull(sv) == 0 and c.isUndefined(sv) == 0) {
            return .{ .kind = .struct_, .spec = try parseStructArray(ctx, sv, sym_name, depth, false) };
        }
        _ = c.throwTypeError(ctx, "ffi: '%s': spec object needs a 'struct' or 'union' field", sym_name.ptr);
        return error.BadSpec;
    }
    const ts = strOf(ctx, v) orelse {
        _ = c.throwTypeError(ctx, "ffi: '%s': bad type spec", sym_name.ptr);
        return error.BadSpec;
    };
    defer c.freeCString(ctx, ts);
    const kind = parseType(std.mem.span(ts)) orelse {
        _ = c.throwTypeError(ctx, "ffi: '%s': unknown type '%s'", sym_name.ptr, ts);
        return error.BadSpec;
    };
    return .{ .kind = kind, .spec = null };
}

/// Field list: `[ "i32", InnerSpec ]`, `[ ["name", spec], … ]`, or the
/// type-only `[ "u8", "u64" ]` (auto names f0, f1, …).
/// Nested spec values may be FfiStruct/FfiUnion instances or inline
/// {struct:[…]} / {union:[…]}. With is_union, all offsets are 0 and the
/// size is the max member size aligned.
fn parseStructArray(ctx: ?*c.Context, arr: c.Value, sym_name: []const u8, depth: u32, is_union: bool) SpecError!*StructDesc {
    if (depth >= MAX_STRUCT_DEPTH) {
        _ = c.throwTypeError(ctx, "ffi: '%s': struct nesting too deep (max %d)", sym_name.ptr, @as(c_int, MAX_STRUCT_DEPTH));
        return error.BadSpec;
    }
    if (c.isArray(ctx, arr) == 0) {
        _ = c.throwTypeError(ctx, "ffi: '%s': struct spec must be an array", sym_name.ptr);
        return error.BadSpec;
    }
    const len_v = c.getPropertyStr(ctx, arr, "length");
    defer c.freeValue(ctx, len_v);
    var n: i64 = 0;
    if (c.toInt64(ctx, &n, len_v) != 0 or n <= 0 or n > 64) {
        _ = c.throwTypeError(ctx, "ffi: '%s': bad struct field count", sym_name.ptr);
        return error.BadSpec;
    }

    const specs = gpa.alloc(ArgSpec, @intCast(n)) catch return error.OutOfMemory;
    var owned: [64][:0]u8 = undefined;
    var names: [64][]const u8 = undefined;
    var count: usize = 0;
    var transferred = false;
    errdefer if (!transferred) {
        for (specs[0..count]) |sp| if (sp.spec) |nd| freeStructDesc(nd);
        gpa.free(specs);
    };
    defer for (owned[0..count]) |o| gpa.free(o); // makeStructDesc dupes names

    while (count < n) : (count += 1) {
        const ev = c.getPropertyUint32(ctx, arr, @intCast(count));
        defer c.freeValue(ctx, ev);
        if (c.isArray(ctx, ev) != 0) {
            const nv = c.getPropertyUint32(ctx, ev, 0);
            defer c.freeValue(ctx, nv);
            const sv = c.getPropertyUint32(ctx, ev, 1);
            defer c.freeValue(ctx, sv);
            const ns = strOf(ctx, nv) orelse return error.BadSpec;
            defer c.freeCString(ctx, ns);
            specs[count] = try parseSpec(ctx, sv, sym_name, depth + 1);
            owned[count] = try gpa.dupeZ(u8, std.mem.span(ns));
            names[count] = owned[count];
        } else {
            specs[count] = try parseSpec(ctx, ev, sym_name, depth + 1);
            var buf: [8]u8 = undefined;
            const nm = std.fmt.bufPrint(&buf, "f{d}", .{count}) catch unreachable;
            owned[count] = try gpa.dupeZ(u8, nm);
            names[count] = owned[count];
        }
        if (specs[count].kind == .void_) {
            _ = c.throwTypeError(ctx, "ffi: '%s': fields must be scalar or aggregate specs (no void)", sym_name.ptr);
            return error.BadSpec;
        }
    }

    transferred = true;
    return makeStructDesc(names[0..count], specs, is_union) catch |e| switch (e) {
        error.BadStructField => {
            _ = c.throwTypeError(ctx, "ffi: '%s': fields must be scalar or aggregate specs (no void)", sym_name.ptr);
            return e;
        },
        error.StructTooLarge => {
            _ = c.throwTypeError(ctx, "ffi: '%s': struct exceeds the %d-byte limit", sym_name.ptr, @as(c_int, MAX_STRUCT));
            return e;
        },
        error.OutOfMemory => return e,
    };
}

/// Returns the desc, or null when the symbol is optional and missing.
/// Throws (JS exception pending) and returns an error otherwise.
fn parseSymbol(ctx: ?*c.Context, lib: *Lib, name: []const u8, desc: c.Value, handle: *anyopaque) !?*SymbolDesc {
    const params_v = c.getPropertyStr(ctx, desc, "parameters");
    defer c.freeValue(ctx, params_v);
    if (c.isArray(ctx, params_v) == 0) {
        _ = c.throwTypeError(ctx, "ffi: '%s': 'parameters' must be an array", name.ptr);
        return error.BadSymbol;
    }
    const len_v = c.getPropertyStr(ctx, params_v, "length");
    defer c.freeValue(ctx, len_v);
    var plen: i64 = 0;
    if (c.toInt64(ctx, &plen, len_v) != 0 or plen < 0 or plen > MAX_ARGS) {
        _ = c.throwTypeError(ctx, "ffi: '%s': bad parameter count", name.ptr);
        return error.BadSymbol;
    }

    const params = gpa.alloc(ArgSpec, @intCast(plen)) catch return error.OutOfMemory;
    for (params) |*p| p.* = .{ .kind = .void_, .spec = null };
    errdefer {
        for (params) |p| {
            if (p.spec) |s| freeStructDesc(s);
        }
        gpa.free(params);
    }
    const atypes = gpa.alloc(?*FfiType, @intCast(plen)) catch return error.OutOfMemory;
    errdefer gpa.free(atypes);

    for (params, 0..) |*p, i| {
        const tv = c.getPropertyUint32(ctx, params_v, @intCast(i));
        defer c.freeValue(ctx, tv);
        p.* = try parseSpec(ctx, tv, name, 0);
        if (p.kind == .void_) {
            _ = c.throwTypeError(ctx, "ffi: '%s': 'void' is not a parameter type", name.ptr);
            return error.BadSymbol;
        }
        atypes[i] = p.ffiType();
    }

    const result_v = c.getPropertyStr(ctx, desc, "result");
    defer c.freeValue(ctx, result_v);
    const result = try parseSpec(ctx, result_v, name, 0);
    errdefer if (result.spec) |s| freeStructDesc(s);

    const opt_v = c.getPropertyStr(ctx, desc, "optional");
    defer c.freeValue(ctx, opt_v);
    const optional = c.toBool(ctx, opt_v) != 0;

    const nb_v = c.getPropertyStr(ctx, desc, "nonblocking");
    defer c.freeValue(ctx, nb_v);
    const nonblocking = c.toBool(ctx, nb_v) != 0;

    const name_z = gpa.dupeZ(u8, name) catch return error.OutOfMemory;
    errdefer gpa.free(name_z);

    const fn_ptr = dlsym(handle, name_z.ptr);
    if (fn_ptr == null) {
        if (!optional) {
            _ = c.throwTypeError(ctx, "ffi: symbol '%s' not found", name.ptr);
            return error.BadSymbol;
        }
        gpa.free(name_z);
        gpa.free(params);
        gpa.free(atypes);
        return @as(?*SymbolDesc, null);
    }

    var cif: FfiCif = undefined;
    if (ffi_prep_cif(&cif, FFI_DEFAULT_ABI, @intCast(plen), result.ffiType(), atypes.ptr) != 0) {
        _ = c.throwTypeError(ctx, "ffi: '%s': bad signature", name.ptr);
        return error.BadSymbol;
    }

    const sym = gpa.create(SymbolDesc) catch return error.OutOfMemory;
    sym.* = .{
        .lib = lib,
        .name_z = name_z,
        .params = params,
        .result = result,
        .atypes = atypes,
        .cif = cif,
        .fn_ptr = fn_ptr,
        .nonblocking = nonblocking,
    };
    return sym;
}

// ── dlopen ──

fn dlopenCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (!allow) {
        _ = c.throwTypeError(ctx, "ffi.dlopen requires --allow-ffi");
        return c.JS_EXCEPTION;
    }
    if (argc < 1) {
        _ = c.throwTypeError(ctx, "ffi.dlopen: expected a library path");
        return c.JS_EXCEPTION;
    }
    if (argc < 2) {
        _ = c.throwTypeError(ctx, "ffi.dlopen: expected a symbols object");
        return c.JS_EXCEPTION;
    }
    const path_c = strOf(ctx, argv[0]) orelse return c.JS_EXCEPTION;
    defer c.freeCString(ctx, path_c);

    const handle = dlopen(std.mem.span(path_c).ptr, RTLD_NOW) orelse {
        const err = dlerror();
        const msg: [*:0]const u8 = err orelse "unknown error";
        _ = c.throwTypeError(ctx, "ffi.dlopen: '%s': %s", path_c, msg);
        return c.JS_EXCEPTION;
    };

    const lib = gpa.create(Lib) catch {
        _ = dlclose(handle);
        return c.throwOutOfMemory(ctx);
    };
    lib.* = .{ .handle = handle, .symbols = .empty };

    // Parse the symbol table: { name: { parameters, result, optional?, nonblocking? } }.
    var tab: [*c]c.PropertyEnum = undefined;
    var n: u32 = 0;
    if (c.getOwnPropertyNames(ctx, &tab, &n, argv[1], c.GPN_STRING_MASK | c.GPN_ENUM_ONLY) < 0) {
        freeLib(lib);
        return c.JS_EXCEPTION;
    }

    const lib_obj = c.newObjectClass(ctx, lib_class_id);
    if (c.isException(lib_obj) != 0) {
        c.freePropertyEnum(ctx, tab, n);
        freeLib(lib);
        return lib_obj;
    }
    c.setOpaque(lib_obj, lib);

    const symbols_obj = c.newObject(ctx);
    if (c.isException(symbols_obj) != 0) {
        c.freePropertyEnum(ctx, tab, n);
        freeLib(lib);
        return symbols_obj;
    }

    var idx: usize = 0;
    var k: u32 = 0;
    while (k < n) : (k += 1) {
        const name_c = atomStrOf(ctx, tab[k].atom) orelse {
            c.freePropertyEnum(ctx, tab, n);
            freeLib(lib);
            return c.JS_EXCEPTION;
        };
        defer c.freeCString(ctx, name_c);
        const name = std.mem.span(name_c);

        const desc = c.getPropertyStr(ctx, argv[1], name_c);
        defer c.freeValue(ctx, desc);

        const sym = parseSymbol(ctx, lib, name, desc, handle) catch {
            c.freePropertyEnum(ctx, tab, n);
            freeLib(lib);
            return c.JS_EXCEPTION;
        };
        if (sym) |s| {
            lib.symbols.append(gpa, s) catch {
                c.freePropertyEnum(ctx, tab, n);
                freeLib(lib);
                return c.throwOutOfMemory(ctx);
            };
            var data_arr = [1]c.Value{lib_obj};
            const fn_obj = c.newCFunctionData(ctx, symCall, @intCast(s.params.len), @intCast(idx), 1, &data_arr);
            if (c.isException(fn_obj) != 0) {
                c.freePropertyEnum(ctx, tab, n);
                freeLib(lib);
                return fn_obj;
            }
            _ = c.definePropertyValueStr(ctx, symbols_obj, s.name_z.ptr, fn_obj, c.PROP_C_W_E);
            idx += 1;
        } else {
            // optional + missing: expose null
            _ = c.definePropertyValueStr(ctx, symbols_obj, name_c, c.JS_NULL, c.PROP_C_W_E);
        }
    }
    c.freePropertyEnum(ctx, tab, n);

    _ = c.definePropertyValueStr(ctx, lib_obj, "symbols", symbols_obj, c.PROP_C_W_E);
    return lib_obj;
}

// ── Pointer class: addr/toString + view getters (phase 2a memory API) ──

fn viewBase(ctx: ?*c.Context, this_val: c.Value) ?usize {
    const p = opaqueAs(u8, c.getOpaque2(ctx, this_val, ptr_class_id)) orelse return null;
    return @intFromPtr(p);
}

fn viewOffset(ctx: ?*c.Context, argc: c_int, argv: [*c]c.Value) ?usize {
    if (argc < 1) return 0;
    const o = coerceInt(ctx, argv[0]) orelse return null;
    if (o < 0) {
        _ = c.throwTypeError(ctx, "ffi view: negative offset");
        return null;
    }
    return @intCast(o);
}

fn viewGet(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value, kind: FfiKind) c.Value {
    const base = viewBase(ctx, this_val) orelse {
        _ = c.throwTypeError(ctx, "ffi view: not a pointer");
        return c.JS_EXCEPTION;
    };
    const off = viewOffset(ctx, argc, argv) orelse return c.JS_EXCEPTION;
    return readAt(ctx, base + off, kind);
}

fn viewGetInt8(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    return viewGet(ctx, this_val, argc, argv, .i8_);
}
fn viewGetUint8(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    return viewGet(ctx, this_val, argc, argv, .u8_);
}
fn viewGetInt16(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    return viewGet(ctx, this_val, argc, argv, .i16_);
}
fn viewGetUint16(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    return viewGet(ctx, this_val, argc, argv, .u16_);
}
fn viewGetInt32(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    return viewGet(ctx, this_val, argc, argv, .i32_);
}
fn viewGetUint32(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    return viewGet(ctx, this_val, argc, argv, .u32_);
}
fn viewGetInt64(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    return viewGet(ctx, this_val, argc, argv, .i64_);
}
fn viewGetUint64(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    return viewGet(ctx, this_val, argc, argv, .u64_);
}
fn viewGetFloat32(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    return viewGet(ctx, this_val, argc, argv, .f32_);
}
fn viewGetFloat64(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    return viewGet(ctx, this_val, argc, argv, .f64_);
}
fn viewGetPointer(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    return viewGet(ctx, this_val, argc, argv, .pointer);
}

fn viewGetArrayBufferCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const base = viewBase(ctx, this_val) orelse {
        _ = c.throwTypeError(ctx, "ffi view: not a pointer");
        return c.JS_EXCEPTION;
    };
    if (argc < 1) {
        _ = c.throwTypeError(ctx, "ffi view: getArrayBuffer needs a byte length");
        return c.JS_EXCEPTION;
    }
    const len = coerceInt(ctx, argv[0]) orelse return c.JS_EXCEPTION;
    if (len < 0) {
        _ = c.throwTypeError(ctx, "ffi view: negative length");
        return c.JS_EXCEPTION;
    }
    const off = if (argc > 1) (viewOffset(ctx, 1, argv + 1) orelse return c.JS_EXCEPTION) else 0;
    return copyBytesAt(ctx, base + off, @intCast(len));
}

fn viewCopyIntoCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const base = viewBase(ctx, this_val) orelse {
        _ = c.throwTypeError(ctx, "ffi view: copyInto needs a destination");
        return c.JS_EXCEPTION;
    };
    if (argc < 1) {
        _ = c.throwTypeError(ctx, "ffi view: copyInto needs a destination");
        return c.JS_EXCEPTION;
    }
    const off = if (argc > 1) (viewOffset(ctx, 1, argv + 1) orelse return c.JS_EXCEPTION) else 0;
    var len: usize = 0;
    const dst = bufferData2(ctx, argv[0], &len) orelse {
        _ = c.throwTypeError(ctx, "ffi view: copyInto needs a TypedArray destination");
        return c.JS_EXCEPTION;
    };
    const src: [*]const u8 = @ptrFromInt(base + off);
    const d: [*]u8 = @ptrCast(dst);
    @memcpy(d[0..len], src[0..len]);
    return c.JS_UNDEFINED;
}

fn viewGetCStringCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const base = viewBase(ctx, this_val) orelse {
        _ = c.throwTypeError(ctx, "ffi view: not a pointer");
        return c.JS_EXCEPTION;
    };
    const off = viewOffset(ctx, argc, argv) orelse return c.JS_EXCEPTION;
    const addr = base + off;
    if (addr == 0) return c.JS_NULL;
    const s: [*:0]const u8 = @ptrFromInt(addr);
    return c.newStringLen(ctx, s, std.mem.len(s));
}

fn ptrAddrGetter(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const p = opaqueAs(u8, c.getOpaque2(ctx, this_val, ptr_class_id)) orelse return c.JS_NULL;
    return c.newBigUint64(ctx, @intFromPtr(p));
}

fn ptrToString(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const p = opaqueAs(u8, c.getOpaque2(ctx, this_val, ptr_class_id)) orelse return c.newStringLen(ctx, "FfiPtr(null)", 12);
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "FfiPtr(0x{x})", .{@intFromPtr(p)}) catch return c.JS_EXCEPTION;
    return c.newStringLen(ctx, s.ptr, s.len);
}

// ── Memory API on the ffi global (phase 2a) ──

/// Readable/writable type for ffi.read/ffi.write: scalars + pointer only.
fn memTypeArg(ctx: ?*c.Context, v: c.Value) ?FfiKind {
    const ts = strOf(ctx, v) orelse {
        _ = c.throwTypeError(ctx, "ffi: expected a type name");
        return null;
    };
    defer c.freeCString(ctx, ts);
    const k = parseType(std.mem.span(ts)) orelse {
        _ = c.throwTypeError(ctx, "ffi: unknown type '%s'", ts);
        return null;
    };
    switch (k) {
        .void_, .struct_, .cstring, .buffer => {
            _ = c.throwTypeError(ctx, "ffi: type '%s' is not readable/writable this way", ts);
            return null;
        },
        else => return k,
    }
}

fn readCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 2) {
        _ = c.throwTypeError(ctx, "ffi.read: expected (ptr, type, offset?)");
        return c.JS_EXCEPTION;
    }
    const addr = ptrArg(ctx, argv[0], .buffer) orelse return c.JS_EXCEPTION;
    const kind = memTypeArg(ctx, argv[1]) orelse return c.JS_EXCEPTION;
    const off = viewOffset(ctx, argc - 2, if (argc > 2) argv + 2 else argv) orelse return c.JS_EXCEPTION;
    return readAt(ctx, addr + off, kind);
}

fn writeCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 3) {
        _ = c.throwTypeError(ctx, "ffi.write: expected (ptr, type, value, offset?)");
        return c.JS_EXCEPTION;
    }
    const addr = ptrArg(ctx, argv[0], .buffer) orelse return c.JS_EXCEPTION;
    const kind = memTypeArg(ctx, argv[1]) orelse return c.JS_EXCEPTION;
    const off = viewOffset(ctx, argc - 3, if (argc > 3) argv + 3 else argv) orelse return c.JS_EXCEPTION;
    if (!writeAt(ctx, addr + off, kind, argv[2])) return c.JS_EXCEPTION;
    return c.JS_UNDEFINED;
}

fn copyBytesCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 2) {
        _ = c.throwTypeError(ctx, "ffi.copyBytes: expected (ptr, byteLength)");
        return c.JS_EXCEPTION;
    }
    const addr = ptrArg(ctx, argv[0], .buffer) orelse return c.JS_EXCEPTION;
    const len = coerceInt(ctx, argv[1]) orelse return c.JS_EXCEPTION;
    if (len < 0) {
        _ = c.throwTypeError(ctx, "ffi.copyBytes: negative length");
        return c.JS_EXCEPTION;
    }
    return copyBytesAt(ctx, addr, @intCast(len));
}

fn writeBytesCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 2) {
        _ = c.throwTypeError(ctx, "ffi.writeBytes: expected (ptr, data)");
        return c.JS_EXCEPTION;
    }
    const addr = ptrArg(ctx, argv[0], .buffer) orelse return c.JS_EXCEPTION;
    if (!writeBytesAt(ctx, addr, argv[1])) return c.JS_EXCEPTION;
    return c.JS_UNDEFINED;
}

// ── ffi.struct (phase 2a) ──

fn structFinalizer(rt: ?*c.Runtime, val: c.Value) callconv(.c) void {
    _ = rt;
    const p = c.getOpaque(val, struct_class_id) orelse return;
    freeStructDesc(@ptrCast(@alignCast(p)));
}

fn structInitCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 1) {
        _ = c.throwTypeError(ctx, "ffi.struct: expected a field array");
        return c.JS_EXCEPTION;
    }
    const desc = parseStructArray(ctx, argv[0], "struct", 0, false) catch return c.JS_EXCEPTION;
    const obj = c.newObjectClass(ctx, struct_class_id);
    if (c.isException(obj) != 0) {
        freeStructDesc(desc);
        return obj;
    }
    c.setOpaque(obj, desc);
    _ = c.definePropertyValueStr(ctx, obj, "size", c.newUint32(ctx, @intCast(desc.size)), c.PROP_C_W_E);
    const offs = c.newObject(ctx);
    for (desc.names, 0..) |nm, i| {
        _ = c.definePropertyValueStr(ctx, offs, nm.ptr, c.newUint32(ctx, @intCast(desc.offsets[i])), c.PROP_C_W_E);
    }
    _ = c.definePropertyValueStr(ctx, obj, "offsets", offs, c.PROP_C_W_E);
    return obj;
}

// ── ffi.union (phase 2c) ──

fn unionFinalizer(rt: ?*c.Runtime, val: c.Value) callconv(.c) void {
    _ = rt;
    const p = c.getOpaque(val, union_class_id) orelse return;
    freeStructDesc(@ptrCast(@alignCast(p)));
}

fn unionInitCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 1) {
        _ = c.throwTypeError(ctx, "ffi.union: expected a member array");
        return c.JS_EXCEPTION;
    }
    const desc = parseStructArray(ctx, argv[0], "union", 0, true) catch return c.JS_EXCEPTION;
    const obj = c.newObjectClass(ctx, union_class_id);
    if (c.isException(obj) != 0) {
        freeStructDesc(desc);
        return obj;
    }
    c.setOpaque(obj, desc);
    _ = c.definePropertyValueStr(ctx, obj, "size", c.newUint32(ctx, @intCast(desc.size)), c.PROP_C_W_E);
    return obj;
}

// ── JS→C callbacks: FfiCallback class + ffi.callback factory ──

fn callbackPointerGetter(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const d = opaqueAs(ClosureDesc, c.getOpaque2(ctx, this_val, callback_class_id)) orelse return c.JS_NULL;
    if (d.closed) return c.JS_NULL;
    return makePtr(ctx, @intFromPtr(d.code));
}

fn callbackCloseCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const d = opaqueAs(ClosureDesc, c.getOpaque2(ctx, this_val, callback_class_id)) orelse {
        _ = c.throwTypeError(ctx, "FfiCallback.close: not a callback");
        return c.JS_EXCEPTION;
    };
    if (!d.closed) {
        if (d.in_flight.load(.acquire) > 0) {
            _ = c.throwTypeError(ctx, "FfiCallback.close: callback is busy (in-flight native call)");
            return c.JS_EXCEPTION;
        }
        if (d.bridge_job.load(.acquire) != 0) {
            _ = c.throwTypeError(ctx, "FfiCallback.close: callback is busy (in-flight nonblocking call)");
            return c.JS_EXCEPTION;
        }
        d.closed = true;
        if (d.closure) |cl| ffi_closure_free(cl);
        d.closure = null;
        c.freeValue(ctx, d.js_fn);
    }
    return c.JS_UNDEFINED;
}

fn callbackFinalizer(rt: ?*c.Runtime, val: c.Value) callconv(.c) void {
    const p = c.getOpaque(val, callback_class_id) orelse return;
    const d: *ClosureDesc = @ptrCast(@alignCast(p));
    freeClosureDesc(d, rt);
}

fn callbackFactory(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (!allow) {
        _ = c.throwTypeError(ctx, "ffi.callback requires --allow-ffi");
        return c.JS_EXCEPTION;
    }
    if (argc < 2) {
        _ = c.throwTypeError(ctx, "ffi.callback: expected (spec, fn)");
        return c.JS_EXCEPTION;
    }
    const spec = argv[0];
    const params_v = c.getPropertyStr(ctx, spec, "parameters");
    defer c.freeValue(ctx, params_v);
    if (c.isArray(ctx, params_v) == 0) {
        _ = c.throwTypeError(ctx, "ffi.callback: 'parameters' must be an array");
        return c.JS_EXCEPTION;
    }
    const len_v = c.getPropertyStr(ctx, params_v, "length");
    defer c.freeValue(ctx, len_v);
    var plen: i64 = 0;
    if (c.toInt64(ctx, &plen, len_v) != 0 or plen < 0 or plen > MAX_ARGS) {
        _ = c.throwTypeError(ctx, "ffi.callback: bad parameter count");
        return c.JS_EXCEPTION;
    }

    const params = gpa.alloc(ArgSpec, @intCast(plen)) catch return c.throwOutOfMemory(ctx);
    for (params) |*pp| pp.* = .{ .kind = .void_, .spec = null };
    const atypes = gpa.alloc(?*FfiType, @intCast(plen)) catch {
        gpa.free(params);
        return c.throwOutOfMemory(ctx);
    };
    var adopted = false;
    errdefer if (!adopted) {
        for (params) |pp| {
            if (pp.spec) |s| freeStructDesc(s);
        }
        gpa.free(params);
        gpa.free(atypes);
    };

    for (params, 0..) |*pp, i| {
        const tv = c.getPropertyUint32(ctx, params_v, @intCast(i));
        defer c.freeValue(ctx, tv);
        pp.* = parseSpec(ctx, tv, "callback", 0) catch return c.JS_EXCEPTION;
        if (pp.kind == .void_) {
            _ = c.throwTypeError(ctx, "ffi.callback: 'void' is not a parameter type");
            return c.JS_EXCEPTION;
        }
        atypes[i] = pp.ffiType();
    }

    const result_v = c.getPropertyStr(ctx, spec, "result");
    defer c.freeValue(ctx, result_v);
    var result: ArgSpec = .{ .kind = .void_, .spec = null };
    result = parseSpec(ctx, result_v, "callback", 0) catch return c.JS_EXCEPTION;
    errdefer if (result.spec) |s| freeStructDesc(s);
    if (result.kind == .cstring) {
        _ = c.throwTypeError(ctx, "ffi.callback: cstring results are not supported (v1)");
        return c.JS_EXCEPTION;
    }

    const d = gpa.create(ClosureDesc) catch return c.throwOutOfMemory(ctx);
    d.* = .{
        .params = params,
        .result = result,
        .atypes = atypes,
        .cif = undefined,
        .closure = null,
        .code = null,
        .js_fn = c.JS_UNDEFINED,
        .ctx = ctx,
        .closed = true,
    };
    adopted = true;
    errdefer freeClosureDesc(d, c.getRuntime(ctx));

    if (ffi_prep_cif(&d.cif, FFI_DEFAULT_ABI, @intCast(plen), result.ffiType(), atypes.ptr) != 0) {
        _ = c.throwTypeError(ctx, "ffi.callback: bad signature");
        return c.JS_EXCEPTION;
    }

    var code: ?*anyopaque = null;
    // 256 > sizeof(ffi_closure) on every supported target; over-alloc safe.
    d.closure = ffi_closure_alloc(256, &code);
    if (d.closure == null or code == null) {
        _ = c.throwTypeError(ctx, "ffi.callback: closure allocation failed");
        return c.JS_EXCEPTION;
    }
    d.code = code;
    if (ffi_prep_closure_loc(d.closure, &d.cif, closureTrampoline, d, code) != 0) {
        if (d.closure) |cl| ffi_closure_free(cl);
        d.closure = null;
        _ = c.throwTypeError(ctx, "ffi.callback: closure preparation failed");
        return c.JS_EXCEPTION;
    }
    cbMap().put(@intFromPtr(code), d) catch {
        if (d.closure) |cl| ffi_closure_free(cl);
        d.closure = null;
        return c.throwOutOfMemory(ctx);
    };
    d.js_fn = c.dupValue(ctx, argv[1]);
    d.closed = false;

    const obj = c.newObjectClass(ctx, callback_class_id);
    if (c.isException(obj) != 0) {
        freeClosureDesc(d, c.getRuntime(ctx));
        return obj;
    }
    c.setOpaque(obj, d);
    return obj;
}

// ── Small helpers ──

fn cstringCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 1) return c.JS_NULL;
    const arg = argv[0];
    if (c.isNull(arg) != 0 or c.isUndefined(arg) != 0) return c.JS_NULL;
    var addr: usize = 0;
    if (opaqueAs(u8, c.getOpaque2(ctx, arg, ptr_class_id))) |p| {
        addr = @intFromPtr(p);
    } else if (c.isObject(arg) != 0) {
        addr = @intFromPtr(bufferData(ctx, arg) orelse {
            _ = c.throwTypeError(ctx, "ffi.cstring: expected pointer or buffer");
            return c.JS_EXCEPTION;
        });
    } else {
        const t = arg.tag;
        if (t == c.TAG_BIG_INT or t == c.TAG_SHORT_BIG_INT) {
            var out: i64 = 0;
            if (c.toBigInt64(ctx, &out, arg) != 0) return c.JS_EXCEPTION;
            addr = @bitCast(out);
        } else {
            _ = c.throwTypeError(ctx, "ffi.cstring: expected pointer or buffer");
            return c.JS_EXCEPTION;
        }
    }
    if (addr == 0) return c.JS_NULL;
    const s: [*:0]const u8 = @ptrFromInt(addr);
    return c.newStringLen(ctx, s, std.mem.len(s));
}

fn ptrCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 1) return c.JS_NULL;
    const arg = argv[0];
    if (c.isNull(arg) != 0 or c.isUndefined(arg) != 0) return c.JS_NULL;
    if (opaqueAs(u8, c.getOpaque2(ctx, arg, ptr_class_id))) |p| {
        const off: usize = if (argc > 1) blk: {
            var o: i64 = 0;
            if (c.toInt64(ctx, &o, argv[1]) != 0) return c.JS_EXCEPTION;
            break :blk @intCast(o);
        } else 0;
        return makePtr(ctx, @intFromPtr(p) + off);
    }
    if (c.isObject(arg) != 0) {
        const p = bufferData(ctx, arg) orelse {
            _ = c.throwTypeError(ctx, "ffi.ptr: expected a TypedArray or ArrayBuffer");
            return c.JS_EXCEPTION;
        };
        return makePtr(ctx, @intFromPtr(p));
    }
    const t = arg.tag;
    if (t == c.TAG_BIG_INT or t == c.TAG_SHORT_BIG_INT) {
        var out: i64 = 0;
        if (c.toBigInt64(ctx, &out, arg) != 0) return c.JS_EXCEPTION;
        return makePtr(ctx, @bitCast(out));
    }
    _ = c.throwTypeError(ctx, "ffi.ptr: expected pointer or buffer");
    return c.JS_EXCEPTION;
}

fn isNullCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 1) return jsBool(ctx, true);
    const arg = argv[0];
    if (c.isNull(arg) != 0 or c.isUndefined(arg) != 0) return jsBool(ctx, true);
    if (opaqueAs(u8, c.getOpaque2(ctx, arg, ptr_class_id))) |p| {
        return jsBool(ctx, @intFromPtr(p) == 0);
    }
    return jsBool(ctx, false);
}

// ── Registration ──

pub fn setup(ctx: *c.Context) void {
    const rt = c.getRuntime(ctx);
    g_ctx = ctx;
    js_thread = std.Thread.getCurrentId();

    var lib_def = c.ClassDef{ .class_name = "FfiLibrary", .finalizer = libFinalizer };
    _ = c.newClassID(rt, &lib_class_id);
    _ = c.newClass(rt, lib_class_id, &lib_def);
    const lib_proto = c.newObject(ctx);
    const close_fn = c.newCFunction(ctx, closeCallback, "close", 0);
    _ = c.definePropertyValueStr(ctx, lib_proto, "close", close_fn, c.PROP_C_W_E);
    _ = c.setClassProto(ctx, lib_class_id, lib_proto);

    var ptr_def = c.ClassDef{ .class_name = "FfiPtr" };
    _ = c.newClassID(rt, &ptr_class_id);
    _ = c.newClass(rt, ptr_class_id, &ptr_def);
    const ptr_proto = c.newObject(ctx);
    const addr_get = c.newCFunction(ctx, ptrAddrGetter, "get addr", 0);
    const tostr_fn = c.newCFunction(ctx, ptrToString, "toString", 0);
    _ = c.definePropertyValueStr(ctx, ptr_proto, "toString", tostr_fn, c.PROP_C_W_E);
    // `addr` must be an accessor: p.addr → BigInt. A plain data property
    // makes p.addr return the getter function itself.
    const addr_atom = c.newAtom(ctx, "addr");
    defer c.freeAtom(ctx, addr_atom);
    _ = c.definePropertyGetSet(ctx, ptr_proto, addr_atom, addr_get, c.JS_UNDEFINED, c.PROP_CONFIGURABLE | c.PROP_ENUMERABLE);

    // Deno-style view getters on the pointer object (ffi.view(p) → same
    // object shape; plain functions so names show up in traces).
    inline for ([_]struct { [*:0]const u8, *const fn (?*c.Context, c.Value, c_int, [*c]c.Value) callconv(.c) c.Value }{
        .{ "getInt8", viewGetInt8 },
        .{ "getUint8", viewGetUint8 },
        .{ "getInt16", viewGetInt16 },
        .{ "getUint16", viewGetUint16 },
        .{ "getInt32", viewGetInt32 },
        .{ "getUint32", viewGetUint32 },
        .{ "getBigInt64", viewGetInt64 },
        .{ "getBigUint64", viewGetUint64 },
        .{ "getFloat32", viewGetFloat32 },
        .{ "getFloat64", viewGetFloat64 },
        .{ "getPointer", viewGetPointer },
    }) |g| {
        const fn_obj = c.newCFunction(ctx, g[1], g[0], 1);
        _ = c.definePropertyValueStr(ctx, ptr_proto, g[0], fn_obj, c.PROP_C_W_E);
    }
    const gab_fn = c.newCFunction(ctx, viewGetArrayBufferCallback, "getArrayBuffer", 2);
    _ = c.definePropertyValueStr(ctx, ptr_proto, "getArrayBuffer", gab_fn, c.PROP_C_W_E);
    const ci_fn = c.newCFunction(ctx, viewCopyIntoCallback, "copyInto", 2);
    _ = c.definePropertyValueStr(ctx, ptr_proto, "copyInto", ci_fn, c.PROP_C_W_E);
    const gcs_fn = c.newCFunction(ctx, viewGetCStringCallback, "getCString", 1);
    _ = c.definePropertyValueStr(ctx, ptr_proto, "getCString", gcs_fn, c.PROP_C_W_E);
    _ = c.setClassProto(ctx, ptr_class_id, ptr_proto);

    var struct_def = c.ClassDef{ .class_name = "FfiStruct", .finalizer = structFinalizer };
    _ = c.newClassID(rt, &struct_class_id);
    _ = c.newClass(rt, struct_class_id, &struct_def);

    var union_def = c.ClassDef{ .class_name = "FfiUnion", .finalizer = unionFinalizer };
    _ = c.newClassID(rt, &union_class_id);
    _ = c.newClass(rt, union_class_id, &union_def);

    var cb_def = c.ClassDef{ .class_name = "FfiCallback", .finalizer = callbackFinalizer };
    _ = c.newClassID(rt, &callback_class_id);
    _ = c.newClass(rt, callback_class_id, &cb_def);
    const cb_proto = c.newObject(ctx);
    const ptr_atom2 = c.newAtom(ctx, "pointer");
    defer c.freeAtom(ctx, ptr_atom2);
    const cb_ptr_get = c.newCFunction(ctx, callbackPointerGetter, "get pointer", 0);
    _ = c.definePropertyGetSet(ctx, cb_proto, ptr_atom2, cb_ptr_get, c.JS_UNDEFINED, c.PROP_CONFIGURABLE | c.PROP_ENUMERABLE);
    const cb_close_fn = c.newCFunction(ctx, callbackCloseCallback, "close", 0);
    _ = c.definePropertyValueStr(ctx, cb_proto, "close", cb_close_fn, c.PROP_C_W_E);
    _ = c.setClassProto(ctx, callback_class_id, cb_proto);

    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);
    const ffi_obj = c.newObject(ctx);

    const dlopen_fn = c.newCFunction(ctx, dlopenCallback, "dlopen", 2);
    _ = c.definePropertyValueStr(ctx, ffi_obj, "dlopen", dlopen_fn, c.PROP_C_W_E);

    const cstr_fn = c.newCFunction(ctx, cstringCallback, "cstring", 1);
    _ = c.definePropertyValueStr(ctx, ffi_obj, "cstring", cstr_fn, c.PROP_C_W_E);

    const ptr_fn = c.newCFunction(ctx, ptrCallback, "ptr", 2);
    _ = c.definePropertyValueStr(ctx, ffi_obj, "ptr", ptr_fn, c.PROP_C_W_E);

    // ffi.view(p) normalizes to a FfiPtr — the pointer object itself is
    // the view (getters live on it).
    const view_fn = c.newCFunction(ctx, ptrCallback, "view", 2);
    _ = c.definePropertyValueStr(ctx, ffi_obj, "view", view_fn, c.PROP_C_W_E);

    const isnull_fn = c.newCFunction(ctx, isNullCallback, "isNull", 1);
    _ = c.definePropertyValueStr(ctx, ffi_obj, "isNull", isnull_fn, c.PROP_C_W_E);

    const read_fn = c.newCFunction(ctx, readCallback, "read", 3);
    _ = c.definePropertyValueStr(ctx, ffi_obj, "read", read_fn, c.PROP_C_W_E);
    const write_fn = c.newCFunction(ctx, writeCallback, "write", 4);
    _ = c.definePropertyValueStr(ctx, ffi_obj, "write", write_fn, c.PROP_C_W_E);
    const cp_fn = c.newCFunction(ctx, copyBytesCallback, "copyBytes", 2);
    _ = c.definePropertyValueStr(ctx, ffi_obj, "copyBytes", cp_fn, c.PROP_C_W_E);
    const wp_fn = c.newCFunction(ctx, writeBytesCallback, "writeBytes", 2);
    _ = c.definePropertyValueStr(ctx, ffi_obj, "writeBytes", wp_fn, c.PROP_C_W_E);
    const st_fn = c.newCFunction(ctx, structInitCallback, "struct", 1);
    _ = c.definePropertyValueStr(ctx, ffi_obj, "struct", st_fn, c.PROP_C_W_E);
    const un_fn = c.newCFunction(ctx, unionInitCallback, "union", 1);
    _ = c.definePropertyValueStr(ctx, ffi_obj, "union", un_fn, c.PROP_C_W_E);
    const cb_f = c.newCFunction(ctx, callbackFactory, "callback", 2);
    _ = c.definePropertyValueStr(ctx, ffi_obj, "callback", cb_f, c.PROP_C_W_E);

    _ = c.definePropertyValueStr(ctx, ffi_obj, "allowed", jsBool(ctx, allow), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, global, "ffi", ffi_obj, c.PROP_C_W_E);
}
