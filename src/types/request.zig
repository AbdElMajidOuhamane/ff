const std = @import("std");
const c = @import("../c.zig").c;
const headers_mod = @import("headers.zig");
const pool_slice_mod = @import("pool_slice.zig");
const blob_mod = @import("blob.zig");
const formdata_mod = @import("formdata.zig");
const gpa = std.heap.smp_allocator;

pub var request_class_id: c.ClassID = 0;

// ── DOD note ──
// Cold JS-bridge object, NOT hot I/O path (http_native uses ParsedRequest).
// Layout fix per skill §3: largest→smallest, trailing grouped bools so the
// struct stride carries no padding holes. `cold` box keeps `.other` strings
// out of the hot inline path. AoS per-Request is correct — GC lifetime.

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

fn extractRequestData(ctx: ?*c.Context, this_val: c.Value) ?*RequestData {
    const ptr = c.getOpaque2(ctx, this_val, request_class_id) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

pub const Method = enum(u8) {
    GET, POST, PUT, DELETE, HEAD, OPTIONS, PATCH, other,
    pub fn fromSlice(s: []const u8) Method {
        if (std.mem.eql(u8, s, "GET")) return .GET;
        if (std.mem.eql(u8, s, "POST")) return .POST;
        if (std.mem.eql(u8, s, "PUT")) return .PUT;
        if (std.mem.eql(u8, s, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, s, "HEAD")) return .HEAD;
        if (std.mem.eql(u8, s, "OPTIONS")) return .OPTIONS;
        if (std.mem.eql(u8, s, "PATCH")) return .PATCH;
        return .other;
    }
    pub fn string(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET", .POST => "POST", .PUT => "PUT", .DELETE => "DELETE",
            .HEAD => "HEAD", .OPTIONS => "OPTIONS", .PATCH => "PATCH",
            .other => unreachable,
        };
    }
};
pub const CacheMode = enum(u8) {
    default, no_store, reload, no_cache, force_cache, only_if_cached, other,
    pub fn fromSlice(s: []const u8) CacheMode {
        if (std.mem.eql(u8, s, "default")) return .default;
        if (std.mem.eql(u8, s, "no-store")) return .no_store;
        if (std.mem.eql(u8, s, "reload")) return .reload;
        if (std.mem.eql(u8, s, "no-cache")) return .no_cache;
        if (std.mem.eql(u8, s, "force-cache")) return .force_cache;
        if (std.mem.eql(u8, s, "only-if-cached")) return .only_if_cached;
        return .other;
    }
    pub fn string(self: CacheMode) []const u8 {
        return switch (self) {
            .default => "default", .no_store => "no-store", .reload => "reload",
            .no_cache => "no-cache", .force_cache => "force-cache",
            .only_if_cached => "only-if-cached", .other => unreachable,
        };
    }
};
pub const CredMode = enum(u8) {
    same_origin, include, omit, other,
    pub fn fromSlice(s: []const u8) CredMode {
        if (std.mem.eql(u8, s, "same-origin")) return .same_origin;
        if (std.mem.eql(u8, s, "include")) return .include;
        if (std.mem.eql(u8, s, "omit")) return .omit;
        return .other;
    }
    pub fn string(self: CredMode) []const u8 {
        return switch (self) {
            .same_origin => "same-origin", .include => "include",
            .omit => "omit", .other => unreachable,
        };
    }
};
pub const Mode = enum(u8) {
    navigate, same_origin, no_cors, cors, other,
    pub fn fromSlice(s: []const u8) Mode {
        if (std.mem.eql(u8, s, "navigate")) return .navigate;
        if (std.mem.eql(u8, s, "same-origin")) return .same_origin;
        if (std.mem.eql(u8, s, "no-cors")) return .no_cors;
        if (std.mem.eql(u8, s, "cors")) return .cors;
        return .other;
    }
    pub fn string(self: Mode) []const u8 {
        return switch (self) {
            .navigate => "navigate", .same_origin => "same-origin",
            .no_cors => "no-cors", .cors => "cors", .other => unreachable,
        };
    }
};
pub const RedirectMode = enum(u8) {
    follow, err, manual, other,
    pub fn fromSlice(s: []const u8) RedirectMode {
        if (std.mem.eql(u8, s, "follow")) return .follow;
        if (std.mem.eql(u8, s, "error")) return .err;
        if (std.mem.eql(u8, s, "manual")) return .manual;
        return .other;
    }
    pub fn string(self: RedirectMode) []const u8 {
        return switch (self) {
            .follow => "follow", .err => "error",
            .manual => "manual", .other => unreachable,
        };
    }
};

