const std = @import("std");
const c = @import("../c.zig").c;
const request_mod = @import("../types/request.zig");
const headers_mod = @import("../types/headers.zig");
const async_fetch = @import("../net/async_fetch.zig");
const tls = @import("../net/tls.zig");
const gpa = std.heap.smp_allocator;
const http = std.http;

// ============================================================
// Helpers
// ============================================================
fn zigStringToJS(ctx: ?*c.Context, str: []const u8) c.Value {
    return c.newStringLen(ctx, str.ptr, @intCast(str.len));
}

fn extractStringFromVal(ctx: ?*c.Context, val: c.Value) ?[:0]const u8 {
    const cstr = c.toCString(ctx, val) orelse return null;
    const len = std.mem.len(cstr);
    if (len == 0) {
        c.freeCString(ctx, cstr);
        return gpa.dupeZ(u8, "") catch return null;
    }
    const buf = gpa.allocSentinel(u8, len, 0) catch {
        c.freeCString(ctx, cstr);
        return null;
    };
    @memcpy(buf[0..len], cstr[0..len]);
    buf[len] = 0;
    c.freeCString(ctx, cstr);
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

fn collectHeadersFromJS(ctx: ?*c.Context, val: c.Value, list: *std.ArrayList(http.Header)) void {
    if (c.isUndefined(val) != 0 or c.isNull(val) != 0) return;
    if (c.isObject(val) == 0) return;
    if (c.getOpaque2(ctx, val, headers_mod.headers_class_id)) |ptr| {
        const src: *headers_mod.HeadersData = @ptrCast(@alignCast(ptr));
        for (0..src.len()) |i| {
            const p = src.getPair(i);
            const n = gpa.dupe(u8, p.name) catch continue;
            const v = gpa.dupe(u8, p.value) catch {
                gpa.free(n);
                continue;
            };
            list.append(gpa, .{ .name = n, .value = v }) catch {
                gpa.free(n);
                gpa.free(v);
            };
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
            const name_z = extractStringFromVal(ctx, name_val) orelse continue;
            const val_z = extractStringFromVal(ctx, prop_val) orelse {
                gpa.free(name_z);
                continue;
            };
            list.append(gpa, .{ .name = name_z, .value = val_z }) catch {
                gpa.free(name_z);
                gpa.free(val_z);
            };
        }
    }
}

// ============================================================
// Main fetch callback
// ============================================================
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
    var extra_headers: ?std.ArrayList(http.Header) = null;
    var body_payload: ?[:0]const u8 = null;
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
    if (c.isString(arg0) != 0) {
        url_str = extractStringFromVal(ctx, arg0);
    } else if (c.isObject(arg0) != 0) {
        const req_data = extractRequestData(ctx, arg0);
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
            const url_val = c.getPropertyStr(ctx, arg0, "url");
            defer c.freeValue(ctx, url_val);
            url_str = extractStringFromVal(ctx, url_val);
        }
    } else {
        _ = c.throwTypeError(ctx, "fetch requires a URL string or Request as first argument");
        return c.JS_EXCEPTION;
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
        if (extra_headers == null) {
            extra_headers = .empty;
        }
        collectHeadersFromJS(ctx, headers_val, &extra_headers.?);
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
    const header_list: std.ArrayList(http.Header) = if (extra_headers) |*h| h.* else .empty;
    extra_headers = null;
    const body_copy = body_payload;
    body_payload = null;
    const url_copy = url;
    url_str = null;
    async_fetch.submit(ctx, cap[0], cap[1], url_copy, uri, method, header_list, body_copy) catch {
        var msg = zigStringToJS(ctx, "Failed to start fetch");
        _ = c.call(ctx, cap[1], c.JS_UNDEFINED, 1, &msg);
        return promise;
    };
    return promise;
}

// ============================================================
// Setup / teardown
// ============================================================
pub fn deinitClient() void {
    async_fetch.deinit();
    tls.deinit();
}

pub fn setup(ctx: ?*c.Context) void {
    tls.init();
    async_fetch.init();
    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);
    const fetch_func = c.newCFunction(ctx, &fetchCallback, "fetch", 2);
    _ = c.definePropertyValueStr(ctx, global, "fetch", fetch_func, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
}
