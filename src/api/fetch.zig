const std = @import("std");
const c = @import("../c.zig").c;
const request_mod = @import("../types/request.zig");
const headers_mod = @import("../types/headers.zig");
const async_fetch = @import("../net/async_fetch.zig");
const tls = @import("../net/tls.zig");
const gpa = std.heap.smp_allocator;
const http = std.http;

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

// DOD-FIX 2 (corrected): heap case returns the [:0]u8 directly.
fn extractStringFromVal(ctx: ?*c.Context, val: c.Value) ?[:0]const u8 {
    var stack_buf: [256]u8 = undefined;
    const ex = extractStringAuto(ctx, val, &stack_buf) orelse return null;
    if (ex.heap) |h| return h;
    const buf = gpa.allocSentinel(u8, ex.slice.len, 0) catch return null;
    @memcpy(buf[0..ex.slice.len], ex.slice);
    buf[ex.slice.len] = 0;
    return buf;
}

fn extractRequestData(ctx: ?*c.Context, obj: c.Value) ?*request_mod.RequestData {
    if (c.isObject(obj) == 0) return null;
    const ptr = c.getOpaque2(ctx, obj, request_mod.request_class_id) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

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

fn collectHeadersFromJS(
    ctx: ?*c.Context,
    val: c.Value,
    target: *headers_mod.HeadersData,
) void {
    if (c.isUndefined(val) != 0 or c.isNull(val) != 0) return;
    if (c.isObject(val) == 0) return;
    if (c.getOpaque2(ctx, val, headers_mod.headers_class_id)) |ptr| {
        const src: *headers_mod.HeadersData = @ptrCast(@alignCast(ptr));
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

fn fetchCallback(ctx: ?*c.Context, _: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    if (argc < 1) {
        _ = c.throwTypeError(ctx, "fetch requires a URL string or Request as first argument");
        return c.JS_EXCEPTION;
    }
    var cap: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &cap);
    const arg0 = argv[0];
    var url_str: ?[:0]const u8 = null;
    var method_override: ?[]const u8 = null;
    var owned_method: ?[:0]const u8 = null;
    var body_payload: ?[:0]const u8 = null;
    defer {
        if (url_str) |u| gpa.free(u);
        if (owned_method) |m| gpa.free(m);
        if (body_payload) |b| gpa.free(b);
    }
    if (c.isString(arg0) != 0) {
        url_str = extractStringFromVal(ctx, arg0);
    } else if (c.isObject(arg0) != 0) {
        if (extractRequestData(ctx, arg0)) |rd| {
            url_str = gpa.dupeZ(u8, rd.url()) catch null;
            method_override = rd.method();
            body_payload = if (rd.body()) |b| gpa.dupeZ(u8, b) catch null else null;
        } else {
            const url_val = c.getPropertyStr(ctx, arg0, "url");
            defer c.freeValue(ctx, url_val);
            url_str = extractStringFromVal(ctx, url_val);
        }
    } else {
        _ = c.throwTypeError(ctx, "fetch requires a URL string or Request as first argument");
        return c.JS_EXCEPTION;
    }

    // DOD-FIX 5: build a single dense HeadersData in-place.
    var in_flight_headers = headers_mod.HeadersData.init();
    errdefer in_flight_headers.deinit();

    // If arg0 is a Request, copy its headers into the in-flight pool.
    if (extractRequestData(ctx, arg0)) |rd| {
        for (0..rd.headers.len()) |i| {
            const pair = rd.headers.getPair(i);
            in_flight_headers.appendEntry(pair.name, pair.value);
        }
    }

    if (argc > 1 and c.isObject(argv[1]) != 0) {
        const init_val = argv[1];
        const method_val = c.getPropertyStr(ctx, init_val, "method");
        defer c.freeValue(ctx, method_val);
        if (extractStringFromVal(ctx, method_val)) |m| {
            method_override = m;
            owned_method = m;
        }
        const headers_val = c.getPropertyStr(ctx, init_val, "headers");
        defer c.freeValue(ctx, headers_val);
        collectHeadersFromJS(ctx, headers_val, &in_flight_headers);
        const body_val = c.getPropertyStr(ctx, init_val, "body");
        defer c.freeValue(ctx, body_val);
        if (c.isUndefined(body_val) == 0 and c.isNull(body_val) == 0) {
            body_payload = extractStringFromVal(ctx, body_val);
        }
    }

    const url = url_str orelse {
        var msg = zigStringToJS(ctx, "Invalid URL");
        _ = c.call(ctx, cap[1], c.JS_UNDEFINED, 1, &msg);
        return promise;
    };
    var method_str = method_override orelse "GET";
    if (body_payload != null and std.mem.eql(u8, method_str, "GET")) {
        method_str = "POST";
    }
    const method = parseMethod(method_str);
    const uri = std.Uri.parse(url) catch {
        var msg = zigStringToJS(ctx, "Invalid URL");
        _ = c.call(ctx, cap[1], c.JS_UNDEFINED, 1, &msg);
        return promise;
    };
    const url_copy = url;
    url_str = null;
    const body_copy = body_payload;
    body_payload = null;

    // Transfer ownership of in_flight_headers to async_fetch. Wrap in a
    // heap-allocated HeadersData so async_fetch can hold a stable pointer.
    // The wrapper is destroyed by runJob once its contents are moved into
    // the response's HeadersData.
    const hdr_ptr = gpa.create(headers_mod.HeadersData) catch {
        var msg = zigStringToJS(ctx, "Out of memory");
        _ = c.call(ctx, cap[1], c.JS_UNDEFINED, 1, &msg);
        return promise;
    };
    hdr_ptr.* = in_flight_headers;
    async_fetch.submit(ctx, cap[0], cap[1], url_copy, uri, method, hdr_ptr, body_copy) catch {
        hdr_ptr.release();
        var msg = zigStringToJS(ctx, "Failed to start fetch");
        _ = c.call(ctx, cap[1], c.JS_UNDEFINED, 1, &msg);
        return promise;
    };
    return promise;
}

pub fn deinitClient() void {
    async_fetch.deinit();
    tls.deinit();
}

pub fn setup(ctx: ?*c.Context) void {
    tls.init();
    async_fetch.init(ctx); // CHANGED: pass ctx so the pump can resolve promises
    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);
    const fetch_func = c.newCFunction(ctx, &fetchCallback, "fetch", 2);
    _ = c.definePropertyValueStr(ctx, global, "fetch", fetch_func, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
}