const PoolSlice = pool_slice_mod.PoolSlice;

pub const RequestDataCold = struct {
    _method_other: PoolSlice,
    _cache_other: PoolSlice,
    _credentials_other: PoolSlice,
    _mode_other: PoolSlice,
    _redirect_other: PoolSlice,
};

// DOD-FIX §3: largest→smallest, bools grouped trailing. Same field names
// so callers (fetch.zig, http layer) keep compiling.
pub const RequestData = struct {
    pool: std.ArrayList(u8),
    headers: *headers_mod.HeadersData,
    cold: ?*RequestDataCold,
    _url: PoolSlice,
    _body: PoolSlice,
    _integrity: PoolSlice,
    _method: Method,
    _cache: CacheMode,
    _credentials: CredMode,
    _mode: Mode,
    _redirect: RedirectMode,
    has_body: bool,
    body_used: bool,
    keepalive: bool,

    comptime {
        std.debug.assert(@sizeOf(PoolSlice) == 8);
        std.debug.assert(@alignOf(RequestData) >= 8);
    }

    pub fn init() RequestData {
        // Gap-5 fix: headers live in a heap refcounted HeadersData like
        // ResponseData (see response.zig), so createEmbeddedHeaders' retain
        // and deinit's release always pair on a real heap object.
        const h = gpa.create(headers_mod.HeadersData) catch @panic("OOM HeadersData");
        h.* = headers_mod.HeadersData.init();
        return .{
            .pool = std.ArrayList(u8).empty,
            .headers = h,
            .cold = null,
            ._url = .{}, ._body = .{}, ._integrity = .{},
            ._method = .GET, ._cache = .default, ._credentials = .same_origin,
            ._mode = .cors, ._redirect = .follow,
            .has_body = false, .body_used = false, .keepalive = false,
        };
    }
    pub fn deinit(self: *RequestData) void {
        self.pool.deinit(gpa);
        if (self.cold) |cd| gpa.destroy(cd);
        self.headers.release();
    }
    pub fn url(self: *const RequestData) []const u8 {
        return self.pool.items[self._url.off .. self._url.off + self._url.len];
    }
    pub fn body(self: *const RequestData) ?[]const u8 {
        if (!self.has_body) return null;
        return self.pool.items[self._body.off .. self._body.off + self._body.len];
    }
    pub fn integrity(self: *const RequestData) []const u8 {
        return self.pool.items[self._integrity.off .. self._integrity.off + self._integrity.len];
    }
    pub fn method(self: *const RequestData) []const u8 {
        if (self._method == .other) {
            const cd = self.cold orelse return "";
            return self.pool.items[cd._method_other.off .. cd._method_other.off + cd._method_other.len];
        }
        return self._method.string();
    }
    pub fn cache(self: *const RequestData) []const u8 {
        if (self._cache == .other) {
            const cd = self.cold orelse return "";
            return self.pool.items[cd._cache_other.off .. cd._cache_other.off + cd._cache_other.len];
        }
        return self._cache.string();
    }
    pub fn credentials(self: *const RequestData) []const u8 {
        if (self._credentials == .other) {
            const cd = self.cold orelse return "";
            return self.pool.items[cd._credentials_other.off .. cd._credentials_other.off + cd._credentials_other.len];
        }
        return self._credentials.string();
    }
    pub fn mode(self: *const RequestData) []const u8 {
        if (self._mode == .other) {
            const cd = self.cold orelse return "";
            return self.pool.items[cd._mode_other.off .. cd._mode_other.off + cd._mode_other.len];
        }
        return self._mode.string();
    }
    pub fn redirect(self: *const RequestData) []const u8 {
        if (self._redirect == .other) {
            const cd = self.cold orelse return "";
            return self.pool.items[cd._redirect_other.off .. cd._redirect_other.off + cd._redirect_other.len];
        }
        return self._redirect.string();
    }
    fn store(self: *RequestData, owned: []const u8, dst: *PoolSlice) void {
        if (owned.len == 0) return;
        const off = self.pool.items.len;
        self.pool.appendSlice(gpa, owned) catch return;
        dst.* = .{ .off = @intCast(off), .len = @intCast(owned.len) };
    }
    fn ensureCold(self: *RequestData) ?*RequestDataCold {
        if (self.cold) |cd| return cd;
        const cd = gpa.create(RequestDataCold) catch return null;
        cd.* = .{
            ._method_other = .{},
            ._cache_other = .{},
            ._credentials_other = .{},
            ._mode_other = .{},
            ._redirect_other = .{},
        };
        self.cold = cd;
        return cd;
    }
    pub fn setUrl(self: *RequestData, owned: []const u8) void {
        defer gpa.free(owned);
        self.store(owned, &self._url);
    }
    pub fn setBody(self: *RequestData, owned: []const u8) void {
        defer gpa.free(owned);
        self.has_body = owned.len > 0;
        self.store(owned, &self._body);
    }
    pub fn setIntegrity(self: *RequestData, owned: []const u8) void {
        defer gpa.free(owned);
        self.store(owned, &self._integrity);
    }
    pub fn setMethod(self: *RequestData, owned: []const u8) void {
        defer gpa.free(owned);
        const m = Method.fromSlice(owned);
        self._method = m;
        if (m == .other) {
            if (self.ensureCold()) |cd| self.store(owned, &cd._method_other);
        }
    }
    pub fn setCache(self: *RequestData, owned: []const u8) void {
        defer gpa.free(owned);
        const v = CacheMode.fromSlice(owned);
        self._cache = v;
        if (v == .other) {
            if (self.ensureCold()) |cd| self.store(owned, &cd._cache_other);
        }
    }
    pub fn setCredentials(self: *RequestData, owned: []const u8) void {
        defer gpa.free(owned);
        const v = CredMode.fromSlice(owned);
        self._credentials = v;
        if (v == .other) {
            if (self.ensureCold()) |cd| self.store(owned, &cd._credentials_other);
        }
    }
    pub fn setMode(self: *RequestData, owned: []const u8) void {
        defer gpa.free(owned);
        const v = Mode.fromSlice(owned);
        self._mode = v;
        if (v == .other) {
            if (self.ensureCold()) |cd| self.store(owned, &cd._mode_other);
        }
    }
    pub fn setRedirect(self: *RequestData, owned: []const u8) void {
        defer gpa.free(owned);
        const v = RedirectMode.fromSlice(owned);
        self._redirect = v;
        if (v == .other) {
            if (self.ensureCold()) |cd| self.store(owned, &cd._redirect_other);
        }
    }
    pub fn cloneFrom(self: *RequestData, src: *const RequestData) void {
        self.pool.ensureTotalCapacity(gpa, self.pool.items.len + src.pool.items.len) catch {};
        self.pool.appendSlice(gpa, src.pool.items) catch {};
        self._url = src._url;
        self._body = src._body;
        self._integrity = src._integrity;
        self._method = src._method;
        self._cache = src._cache;
        self._credentials = src._credentials;
        self._mode = src._mode;
        self._redirect = src._redirect;
        self.has_body = src.has_body;
        self.body_used = false;
        self.keepalive = src.keepalive;
        if (src.cold) |sc| {
            if (self.ensureCold()) |dc| {
                dc._method_other = sc._method_other;
                dc._cache_other = sc._cache_other;
                dc._credentials_other = sc._credentials_other;
                dc._mode_other = sc._mode_other;
                dc._redirect_other = sc._redirect_other;
            }
        }
        self.headers.reserve(src.headers.len(), src.headers.names.items.len, src.headers.values.items.len);
        for (0..src.headers.len()) |i| {
            const p = src.headers.getPair(i);
            self.headers.appendEntry(p.name, p.value);
        }
    }
};

