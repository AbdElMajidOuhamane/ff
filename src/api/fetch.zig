const std = @import("std");
const c = @import("../c.zig").c;
const request_mod = @import("../types/request.zig");
const async_fetch = @import("../net/async_fetch.zig");
const tls = @import("../net/tls.zig");
const abort_api = @import("./abort.zig");
const TimerManager = @import("../event/timers.zig").TimerManager;

const gpa = std.heap.page_allocator;
const http = std.http;

// ============================================================
// Pre-aborted fetch: defer the rejection to a microtask so the caller's
// await handler attaches first (kills the unhandled-rejection report and
// mirrors the spec's queued task). Tiny DOD free-list of Global cells.
// ============================================================
const DEFER_MAX = 8;
var defer_globals: [DEFER_MAX]c.Global = undefined;
var defer_next: [DEFER_MAX]u8 = undefined;
var defer_head: u8 = DEFER_MAX; // DEFER_MAX doubles as the "empty" sentinel

fn deferInit() void {
    for (0..DEFER_MAX) |i| defer_next[i] = @intCast(i + 1);
    defer_next[DEFER_MAX - 1] = DEFER_MAX;
    defer_head = 0;
}

fn deferAcquire() ?u8 {
    const head = defer_head;
    if (head == DEFER_MAX) return null;
    defer_head = defer_next[head];
    return head;
}

fn deferPush(i: u8) void {
    defer_next[i] = defer_head;
    defer_head = i;
}

fn preAbortedRejectCb(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const ctx = c.v8__Isolate__GetCurrentContext(isolate) orelse return;
    const dv = c.v8__FunctionCallbackInfo__Data(info) orelse return;
    const gp: *c.Global = @ptrCast(@alignCast(c.v8__External__Value(@ptrCast(dv))));
    const idx = (@intFromPtr(gp) - @intFromPtr(&defer_globals[0])) / @sizeOf(c.Global);
    if (c.v8__Global__Get(gp, isolate)) |resolver| {
        var out: c.MaybeBool = undefined;
        c.v8__Promise__Resolver__Reject(@ptrCast(resolver), ctx, abortReasonValue(isolate, ctx), &out);
    }
    c.v8__Global__Reset(gp);
    deferPush(@intCast(idx));
}

// ============================================================
// Helpers
// ============================================================

