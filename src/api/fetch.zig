const std = @import("std");
const c = @import("../c.zig").c;
const request_mod = @import("../types/request.zig");
const headers_mod = @import("../types/headers.zig");
const async_fetch = @import("../net/async_fetch.zig");
const tls = @import("../net/tls.zig");
const perm = @import("../security/permissions.zig");
const deny = @import("../security/deny.zig");
const loop_mod = @import("../event/loop.zig");
const http_native = @import("../net/http_native.zig");
const gpa = std.heap.smp_allocator;
const http = std.http;

pub var abort_signal_class_id: c.ClassID = 0;

pub const AbortSignalData = struct {
    aborted: bool = false,
    close_server: bool = false,
    self_timer_slot: i16 = -1,
    fetch_mask: u16 = 0,
    fetch_gens: [async_fetch.MAX_FETCH]u16 = [_]u16{0} ** async_fetch.MAX_FETCH,
    timer_mask: [2]u64 = .{ 0, 0 },
    // Generation captured when a timer is attached. A timer slot can be
    // recycled after it fires; without this, a later abort would clear an
    // unrelated timer that reused the same slot.
    timer_gens: [128]u32 = [_]u32{0} ** 128,
};

fn abortSignalFinalizer(_: ?*c.Runtime, val: c.Value) callconv(.c) void {
    const ptr = c.getOpaque(val, abort_signal_class_id) orelse return;
    const data: *AbortSignalData = @ptrCast(@alignCast(ptr));
    gpa.destroy(data);
}