fn parseHeadersInit(ctx: ?*c.Context, init_val: c.Value, target: *headers_mod.HeadersData) void {
    if (c.isUndefined(init_val) != 0 or c.isNull(init_val) != 0) return;
    if (c.isObject(init_val) == 0) return;
    if (c.getOpaque2(ctx, init_val, headers_mod.headers_class_id)) |ptr| {
        const src: *headers_mod.HeadersData = @ptrCast(@alignCast(ptr));
        target.reserve(src.len(), src.names.items.len, src.values.items.len);
        for (0..src.len()) |i| {
            const p = src.getPair(i);
            target.appendEntry(p.name, p.value);
        }
        return;
    }
    if (c.isArray(ctx, init_val) != 0) {
        const len_val = c.getPropertyStr(ctx, init_val, "length");
        defer c.freeValue(ctx, len_val);
        var len: c_int = 0;
        _ = c.toInt32(ctx, &len, len_val);
        if (len > 0) target.reserveEntries(@intCast(len));
        var i: c_uint = 0;
        while (i < @as(c_uint, @intCast(len))) : (i += 1) {
            const item = c.getPropertyUint32(ctx, init_val, i);
            defer c.freeValue(ctx, item);
            if (c.isObject(item) == 0) continue;
            const name_val = c.getPropertyUint32(ctx, item, 0);
            defer c.freeValue(ctx, name_val);
            const val_val = c.getPropertyUint32(ctx, item, 1);
            defer c.freeValue(ctx, val_val);
            var nbuf: [128]u8 = undefined;
            var vbuf: [256]u8 = undefined;
            const n = extractStringAuto(ctx, name_val, &nbuf);
            const v = extractStringAuto(ctx, val_val, &vbuf);
            if (n) |nn| {
                defer nn.deinit();
                if (v) |vv| {
                    defer vv.deinit();
                    target.appendEntry(nn.slice, vv.slice);
                }
            }
        }
        return;
    }
    var p: [*c]c.PropertyEnum = null;
    var count: c_uint = 0;
    if (c.getOwnPropertyNames(ctx, &p, &count, init_val, c.GPN_STRING_MASK | c.GPN_ENUM_ONLY) == 0) {
        defer c.freePropertyEnum(ctx, p, count);
        target.reserveEntries(count);
        for (0..count) |idx| {
            const name_atom = p[idx].atom;
            const name_val = c.atomToString(ctx, name_atom);
            defer c.freeValue(ctx, name_val);
            const val_val = c.getProperty(ctx, init_val, name_atom);
            defer c.freeValue(ctx, val_val);
            var nbuf: [128]u8 = undefined;
            var vbuf: [256]u8 = undefined;
            const n = extractStringAuto(ctx, name_val, &nbuf);
            const v = extractStringAuto(ctx, val_val, &vbuf);
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

fn parseHeadersInitFromObj(ctx: ?*c.Context, init_obj: c.Value, target: *headers_mod.HeadersData) void {
    const headers_val = c.getPropertyStr(ctx, init_obj, "headers");
    defer c.freeValue(ctx, headers_val);
    if (c.isUndefined(headers_val) == 0 and c.isNull(headers_val) == 0) {
        parseHeadersInit(ctx, headers_val, target);
    }
}

fn createEmbeddedHeaders(ctx: ?*c.Context, src: *headers_mod.HeadersData) c.Value {
    src.retain();
    return headers_mod.createJSObject(ctx, src);
}

fn setRequestProps(ctx: ?*c.Context, obj: c.Value, data: *RequestData) void {
    _ = c.definePropertyValueStr(ctx, obj, "url", zigStringToJS(ctx, data.url()), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "method", zigStringToJS(ctx, data.method()), c.PROP_C_W_E);
    const hdr_obj = createEmbeddedHeaders(ctx, data.headers);
    _ = c.definePropertyValueStr(ctx, obj, "headers", hdr_obj, c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "bodyUsed", if (data.body_used) c.JS_TRUE else c.JS_FALSE, c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "cache", zigStringToJS(ctx, data.cache()), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "credentials", zigStringToJS(ctx, data.credentials()), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "mode", zigStringToJS(ctx, data.mode()), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "redirect", zigStringToJS(ctx, data.redirect()), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "integrity", zigStringToJS(ctx, data.integrity()), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "keepalive", if (data.keepalive) c.JS_TRUE else c.JS_FALSE, c.PROP_C_W_E);
}

fn requestText(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc; _ = argv;
    const data = extractRequestData(ctx, this_val) orelse return c.JS_EXCEPTION;
    data.body_used = true;
    const body_text = data.body() orelse "";
    var cap: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &cap);
    var result = zigStringToJS(ctx, body_text);
    _ = c.call(ctx, cap[0], c.JS_UNDEFINED, 1, &result);
    return promise;
}

fn requestJson(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc; _ = argv;
    const data = extractRequestData(ctx, this_val) orelse return c.JS_EXCEPTION;
    data.body_used = true;
    const body_text = data.body() orelse "";
    var cap: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &cap);
    if (body_text.len == 0) {
        var msg = zigStringToJS(ctx, "Unexpected end of JSON input");
        _ = c.call(ctx, cap[1], c.JS_UNDEFINED, 1, &msg);
        return promise;
    }
    var parsed = c.parseJSON(ctx, body_text.ptr, body_text.len, "");
    if (c.isException(parsed) != 0) {
        var exc = c.getException(ctx);
        defer c.freeValue(ctx, exc);
        _ = c.call(ctx, cap[1], c.JS_UNDEFINED, 1, &exc);
    } else {
        _ = c.call(ctx, cap[0], c.JS_UNDEFINED, 1, &parsed);
    }
    return promise;
}

fn requestArrayBuffer(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc; _ = argv;
    const data = extractRequestData(ctx, this_val) orelse return c.JS_EXCEPTION;
    data.body_used = true;
    const body_bytes = data.body() orelse "";
    var cap: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &cap);
    var ab = c.newArrayBufferCopy(ctx, body_bytes.ptr, body_bytes.len);
    _ = c.call(ctx, cap[0], c.JS_UNDEFINED, 1, &ab);
    return promise;
}

