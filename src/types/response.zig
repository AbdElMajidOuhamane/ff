const std = @import("std");
const c = @import("../c.zig").c;
const headers_mod = @import("headers.zig");
const gpa = std.heap.smp_allocator;
// ============================================================
// Cached V8 strings + functions (created once in setup)
// ============================================================
var str___d: c.Global = .{ .data_ptr = 0 };
var str_headers: c.Global = .{ .data_ptr = 0 };
var str_bodyUsed: c.Global = .{ .data_ptr = 0 };
var str_ok: c.Global = .{ .data_ptr = 0 };
var str_status: c.Global = .{ .data_ptr = 0 };
var str_statusText: c.Global = .{ .data_ptr = 0 };
var str_url: c.Global = .{ .data_ptr = 0 };
var str_type: c.Global = .{ .data_ptr = 0 };
var str_redirected: c.Global = .{ .data_ptr = 0 };
var str_text: c.Global = .{ .data_ptr = 0 };
var str_json: c.Global = .{ .data_ptr = 0 };
var str_arrayBuffer: c.Global = .{ .data_ptr = 0 };
var str_blob: c.Global = .{ .data_ptr = 0 };
var str_formData: c.Global = .{ .data_ptr = 0 };
var str_bytes: c.Global = .{ .data_ptr = 0 };
var str_clone: c.Global = .{ .data_ptr = 0 };
var fn_text: c.Global = .{ .data_ptr = 0 };
var fn_json: c.Global = .{ .data_ptr = 0 };
var fn_arrayBuffer: c.Global = .{ .data_ptr = 0 };
var fn_blob: c.Global = .{ .data_ptr = 0 };
var fn_formData: c.Global = .{ .data_ptr = 0 };
var fn_bytes: c.Global = .{ .data_ptr = 0 };
var fn_clone: c.Global = .{ .data_ptr = 0 };
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
// Interned-field V8 strings: one Global per non-"other" ResponseType variant,
// plus a shared empty string for zero-length url/statusText fast paths.
var type_strs: [@typeInfo(ResponseType).@"enum".fields.len - 1]c.Global = undefined;
var str_empty_v8: c.Global = .{ .data_ptr = 0 };
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
// Empty-string fast path: cached V8 "" instead of a fresh allocation.
fn emptyOrStringToV8(isolate: ?*c.Isolate, s: []const u8) *const c.Value {
    if (s.len == 0) {
        if (c.v8__Global__Get(&str_empty_v8, isolate)) |v| return @ptrCast(v);
    }
    return zigStringToV8(isolate, s);
}
// Interned-field accessor: cached Global when the tag is a known variant,
// fresh string from the pool slice only for custom (.other) values.
fn typeToV8(isolate: ?*c.Isolate, d: *const ResponseData) *const c.Value {
    if (d.response_type != .other) {
        if (c.v8__Global__Get(&type_strs[@intFromEnum(d.response_type)], isolate)) |v| return @ptrCast(v);
    }
    return zigStringToV8(isolate, d.responseType());
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
fn extractIntFromVal(isolate: ?*c.Isolate, context: ?*c.Context, val: ?*const c.Value, default: u16) u16 {
    _ = isolate;
    const v = val orelse return default;
    if (c.v8__Value__IsUndefined(v) or c.v8__Value__IsNull(v)) return default;
    var out: c.MaybeI32 = undefined;
    c.v8__Value__Int32Value(v, context, &out);
    return @intCast(out.value);
}
// ============================================================
// Interning — spec-constrained Response.type as a dense enum
// ============================================================
pub const ResponseType = enum(u8) {
    basic,
    cors,
    default,
    err,
    opaque_type,
    opaqueredirect,
    other,
    pub fn fromSlice(s: []const u8) ResponseType {
        if (std.mem.eql(u8, s, "basic")) return .basic;
        if (std.mem.eql(u8, s, "cors")) return .cors;
        if (std.mem.eql(u8, s, "default")) return .default;
        if (std.mem.eql(u8, s, "error")) return .err;
        if (std.mem.eql(u8, s, "opaque")) return .opaque_type;
        if (std.mem.eql(u8, s, "opaqueredirect")) return .opaqueredirect;
        return .other;
    }
    pub fn string(self: ResponseType) []const u8 {
        return switch (self) {
            .basic => "basic",
            .cors => "cors",
            .default => "default",
            .err => "error",
            .opaque_type => "opaque",
            .opaqueredirect => "opaqueredirect",
            .other => unreachable,
        };
    }
};
// ============================================================
// ResponseData — DOD: contiguous string pool + interned scalars
// ============================================================
const PoolSlice = struct { off: usize = 0, len: usize = 0 };
pub const ResponseData = struct {
    pool: std.ArrayList(u8),
    status: u16,
    status_text: PoolSlice,
    headers: headers_mod.HeadersData,
    _body: PoolSlice,
    owned_body: ?[]u8 = null,
    has_body: bool,
    body_used: bool,
    _url: PoolSlice,
    redirected: bool,
    response_type: ResponseType,
    response_type_other: PoolSlice,
    pub fn init() ResponseData {
        var self = ResponseData{
            .pool = std.ArrayList(u8).empty,
            .status = 200,
            .status_text = .{},
            .headers = headers_mod.HeadersData.init(),
            ._body = .{},
            .has_body = false,
            .body_used = false,
            ._url = .{},
            .redirected = false,
            .response_type = .basic,
            .response_type_other = .{},
        };
        self.storeString("OK", &self.status_text);
        return self;
    }
    pub fn deinit(self: *ResponseData) void {
        if (self.owned_body) |b| gpa.free(b);
        self.pool.deinit(gpa);
        self.headers.deinit();
    }
    pub fn statusText(self: *const ResponseData) []const u8 {
        return self.pool.items[self.status_text.off .. self.status_text.off + self.status_text.len];
    }
    pub fn body(self: *const ResponseData) ?[]const u8 {
        if (!self.has_body) return null;
        if (self.owned_body) |b| return b;
        return self.pool.items[self._body.off .. self._body.off + self._body.len];
    }
    pub fn url(self: *const ResponseData) []const u8 {
        return self.pool.items[self._url.off .. self._url.off + self._url.len];
    }
    pub fn responseType(self: *const ResponseData) []const u8 {
        if (self.response_type == .other) {
            return self.pool.items[self.response_type_other.off .. self.response_type_other.off + self.response_type_other.len];
        }
        return self.response_type.string();
    }
    fn storeString(self: *ResponseData, s: []const u8, dst: *PoolSlice) void {
        if (s.len == 0) {
            dst.* = .{};
            return;
        }
        const off = self.pool.items.len;
        self.pool.appendSlice(gpa, s) catch return;
        dst.* = .{ .off = off, .len = s.len };
    }
    pub fn setStatusText(self: *ResponseData, s: []const u8) void {
        self.storeString(s, &self.status_text);
    }
    pub fn setBodyOwned(self: *ResponseData, b: []u8) void {
        if (self.owned_body) |old| gpa.free(old);
        self.has_body = b.len > 0;
        if (b.len > 0) {
            self.owned_body = b;
            self._body = .{};
        } else {
            self.owned_body = null;
        }
    }
    pub fn setBody(self: *ResponseData, s: ?[]const u8) void {
        if (self.owned_body) |old| gpa.free(old);
        self.owned_body = null;
        if (s) |b| {
            self.has_body = b.len > 0;
            self.storeString(b, &self._body);
        } else {
            self.has_body = false;
        }
    }
    pub fn setUrl(self: *ResponseData, s: []const u8) void {
        self.storeString(s, &self._url);
    }
    pub fn setResponseType(self: *ResponseData, s: []const u8) void {
        const t = ResponseType.fromSlice(s);
        self.response_type = t;
        if (t == .other) self.storeString(s, &self.response_type_other);
    }
    pub fn cloneFrom(self: *ResponseData, src: *const ResponseData) void {
        self.pool.appendSlice(gpa, src.pool.items) catch {};
        self.status = src.status;
        self.status_text = src.status_text;
        self._body = src._body;
        self.has_body = src.has_body;
        self.body_used = false;
        self._url = src._url;
        self.redirected = src.redirected;
        self.response_type = src.response_type;
        self.response_type_other = src.response_type_other;
        self.owned_body = if (src.owned_body) |b| gpa.dupe(u8, b) catch null else null;
        for (0..src.headers.len()) |i| {
            const p = src.headers.getPair(i);
            self.headers.appendEntry(p.name, p.value);
        }
    }
};
// ============================================================
// Extract ResponseData from JS this.__d
// ============================================================
fn extractResponseData(info: ?*const c.FunctionCallbackInfo) ?*ResponseData {
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
// Build Headers JS object (cached)
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
// JS Callbacks — Instance body methods
// ============================================================
fn responseText(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractResponseData(info) orelse {
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
    refreshBodyUsed(isolate, context, c.v8__FunctionCallbackInfo__This(info), true);
    const body_text = data.body() orelse "";
    var out: c.MaybeBool = undefined;
    _ = c.v8__Promise__Resolver__Resolve(resolver, context, @ptrCast(zigStringToV8(isolate, body_text)), &out);
    c.v8__ReturnValue__Set(ret, @ptrCast(promise));
}
fn responseJson(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractResponseData(info) orelse {
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
    refreshBodyUsed(isolate, context, c.v8__FunctionCallbackInfo__This(info), true);
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
fn responseArrayBuffer(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractResponseData(info) orelse {
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
    refreshBodyUsed(isolate, context, c.v8__FunctionCallbackInfo__This(info), true);
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
fn responseBlob(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
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
fn responseFormData(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
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
fn responseBytes(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractResponseData(info) orelse {
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
    refreshBodyUsed(isolate, context, c.v8__FunctionCallbackInfo__This(info), true);
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
fn responseClone(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractResponseData(info) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));
        return;
    };
    const new_data = gpa.create(ResponseData) catch {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));
        return;
    };
    new_data.* = ResponseData.init();
    new_data.cloneFrom(data);
    const obj = buildResponseJSObject(isolate, context, new_data);
    if (obj) |o| c.v8__ReturnValue__Set(ret, @ptrCast(o));
}
// ============================================================
// JS Callbacks — Static methods
// ============================================================
fn responseStaticJson(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    var scratch: [256]u8 = undefined;
    const data = gpa.create(ResponseData) catch {
        throw(isolate, "out of memory");
        return;
    };
    data.* = ResponseData.init();
    if (c.v8__FunctionCallbackInfo__Length(info) > 0) {
        const arg0 = c.v8__FunctionCallbackInfo__INDEX(info, 0);
        const json_str = c.v8__JSON__Stringify(context, arg0, null);
        if (json_str != null) {
            if (extractStringAuto(isolate, json_str, &scratch)) |owned| {
                defer owned.deinit();
                data.setBody(owned.slice);
            }
        }
        data.headers.appendEntry("content-type", "application/json");
    }
    if (c.v8__FunctionCallbackInfo__Length(info) > 1) {
        const init_val = c.v8__FunctionCallbackInfo__INDEX(info, 1);
        if (c.v8__Value__IsObject(init_val)) {
            const status_val = c.v8__Object__Get(@ptrCast(init_val), context, @ptrCast(c.v8__Global__Get(&str_status, isolate)));
            data.status = extractIntFromVal(isolate, context, status_val, 200);
            const status_text_val = c.v8__Object__Get(@ptrCast(init_val), context, @ptrCast(c.v8__Global__Get(&str_statusText, isolate)));
            if (extractStringAuto(isolate, status_text_val, &scratch)) |st| {
                defer st.deinit();
                data.setStatusText(st.slice);
            }
            parseHeadersInitFromObj(isolate, context, init_val, &data.headers);
        }
    }
    const obj = buildResponseJSObject(isolate, context, data);
    if (obj) |o| c.v8__ReturnValue__Set(ret, @ptrCast(o));
}
fn responseStaticRedirect(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    if (c.v8__FunctionCallbackInfo__Length(info) < 1) {
        throwTypeError(isolate, "Response.redirect requires a URL");
        return;
    }
    var url_buf: [512]u8 = undefined;
    const data = gpa.create(ResponseData) catch {
        throw(isolate, "out of memory");
        return;
    };
    data.* = ResponseData.init();
    const url_val = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    if (extractStringAuto(isolate, url_val, &url_buf)) |u| {
        defer u.deinit();
        data.setUrl(u.slice);
    }
    data.status = 302;
    data.setStatusText("Found");
    data.redirected = true;
    if (c.v8__FunctionCallbackInfo__Length(info) > 1) {
        const status_val = c.v8__FunctionCallbackInfo__INDEX(info, 1);
        data.status = extractIntFromVal(isolate, context, status_val, 302);
    }
    const obj = buildResponseJSObject(isolate, context, data);
    if (obj) |o| c.v8__ReturnValue__Set(ret, @ptrCast(o));
}
fn responseStaticError(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = gpa.create(ResponseData) catch {
        throw(isolate, "out of memory");
        return;
    };
    data.* = ResponseData.init();
    data.status = 0;
    data.setStatusText("");
    data.setResponseType("error");
    const obj = buildResponseJSObject(isolate, context, data);
    if (obj) |o| c.v8__ReturnValue__Set(ret, @ptrCast(o));
}
// ============================================================
// Helper: set scalar data properties + cached functions
// ============================================================
fn setDataProps(obj: ?*const c.Object, context: ?*c.Context, isolate: ?*c.Isolate, data: *ResponseData) void {
    var out: c.MaybeBool = undefined;
    const body_used = if (data.body_used) c.v8__True(isolate) else c.v8__False(isolate);
    c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(&str_bodyUsed, isolate)), @ptrCast(body_used), &out);
    const ok = if (data.status >= 200 and data.status <= 299) c.v8__True(isolate) else c.v8__False(isolate);
    c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(&str_ok, isolate)), @ptrCast(ok), &out);
    const redirected = if (data.redirected) c.v8__True(isolate) else c.v8__False(isolate);
    c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(&str_redirected, isolate)), @ptrCast(redirected), &out);
    c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(&str_status, isolate)), @ptrCast(c.v8__Integer__NewFromUnsigned(isolate, data.status)), &out);
    c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(&str_statusText, isolate)), @ptrCast(emptyOrStringToV8(isolate, data.statusText())), &out);
    c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(&str_url, isolate)), @ptrCast(emptyOrStringToV8(isolate, data.url())), &out);
    c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(&str_type, isolate)), @ptrCast(typeToV8(isolate, data)), &out);
}
fn refreshBodyUsed(isolate: ?*c.Isolate, context: ?*c.Context, this_val: ?*const c.Value, value: bool) void {
    if (this_val == null) return;
    var out: c.MaybeBool = undefined;
    const bv = if (value) c.v8__True(isolate) else c.v8__False(isolate);
    c.v8__Object__Set(@ptrCast(this_val), context, @ptrCast(c.v8__Global__Get(&str_bodyUsed, isolate)), @ptrCast(bv), &out);
}
fn setCachedFns(obj: ?*const c.Object, context: ?*c.Context, isolate: ?*c.Isolate) void {
    var out: c.MaybeBool = undefined;
    const pairs = .{
        .{ &fn_text, &str_text },               .{ &fn_json, &str_json },
        .{ &fn_arrayBuffer, &str_arrayBuffer }, .{ &fn_blob, &str_blob },
        .{ &fn_formData, &str_formData },       .{ &fn_bytes, &str_bytes },
        .{ &fn_clone, &str_clone },
    };
    inline for (pairs) |pair| {
        c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(pair[1], isolate)), @ptrCast(c.v8__Global__Get(pair[0], isolate)), &out);
    }
}
// ============================================================
// buildResponseJSObject (cached)
// ============================================================
pub fn buildResponseJSObject(isolate: ?*c.Isolate, context: ?*c.Context, data: *ResponseData) ?*const c.Object {
    const obj = c.v8__Object__New(isolate);
    const ext = c.v8__External__New(isolate, @ptrCast(data));
    var out: c.MaybeBool = undefined;
    c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(&str___d, isolate)), ext, &out);
    const headers_obj = createHeadersJSObject(isolate, context, &data.headers);
    c.v8__Object__Set(obj, context, @ptrCast(c.v8__Global__Get(&str_headers, isolate)), @ptrCast(headers_obj), &out);
    setDataProps(obj, context, isolate, data);
    setCachedFns(obj, context, isolate);
    return obj;
}
// ============================================================
// Constructor: new Response(body?, init?)
// ============================================================
fn responseConstructor(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    var body_buf: [512]u8 = undefined;
    var scratch: [128]u8 = undefined;
    const data = gpa.create(ResponseData) catch {
        throw(isolate, "out of memory");
        return;
    };
    data.* = ResponseData.init();
    if (c.v8__FunctionCallbackInfo__Length(info) > 0) {
        const body_val = c.v8__FunctionCallbackInfo__INDEX(info, 0);
        if (!c.v8__Value__IsUndefined(body_val) and !c.v8__Value__IsNull(body_val)) {
            if (extractStringAuto(isolate, body_val, &body_buf)) |owned| {
                defer owned.deinit();
                data.setBody(owned.slice);
            }
        }
    }
    if (c.v8__FunctionCallbackInfo__Length(info) > 1) {
        const init_val = c.v8__FunctionCallbackInfo__INDEX(info, 1);
        if (c.v8__Value__IsObject(init_val)) {
            const status_val = c.v8__Object__Get(@ptrCast(init_val), context, @ptrCast(c.v8__Global__Get(&str_status, isolate)));
            data.status = extractIntFromVal(isolate, context, status_val, 200);
            const status_text_val = c.v8__Object__Get(@ptrCast(init_val), context, @ptrCast(c.v8__Global__Get(&str_statusText, isolate)));
            if (extractStringAuto(isolate, status_text_val, &scratch)) |st| {
                defer st.deinit();
                data.setStatusText(st.slice);
            }
            parseHeadersInitFromObj(isolate, context, init_val, &data.headers);
        }
    }
    const obj = buildResponseJSObject(isolate, context, data);
    if (obj) |o| c.v8__ReturnValue__Set(ret, @ptrCast(o));
}
// ============================================================
// Setup
// ============================================================
pub fn setup(isolate: ?*c.Isolate, context: ?*c.Context) void {
    var hs: c.HandleScope = undefined;
    c.v8__HandleScope__CONSTRUCT(&hs, isolate);
    defer c.v8__HandleScope__DESTRUCT(&hs);
    const global = c.v8__Context__Global(context);
    var out: c.MaybeBool = undefined;
    // Cache strings
    const strings = .{
        .{ "__d", &str___d },       .{ "headers", &str_headers },   .{ "bodyUsed", &str_bodyUsed },
        .{ "ok", &str_ok },         .{ "status", &str_status },      .{ "statusText", &str_statusText },
        .{ "url", &str_url },       .{ "type", &str_type },          .{ "redirected", &str_redirected },
        .{ "text", &str_text },     .{ "json", &str_json },          .{ "arrayBuffer", &str_arrayBuffer },
        .{ "blob", &str_blob },     .{ "formData", &str_formData },  .{ "bytes", &str_bytes },
        .{ "clone", &str_clone },
    };
    inline for (strings) |entry| {
        c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, entry[0], 0, -1)), entry[1]);
    }
    // Cache functions
    const funcs = .{
        .{ responseText, &fn_text },                 .{ responseJson, &fn_json },
        .{ responseArrayBuffer, &fn_arrayBuffer },   .{ responseBlob, &fn_blob },
        .{ responseFormData, &fn_formData },         .{ responseBytes, &fn_bytes },
        .{ responseClone, &fn_clone },
    };
    inline for (funcs) |entry| {
        c.v8__Global__New(isolate, @ptrCast(c.v8__Function__New__DEFAULT(context, entry[0])), entry[1]);
    }
    // Cache headers strings
    const h_strings = .{
        .{ "__d", &h_str___d },   .{ "get", &h_str_get },   .{ "getAll", &h_str_getAll },
        .{ "has", &h_str_has },   .{ "set", &h_str_set },   .{ "append", &h_str_append },
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
    // Interned ResponseType variant strings (one per non-"other" variant).
    inline for (std.enums.values(ResponseType)) |rt| {
        if (rt != .other) {
            const s = rt.string();
            c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, @ptrCast(s.ptr), 0, @intCast(s.len))), &type_strs[@intFromEnum(rt)]);
        }
    }
    // Shared empty-string Global for zero-length url/statusText fast paths.
    c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, "", 0, -1)), &str_empty_v8);
    // Register Response constructor + static methods
    const constructor = c.v8__Function__New__DEFAULT(context, responseConstructor);
    const ctor_obj: *const c.Object = @ptrCast(constructor);
    const json_fn = c.v8__Function__New__DEFAULT(context, responseStaticJson);
    _ = c.v8__Object__Set(ctor_obj, context, c.v8__String__NewFromUtf8(isolate, "json", 0, -1), @ptrCast(json_fn), &out);
    const redirect_fn = c.v8__Function__New__DEFAULT(context, responseStaticRedirect);
    _ = c.v8__Object__Set(ctor_obj, context, c.v8__String__NewFromUtf8(isolate, "redirect", 0, -1), @ptrCast(redirect_fn), &out);
    const error_fn = c.v8__Function__New__DEFAULT(context, responseStaticError);
    _ = c.v8__Object__Set(ctor_obj, context, c.v8__String__NewFromUtf8(isolate, "error", 0, -1), @ptrCast(error_fn), &out);
    _ = c.v8__Object__Set(global, context, c.v8__String__NewFromUtf8(isolate, "Response", 0, -1), constructor, &out);
}
