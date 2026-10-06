const std = @import("std");
const c = @import("../c.zig").c;
const request_mod = @import("../types/request.zig");
const headers_mod = @import("../types/headers.zig");
const async_fetch = @import("../net/async_fetch.zig");
const tls = @import("../net/tls.zig");
const gpa = std.heap.smp_allocator;
const http = std.http;

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

    if (argc > 1 and c.isObject(argv[1]) != 0) {
        const init_val = argv[1];
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

    // FIX-4: materialize the borrow before use (GET→POST check and submit
    // handoff below both read body_borrowed). // ◀ FIX-4
    if (body_ex) |ex| body_borrowed = ex.slice; // ◀ FIX-4

    const url_slice = url orelse {
        // BUG-5: the old `errdefer in_flight_headers.deinit()` never fired
        // (this function has no error returns) → the reserved name/value
        // pools leaked on every early return. Explicit cleanup instead.
        in_flight_headers.deinit();
        var msg = zigStringToJS(ctx, "Invalid URL");
        _ = c.call(ctx, cap[1], c.JS_UNDEFINED, 1, &msg);
        c.freeValue(ctx, msg);
        return promise;
    };
    var method_str = method_override orelse "GET";
    if (body_borrowed != null and std.mem.eql(u8, method_str, "GET")) { // ◀ FIX-4 (was: body_payload)
        method_str = "POST";
    }
    const method = parseMethod(method_str);
    const uri = std.Uri.parse(url_slice) catch {
        in_flight_headers.deinit();
        var msg = zigStringToJS(ctx, "Invalid URL");
        _ = c.call(ctx, cap[1], c.JS_UNDEFINED, 1, &msg);
        c.freeValue(ctx, msg);
        return promise;
    };

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
    async_fetch.submit(ctx, cap[0], cap[1], url_slice, uri, method, hdr_ptr, body_borrowed) catch {
        // BUG-6 FIX (double-release UAF): submit() takes ownership the moment
        // it is called and has ALREADY released headers on BOTH of its
        // failure paths — pool-full and shutdown. (URL and body are borrowed,
        // nothing to release.) Do not touch hdr_ptr again here. // ◀ FIX-4
        var msg = zigStringToJS(ctx, "Failed to start fetch");
        _ = c.call(ctx, cap[1], c.JS_UNDEFINED, 1, &msg);
        c.freeValue(ctx, msg);
        return promise;
    };
    return promise;
}

pub fn deinitClient() void {
    if (fetch_inited) async_fetch.deinit();
    tls.deinit(); // self-guards when never initialized
}

pub fn setup(ctx: ?*c.Context) void {
    tls.init(); // eager: wss/PEM paths share tls.client() without fetch
    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);
    const fetch_func = c.newCFunction(ctx, &fetchCallback, "fetch", 2);
    _ = c.definePropertyValueStr(ctx, global, "fetch", fetch_func, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
}