pub fn getAbortSignalData(ctx: ?*c.Context, val: c.Value) ?*AbortSignalData {
    if (c.isObject(val) == 0) return null;
    const ptr = c.getOpaque2(ctx, val, abort_signal_class_id) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

pub fn attachTimerToSignal(ctx: ?*c.Context, sig_val: c.Value, timer_slot: usize) bool {
    if (timer_slot >= 128) return true;
    const data = getAbortSignalData(ctx, sig_val) orelse return true;
    if (data.aborted) return false;
    const w = timer_slot >> 6;
    const b: u6 = @intCast(timer_slot & 63);
    data.timer_mask[w] |= (@as(u64, 1) << b);
    if (loop_mod.timer_mgr) |tm| {
        data.timer_gens[timer_slot] = tm.generation(@intCast(timer_slot));
    }
    return true;
}

pub fn attachServerToSignal(ctx: ?*c.Context, sig_val: c.Value) bool {
    const data = getAbortSignalData(ctx, sig_val) orelse return true;
    if (data.aborted) return false;
    data.close_server = true;
    return true;
}

fn makeAbortError(ctx: ?*c.Context, name: []const u8, msg: []const u8) c.Value {
    const err = c.newError(ctx);
    if (c.isException(err) != 0) return err;
    _ = c.definePropertyValueStr(ctx, err, "name", zigStringToJS(ctx, name), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, err, "message", zigStringToJS(ctx, msg), c.PROP_C_W_E);
    return err;
}

fn newAbortSignalObject(ctx: ?*c.Context) ?struct { obj: c.Value, data: *AbortSignalData } {
    const data = gpa.create(AbortSignalData) catch return null;
    data.* = .{};
    const obj = c.newObjectClass(ctx, @intCast(abort_signal_class_id));
    if (c.isException(obj) != 0) {
        gpa.destroy(data);
        return null;
    }
    c.setOpaque(obj, data);
    _ = c.definePropertyValueStr(ctx, obj, "aborted", c.JS_FALSE, c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "reason", c.JS_UNDEFINED, c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "_onabort", c.JS_NULL, c.PROP_C_W_E);
    return .{ .obj = obj, .data = data };
}

pub fn triggerAbortSignal(ctx: ?*c.Context, sig_obj: c.Value, reason_arg: c.Value) void {
    const data = getAbortSignalData(ctx, sig_obj) orelse return;
    if (data.aborted) return;
    data.aborted = true;

    if (data.self_timer_slot >= 0) {
        const ts: usize = @intCast(data.self_timer_slot);
        data.self_timer_slot = -1;
        if (loop_mod.timer_mgr) |tm| tm.clear(ts);
    }

    const reason = if (c.isUndefined(reason_arg) != 0)
        makeAbortError(ctx, "AbortError", "The operation was aborted")
    else
        c.dupValue(ctx, reason_arg);
    defer c.freeValue(ctx, reason);

    _ = c.definePropertyValueStr(ctx, sig_obj, "aborted", c.JS_TRUE, c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, sig_obj, "reason", c.dupValue(ctx, reason), c.PROP_C_W_E);

    // 1. Cancel any attached in-flight fetch slots immediately.
    var fmask = data.fetch_mask;
    data.fetch_mask = 0;
    while (fmask != 0) {
        const s: usize = @ctz(fmask);
        fmask &= fmask - 1;
        async_fetch.abortSlot(ctx, s, data.fetch_gens[s], reason);
    }

    // 2. Cancel any attached timers. Only clear if the slot still has the
    // generation captured at attach time; otherwise the original timer has
    // already fired and the slot belongs to somebody else.
    for (0..2) |w| {
        var tmask = data.timer_mask[w];
        data.timer_mask[w] = 0;
        while (tmask != 0) {
            const bit: usize = @ctz(tmask);
            tmask &= tmask - 1;
            const slot = w * 64 + bit;
            if (loop_mod.timer_mgr) |tm| {
                if (tm.generation(@intCast(slot)) == data.timer_gens[slot]) {
                    tm.clear(slot);
                }
            }
        }
    }

    // 3. Close HTTP server if attached via http.serve({ signal }).
    if (data.close_server) {
        data.close_server = false;
        http_native.closeServer();
    }

    // 4. Dispatch abort event to onabort and addEventListener listeners.
    const ev = c.newObject(ctx);
    defer c.freeValue(ctx, ev);
    _ = c.definePropertyValueStr(ctx, ev, "type", zigStringToJS(ctx, "abort"), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, ev, "target", c.dupValue(ctx, sig_obj), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, ev, "currentTarget", c.dupValue(ctx, sig_obj), c.PROP_C_W_E);

    const onabort = c.getPropertyStr(ctx, sig_obj, "_onabort");
    defer c.freeValue(ctx, onabort);
    if (c.isFunction(ctx, onabort) != 0) {
        var args = [_]c.Value{ev};
        const ret = c.call(ctx, onabort, sig_obj, 1, &args);
        c.freeValue(ctx, ret);
    }

    const list = c.getPropertyStr(ctx, sig_obj, "_listeners");
    defer c.freeValue(ctx, list);
    if (c.isArray(ctx, list) != 0) {
        const len_val = c.getPropertyStr(ctx, list, "length");
        defer c.freeValue(ctx, len_val);
        var len: i32 = 0;
        if (c.toInt32(ctx, &len, len_val) == 0 and len > 0) {
            var i: u32 = 0;
            while (i < @as(u32, @intCast(len))) : (i += 1) {
                const fn_val = c.getPropertyUint32(ctx, list, i);
                defer c.freeValue(ctx, fn_val);
                if (c.isFunction(ctx, fn_val) != 0) {
                    var args = [_]c.Value{ev};
                    const ret = c.call(ctx, fn_val, sig_obj, 1, &args);
                    c.freeValue(ctx, ret);
                }
            }
        }
        _ = c.definePropertyValueStr(ctx, sig_obj, "_listeners", c.JS_UNDEFINED, c.PROP_C_W_E);
    }
}

fn signalGetOnabort(ctx: ?*c.Context, this_val: c.Value, _: c_int, _: [*c]c.Value) callconv(.c) c.Value {
    return c.getPropertyStr(ctx, this_val, "_onabort");
}

fn signalSetOnabort(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const val = if (argc >= 1 and (c.isFunction(ctx, argv[0]) != 0 or c.isNull(argv[0]) != 0))
        c.dupValue(ctx, argv[0])
    else
        c.JS_NULL;
    _ = c.definePropertyValueStr(ctx, this_val, "_onabort", val, c.PROP_C_W_E);
    if (argc >= 1 and c.isFunction(ctx, argv[0]) != 0) {
        if (getAbortSignalData(ctx, this_val)) |data| {
            if (!data.aborted and data.self_timer_slot >= 0) {
                if (loop_mod.timer_mgr) |tm| tm.refSlot(@intCast(data.self_timer_slot));
            }
        }
    }
    return c.JS_UNDEFINED;
}

fn signalThrowIfAborted(ctx: ?*c.Context, this_val: c.Value, _: c_int, _: [*c]c.Value) callconv(.c) c.Value {
    const data = getAbortSignalData(ctx, this_val) orelse {
        return c.throwTypeError(ctx, "throwIfAborted called on invalid AbortSignal");
    };
    if (!data.aborted) return c.JS_UNDEFINED;
    const reason = c.getPropertyStr(ctx, this_val, "reason");
    return c.throw(ctx, reason);
}

fn signalAddEventListener(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    if (argc < 2 or c.isString(argv[0]) == 0 or c.isFunction(ctx, argv[1]) == 0) return c.JS_UNDEFINED;
    const data = getAbortSignalData(ctx, this_val) orelse return c.JS_UNDEFINED;
    if (data.aborted) return c.JS_UNDEFINED;
    var tbuf: [32]u8 = undefined;
    const tex = extractStringAuto(ctx, argv[0], &tbuf) orelse return c.JS_UNDEFINED;
    defer tex.deinit();
    if (!std.mem.eql(u8, tex.slice, "abort")) return c.JS_UNDEFINED;

    var list = c.getPropertyStr(ctx, this_val, "_listeners");
    if (c.isArray(ctx, list) == 0) {
        c.freeValue(ctx, list);
        list = c.newArray(ctx);
        _ = c.definePropertyValueStr(ctx, this_val, "_listeners", c.dupValue(ctx, list), c.PROP_C_W_E);
    }
    defer c.freeValue(ctx, list);

    const len_val = c.getPropertyStr(ctx, list, "length");
    defer c.freeValue(ctx, len_val);
    var len: i32 = 0;
    _ = c.toInt32(ctx, &len, len_val);
    if (len >= 0) {
        _ = c.definePropertyValueUint32(ctx, list, @intCast(len), c.dupValue(ctx, argv[1]), c.PROP_C_W_E);
    }
    if (data.self_timer_slot >= 0) {
        if (loop_mod.timer_mgr) |tm| tm.refSlot(@intCast(data.self_timer_slot));
    }
    return c.JS_UNDEFINED;
}

fn signalRemoveEventListener(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    if (argc < 2 or c.isString(argv[0]) == 0 or c.isFunction(ctx, argv[1]) == 0) return c.JS_UNDEFINED;
    var tbuf: [32]u8 = undefined;
    const tex = extractStringAuto(ctx, argv[0], &tbuf) orelse return c.JS_UNDEFINED;
    defer tex.deinit();
    if (!std.mem.eql(u8, tex.slice, "abort")) return c.JS_UNDEFINED;

    const list = c.getPropertyStr(ctx, this_val, "_listeners");
    defer c.freeValue(ctx, list);
    if (c.isArray(ctx, list) == 0) return c.JS_UNDEFINED;

    const len_val = c.getPropertyStr(ctx, list, "length");
    defer c.freeValue(ctx, len_val);
    var len: i32 = 0;
    if (c.toInt32(ctx, &len, len_val) != 0 or len <= 0) return c.JS_UNDEFINED;

    var i: u32 = 0;
    while (i < @as(u32, @intCast(len))) : (i += 1) {
        const item = c.getPropertyUint32(ctx, list, i);
        defer c.freeValue(ctx, item);
        if (item.u.ptr == argv[1].u.ptr and item.tag == argv[1].tag) {
            _ = c.setPropertyUint32(ctx, list, i, c.JS_UNDEFINED);
            break;
        }
    }
    return c.JS_UNDEFINED;
}

fn signalStaticAbort(ctx: ?*c.Context, _: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const created = newAbortSignalObject(ctx) orelse return c.throwOutOfMemory(ctx);
    const reason_arg = if (argc >= 1) argv[0] else c.JS_UNDEFINED;
    triggerAbortSignal(ctx, created.obj, reason_arg);
    return created.obj;
}

fn timeoutSignalFireCallback(ctx: ?*c.Context, _: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    if (argc < 1) return c.JS_UNDEFINED;
    const sig_obj = argv[0];
    if (getAbortSignalData(ctx, sig_obj)) |data| {
        data.self_timer_slot = -1;
    }
    const err = makeAbortError(ctx, "TimeoutError", "The operation timed out");
    defer c.freeValue(ctx, err);
    triggerAbortSignal(ctx, sig_obj, err);
    return c.JS_UNDEFINED;
}

fn signalStaticTimeout(ctx: ?*c.Context, _: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    if (argc < 1) {
        return c.throwTypeError(ctx, "AbortSignal.timeout requires a millisecond delay");
    }
    var ms: i64 = 0;
    if (c.toInt64(ctx, &ms, argv[0]) != 0) return c.JS_EXCEPTION;
    if (ms < 0) ms = 0;

    const created = newAbortSignalObject(ctx) orelse return c.throwOutOfMemory(ctx);
    const tm = loop_mod.timer_mgr orelse return created.obj;
    const cb = c.newCFunction(ctx, timeoutSignalFireCallback, "timeoutAbort", 1);
    defer c.freeValue(ctx, cb);
    const args = [_]c.Value{created.obj};
    const slot = tm.setTimeout(ctx.?, cb, @intCast(ms), &args) catch {
        c.freeValue(ctx, created.obj);
        return c.throwTypeError(ctx, "too many timers (max 128)");
    };
    created.data.self_timer_slot = @intCast(slot);
    // Unref by default so a fast fetch with AbortSignal.timeout(30000) does not
    // hold the process open after fetch settles; attaching onabort/addEventListener
    // upgrades it to referenced.
    tm.unrefSlot(@intCast(slot));
    return created.obj;
}

fn abortControllerConstructor(ctx: ?*c.Context, _: c.Value, _: c_int, _: [*c]c.Value) callconv(.c) c.Value {
    const sig = newAbortSignalObject(ctx) orelse return c.throwOutOfMemory(ctx);
    const ctrl = c.newObject(ctx);
    if (c.isException(ctrl) != 0) {
        c.freeValue(ctx, sig.obj);
        return ctrl;
    }
    _ = c.definePropertyValueStr(ctx, ctrl, "signal", sig.obj, c.PROP_C_W_E);
    const abort_fn = c.newCFunction(ctx, abortControllerAbort, "abort", 1);
    _ = c.definePropertyValueStr(ctx, ctrl, "abort", abort_fn, c.PROP_C_W_E);
    return ctrl;
}

fn abortControllerAbort(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const sig_val = c.getPropertyStr(ctx, this_val, "signal");
    defer c.freeValue(ctx, sig_val);
    if (getAbortSignalData(ctx, sig_val) == null) {
        return c.throwTypeError(ctx, "AbortController.abort: invalid receiver");
    }
    const reason_arg = if (argc >= 1) argv[0] else c.JS_UNDEFINED;
    triggerAbortSignal(ctx, sig_val, reason_arg);
    return c.JS_UNDEFINED;
}

// ── DOD note ──
// This file is cold submit path (once per fetch() call), NOT the hot drain
// path (async_fetch.runJob / event-loop pump).
// C1 FIX (+ FIX-4): URL/method/body are BORROWED here, not heap-duped —
// submit() stages URL and body into its per-slot static buffers
// synchronously (under poolLock) and the method is parsed to an enum
// before submit, so stack lifetimes suffice. HeadersData comes from the
// freelist. (Supersedes the old "heap ownership transferred to the worker"
// note for URL/method/body; headers ownership is unchanged.) // ◀ FIX-4

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

fn extractRequestData(ctx: ?*c.Context, obj: c.Value) ?*request_mod.RequestData {
    if (c.isObject(obj) == 0) return null;
    const ptr = c.getOpaque2(ctx, obj, request_mod.request_class_id) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn methodToken(comptime s: []const u8) u64 {
    var buf = [_]u8{0} ** 8;
    @memcpy(buf[0..s.len], s);
    return std.mem.readInt(u64, &buf, .little);
}

fn parseMethod(method_str: []const u8) http.Method {
    var buf = [_]u8{0} ** 8;
    const n = @min(method_str.len, 8);
    @memcpy(buf[0..n], method_str[0..n]);
    const w = std.mem.readInt(u64, &buf, .little);
    return switch (method_str.len) {
        3 => if (w == methodToken("GET")) .GET else if (w == methodToken("PUT")) .PUT else .GET,
        4 => if (w == methodToken("HEAD")) .HEAD else if (w == methodToken("POST")) .POST else .GET,
        5 => if (w == methodToken("PATCH")) .PATCH else .GET,
        6 => if (w == methodToken("DELETE")) .DELETE else .GET,
        7 => if (w == methodToken("OPTIONS")) .OPTIONS else .GET,
        else => .GET,
    };
}

fn collectHeadersFromJS(
    ctx: ?*c.Context,
    val: c.Value,
    target: *headers_mod.HeadersData,
) void {
    if (c.isUndefined(val) != 0 or c.isNull(val) != 0) return;
    if (c.isObject(val) == 0) return;
    if (c.getOpaque2(ctx, val, headers_mod.headers_class_id)) |ptr| {
        const src: *headers_mod.HeadersData = @ptrCast(@alignCast(ptr));
        // Batch reserve: one growth instead of per-header realloc.
        target.reserve(src.len(), src.names.items.len, src.values.items.len);
        for (0..src.len()) |i| {
            const p = src.getPair(i);
            target.appendEntry(p.name, p.value);
        }
        return;
    }
    var p: [*c]c.PropertyEnum = null;
    var count: c_uint = 0;
    if (c.getOwnPropertyNames(ctx, &p, &count, val, c.GPN_STRING_MASK | c.GPN_ENUM_ONLY) == 0) {
        defer c.freePropertyEnum(ctx, p, count);
        // DOD-FIX: pre-reserve with count hint (avg 16B name / 32B value).
        target.reserveEntries(count);
        for (0..count) |idx| {
            const name_atom = p[idx].atom;
            const name_val = c.atomToString(ctx, name_atom);
            defer c.freeValue(ctx, name_val);
            const prop_val = c.getProperty(ctx, val, name_atom);
            defer c.freeValue(ctx, prop_val);
            var nbuf: [128]u8 = undefined;
            var vbuf: [256]u8 = undefined;
            const n = extractStringAuto(ctx, name_val, &nbuf);
            const v = extractStringAuto(ctx, prop_val, &vbuf);
            if (n) |nn| {
                defer nn.deinit();
                if (v) |vv| {
                    defer vv.deinit();
                    target.appendEntry(nn.slice, vv.slice);
                }
            }
        }
    }
}

// The fetch worker pool (16 threads + job pipe + xev.Async) starts on the
// first fetch() call — HTTP-only processes pay zero thread footprint at
// boot. async_fetch.init is idempotent-by-flag; the event loop is safe
// pre-init (drainCompleted no-ops while all slots are JOB_FREE, arm is
// gated on pending > 0).
var fetch_inited = false;

fn ensureFetchInit(ctx: ?*c.Context) void {
    if (fetch_inited) return;
    async_fetch.init(ctx); // pump ctx: completions resolve promises here
    fetch_inited = true;
}

fn rejectInvalidUrl(ctx: ?*c.Context, cap: [2]c.Value, promise: c.Value) c.Value {
    var msg = zigStringToJS(ctx, "Invalid URL");
    _ = c.call(ctx, cap[1], c.JS_UNDEFINED, 1, &msg);
    c.freeValue(ctx, msg);
    return promise;
}

fn fetchCallback(ctx: ?*c.Context, _: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    if (argc < 1) {
        _ = c.throwTypeError(ctx, "fetch requires a URL string or Request as first argument");
        return c.JS_EXCEPTION;
    }
    ensureFetchInit(ctx);
    var cap: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &cap);
    // BUG-5: JS_NewPromiseCapability gives the caller owning refs on BOTH
    // resolving functions. async_fetch.submit dupValue()s them into the
    // slot, so ours must be freed on every path — pattern matches the two
    // correct sites already in the tree (sql.zig:303-314, crypto.zig:216-237).
    // Registered after the exception guard so cap[] is never touched when
    // capability creation itself failed.
    if (c.isException(promise) != 0) return promise;
    defer c.freeValue(ctx, cap[0]);
    defer c.freeValue(ctx, cap[1]);
    const arg0 = argv[0];
    // C1 FIX (+ FIX-4): URL + method + body are BORROWED (stack scratch,
    // heap spill only for longer). submit() stages URL and body
    // synchronously under poolLock and the method is parsed to an enum
    // before submit, so nothing outlives the frame. The JS values and the
    // Request pool behind these borrows stay alive for the whole call
    // (arg0/body_val rooted; defers below run after submit returns). // ◀ FIX-4
    var url_stack: [2048]u8 = undefined;
    var url_heap: ?[:0]const u8 = null;
    defer if (url_heap) |u| gpa.free(u);
    var url: ?[]const u8 = null;
    var method_stack: [64]u8 = undefined;
    var method_heap: ?[:0]const u8 = null;
    defer if (method_heap) |m| gpa.free(m);
    var method_override: ?[]const u8 = null;
    // FIX-4: borrowed body (Request pool / stack / transient spill).
    // submit() stages it before return; the heap half (if any) is freed
    // by the defer below — after submit has copied. // ◀ FIX-4
    var body_stack: [2048]u8 = undefined; // ◀ FIX-4
    var body_ex: ?ExtractedStr = null; // ◀ FIX-4
    defer if (body_ex) |ex| ex.deinit(); // ◀ FIX-4
    var body_borrowed: ?[]const u8 = null; // ◀ FIX-4
    // DOD-FIX: single getOpaque2 lookup, reused below (was looked up twice).
    const req_data = extractRequestData(ctx, arg0);
    if (c.isString(arg0) != 0) {
        if (extractStringAuto(ctx, arg0, &url_stack)) |ex| {
            url = ex.slice;
            url_heap = ex.heap;
        }
    } else if (c.isObject(arg0) != 0) {
        if (req_data) |rd| {
            // Borrowed from the live Request object (arg0 is rooted for this
            // call); submit() copies synchronously before return.
            url = rd.url();
            method_override = rd.method();
            // FIX-4: borrow (was gpa.dupeZ per fetch). Also fixes a leak:
            // the old dupe was overwritten — and lost — by the init-body
            // path below when both were present. // ◀ FIX-4
            if (rd.body()) |b| body_ex = .{ .slice = b }; // ◀ FIX-4
        } else {
            const url_val = c.getPropertyStr(ctx, arg0, "url");
            defer c.freeValue(ctx, url_val);
            if (extractStringAuto(ctx, url_val, &url_stack)) |ex| {
                url = ex.slice;
                url_heap = ex.heap;
            }
        }
    } else {
        _ = c.throwTypeError(ctx, "fetch requires a URL string or Request as first argument");
        // BUG-5: promise + cap[0] + cap[1] are owned by this frame and
        // referenced by nothing yet — 3 JSValues leaked per bad-argument call.
        c.freeValue(ctx, promise);
        return c.JS_EXCEPTION;
    }

    // DOD-FIX 5: build a single dense HeadersData in-place.
    var in_flight_headers = headers_mod.HeadersData.init();

    // If arg0 is a Request, copy its headers into the in-flight pool.
    // Batch reserve first: one growth, not per-header.
    if (req_data) |rd| {
        in_flight_headers.reserve(rd.headers.len(), rd.headers.names.items.len, rd.headers.values.items.len);
        for (0..rd.headers.len()) |i| {
            const pair = rd.headers.getPair(i);
            in_flight_headers.appendEntry(pair.name, pair.value);
        }
    }

    var signal_val: c.Value = c.JS_UNDEFINED;
    if (req_data != null) {
        signal_val = c.getPropertyStr(ctx, arg0, "signal");
    }
    defer c.freeValue(ctx, signal_val);

    if (argc > 1 and c.isObject(argv[1]) != 0) {
        const init_val = argv[1];
        const init_sig = c.getPropertyStr(ctx, init_val, "signal");
        if (c.isUndefined(init_sig) == 0 and c.isNull(init_sig) == 0) {
            c.freeValue(ctx, signal_val);
            signal_val = init_sig;
        } else {
            c.freeValue(ctx, init_sig);
        }
        const method_val = c.getPropertyStr(ctx, init_val, "method");
        defer c.freeValue(ctx, method_val);
        // Guard undefined/null before alloc (was unconditional alloc).
        if (c.isUndefined(method_val) == 0 and c.isNull(method_val) == 0) {
            if (extractStringAuto(ctx, method_val, &method_stack)) |m| {
                method_override = m.slice;
                method_heap = m.heap;
            }
        }
        const headers_val = c.getPropertyStr(ctx, init_val, "headers");
        defer c.freeValue(ctx, headers_val);
        collectHeadersFromJS(ctx, headers_val, &in_flight_headers);
        const body_val = c.getPropertyStr(ctx, init_val, "body");
        defer c.freeValue(ctx, body_val);
        if (c.isUndefined(body_val) == 0 and c.isNull(body_val) == 0) {
            // FIX-4: borrow via stack scratch (heap spill only for >2K),
            // staged by submit(). body_val is freed by the defer above —
            // after submit returns. (Was: unconditional heap dupe.) // ◀ FIX-4
            if (extractStringAuto(ctx, body_val, &body_stack)) |ex| body_ex = ex; // ◀ FIX-4
        }
    }

    const sig_data = getAbortSignalData(ctx, signal_val);
    if (sig_data) |sd| {
        if (sd.aborted) {
            in_flight_headers.deinit();
            var reason = c.getPropertyStr(ctx, signal_val, "reason");
            defer c.freeValue(ctx, reason);
            _ = c.call(ctx, cap[1], c.JS_UNDEFINED, 1, &reason);
            return promise;
        }
    }

    // FIX-4: materialize the borrow before use (GET→POST check and submit
    // handoff below both read body_borrowed). // ◀ FIX-4
    if (body_ex) |ex| body_borrowed = ex.slice; // ◀ FIX-4

    const url_slice = url orelse {
        // BUG-5: the old `errdefer in_flight_headers.deinit()` never fired
        // (this function has no error returns) → the reserved name/value
        // pools leaked on every early return. Explicit cleanup instead.
        in_flight_headers.deinit();
        return rejectInvalidUrl(ctx, cap, promise);
    };
    var method_str = method_override orelse "GET";
    if (body_borrowed != null and std.mem.eql(u8, method_str, "GET")) { // ◀ FIX-4 (was: body_payload)
        method_str = "POST";
    }
    const method = parseMethod(method_str);
    const uri = std.Uri.parse(url_slice) catch {
        in_flight_headers.deinit();
        return rejectInvalidUrl(ctx, cap, promise);
    };

    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and
        !std.ascii.eqlIgnoreCase(uri.scheme, "https"))
    {
        in_flight_headers.deinit();
        return rejectInvalidUrl(ctx, cap, promise);
    }

    const host_comp = uri.host orelse {
        in_flight_headers.deinit();
        return rejectInvalidUrl(ctx, cap, promise);
    };
    var host_buf: [256]u8 = undefined;
    const host = host_comp.toRaw(&host_buf) catch {
        in_flight_headers.deinit();
        return rejectInvalidUrl(ctx, cap, promise);
    };
    const default_port: u16 = if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) 443 else 80;
    const port: u16 = uri.port orelse default_port;

    if (perm.global().checkNet(host, port) == .denied) {
        in_flight_headers.deinit();
        c.freeValue(ctx, promise);
        var detail_buf: [320]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_buf, "{s}:{d}", .{ host, port }) catch host;
        return deny.throw(ctx, "fetch", .net, detail);
    }

    // Transfer ownership of in_flight_headers to async_fetch. Wrap in a
    // pooled HeadersData shell so async_fetch can hold a stable pointer.
    // The shell is returned to the freelist by freeOwned once runJob has
    // adopted its contents into the response's HeadersData.
    // C1 FIX: pooled shell (was gpa.create per fetch() call).
    const hdr_ptr = headers_mod.acquire() orelse {
        in_flight_headers.deinit();
        var msg = zigStringToJS(ctx, "Out of memory");
        _ = c.call(ctx, cap[1], c.JS_UNDEFINED, 1, &msg);
        c.freeValue(ctx, msg);
        return promise;
    };
    hdr_ptr.* = in_flight_headers;
    // FIX-4: body_borrowed is staged synchronously by submit(); the body_ex
    // defer above frees any transient spill after submit returns. URL needs
    // no handoff — submit() staged a copy synchronously, and url_heap
    // (spill only) is freed by the defer above on return. // ◀ FIX-4
    const tok = async_fetch.submit(ctx, cap[0], cap[1], url_slice, uri, method, hdr_ptr, body_borrowed) catch {
        // BUG-6 FIX (double-release UAF): submit() takes ownership the moment
        // it is called and has ALREADY released headers on BOTH of its
        // failure paths — pool-full and shutdown. (URL and body are borrowed,
        // nothing to release.) Do not touch hdr_ptr again here. // ◀ FIX-4
        var msg = zigStringToJS(ctx, "Failed to start fetch");
        _ = c.call(ctx, cap[1], c.JS_UNDEFINED, 1, &msg);
        c.freeValue(ctx, msg);
        return promise;
    };
    if (sig_data) |sd| {
        sd.fetch_gens[tok.slot] = tok.gen;
        sd.fetch_mask |= (@as(u16, 1) << @intCast(tok.slot));
    }
    return promise;
}