fn requestBlob(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc; _ = argv;
    const data = extractRequestData(ctx, this_val) orelse return c.JS_EXCEPTION;
    data.body_used = true;
    const body_bytes = data.body() orelse "";
    var cap: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &cap);
    const blob = gpa.create(blob_mod.BlobData) catch {
        var msg = zigStringToJS(ctx, "out of memory");
        _ = c.call(ctx, cap[1], c.JS_UNDEFINED, 1, &msg);
        return promise;
    };
    blob.* = blob_mod.BlobData.init();
    blob.setBytes(body_bytes);
    if (data.headers.getFirst("content-type")) |ct| blob.setTypeNormalized(ct);
    var obj = blob_mod.buildBlobJSObject(ctx, blob);
    _ = c.call(ctx, cap[0], c.JS_UNDEFINED, 1, &obj);
    return promise;
}

fn requestFormData(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc; _ = argv;
    const data = extractRequestData(ctx, this_val) orelse return c.JS_EXCEPTION;
    data.body_used = true;
    const body_bytes = data.body() orelse "";
    var cap: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &cap);
    const fd = gpa.create(formdata_mod.FormData) catch {
        var msg = zigStringToJS(ctx, "out of memory");
        _ = c.call(ctx, cap[1], c.JS_UNDEFINED, 1, &msg);
        return promise;
    };
    fd.* = formdata_mod.FormData.init();
    const ct = data.headers.getFirst("content-type") orelse "";
    if (!formdata_mod.parseBody(fd, ct, body_bytes)) {
        fd.deinit();
        gpa.destroy(fd);
        var msg = zigStringToJS(ctx, "FormData unsupported content-type");
        _ = c.call(ctx, cap[1], c.JS_UNDEFINED, 1, &msg);
        return promise;
    }
    var obj = formdata_mod.buildFormDataJSObject(ctx, fd);
    _ = c.call(ctx, cap[0], c.JS_UNDEFINED, 1, &obj);
    return promise;
}

