const std = @import("std");
const c = @import("../c.zig").c;
const headers_mod = @import("headers.zig");
const gpa = std.heap.page_allocator;
// ============================================================
// Cached V8 strings + functions (created once in setup)
// ============================================================
var str___d: c.Global = .{ .data_ptr = 0 };
var str_url: c.Global = .{ .data_ptr = 0 };
var str_method: c.Global = .{ .data_ptr = 0 };
var str_headers: c.Global = .{ .data_ptr = 0 };
var str_bodyUsed: c.Global = .{ .data_ptr = 0 };
var str_cache: c.Global = .{ .data_ptr = 0 };
var str_credentials: c.Global = .{ .data_ptr = 0 };
var str_mode: c.Global = .{ .data_ptr = 0 };
var str_redirect: c.Global = .{ .data_ptr = 0 };
var str_integrity: c.Global = .{ .data_ptr = 0 };
var str_keepalive: c.Global = .{ .data_ptr = 0 };
var str_text: c.Global = .{ .data_ptr = 0 };
var str_json: c.Global = .{ .data_ptr = 0 };
var str_arrayBuffer: c.Global = .{ .data_ptr = 0 };
var str_blob: c.Global = .{ .data_ptr = 0 };
var str_formData: c.Global = .{ .data_ptr = 0 };
var str_bytes: c.Global = .{ .data_ptr = 0 };
var str_clone: c.Global = .{ .data_ptr = 0 };
var str_toString: c.Global = .{ .data_ptr = 0 };
var str_toJSON: c.Global = .{ .data_ptr = 0 };
var fn_text: c.Global = .{ .data_ptr = 0 };
var fn_json: c.Global = .{ .data_ptr = 0 };
var fn_arrayBuffer: c.Global = .{ .data_ptr = 0 };
var fn_blob: c.Global = .{ .data_ptr = 0 };
var fn_formData: c.Global = .{ .data_ptr = 0 };
var fn_bytes: c.Global = .{ .data_ptr = 0 };
var fn_clone: c.Global = .{ .data_ptr = 0 };
var fn_toString: c.Global = .{ .data_ptr = 0 };
var fn_toJSON: c.Global = .{ .data_ptr = 0 };
// Cached Headers strings + functions
var h_str___d: c.Global = .{ .data_ptr = 0 };
var h_str_get: c.Global = .{ .data_ptr = 0 };
var h_str_getAll: c.Global = .{ .data_ptr = 0 };
var h_str_has: c.Global = .{ .data_ptr = 0 };
var h_str_set: c.Global = .{ .data_ptr = 0 };
var h_str_append: c.Global = .{ .data_ptr = 0 };
var h_str_delete: c.Global = .{ .data_ptr = 0 };
var h_str_entries: c.Global = .{ .data_ptr = 0 };
var h_str_keys: c.Global = .{ .data_ptr = 0 };
var h_str_values: c.Global = .{ .data_ptr = 0 };
var h_str_forEach: c.Global = .{ .data_ptr = 0 };
var h_str_toString: c.Global = .{ .data_ptr = 0 };
var h_str_size: c.Global = .{ .data_ptr = 0 };
var h_fn_get: c.Global = .{ .data_ptr = 0 };
var h_fn_getAll: c.Global = .{ .data_ptr = 0 };
var h_fn_has: c.Global = .{ .data_ptr = 0 };
var h_fn_set: c.Global = .{ .data_ptr = 0 };
var h_fn_append: c.Global = .{ .data_ptr = 0 };
var h_fn_delete: c.Global = .{ .data_ptr = 0 };
var h_fn_entries: c.Global = .{ .data_ptr = 0 };
var h_fn_keys: c.Global = .{ .data_ptr = 0 };
var h_fn_values: c.Global = .{ .data_ptr = 0 };
var h_fn_forEach: c.Global = .{ .data_ptr = 0 };
var h_fn_toString: c.Global = .{ .data_ptr = 0 };
var h_fn_size: c.Global = .{ .data_ptr = 0 };
// Interned-field V8 strings: one Global per non-"other" enum variant.
// Request objects are built per HTTP request; these tables let builders
// reuse constant V8 strings instead of allocating fresh ones for fields
// whose value is one of a handful of fixed spec tokens.
var method_strs: [@typeInfo(Method).@"enum".fields.len - 1]c.Global = undefined;
var cache_strs: [@typeInfo(CacheMode).@"enum".fields.len - 1]c.Global = undefined;
var cred_strs: [@typeInfo(CredMode).@"enum".fields.len - 1]c.Global = undefined;
var mode_strs: [@typeInfo(Mode).@"enum".fields.len - 1]c.Global = undefined;
var redirect_strs: [@typeInfo(RedirectMode).@"enum".fields.len - 1]c.Global = undefined;
var str_body: c.Global = .{ .data_ptr = 0 };
// ============================================================
// Helpers
// ============================================================
fn throw(isolate: ?*c.Isolate, msg: []const u8) void {
    const v8_msg = c.v8__String__NewFromUtf8(isolate, @ptrCast(msg.ptr), 0, @intCast(msg.len));
    const exc = c.v8__Exception__Error(v8_msg);
    _ = c.v8__Isolate__ThrowException(isolate, exc);
}
fn throwTypeError(isolate: ?*c.Isolate, msg: []const u8) void {
    const v8_msg = c.v8__String__NewFromUtf8(isolate, @ptrCast(msg.ptr), 0, @intCast(msg.len));
    const exc = c.v8__Exception__TypeError(v8_msg);
    _ = c.v8__Isolate__ThrowException(isolate, exc);
}
fn zigStringToV8(isolate: ?*c.Isolate, str: []const u8) *const c.Value {
    return @ptrCast(c.v8__String__NewFromUtf8(isolate, @ptrCast(str.ptr), 0, @intCast(str.len)));
}
// Interned-field accessors: cached Global when the tag is a known variant,
// fresh string from the pool slice only for custom (.other) values.
fn methodToV8(isolate: ?*c.Isolate, d: *const RequestData) *const c.Value {
    if (d._method != .other) {
        if (c.v8__Global__Get(&method_strs[@intFromEnum(d._method)], isolate)) |v| return @ptrCast(v);
    }
    return zigStringToV8(isolate, d.method());
}
fn cacheToV8(isolate: ?*c.Isolate, d: *const RequestData) *const c.Value {
    if (d._cache != .other) {
        if (c.v8__Global__Get(&cache_strs[@intFromEnum(d._cache)], isolate)) |v| return @ptrCast(v);
    }
    return zigStringToV8(isolate, d.cache());
}
fn credentialsToV8(isolate: ?*c.Isolate, d: *const RequestData) *const c.Value {
    if (d._credentials != .other) {
        if (c.v8__Global__Get(&cred_strs[@intFromEnum(d._credentials)], isolate)) |v| return @ptrCast(v);
    }
    return zigStringToV8(isolate, d.credentials());
}
fn modeToV8(isolate: ?*c.Isolate, d: *const RequestData) *const c.Value {
    if (d._mode != .other) {
        if (c.v8__Global__Get(&mode_strs[@intFromEnum(d._mode)], isolate)) |v| return @ptrCast(v);
    }
    return zigStringToV8(isolate, d.mode());
}
fn redirectToV8(isolate: ?*c.Isolate, d: *const RequestData) *const c.Value {
    if (d._redirect != .other) {
        if (c.v8__Global__Get(&redirect_strs[@intFromEnum(d._redirect)], isolate)) |v| return @ptrCast(v);
    }
    return zigStringToV8(isolate, d.redirect());
}
// Hot-path string extraction: writes into the caller-provided stack buffer
// when the string fits, falling back to one heap allocation otherwise.
const ExtractedStr = struct {
    slice: []const u8,
    heap: ?[:0]u8 = null,
    fn deinit(self: ExtractedStr) void {
        if (self.heap) |h| gpa.free(h);
    }
};
fn extractStringAuto(isolate: ?*c.Isolate, val: ?*const c.Value, stack_buf: []u8) ?ExtractedStr {
    const v = val orelse return null;
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    const str = c.v8__Value__ToDetailString(v, context);
    if (str == null) return null;
    const utf8_len: usize = @intCast(c.v8__String__Utf8Length(str, isolate));
    if (utf8_len <= stack_buf.len) {
        _ = c.v8__String__WriteUtf8(str, isolate, stack_buf.ptr, utf8_len, 0);
        return .{ .slice = stack_buf[0..utf8_len] };
    }
    const heap_buf = gpa.allocSentinel(u8, utf8_len, 0) catch return null;
    _ = c.v8__String__WriteUtf8(str, isolate, heap_buf.ptr, utf8_len, 0);
    return .{ .slice = heap_buf, .heap = heap_buf };
}
// Setup-time extraction (heap-allocated), retained for non-hot paths.
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
// ============================================================
// Interning — spec-constrained string fields as dense enums
// ============================================================
pub const Method = enum(u8) {
    GET,
    POST,
    PUT,
    DELETE,
    HEAD,
    OPTIONS,
    PATCH,
    other,
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
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
            .PATCH => "PATCH",
            .other => unreachable,
        };
    }
};
pub const CacheMode = enum(u8) {
    default,
    no_store,
    reload,
    no_cache,
    force_cache,
    only_if_cached,
    other,
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
            .default => "default",
            .no_store => "no-store",
            .reload => "reload",
            .no_cache => "no-cache",
            .force_cache => "force-cache",
            .only_if_cached => "only-if-cached",
            .other => unreachable,
        };
    }
};
pub const CredMode = enum(u8) {
    same_origin,
    include,
    omit,
    other,
    pub fn fromSlice(s: []const u8) CredMode {
        if (std.mem.eql(u8, s, "same-origin")) return .same_origin;
        if (std.mem.eql(u8, s, "include")) return .include;
        if (std.mem.eql(u8, s, "omit")) return .omit;
        return .other;
    }
    pub fn string(self: CredMode) []const u8 {
        return switch (self) {
            .same_origin => "same-origin",
            .include => "include",
            .omit => "omit",
            .other => unreachable,
        };
    }
};
pub const Mode = enum(u8) {
    navigate,
    same_origin,
    no_cors,
    cors,
    other,
    pub fn fromSlice(s: []const u8) Mode {
        if (std.mem.eql(u8, s, "navigate")) return .navigate;
        if (std.mem.eql(u8, s, "same-origin")) return .same_origin;
        if (std.mem.eql(u8, s, "no-cors")) return .no_cors;
        if (std.mem.eql(u8, s, "cors")) return .cors;
        return .other;
    }
    pub fn string(self: Mode) []const u8 {
        return switch (self) {
            .navigate => "navigate",
            .same_origin => "same-origin",
            .no_cors => "no-cors",
            .cors => "cors",
            .other => unreachable,
        };
    }
};
pub const RedirectMode = enum(u8) {
    follow,
    err,
    manual,
    other,
    pub fn fromSlice(s: []const u8) RedirectMode {
        if (std.mem.eql(u8, s, "follow")) return .follow;
        if (std.mem.eql(u8, s, "error")) return .err;
        if (std.mem.eql(u8, s, "manual")) return .manual;
        return .other;
    }
    pub fn string(self: RedirectMode) []const u8 {
        return switch (self) {
            .follow => "follow",
            .err => "error",
            .manual => "manual",
            .other => unreachable,
        };
    }
};
// ============================================================
// RequestData — DOD: contiguous string pool + interned scalars
// ============================================================
const PoolSlice = struct { off: usize = 0, len: usize = 0 };
pub const RequestData = struct {
    pool: std.ArrayList(u8),
    _url: PoolSlice,
    _body: PoolSlice,
    has_body: bool,
    _integrity: PoolSlice,
    _method: Method,
    _cache: CacheMode,
    _credentials: CredMode,
    _mode: Mode,
    _redirect: RedirectMode,
    _method_other: PoolSlice,
    _cache_other: PoolSlice,
    _credentials_other: PoolSlice,
    _mode_other: PoolSlice,
    _redirect_other: PoolSlice,
    headers: headers_mod.HeadersData,
    body_used: bool,
    keepalive: bool,
    pub fn init() RequestData {
        return .{
            .pool = std.ArrayList(u8).empty,
            ._url = .{},
            ._body = .{},
            .has_body = false,
            ._integrity = .{},
            ._method = .GET,
            ._cache = .default,
            ._credentials = .same_origin,
            ._mode = .cors,
            ._redirect = .follow,
            ._method_other = .{},
            ._cache_other = .{},
            ._credentials_other = .{},
            ._mode_other = .{},
            ._redirect_other = .{},
            .headers = headers_mod.HeadersData.init(),
            .body_used = false,
            .keepalive = false,
        };
    }
    pub fn deinit(self: *RequestData) void {
        self.pool.deinit(gpa);
        self.headers.deinit();
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
            return self.pool.items[self._method_other.off .. self._method_other.off + self._method_other.len];
        }
        return self._method.string();
    }
    pub fn cache(self: *const RequestData) []const u8 {
        if (self._cache == .other) {
            return self.pool.items[self._cache_other.off .. self._cache_other.off + self._cache_other.len];
        }
        return self._cache.string();
    }
    pub fn credentials(self: *const RequestData) []const u8 {
        if (self._credentials == .other) {
            return self.pool.items[self._credentials_other.off .. self._credentials_other.off + self._credentials_other.len];
        }
        return self._credentials.string();
    }
    pub fn mode(self: *const RequestData) []const u8 {
        if (self._mode == .other) {
            return self.pool.items[self._mode_other.off .. self._mode_other.off + self._mode_other.len];
        }
        return self._mode.string();
    }
    pub fn redirect(self: *const RequestData) []const u8 {
        if (self._redirect == .other) {
            return self.pool.items[self._redirect_other.off .. self._redirect_other.off + self._redirect_other.len];
        }
        return self._redirect.string();
    }
    fn store(self: *RequestData, owned: []const u8, dst: *PoolSlice) void {
        if (owned.len == 0) return;
        const off = self.pool.items.len;
        self.pool.appendSlice(gpa, owned) catch return;
        dst.* = .{ .off = off, .len = owned.len };
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
        if (m == .other) self.store(owned, &self._method_other);
    }
    pub fn setCache(self: *RequestData, owned: []const u8) void {
        defer gpa.free(owned);
        const v = CacheMode.fromSlice(owned);
        self._cache = v;
        if (v == .other) self.store(owned, &self._cache_other);
    }
    pub fn setCredentials(self: *RequestData, owned: []const u8) void {
        defer gpa.free(owned);
        const v = CredMode.fromSlice(owned);
        self._credentials = v;
        if (v == .other) self.store(owned, &self._credentials_other);
    }
    pub fn setMode(self: *RequestData, owned: []const u8) void {
        defer gpa.free(owned);
        const v = Mode.fromSlice(owned);
        self._mode = v;
        if (v == .other) self.store(owned, &self._mode_other);
    }
    pub fn setRedirect(self: *RequestData, owned: []const u8) void {
        defer gpa.free(owned);
        const v = RedirectMode.fromSlice(owned);
        self._redirect = v;
        if (v == .other) self.store(owned, &self._redirect_other);
    }
    pub fn cloneFrom(self: *RequestData, src: *const RequestData) void {
        self.pool.appendSlice(gpa, src.pool.items) catch {};
        self._url = src._url;
        self._body = src._body;
        self.has_body = src.has_body;
        self._integrity = src._integrity;
        self._method = src._method;
        self._cache = src._cache;
        self._credentials = src._credentials;
        self._mode = src._mode;
        self._redirect = src._redirect;
        self._method_other = src._method_other;
        self._cache_other = src._cache_other;
        self._credentials_other = src._credentials_other;
        self._mode_other = src._mode_other;
        self._redirect_other = src._redirect_other;
        self.body_used = false;
        self.keepalive = src.keepalive;
        for (0..src.headers.len()) |i| {
            const p = src.headers.getPair(i);
            self.headers.appendEntry(p.name, p.value);
        }
    }
};
// ============================================================
// Extract RequestData from JS this.__d
// ============================================================
fn extractRequestData(info: ?*const c.FunctionCallbackInfo) ?*RequestData {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    const this = c.v8__FunctionCallbackInfo__This(info);
    if (this == null) return null;
    const ext_val = c.v8__Object__Get(@ptrCast(this), context, @ptrCast(c.v8__Global__Get(&str___d, isolate)));
    if (ext_val == null or !c.v8__Value__IsExternal(ext_val)) return null;
    const ptr = c.v8__External__Value(@ptrCast(ext_val));
    return @ptrCast(@alignCast(ptr));
}
// ============================================================
// Build Headers JS object (cached strings + functions)
// ============================================================
fn createHeadersJSObject(isolate: ?*c.Isolate, context: ?*c.Context, hdr_data: *headers_mod.HeadersData) ?*const c.Value {
    const obj = c.v8__Object__New(isolate);
    const ext = c.v8__External__New(isolate, @ptrCast(hdr_data));
    var out: c.MaybeBool = undefined;
    c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(&h_str___d, isolate)), ext, &out);
    const pairs = .{
        .{ &h_fn_get, &h_str_get },
        .{ &h_fn_getAll, &h_str_getAll },
        .{ &h_fn_has, &h_str_has },
        .{ &h_fn_set, &h_str_set },
        .{ &h_fn_append, &h_str_append },
        .{ &h_fn_delete, &h_str_delete },
        .{ &h_fn_entries, &h_str_entries },
        .{ &h_fn_keys, &h_str_keys },
        .{ &h_fn_values, &h_str_values },
        .{ &h_fn_forEach, &h_str_forEach },
        .{ &h_fn_toString, &h_str_toString },
        .{ &h_fn_size, &h_str_size },
    };
    inline for (pairs) |pair| {
        c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(pair[1], isolate)), @ptrCast(c.v8__Global__Get(pair[0], isolate)), &out);
    }
    return obj;
}
// ============================================================
// Headers stubs
// ============================================================
fn headersGetStub(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    headers_mod.headersGet(info);
}
fn headersGetAllStub(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    headers_mod.headersGetAll(info);
}
fn headersHasStub(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    headers_mod.headersHas(info);
}
fn headersSetStub(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    headers_mod.headersSet(info);
}
fn headersAppendStub(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    headers_mod.headersAppend(info);
}
fn headersDeleteStub(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    headers_mod.headersDelete(info);
}
fn headersEntriesStub(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    headers_mod.headersEntries(info);
}
fn headersKeysStub(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    headers_mod.headersKeys(info);
}
fn headersValuesStub(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    headers_mod.headersValues(info);
}
fn headersForEachStub(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    headers_mod.headersForEach(info);
}
fn headersToStringStub(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    headers_mod.headersToString(info);
}
fn headersSizeStub(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    headers_mod.headersSize(info);
}
// ============================================================
// Headers init parsing
// ============================================================
fn parseHeadersInit(isolate: ?*c.Isolate, context: ?*c.Context, init_val: ?*const c.Value, target: *headers_mod.HeadersData) void {
    if (init_val == null) return;
    if (c.v8__Value__IsUndefined(init_val) or c.v8__Value__IsNull(init_val)) return;
    if (c.v8__Value__IsObject(init_val)) {
        const ext_val = c.v8__Object__Get(@ptrCast(init_val), context, @ptrCast(c.v8__Global__Get(&str___d, isolate)));
        if (ext_val != null and c.v8__Value__IsExternal(ext_val)) {
            const src: *headers_mod.HeadersData = @ptrCast(@alignCast(c.v8__External__Value(@ptrCast(ext_val))));
            for (0..src.len()) |i| {
                const p = src.getPair(i);
                target.appendEntry(p.name, p.value);
            }
            return;
        }
        if (c.v8__Value__IsArray(init_val)) {
            const len: usize = @intCast(c.v8__Array__Length(init_val));
            var i: usize = 0;
            while (i < len) : (i += 1) {
                const idx = c.v8__Integer__NewFromUnsigned(isolate, @intCast(i));
                const item = c.v8__Object__Get(@ptrCast(init_val), context, idx);
                if (item == null) continue;
                if (!c.v8__Value__IsObject(item)) continue;
                const item_obj: *const c.Object = @ptrCast(item);
                const key = c.v8__Integer__NewFromUnsigned(isolate, 0);
                const val = c.v8__Integer__NewFromUnsigned(isolate, 1);
                const name_val = c.v8__Object__Get(item_obj, context, key);
                const val_val = c.v8__Object__Get(item_obj, context, val);
                const name_z = extractStringFromVal(isolate, name_val);
                const val_z = extractStringFromVal(isolate, val_val);
                if (name_z) |n| {
                    if (val_z) |v| {
                        target.appendEntry(n, v);
                        gpa.free(v);
                    }
                    gpa.free(n);
                }
            }
            return;
        }
        const names_arr = c.v8__Object__GetPropertyNames(@ptrCast(init_val), context);
        if (names_arr != null) {
            const names_len: usize = @intCast(c.v8__Array__Length(names_arr));
            var i: usize = 0;
            while (i < names_len) : (i += 1) {
                const idx = c.v8__Integer__NewFromUnsigned(isolate, @intCast(i));
                const name_val = c.v8__Object__Get(@ptrCast(names_arr), context, idx);
                if (name_val == null) continue;
                const val_val = c.v8__Object__Get(@ptrCast(init_val), context, name_val);
                const name_z = extractStringFromVal(isolate, name_val);
                const val_z = extractStringFromVal(isolate, val_val);
                if (name_z) |n| {
                    if (val_z) |v| {
                        target.appendEntry(n, v);
                        gpa.free(v);
                    }
                    gpa.free(n);
                }
            }
        }
    }
}
fn parseHeadersInitFromObj(isolate: ?*c.Isolate, context: ?*c.Context, init_obj: ?*const c.Value, target: *headers_mod.HeadersData) void {
    if (init_obj == null) return;
    const headers_val = c.v8__Object__Get(@ptrCast(init_obj), context, @ptrCast(c.v8__Global__Get(&str_headers, isolate)));
    if (headers_val != null and !c.v8__Value__IsUndefined(headers_val) and !c.v8__Value__IsNull(headers_val)) {
        parseHeadersInit(isolate, context, headers_val, target);
    }
}
// ============================================================
// JS Callbacks — Body methods
// ============================================================
fn requestText(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractRequestData(info) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));
        return;
    };
    const resolver = c.v8__Promise__Resolver__New(context);
    if (resolver == null) {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));
        return;
    }
    const promise = c.v8__Promise__Resolver__GetPromise(resolver);
    data.body_used = true;
    const body_text = data.body() orelse "";
    var out: c.MaybeBool = undefined;
    _ = c.v8__Promise__Resolver__Resolve(resolver, context, @ptrCast(zigStringToV8(isolate, body_text)), &out);
    c.v8__ReturnValue__Set(ret, @ptrCast(promise));
}
fn requestJson(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractRequestData(info) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));
        return;
    };
    const resolver = c.v8__Promise__Resolver__New(context);
    if (resolver == null) {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));
        return;
    }
    const promise = c.v8__Promise__Resolver__GetPromise(resolver);
    data.body_used = true;
    const body_text = data.body() orelse "";
    const js_str = c.v8__String__NewFromUtf8(isolate, @ptrCast(body_text.ptr), 0, @intCast(body_text.len));
    const parsed = c.v8__JSON__Parse(context, js_str);
    var out: c.MaybeBool = undefined;
    if (parsed != null) {
        _ = c.v8__Promise__Resolver__Resolve(resolver, context, parsed, &out);
    } else {
        _ = c.v8__Promise__Resolver__Reject(resolver, context, @ptrCast(zigStringToV8(isolate, "Invalid JSON")), &out);
    }
    c.v8__ReturnValue__Set(ret, @ptrCast(promise));
}
fn requestArrayBuffer(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractRequestData(info) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));
        return;
    };
    const resolver = c.v8__Promise__Resolver__New(context);
    if (resolver == null) {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));
        return;
    }
    const promise = c.v8__Promise__Resolver__GetPromise(resolver);
    data.body_used = true;
    const body_bytes = data.body() orelse "";
    const byte_len: usize = body_bytes.len;
    const ab = c.v8__ArrayBuffer__New(isolate, byte_len);
    if (ab != null and byte_len > 0) {
        const backing = c.v8__ArrayBuffer__GetBackingStore(ab);
        const store_ptr = c.std__shared_ptr__v8__BackingStore__get(&backing);
        if (store_ptr != null) {
            const data_ptr: [*]u8 = @ptrCast(@alignCast(c.v8__BackingStore__Data(store_ptr)));
            @memcpy(data_ptr[0..byte_len], body_bytes);
        }
    }
    var out: c.MaybeBool = undefined;
    _ = c.v8__Promise__Resolver__Resolve(resolver, context, @ptrCast(ab), &out);
    c.v8__ReturnValue__Set(ret, @ptrCast(promise));
}
fn requestBlob(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const resolver = c.v8__Promise__Resolver__New(context);
    if (resolver == null) {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));
        return;
    }
    const promise = c.v8__Promise__Resolver__GetPromise(resolver);
    var out: c.MaybeBool = undefined;
    _ = c.v8__Promise__Resolver__Reject(resolver, context, @ptrCast(zigStringToV8(isolate, "Blob not supported")), &out);
    c.v8__ReturnValue__Set(ret, @ptrCast(promise));
}
fn requestFormData(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const resolver = c.v8__Promise__Resolver__New(context);
    if (resolver == null) {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));
        return;
    }
    const promise = c.v8__Promise__Resolver__GetPromise(resolver);
    var out: c.MaybeBool = undefined;
    _ = c.v8__Promise__Resolver__Reject(resolver, context, @ptrCast(zigStringToV8(isolate, "FormData not supported")), &out);
    c.v8__ReturnValue__Set(ret, @ptrCast(promise));
}
fn requestBytes(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractRequestData(info) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));
        return;
    };
    const resolver = c.v8__Promise__Resolver__New(context);
    if (resolver == null) {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));
        return;
    }
    const promise = c.v8__Promise__Resolver__GetPromise(resolver);
    data.body_used = true;
    const body_bytes = data.body() orelse "";
    const byte_len: usize = body_bytes.len;
    const ab = c.v8__ArrayBuffer__New(isolate, byte_len);
    if (ab != null and byte_len > 0) {
        const backing = c.v8__ArrayBuffer__GetBackingStore(ab);
        const store_ptr = c.std__shared_ptr__v8__BackingStore__get(&backing);
        if (store_ptr != null) {
            const data_ptr: [*]u8 = @ptrCast(@alignCast(c.v8__BackingStore__Data(store_ptr)));
            @memcpy(data_ptr[0..byte_len], body_bytes);
        }
    }
    var out: c.MaybeBool = undefined;
    _ = c.v8__Promise__Resolver__Resolve(resolver, context, @ptrCast(ab), &out);
    c.v8__ReturnValue__Set(ret, @ptrCast(promise));
}
fn requestClone(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractRequestData(info) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));
        return;
    };
    const new_data = gpa.create(RequestData) catch {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));
        return;
    };
    new_data.* = RequestData.init();
    new_data.cloneFrom(data);
    const obj = c.v8__Object__New(isolate);
    const ext = c.v8__External__New(isolate, @ptrCast(new_data));
    var out: c.MaybeBool = undefined;
    c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(&str___d, isolate)), ext, &out);
    c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(&str_url, isolate)), @ptrCast(zigStringToV8(isolate, new_data.url())), &out);
    c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(&str_method, isolate)), methodToV8(isolate, new_data), &out);
    const headers_obj = createHeadersJSObject(isolate, context, &new_data.headers);
    c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(&str_headers, isolate)), @ptrCast(headers_obj), &out);
    setDataProps(obj, context, isolate, new_data);
    setCachedFns(obj, context, isolate);
    c.v8__ReturnValue__Set(ret, @ptrCast(obj));
}
fn requestToString(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractRequestData(info) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(zigStringToV8(isolate, "")));
        return;
    };
    c.v8__ReturnValue__Set(ret, @ptrCast(zigStringToV8(isolate, data.url())));
}
fn requestToJSON(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractRequestData(info) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));
        return;
    };
    const obj = c.v8__Object__New(isolate);
    var out: c.MaybeBool = undefined;
    c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(&str_url, isolate)), @ptrCast(zigStringToV8(isolate, data.url())), &out);
    c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(&str_method, isolate)), methodToV8(isolate, data), &out);
    c.v8__ReturnValue__Set(ret, @ptrCast(obj));
}
// ============================================================
// Helper: set scalar data properties + cached function properties
// ============================================================
fn setDataProps(obj: ?*const c.Object, context: ?*c.Context, isolate: ?*c.Isolate, data: *RequestData) void {
    var out: c.MaybeBool = undefined;
    const body_used = if (data.body_used) c.v8__True(isolate) else c.v8__False(isolate);
    c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(&str_bodyUsed, isolate)), @ptrCast(body_used), &out);
    const keepalive = if (data.keepalive) c.v8__True(isolate) else c.v8__False(isolate);
    c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(&str_keepalive, isolate)), @ptrCast(keepalive), &out);
    c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(&str_cache, isolate)), cacheToV8(isolate, data), &out);
    c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(&str_credentials, isolate)), credentialsToV8(isolate, data), &out);
    c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(&str_mode, isolate)), modeToV8(isolate, data), &out);
    c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(&str_redirect, isolate)), redirectToV8(isolate, data), &out);
    c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(&str_integrity, isolate)), @ptrCast(zigStringToV8(isolate, data.integrity())), &out);
}
fn setCachedFns(obj: ?*const c.Object, context: ?*c.Context, isolate: ?*c.Isolate) void {
    var out: c.MaybeBool = undefined;
    const pairs = .{
        .{ &fn_text, &str_text },               .{ &fn_json, &str_json },
        .{ &fn_arrayBuffer, &str_arrayBuffer }, .{ &fn_blob, &str_blob },
        .{ &fn_formData, &str_formData },       .{ &fn_bytes, &str_bytes },
        .{ &fn_clone, &str_clone },             .{ &fn_toString, &str_toString },
        .{ &fn_toJSON, &str_toJSON },
    };
    inline for (pairs) |pair| {
        c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(pair[1], isolate)), @ptrCast(c.v8__Global__Get(pair[0], isolate)), &out);
    }
}
// ============================================================
// buildRequestJSObject (cached)
// ============================================================
pub fn buildRequestJSObject(isolate: ?*c.Isolate, context: ?*c.Context, data: *RequestData) ?*const c.Object {
    const obj = c.v8__Object__New(isolate);
    const ext = c.v8__External__New(isolate, @ptrCast(data));
    var out: c.MaybeBool = undefined;
    c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(&str___d, isolate)), ext, &out);
    c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(&str_url, isolate)), @ptrCast(zigStringToV8(isolate, data.url())), &out);
    c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(&str_method, isolate)), methodToV8(isolate, data), &out);
    const headers_obj = createHeadersJSObject(isolate, context, &data.headers);
    c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(&str_headers, isolate)), @ptrCast(headers_obj), &out);
    setDataProps(obj, context, isolate, data);
    setCachedFns(obj, context, isolate);
    return obj;
}
// ============================================================
// Constructor: new Request(input, init?)
// ============================================================
fn requestConstructor(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    if (c.v8__FunctionCallbackInfo__Length(info) < 1) {
        throwTypeError(isolate, "Request requires a URL string as first argument");
        return;
    }
    const data = gpa.create(RequestData) catch {
        throw(isolate, "out of memory");
        return;
    };
    data.* = RequestData.init();
    // Stack scratch for hot-path extraction; each use is scoped so the
    // buffer is free for the next field. Heap fallback covers long values.
    var url_buf: [512]u8 = undefined;
    var scratch: [128]u8 = undefined;
    const arg0 = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    if (c.v8__Value__IsString(arg0)) {
        if (extractStringAuto(isolate, arg0, &url_buf)) |u| {
            defer u.deinit();
            data.setUrl(u.slice);
        }
    } else if (c.v8__Value__IsObject(arg0)) {
        const ext_val = c.v8__Object__Get(@ptrCast(arg0), context, @ptrCast(c.v8__Global__Get(&str___d, isolate)));
        if (ext_val != null and c.v8__Value__IsExternal(ext_val)) {
            const src: *RequestData = @ptrCast(@alignCast(c.v8__External__Value(@ptrCast(ext_val))));
            data.deinit();
            data.* = RequestData.init();
            data.cloneFrom(src);
        } else {
            const url_val = c.v8__Object__Get(@ptrCast(arg0), context, @ptrCast(c.v8__Global__Get(&str_url, isolate)));
            if (extractStringAuto(isolate, url_val, &url_buf)) |u| {
                defer u.deinit();
                data.setUrl(u.slice);
            }
        }
    } else {
        throwTypeError(isolate, "Request requires a URL string or Request object as first argument");
        gpa.destroy(data);
        return;
    }
    if (c.v8__FunctionCallbackInfo__Length(info) > 1) {
        const init_val = c.v8__FunctionCallbackInfo__INDEX(info, 1);
        if (c.v8__Value__IsObject(init_val)) {
            const method_val = c.v8__Object__Get(@ptrCast(init_val), context, @ptrCast(c.v8__Global__Get(&str_method, isolate)));
            if (method_val != null and !c.v8__Value__IsUndefined(method_val)) {
                if (extractStringAuto(isolate, method_val, &scratch)) |m| {
                    defer m.deinit();
                    data.setMethod(m.slice);
                }
            }
            parseHeadersInitFromObj(isolate, context, init_val, &data.headers);
            const body_val = c.v8__Object__Get(@ptrCast(init_val), context, @ptrCast(c.v8__Global__Get(&str_body, isolate)));
            if (body_val != null and !c.v8__Value__IsUndefined(body_val) and !c.v8__Value__IsNull(body_val)) {
                if (extractStringAuto(isolate, body_val, &url_buf)) |b| {
                    defer b.deinit();
                    data.setBody(b.slice);
                }
            }
            const cache_val = c.v8__Object__Get(@ptrCast(init_val), context, @ptrCast(c.v8__Global__Get(&str_cache, isolate)));
            if (extractStringAuto(isolate, cache_val, &scratch)) |c_val| {
                defer c_val.deinit();
                data.setCache(c_val.slice);
            }
            const cred_val = c.v8__Object__Get(@ptrCast(init_val), context, @ptrCast(c.v8__Global__Get(&str_credentials, isolate)));
            if (extractStringAuto(isolate, cred_val, &scratch)) |c_val| {
                defer c_val.deinit();
                data.setCredentials(c_val.slice);
            }
            const mode_val = c.v8__Object__Get(@ptrCast(init_val), context, @ptrCast(c.v8__Global__Get(&str_mode, isolate)));
            if (extractStringAuto(isolate, mode_val, &scratch)) |m_val| {
                defer m_val.deinit();
                data.setMode(m_val.slice);
            }
            const redir_val = c.v8__Object__Get(@ptrCast(init_val), context, @ptrCast(c.v8__Global__Get(&str_redirect, isolate)));
            if (extractStringAuto(isolate, redir_val, &scratch)) |r_val| {
                defer r_val.deinit();
                data.setRedirect(r_val.slice);
            }
            const integ_val = c.v8__Object__Get(@ptrCast(init_val), context, @ptrCast(c.v8__Global__Get(&str_integrity, isolate)));
            if (extractStringAuto(isolate, integ_val, &scratch)) |i_val| {
                defer i_val.deinit();
                data.setIntegrity(i_val.slice);
            }
            const keep_val = c.v8__Object__Get(@ptrCast(init_val), context, @ptrCast(c.v8__Global__Get(&str_keepalive, isolate)));
            if (keep_val != null and c.v8__Value__IsTrue(keep_val)) data.keepalive = true;
        }
    }
    const obj = c.v8__Object__New(isolate);
    const ext = c.v8__External__New(isolate, @ptrCast(data));
    var out: c.MaybeBool = undefined;
    c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(&str___d, isolate)), ext, &out);
    c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(&str_url, isolate)), @ptrCast(zigStringToV8(isolate, data.url())), &out);
    c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(&str_method, isolate)), methodToV8(isolate, data), &out);
    const headers_obj = createHeadersJSObject(isolate, context, &data.headers);
    c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(&str_headers, isolate)), @ptrCast(headers_obj), &out);
    setDataProps(obj, context, isolate, data);
    setCachedFns(obj, context, isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(obj));
}
// ============================================================
// Setup — create all cached V8 strings and functions once
// ============================================================
pub fn setup(isolate: ?*c.Isolate, context: ?*c.Context) void {
    var hs: c.HandleScope = undefined;
    c.v8__HandleScope__CONSTRUCT(&hs, isolate);
    defer c.v8__HandleScope__DESTRUCT(&hs);
    const global = c.v8__Context__Global(context);
    var out: c.MaybeBool = undefined;
    // Cache strings
    const strings = .{
        .{ "__d", &str___d },                 .{ "url", &str_url },             .{ "method", &str_method },
        .{ "headers", &str_headers },         .{ "bodyUsed", &str_bodyUsed },   .{ "cache", &str_cache },
        .{ "credentials", &str_credentials }, .{ "mode", &str_mode },           .{ "redirect", &str_redirect },
        .{ "integrity", &str_integrity },     .{ "keepalive", &str_keepalive }, .{ "text", &str_text },
        .{ "json", &str_json },               .{ "arrayBuffer", &str_arrayBuffer }, .{ "blob", &str_blob },
        .{ "formData", &str_formData },       .{ "bytes", &str_bytes },         .{ "clone", &str_clone },
        .{ "toString", &str_toString },       .{ "toJSON", &str_toJSON },
    };
    inline for (strings) |entry| {
        c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, entry[0], 0, -1)), entry[1]);
    }
    c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, "body", 0, -1)), &str_body);
    // Cache functions
    const funcs = .{
        .{ requestText, &fn_text },               .{ requestJson, &fn_json },
        .{ requestArrayBuffer, &fn_arrayBuffer }, .{ requestBlob, &fn_blob },
        .{ requestFormData, &fn_formData },       .{ requestBytes, &fn_bytes },
        .{ requestClone, &fn_clone },             .{ requestToString, &fn_toString },
        .{ requestToJSON, &fn_toJSON },
    };
    inline for (funcs) |entry| {
        c.v8__Global__New(isolate, @ptrCast(c.v8__Function__New__DEFAULT(context, entry[0])), entry[1]);
    }
    // Cache headers strings
    const h_strings = .{
        .{ "__d", &h_str___d },   .{ "get", &h_str_get },       .{ "getAll", &h_str_getAll },
        .{ "has", &h_str_has },   .{ "set", &h_str_set },       .{ "append", &h_str_append },
        .{ "delete", &h_str_delete }, .{ "entries", &h_str_entries }, .{ "keys", &h_str_keys },
        .{ "values", &h_str_values }, .{ "forEach", &h_str_forEach }, .{ "toString", &h_str_toString },
        .{ "size", &h_str_size },
    };
    inline for (h_strings) |entry| {
        c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, entry[0], 0, -1)), entry[1]);
    }
    // Cache headers functions
    const h_funcs = .{
        .{ headersGetStub, &h_fn_get },           .{ headersGetAllStub, &h_fn_getAll },
        .{ headersHasStub, &h_fn_has },           .{ headersSetStub, &h_fn_set },
        .{ headersAppendStub, &h_fn_append },     .{ headersDeleteStub, &h_fn_delete },
        .{ headersEntriesStub, &h_fn_entries },   .{ headersKeysStub, &h_fn_keys },
        .{ headersValuesStub, &h_fn_values },     .{ headersForEachStub, &h_fn_forEach },
        .{ headersToStringStub, &h_fn_toString }, .{ headersSizeStub, &h_fn_size },
    };
    inline for (h_funcs) |entry| {
        c.v8__Global__New(isolate, @ptrCast(c.v8__Function__New__DEFAULT(context, entry[0])), entry[1]);
    }
    // Interned-field variant strings (one per non-"other" enum variant).
    inline for (std.enums.values(Method)) |m| {
        if (m != .other) {
            const s = m.string();
            c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, @ptrCast(s.ptr), 0, @intCast(s.len))), &method_strs[@intFromEnum(m)]);
        }
    }
    inline for (std.enums.values(CacheMode)) |m| {
        if (m != .other) {
            const s = m.string();
            c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, @ptrCast(s.ptr), 0, @intCast(s.len))), &cache_strs[@intFromEnum(m)]);
        }
    }
    inline for (std.enums.values(CredMode)) |m| {
        if (m != .other) {
            const s = m.string();
            c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, @ptrCast(s.ptr), 0, @intCast(s.len))), &cred_strs[@intFromEnum(m)]);
        }
    }
    inline for (std.enums.values(Mode)) |m| {
        if (m != .other) {
            const s = m.string();
            c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, @ptrCast(s.ptr), 0, @intCast(s.len))), &mode_strs[@intFromEnum(m)]);
        }
    }
    inline for (std.enums.values(RedirectMode)) |m| {
        if (m != .other) {
            const s = m.string();
            c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, @ptrCast(s.ptr), 0, @intCast(s.len))), &redirect_strs[@intFromEnum(m)]);
        }
    }
    // Register Request constructor
    const fn_val = c.v8__Function__New__DEFAULT(context, requestConstructor);
    const key = c.v8__String__NewFromUtf8(isolate, "Request", 0, -1);
    _ = c.v8__Object__Set(global, context, key, fn_val, &out);
}