fn throwTypeError(isolate: ?*c.Isolate, msg: []const u8) void {
    const v8_msg = c.v8__String__NewFromUtf8(isolate, @ptrCast(msg.ptr), 0, @intCast(msg.len));
    const exc = c.v8__Exception__TypeError(v8_msg);
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

// Packed 64-bit word compare: fold a comptime token (zero-padded on the
// right, little-endian) so a single unaligned wide load matches it.
fn methodToken(comptime s: []const u8) u64 {
    var buf = [_]u8{ 0 } ** 8;
    @memcpy(buf[0..s.len], s);
    return std.mem.readInt(u64, &buf, .little);
}

fn parseMethod(method_str: []const u8) http.Method {
    var buf = [_]u8{ 0 } ** 8;
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

fn collectHeadersFromJS(isolate: ?*c.Isolate, context: ?*c.Context, val: ?*const c.Value, list: *std.ArrayList(http.Header)) void {
    if (val == null) return;
    if (c.v8__Value__IsUndefined(val) or c.v8__Value__IsNull(val)) return;
    if (!c.v8__Value__IsObject(val)) return;

    const names_arr = c.v8__Object__GetPropertyNames(@ptrCast(val), context);
    if (names_arr == null) return;
    const names_len: usize = @intCast(c.v8__Array__Length(names_arr));
    var i: usize = 0;
    while (i < names_len) : (i += 1) {
        const idx = c.v8__Integer__NewFromUnsigned(isolate, @intCast(i));
        const name_val = c.v8__Object__Get(@ptrCast(names_arr), context, idx);
        if (name_val == null) continue;
        const name_z = extractStringFromVal(isolate, name_val) orelse continue;
        const prop_val = c.v8__Object__Get(@ptrCast(val), context, name_val);
        const val_z = extractStringFromVal(isolate, prop_val) orelse {
            gpa.free(name_z);
            continue;
        };
        list.append(gpa, .{ .name = name_z, .value = val_z }) catch {
            gpa.free(name_z);
            gpa.free(val_z);
        };
    }
}

fn extractRequestData(isolate: ?*c.Isolate, context: ?*c.Context, obj: ?*const c.Value) ?*request_mod.RequestData {
    if (obj == null) return null;
    if (!c.v8__Value__IsObject(obj)) return null;
    const data_key = c.v8__String__NewFromUtf8(isolate, "__d", 0, -1);
    const ext_val = c.v8__Object__Get(@ptrCast(obj), context, data_key);
    if (ext_val == null or !c.v8__Value__IsExternal(ext_val)) return null;
    const ptr = c.v8__External__Value(@ptrCast(ext_val));
    return @ptrCast(@alignCast(ptr));
}

fn abortReasonValue(isolate: ?*c.Isolate, context: ?*const c.Context) *const c.Value {
    const err = c.v8__Exception__Error(c.v8__String__NewFromUtf8(isolate, "This operation was aborted", 0, -1));
    var out: c.MaybeBool = undefined;
    _ = c.v8__Object__Set(
        @ptrCast(err),
        context,
        c.v8__String__NewFromUtf8(isolate, "name", 0, -1),
        c.v8__String__NewFromUtf8(isolate, "AbortError", 0, -1),
        &out,
    );
    return @ptrCast(err);
}

// ============================================================
// Main fetch callback — parse args on the v8 thread, spawn a worker,
// return the (pending) promise immediately.
// ============================================================

fn fetchCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);

    if (c.v8__FunctionCallbackInfo__Length(info) < 1) {
        throwTypeError(isolate, "fetch requires a URL string or Request as first argument");
        return;
    }

    const resolver = c.v8__Promise__Resolver__New(context);
    if (resolver == null) {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));
        return;
    }
    const promise = c.v8__Promise__Resolver__GetPromise(resolver);

    const arg0 = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    var url_str: ?[:0]const u8 = null;
    var method_override: ?[]const u8 = null;
    var owned_method: ?[:0]const u8 = null; // only when extractStringFromVal allocated it
    var extra_headers: ?std.ArrayList(http.Header) = null;
    var body_payload: ?[:0]const u8 = null;
    var signal_ptr: ?*anyopaque = null;
    var timeout_ms: ?u64 = null;

    defer {
        if (url_str) |u| gpa.free(u);
        if (owned_method) |m| gpa.free(m);
        if (body_payload) |b| gpa.free(b);
        if (extra_headers) |*h| {
            for (h.items) |hdr| {
                gpa.free(hdr.name);
                gpa.free(hdr.value);
            }
            h.deinit(gpa);
        }
    }

    if (c.v8__Value__IsString(arg0)) {
        url_str = extractStringFromVal(isolate, arg0);
    } else if (c.v8__Value__IsObject(arg0)) {
        const req_data = extractRequestData(isolate, context, arg0);
        if (req_data) |rd| {
            url_str = gpa.dupeZ(u8, rd.url()) catch null;
            method_override = rd.method();
            body_payload = if (rd.body()) |b| gpa.dupeZ(u8, b) catch null else null;
            extra_headers = .empty;
            for (0..rd.headers.len()) |i| {
                const pair = rd.headers.getPair(i);
                const n = gpa.dupe(u8, pair.name) catch continue;
                const v = gpa.dupe(u8, pair.value) catch {
                    gpa.free(n);
                    continue;
                };
                extra_headers.?.append(gpa, .{ .name = n, .value = v }) catch {
                    gpa.free(n);
                    gpa.free(v);
                };
            }
        } else {
            const url_val = c.v8__Object__Get(@ptrCast(arg0), context, c.v8__String__NewFromUtf8(isolate, "url", 0, -1));
            url_str = extractStringFromVal(isolate, url_val);
        }
    } else {
        throwTypeError(isolate, "fetch requires a URL string or Request as first argument");
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));
        return;
    }

    if (c.v8__FunctionCallbackInfo__Length(info) > 1) {
        const init_val = c.v8__FunctionCallbackInfo__INDEX(info, 1);
        if (c.v8__Value__IsObject(init_val)) {
            const method_val = c.v8__Object__Get(@ptrCast(init_val), context, c.v8__String__NewFromUtf8(isolate, "method", 0, -1));
            if (extractStringFromVal(isolate, method_val)) |m| {
                method_override = m;
                owned_method = m;
            }

            const headers_val = c.v8__Object__Get(@ptrCast(init_val), context, c.v8__String__NewFromUtf8(isolate, "headers", 0, -1));
            if (extra_headers == null) {
                extra_headers = .empty;
            }
            collectHeadersFromJS(isolate, context, headers_val, &extra_headers.?);

            const body_val = c.v8__Object__Get(@ptrCast(init_val), context, c.v8__String__NewFromUtf8(isolate, "body", 0, -1));
            if (body_val != null and !c.v8__Value__IsUndefined(body_val) and !c.v8__Value__IsNull(body_val)) {
                body_payload = extractStringFromVal(isolate, body_val);
            }

            const signal_val = c.v8__Object__Get(@ptrCast(init_val), context, c.v8__String__NewFromUtf8(isolate, "signal", 0, -1));
            if (signal_val != null and !c.v8__Value__IsUndefined(signal_val) and !c.v8__Value__IsNull(signal_val)) {
                signal_ptr = @ptrCast(abort_api.dataOf(isolate, context, signal_val) orelse null);
            }

            const timeout_val = c.v8__Object__Get(@ptrCast(init_val), context, c.v8__String__NewFromUtf8(isolate, "timeout", 0, -1));
            if (timeout_val != null and !c.v8__Value__IsUndefined(timeout_val) and !c.v8__Value__IsNull(timeout_val)) {
                var maybe: c.MaybeF64 = undefined;
                c.v8__Value__NumberValue(timeout_val, context, &maybe);
                if (maybe.has_value and maybe.value > 0) timeout_ms = @intFromFloat(maybe.value);
            }
        }
    }

    const url = url_str orelse {
        var out: c.MaybeBool = undefined;
        _ = c.v8__Promise__Resolver__Reject(resolver, context, @ptrCast(zigStringToV8(isolate, "Invalid URL")), &out);
        c.v8__ReturnValue__Set(ret, @ptrCast(promise));
        return;
    };

    var method_str = method_override orelse "GET";
    if (body_payload != null and std.mem.eql(u8, method_str, "GET")) {
        method_str = "POST";
    }
    const method = parseMethod(method_str);

    const uri = std.Uri.parse(url) catch {
        var out: c.MaybeBool = undefined;
        _ = c.v8__Promise__Resolver__Reject(resolver, context, @ptrCast(zigStringToV8(isolate, "Invalid URL")), &out);
        c.v8__ReturnValue__Set(ret, @ptrCast(promise));
        return;
    };

    // Signal already aborted → defer the rejection to a microtask (never
    // send the request). The caller's await handler attaches before V8
    // reports "no handler", so no spurious unhandled-rejection warning.
    if (signal_ptr != null and abort_api.isAborted(signal_ptr)) {
        if (deferAcquire()) |cell| {
            c.v8__Global__New(isolate, @ptrCast(resolver), &defer_globals[cell]);
            const fn_val = c.v8__Function__New__DEFAULT2(
                context,
                preAbortedRejectCb,
                @ptrCast(c.v8__External__New(isolate, @ptrCast(&defer_globals[cell]))),
            ) orelse {
                c.v8__Global__Reset(&defer_globals[cell]);
                deferPush(cell);
                var out: c.MaybeBool = undefined;
                _ = c.v8__Promise__Resolver__Reject(resolver, context, abortReasonValue(isolate, context), &out);
                c.v8__ReturnValue__Set(ret, @ptrCast(promise));
                return;
            };
            c.v8__Isolate__EnqueueMicrotaskFunc(isolate, @ptrCast(fn_val));
        } else {
            var out: c.MaybeBool = undefined;
            _ = c.v8__Promise__Resolver__Reject(resolver, context, abortReasonValue(isolate, context), &out);
        }
        c.v8__ReturnValue__Set(ret, @ptrCast(promise));
        return;
    }

    // Ownership moves into the pool on success, freed by submit on failure.
    // Null first so the defer-frees below never double-free.
    const header_list: std.ArrayList(http.Header) = if (extra_headers) |*h| h.* else .empty;
    extra_headers = null;
    const body_copy = body_payload;
    body_payload = null;
    const url_copy = url;
    url_str = null;

    const slot = async_fetch.submit(
        isolate,
        @ptrCast(resolver),
        url_copy,
        uri,
        method,
        header_list,
        body_copy,
        signal_ptr,
    ) catch {
        var out: c.MaybeBool = undefined;
        _ = c.v8__Promise__Resolver__Reject(resolver, context, @ptrCast(zigStringToV8(isolate, "Failed to start fetch")), &out);
        c.v8__ReturnValue__Set(ret, @ptrCast(promise));
        return;
    };

    if (timeout_ms) |tw| {
        async_fetch.armTimeout(isolate, context, slot, tw);
    }

    c.v8__ReturnValue__Set(ret, @ptrCast(promise));
}

// ============================================================
// Setup / teardown
// ============================================================

pub fn deinitClient() void {
    async_fetch.deinit();
    tls.deinit();
}

pub fn setTimerManager(tm: *TimerManager) void {
    async_fetch.setTimerManager(tm);
}

pub fn setup(isolate: ?*c.Isolate, context: ?*c.Context) void {
    tls.init();
    async_fetch.init();
    deferInit();

    var hs: c.HandleScope = undefined;
    c.v8__HandleScope__CONSTRUCT(&hs, isolate);
    defer c.v8__HandleScope__DESTRUCT(&hs);

    const global = c.v8__Context__Global(context);
    var out: c.MaybeBool = undefined;

    const fetch_func = c.v8__Function__New__DEFAULT(context, fetchCallback);
    const key = c.v8__String__NewFromUtf8(isolate, "fetch", 0, -1);
    _ = c.v8__Object__Set(global, context, key, fetch_func, &out);
}