fn requestBytes(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc; _ = argv;
    const data = extractRequestData(ctx, this_val) orelse return c.JS_EXCEPTION;
    data.body_used = true;
    const body_bytes = data.body() orelse "";
    var cap: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &cap);
    var ab = c.newArrayBufferCopy(ctx, body_bytes.ptr, body_bytes.len);
    _ = c.call(ctx, cap[0], c.JS_UNDEFINED, 1, &ab);
    return promise;
}

fn requestClone(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc; _ = argv;
    const data = extractRequestData(ctx, this_val) orelse return c.JS_EXCEPTION;
    const new_data = gpa.create(RequestData) catch return c.throwOutOfMemory(ctx);
    new_data.* = RequestData.init();
    new_data.cloneFrom(data);
    const obj = c.newObjectClass(ctx, @intCast(request_class_id));
    c.setOpaque(obj, new_data);
    setRequestProps(ctx, obj, new_data);
    return obj;
}

fn requestToString(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc; _ = argv;
    const data = extractRequestData(ctx, this_val) orelse return zigStringToJS(ctx, "");
    return zigStringToJS(ctx, data.url());
}

fn requestToJSON(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc; _ = argv;
    const data = extractRequestData(ctx, this_val) orelse return c.JS_NULL;
    const obj = c.newObject(ctx);
    _ = c.definePropertyValueStr(ctx, obj, "url", zigStringToJS(ctx, data.url()), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "method", zigStringToJS(ctx, data.method()), c.PROP_C_W_E);
    return obj;
}