pub fn deinitClient() void {
    if (fetch_inited) async_fetch.deinit();
    tls.deinit(); // self-guards when never initialized
}

pub fn setup(ctx: ?*c.Context) void {
    tls.init(); // eager: wss/PEM paths share tls.client() without fetch
    const rt = c.getRuntime(ctx);
    var sig_def = c.ClassDef{
        .class_name = "AbortSignal",
        .finalizer = abortSignalFinalizer,
    };
    _ = c.newClassID(rt, &abort_signal_class_id);
    _ = c.newClass(rt, abort_signal_class_id, &sig_def);

    const sig_proto = c.newObject(ctx);
    const throw_fn = c.newCFunction(ctx, signalThrowIfAborted, "throwIfAborted", 0);
    _ = c.definePropertyValueStr(ctx, sig_proto, "throwIfAborted", throw_fn, c.PROP_C_W_E);
    const add_fn = c.newCFunction(ctx, signalAddEventListener, "addEventListener", 2);
    _ = c.definePropertyValueStr(ctx, sig_proto, "addEventListener", add_fn, c.PROP_C_W_E);
    const rem_fn = c.newCFunction(ctx, signalRemoveEventListener, "removeEventListener", 2);
    _ = c.definePropertyValueStr(ctx, sig_proto, "removeEventListener", rem_fn, c.PROP_C_W_E);
    const onabort_atom = c.newAtomLen(ctx, "onabort", 7);
    const get_onabort = c.newCFunction(ctx, signalGetOnabort, "get onabort", 0);
    const set_onabort = c.newCFunction(ctx, signalSetOnabort, "set onabort", 1);
    _ = c.definePropertyGetSet(ctx, sig_proto, onabort_atom, get_onabort, set_onabort, c.PROP_CONFIGURABLE | c.PROP_ENUMERABLE);
    c.freeAtom(ctx, onabort_atom);
    c.setClassProto(ctx, abort_signal_class_id, sig_proto);

    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);

    const sig_ctor = c.newObject(ctx);
    const abort_static = c.newCFunction(ctx, signalStaticAbort, "abort", 1);
    _ = c.definePropertyValueStr(ctx, sig_ctor, "abort", abort_static, c.PROP_C_W_E);
    const timeout_static = c.newCFunction(ctx, signalStaticTimeout, "timeout", 1);
    _ = c.definePropertyValueStr(ctx, sig_ctor, "timeout", timeout_static, c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, global, "AbortSignal", sig_ctor, c.PROP_C_W_E);

    const ctrl_ctor = c.newCFunction2(ctx, abortControllerConstructor, "AbortController", 0, c.JS_CFUNC_constructor, 0);
    _ = c.definePropertyValueStr(ctx, global, "AbortController", ctrl_ctor, c.PROP_C_W_E);

    const fetch_func = c.newCFunction(ctx, &fetchCallback, "fetch", 2);
    _ = c.definePropertyValueStr(ctx, global, "fetch", fetch_func, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
}
