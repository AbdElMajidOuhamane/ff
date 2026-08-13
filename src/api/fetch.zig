const std = @import("std");
const c = @import("../c.zig").c;
const request_mod = @import("../types/request.zig");
const response_mod = @import("../types/response.zig");
const tls = @import("../net/tls.zig");

const gpa = std.heap.page_allocator;
const http = std.http;

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

// ============================================================
// Main fetch callback
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
    var extra_headers: ?std.ArrayList(http.Header) = null;
    var body_payload: ?[:0]const u8 = null;

    defer {
        if (url_str) |u| gpa.free(u);
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

    var req = tls.client().request(method, uri, .{
        .extra_headers = if (extra_headers) |*h| h.items else &.{},
    }) catch {
        var out: c.MaybeBool = undefined;
        _ = c.v8__Promise__Resolver__Reject(resolver, context, @ptrCast(zigStringToV8(isolate, "Network error")), &out);
        c.v8__ReturnValue__Set(ret, @ptrCast(promise));
        return;
    };
    defer req.deinit();

    // Register the connection in the transport pool (records fd + TLS flag)
    // and apply TCP_NODELAY before any byte is written — the TLS handshake
    // runs lazily on the first read/write, so NODELAY covers the
    // ClientHello -> Finished -> request sequence. Without it, each small
    // second write stalls on a delayed-ACK round trip (~90ms per fresh conn).
    var slot: ?usize = null;
    if (req.connection) |cn| slot = tls.attach(cn);
    defer if (slot) |s| tls.detach(s);

    if (body_payload) |payload| {
        req.transfer_encoding = .{ .content_length = payload.len };
        var body_writer = req.sendBodyUnflushed(&.{}) catch {
            var out: c.MaybeBool = undefined;
            _ = c.v8__Promise__Resolver__Reject(resolver, context, @ptrCast(zigStringToV8(isolate, "Failed to send request body")), &out);
            c.v8__ReturnValue__Set(ret, @ptrCast(promise));
            return;
        };
        body_writer.writer.writeAll(payload) catch {
            var out: c.MaybeBool = undefined;
            _ = c.v8__Promise__Resolver__Reject(resolver, context, @ptrCast(zigStringToV8(isolate, "Failed to write request body")), &out);
            c.v8__ReturnValue__Set(ret, @ptrCast(promise));
            return;
        };
        body_writer.end() catch {};
        req.connection.?.flush() catch {};
    } else {
        req.sendBodiless() catch {
            var out: c.MaybeBool = undefined;
            _ = c.v8__Promise__Resolver__Reject(resolver, context, @ptrCast(zigStringToV8(isolate, "Failed to send request")), &out);
            c.v8__ReturnValue__Set(ret, @ptrCast(promise));
            return;
        };
    }

    var redirect_buf: [8000]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch {
        var out: c.MaybeBool = undefined;
        _ = c.v8__Promise__Resolver__Reject(resolver, context, @ptrCast(zigStringToV8(isolate, "Failed to receive response")), &out);
        c.v8__ReturnValue__Set(ret, @ptrCast(promise));
        return;
    };

    var owned_body: ?[]u8 = null;
    defer if (owned_body) |b| gpa.free(b);

    const status_code = @intFromEnum(response.head.status);
    const status_class = status_code / 100;
    const has_body = switch (status_class) {
        1 => false,
        2 => response.head.status != .no_content and response.head.status != .not_modified,
        3 => false,
        else => true,
    };

    if (!has_body) {
        req.connection.?.closing = true;
    }

    if (has_body) {
        var transfer_buf: [8192]u8 = undefined;
        const content_encoding = response.head.content_encoding;
        const compressed = content_encoding != .identity;
        var decompress_buf: ?[]u8 = null;
        defer if (decompress_buf) |d| gpa.free(d);
        var decompress: std.http.Decompress = undefined;

        const reader = if (!compressed)
            response.reader(&transfer_buf)
        else dec: {
            const window_len: usize = switch (content_encoding) {
                .gzip, .deflate => std.compress.flate.max_window_len,
                .zstd => std.compress.zstd.default_window_len,
                else => 0,
            };
            if (window_len == 0) {
                std.debug.print("[fetch] unsupported content-encoding: {s}\n", .{@tagName(content_encoding)});
                break :dec response.reader(&transfer_buf);
            }
            const d = gpa.alloc(u8, window_len) catch break :dec response.reader(&transfer_buf);
            decompress_buf = d;
            break :dec response.readerDecompressing(&transfer_buf, &decompress, d);
        };

        // Content-Length describes the *wire* (compressed) bytes, so the
        // exact-size prealloc path only applies to identity payloads.
        const wire_cl = if (content_encoding == .identity) response.head.content_length else null;

        if (wire_cl) |cl| {
            if (cl > 0) {
                const len: usize = @intCast(cl);
                const buf = gpa.alloc(u8, len) catch |err| alloc_b: {
                    std.debug.print("[fetch] body alloc error: {s}\n", .{@errorName(err)});
                    break :alloc_b null;
                };
                if (buf) |b| {
                    const n = reader.readSliceShort(b) catch |err| read_b: {
                        std.debug.print("[fetch] body read error: {s}\n", .{@errorName(err)});
                        break :read_b 0;
                    };
                    if (n == 0) {
                        gpa.free(b);
                    } else if (n == len) {
                        owned_body = b;
                    } else {
                        owned_body = gpa.dupe(u8, b[0..n]) catch b[0..n];
                        if (owned_body.?.len == n) gpa.free(b);
                    }
                }
            }
        } else {
            var acc: std.ArrayList(u8) = .empty;
            defer acc.deinit(gpa);
            var chunk: [16 * 1024]u8 = undefined;
            var total: usize = 0;
            while (true) {
                const n = reader.readSliceShort(chunk[0..]) catch |err| acc_b: {
                    std.debug.print("[fetch] body read error: {s} after {d} bytes\n", .{ @errorName(err), total });
                    break :acc_b 0;
                };
                if (n == 0) break;
                acc.appendSlice(gpa, chunk[0..n]) catch |err| {
                    std.debug.print("[fetch] body accumulate error: {s}\n", .{@errorName(err)});
                    break;
                };
                total += n;
            }
            if (total > 0) {
                owned_body = acc.toOwnedSlice(gpa) catch |err| fin_b: {
                    std.debug.print("[fetch] body finalize error: {s}\n", .{@errorName(err)});
                    break :fin_b null;
                };
            }
        }

        if (compressed) {
            // readerDecompressing stops at the gzip EOF; for te=chunked the
            // final chunk terminator is left unread. Draining the framing
            // reader to its deterministic end-of-message (no extra RTT) keeps
            // the connection reusable.
            var plain_reader = response.reader(&transfer_buf);
            var drain: [2048]u8 = undefined;
            while (true) {
                const n = plain_reader.readSliceShort(drain[0..]) catch break;
                if (n == 0) break;
            }
        }
    }

    const resp_data = gpa.create(response_mod.ResponseData) catch {
        var out: c.MaybeBool = undefined;
        _ = c.v8__Promise__Resolver__Reject(resolver, context, @ptrCast(zigStringToV8(isolate, "Out of memory")), &out);
        c.v8__ReturnValue__Set(ret, @ptrCast(promise));
        return;
    };
    resp_data.* = response_mod.ResponseData.init();

    resp_data.status = status_code;
    resp_data.setStatusText(response.head.status.phrase() orelse "OK");

    var header_it = response.head.iterateHeaders();
    while (header_it.next()) |h| {
        resp_data.headers.appendEntry(h.name, h.value);
    }

    if (owned_body) |b| {
        resp_data.setBodyOwned(b);
        owned_body = null;
    } else if (response.head.content_length != null and has_body) {
        resp_data.setBody("");
    }

    const resp_obj = response_mod.buildResponseJSObject(isolate, context, resp_data);
    if (resp_obj) |obj| {
        var out: c.MaybeBool = undefined;
        _ = c.v8__Promise__Resolver__Resolve(resolver, context, @ptrCast(obj), &out);
    }

    c.v8__ReturnValue__Set(ret, @ptrCast(promise));
}

// ============================================================
// Setup
// ============================================================

pub fn deinitClient() void {
    tls.deinit();
}

pub fn setup(isolate: ?*c.Isolate, context: ?*c.Context) void {
    tls.init();

    var hs: c.HandleScope = undefined;
    c.v8__HandleScope__CONSTRUCT(&hs, isolate);
    defer c.v8__HandleScope__DESTRUCT(&hs);

    const global = c.v8__Context__Global(context);
    var out: c.MaybeBool = undefined;

    const fetch_func = c.v8__Function__New__DEFAULT(context, fetchCallback);
    const key = c.v8__String__NewFromUtf8(isolate, "fetch", 0, -1);
    _ = c.v8__Object__Set(global, context, key, fetch_func, &out);
}