fn requestFinalizer(rt: ?*c.Runtime, val: c.Value) callconv(.c) void {
    _ = rt;
    if (c.getOpaque(val, request_class_id)) |ptr| {
        const data: *RequestData = @ptrCast(@alignCast(ptr));
        data.deinit();
        gpa.destroy(data);
    }
}

fn requestConstructor(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 1) {
        _ = c.throwTypeError(ctx, "Request requires a URL string as first argument");
        return c.JS_EXCEPTION;
    }
    const data = gpa.create(RequestData) catch return c.throwOutOfMemory(ctx);
    data.* = RequestData.init();

    var url_buf: [512]u8 = undefined;
    var scratch: [128]u8 = undefined;
    const arg0 = argv[0];

    if (c.isString(arg0) != 0) {
        if (extractStringAuto(ctx, arg0, &url_buf)) |u| {
            defer u.deinit();
            data.setUrl(u.slice);
        }
    } else if (c.isObject(arg0) != 0) {
        const src = extractRequestData(ctx, arg0);
        if (src) |src_data| {
            // Fresh headers from init() are empty: clone straight into them.
            // Releasing here would destroy the live container and leave
            // cloneFrom writing through a dangling pointer.
            data.cloneFrom(src_data);
        } else {
            const url_val = c.getPropertyStr(ctx, arg0, "url");
            defer c.freeValue(ctx, url_val);
            if (c.isString(url_val) != 0) {
                if (extractStringAuto(ctx, url_val, &url_buf)) |u| {
                    defer u.deinit();
                    data.setUrl(u.slice);
                }
            }
        }
    } else {
        data.deinit();
        gpa.destroy(data);
        _ = c.throwTypeError(ctx, "Request requires a URL string or Request object as first argument");
        return c.JS_EXCEPTION;
    }

    if (argc > 1 and c.isObject(argv[1]) != 0) {
        const init_val = argv[1];
        const method_val = c.getPropertyStr(ctx, init_val, "method");
        defer c.freeValue(ctx, method_val);
        if (c.isString(method_val) != 0) {
            if (extractStringAuto(ctx, method_val, &scratch)) |m| {
                defer m.deinit();
                data.setMethod(m.slice);
            }
        }
        parseHeadersInitFromObj(ctx, init_val, data.headers);
        const body_val = c.getPropertyStr(ctx, init_val, "body");
        defer c.freeValue(ctx, body_val);
        if (c.isUndefined(body_val) == 0 and c.isNull(body_val) == 0) {
            if (extractStringAuto(ctx, body_val, &url_buf)) |b| {
                defer b.deinit();
                data.setBody(b.slice);
            }
        }
        const cache_val = c.getPropertyStr(ctx, init_val, "cache");
        defer c.freeValue(ctx, cache_val);
        if (extractStringAuto(ctx, cache_val, &scratch)) |c_val| {
            defer c_val.deinit();
            data.setCache(c_val.slice);
        }
        const cred_val = c.getPropertyStr(ctx, init_val, "credentials");
        defer c.freeValue(ctx, cred_val);
        if (extractStringAuto(ctx, cred_val, &scratch)) |c_val| {
            defer c_val.deinit();
            data.setCredentials(c_val.slice);
        }
        const mode_val = c.getPropertyStr(ctx, init_val, "mode");
        defer c.freeValue(ctx, mode_val);
        if (extractStringAuto(ctx, mode_val, &scratch)) |m_val| {
            defer m_val.deinit();
            data.setMode(m_val.slice);
        }
        const redir_val = c.getPropertyStr(ctx, init_val, "redirect");
        defer c.freeValue(ctx, redir_val);
        if (extractStringAuto(ctx, redir_val, &scratch)) |r_val| {
            defer r_val.deinit();
            data.setRedirect(r_val.slice);
        }
        const integ_val = c.getPropertyStr(ctx, init_val, "integrity");
        defer c.freeValue(ctx, integ_val);
        if (extractStringAuto(ctx, integ_val, &scratch)) |i_val| {
            defer i_val.deinit();
            data.setIntegrity(i_val.slice);
        }
        const keep_val = c.getPropertyStr(ctx, init_val, "keepalive");
        defer c.freeValue(ctx, keep_val);
        if (c.toBool(ctx, keep_val) != 0) data.keepalive = true;
    }

    const obj = c.newObjectClass(ctx, @intCast(request_class_id));
    c.setOpaque(obj, data);
    setRequestProps(ctx, obj, data);
    return obj;
}

pub fn buildRequestJSObject(ctx: ?*c.Context, data: *RequestData) c.Value {
    const obj = c.newObjectClass(ctx, @intCast(request_class_id));
    c.setOpaque(obj, data);
    setRequestProps(ctx, obj, data);
    return obj;
}

pub fn setup(ctx: ?*c.Context) void {
    var class_def = c.ClassDef{
        .class_name = "Request",
        .finalizer = requestFinalizer,
    };
    _ = c.newClassID(c.getRuntime(ctx), &request_class_id);
    _ = c.newClass(c.getRuntime(ctx), request_class_id, &class_def);

    const proto = c.newObject(ctx);
    const methods = [_]struct { name: [*:0]const u8, func: *const c.CFunction, len: c_int }{
        .{ .name = "text", .func = &requestText, .len = 0 },
        .{ .name = "json", .func = &requestJson, .len = 0 },
        .{ .name = "arrayBuffer", .func = &requestArrayBuffer, .len = 0 },
        .{ .name = "blob", .func = &requestBlob, .len = 0 },
        .{ .name = "formData", .func = &requestFormData, .len = 0 },
        .{ .name = "bytes", .func = &requestBytes, .len = 0 },
        .{ .name = "clone", .func = &requestClone, .len = 0 },
        .{ .name = "toString", .func = &requestToString, .len = 0 },
        .{ .name = "toJSON", .func = &requestToJSON, .len = 0 },
    };
    for (methods) |m| {
        const fn_val = c.newCFunction(ctx, m.func, m.name, m.len);
        _ = c.definePropertyValueStr(ctx, proto, m.name, fn_val, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
    }
    c.setClassProto(ctx, request_class_id, proto);
    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);
    const ctor = c.newCFunction2(ctx, &requestConstructor, "Request", 2, c.JS_CFUNC_constructor, 0);
    _ = c.definePropertyValueStr(ctx, global, "Request", ctor, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
}
