const std = @import("std");
const c = @import("../c.zig").c;
const headers_mod = @import("headers.zig");

const gpa = std.heap.page_allocator;

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

fn extractStringFromVal(isolate: ?*c.Isolate, val: ?*const c.Value) ?[:0]const u8 {
    const v = val orelse return null;
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    const str = c.v8__Value__ToDetailString(v, context);
    if (str == null) return null;
    const utf8_len: usize = @intCast(c.v8__String__Utf8Length(str, isolate));
    var buf: [8192]u8 = undefined;
    const len = @min(utf8_len, buf.len);
    _ = c.v8__String__WriteUtf8(str, isolate, &buf, @intCast(len), 0);
    return gpa.dupeZ(u8, buf[0..len]) catch null;
}

// ============================================================
// RequestData — pure Zig, no V8 types
// ============================================================

pub const RequestData = struct {
    url: []const u8,
    method: []const u8,
    headers: headers_mod.HeadersData,
    body: ?[]const u8,
    body_used: bool,
    cache: []const u8,
    credentials: []const u8,
    mode: []const u8,
    redirect: []const u8,
    integrity: []const u8,
    keepalive: bool,

    pub fn init() RequestData {
        return .{
            .url = "",
            .method = "GET",
            .headers = headers_mod.HeadersData.init(),
            .body = null,
            .body_used = false,
            .cache = "default",
            .credentials = "same-origin",
            .mode = "cors",
            .redirect = "follow",
            .integrity = "",
            .keepalive = false,
        };
    }

    pub fn deinit(self: *RequestData) void {
        if (self.url.len > 0) gpa.free(self.url);
        if (self.method.len > 0 and !std.mem.eql(u8, self.method, "GET")) gpa.free(self.method);
        self.headers.deinit();
        if (self.body) |b| gpa.free(b);
        if (self.cache.len > 0 and !std.mem.eql(u8, self.cache, "default")) gpa.free(self.cache);
        if (self.credentials.len > 0 and !std.mem.eql(u8, self.credentials, "same-origin")) gpa.free(self.credentials);
        if (self.mode.len > 0 and !std.mem.eql(u8, self.mode, "cors")) gpa.free(self.mode);
        if (self.redirect.len > 0 and !std.mem.eql(u8, self.redirect, "follow")) gpa.free(self.redirect);
        if (self.integrity.len > 0) gpa.free(self.integrity);
    }

    pub fn cloneFrom(self: *RequestData, src: *const RequestData) void {
        self.url = gpa.dupe(u8, src.url) catch "";
        self.method = gpa.dupe(u8, src.method) catch "GET";
        for (src.headers.pairs.items) |pair| {
            self.headers.appendEntry(pair.name, pair.value);
        }
        self.body = if (src.body) |b| gpa.dupe(u8, b) catch null else null;
        self.body_used = false;
        self.cache = if (std.mem.eql(u8, src.cache, "default")) "default" else (gpa.dupe(u8, src.cache) catch "default");
        self.credentials = if (std.mem.eql(u8, src.credentials, "same-origin")) "same-origin" else (gpa.dupe(u8, src.credentials) catch "same-origin");
        self.mode = if (std.mem.eql(u8, src.mode, "cors")) "cors" else (gpa.dupe(u8, src.mode) catch "cors");
        self.redirect = if (std.mem.eql(u8, src.redirect, "follow")) "follow" else (gpa.dupe(u8, src.redirect) catch "follow");
        self.integrity = if (src.integrity.len > 0) (gpa.dupe(u8, src.integrity) catch "") else "";
        self.keepalive = src.keepalive;
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
    const data_key = c.v8__String__NewFromUtf8(isolate, "__d", 0, -1);
    const ext_val = c.v8__Object__Get(@ptrCast(this), context, data_key);
    if (ext_val == null or !c.v8__Value__IsExternal(ext_val)) return null;
    const ptr = c.v8__External__Value(@ptrCast(ext_val));
    return @ptrCast(@alignCast(ptr));
}

// ============================================================
// Build a Headers JS object from HeadersData
// ============================================================

fn createHeadersJSObject(isolate: ?*c.Isolate, context: ?*c.Context, hdr_data: *headers_mod.HeadersData) ?*const c.Value {
    const obj = c.v8__Object__New(isolate);
    const ext = c.v8__External__New(isolate, @ptrCast(hdr_data));
    var out: c.MaybeBool = undefined;
    c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, "__d", 0, -1), ext, &out);

    const fns = .{
        .{ "get", headersGetStub },
        .{ "getAll", headersGetAllStub },
        .{ "has", headersHasStub },
        .{ "set", headersSetStub },
        .{ "append", headersAppendStub },
        .{ "delete", headersDeleteStub },
        .{ "entries", headersEntriesStub },
        .{ "keys", headersKeysStub },
        .{ "values", headersValuesStub },
        .{ "forEach", headersForEachStub },
        .{ "toString", headersToStringStub },
        .{ "size", headersSizeStub },
    };
    inline for (fns) |entry| {
        const fn_val = c.v8__Function__New__DEFAULT(context, entry[1]);
        c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, entry[0], 0, -1), fn_val, &out);
    }
    return obj;
}

// ============================================================
// Headers stubs — delegate to headers.zig functions
// ============================================================

fn headersGetStub(info: ?*const c.FunctionCallbackInfo) callconv(.c) void { headers_mod.headersGet(info); }
fn headersGetAllStub(info: ?*const c.FunctionCallbackInfo) callconv(.c) void { headers_mod.headersGetAll(info); }
fn headersHasStub(info: ?*const c.FunctionCallbackInfo) callconv(.c) void { headers_mod.headersHas(info); }
fn headersSetStub(info: ?*const c.FunctionCallbackInfo) callconv(.c) void { headers_mod.headersSet(info); }
fn headersAppendStub(info: ?*const c.FunctionCallbackInfo) callconv(.c) void { headers_mod.headersAppend(info); }
fn headersDeleteStub(info: ?*const c.FunctionCallbackInfo) callconv(.c) void { headers_mod.headersDelete(info); }
fn headersEntriesStub(info: ?*const c.FunctionCallbackInfo) callconv(.c) void { headers_mod.headersEntries(info); }
fn headersKeysStub(info: ?*const c.FunctionCallbackInfo) callconv(.c) void { headers_mod.headersKeys(info); }
fn headersValuesStub(info: ?*const c.FunctionCallbackInfo) callconv(.c) void { headers_mod.headersValues(info); }
fn headersForEachStub(info: ?*const c.FunctionCallbackInfo) callconv(.c) void { headers_mod.headersForEach(info); }
fn headersToStringStub(info: ?*const c.FunctionCallbackInfo) callconv(.c) void { headers_mod.headersToString(info); }
fn headersSizeStub(info: ?*const c.FunctionCallbackInfo) callconv(.c) void { headers_mod.headersSize(info); }

// ============================================================
// Headers init parsing (reused from constructor logic)
// ============================================================

fn parseHeadersInit(isolate: ?*c.Isolate, context: ?*c.Context, init_val: ?*const c.Value, target: *headers_mod.HeadersData) void {
    if (init_val == null) return;
    if (c.v8__Value__IsUndefined(init_val) or c.v8__Value__IsNull(init_val)) return;

    if (c.v8__Value__IsObject(init_val)) {
        const data_key = c.v8__String__NewFromUtf8(isolate, "__d", 0, -1);
        const ext_val = c.v8__Object__Get(@ptrCast(init_val), context, data_key);
        if (ext_val != null and c.v8__Value__IsExternal(ext_val)) {
            const src: *headers_mod.HeadersData = @ptrCast(@alignCast(c.v8__External__Value(@ptrCast(ext_val))));
            for (src.pairs.items) |pair| target.appendEntry(pair.name, pair.value);
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

        // Plain object
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
    const headers_val = c.v8__Object__Get(@ptrCast(init_obj), context, c.v8__String__NewFromUtf8(isolate, "headers", 0, -1));
    if (headers_val != null and !c.v8__Value__IsUndefined(headers_val) and !c.v8__Value__IsNull(headers_val)) {
        parseHeadersInit(isolate, context, headers_val, target);
    }
}

// ============================================================
// JS Callbacks — Property getters
// ============================================================

fn requestBodyUsed(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractRequestData(info) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__False(isolate)));
        return;
    };
    c.v8__ReturnValue__Set(ret, if (data.body_used) @ptrCast(c.v8__True(isolate)) else @ptrCast(c.v8__False(isolate)));
}

fn requestCache(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractRequestData(info) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(zigStringToV8(isolate, "default")));
        return;
    };
    c.v8__ReturnValue__Set(ret, @ptrCast(zigStringToV8(isolate, data.cache)));
}

fn requestCredentials(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractRequestData(info) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(zigStringToV8(isolate, "same-origin")));
        return;
    };
    c.v8__ReturnValue__Set(ret, @ptrCast(zigStringToV8(isolate, data.credentials)));
}

fn requestMode(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractRequestData(info) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(zigStringToV8(isolate, "cors")));
        return;
    };
    c.v8__ReturnValue__Set(ret, @ptrCast(zigStringToV8(isolate, data.mode)));
}

fn requestRedirect(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractRequestData(info) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(zigStringToV8(isolate, "follow")));
        return;
    };
    c.v8__ReturnValue__Set(ret, @ptrCast(zigStringToV8(isolate, data.redirect)));
}

fn requestIntegrity(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractRequestData(info) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(zigStringToV8(isolate, "")));
        return;
    };
    c.v8__ReturnValue__Set(ret, @ptrCast(zigStringToV8(isolate, data.integrity)));
}

fn requestKeepalive(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractRequestData(info) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__False(isolate)));
        return;
    };
    c.v8__ReturnValue__Set(ret, if (data.keepalive) @ptrCast(c.v8__True(isolate)) else @ptrCast(c.v8__False(isolate)));
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
    const body_text = data.body orelse "";
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
    const body_text = data.body orelse "";
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
    const body_bytes = data.body orelse "";
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
    const body_bytes = data.body orelse "";
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
    c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, "__d", 0, -1), ext, &out);

    _ = c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, "url", 0, -1), @ptrCast(zigStringToV8(isolate, new_data.url)), &out);
    _ = c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, "method", 0, -1), @ptrCast(zigStringToV8(isolate, new_data.method)), &out);
    const headers_obj = createHeadersJSObject(isolate, context, &new_data.headers);
    _ = c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, "headers", 0, -1), @ptrCast(headers_obj), &out);

    const fns = .{
        .{ "bodyUsed", requestBodyUsed },
        .{ "cache", requestCache },
        .{ "credentials", requestCredentials },
        .{ "mode", requestMode },
        .{ "redirect", requestRedirect },
        .{ "integrity", requestIntegrity },
        .{ "keepalive", requestKeepalive },
        .{ "text", requestText },
        .{ "json", requestJson },
        .{ "arrayBuffer", requestArrayBuffer },
        .{ "blob", requestBlob },
        .{ "formData", requestFormData },
        .{ "bytes", requestBytes },
        .{ "clone", requestClone },
        .{ "toString", requestToString },
        .{ "toJSON", requestToJSON },
    };
    inline for (fns) |entry| {
        const fn_val = c.v8__Function__New__DEFAULT(context, entry[1]);
        c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, entry[0], 0, -1), fn_val, &out);
    }

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
    c.v8__ReturnValue__Set(ret, @ptrCast(zigStringToV8(isolate, data.url)));
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
    _ = c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, "url", 0, -1), @ptrCast(zigStringToV8(isolate, data.url)), &out);
    _ = c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, "method", 0, -1), @ptrCast(zigStringToV8(isolate, data.method)), &out);
    c.v8__ReturnValue__Set(ret, @ptrCast(obj));
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

    const arg0 = c.v8__FunctionCallbackInfo__INDEX(info, 0);

    if (c.v8__Value__IsString(arg0)) {
        const url = extractStringFromVal(isolate, arg0) orelse "";
        data.url = url;
    } else if (c.v8__Value__IsObject(arg0)) {
        const data_key = c.v8__String__NewFromUtf8(isolate, "__d", 0, -1);
        const ext_val = c.v8__Object__Get(@ptrCast(arg0), context, data_key);
        if (ext_val != null and c.v8__Value__IsExternal(ext_val)) {
            const src: *RequestData = @ptrCast(@alignCast(c.v8__External__Value(@ptrCast(ext_val))));
            data.deinit();
            data.* = RequestData.init();
            data.cloneFrom(src);
        } else {
            const url_val = c.v8__Object__Get(@ptrCast(arg0), context, c.v8__String__NewFromUtf8(isolate, "url", 0, -1));
            data.url = extractStringFromVal(isolate, url_val) orelse "";
        }
    } else {
        throwTypeError(isolate, "Request requires a URL string or Request object as first argument");
        gpa.destroy(data);
        return;
    }

    if (c.v8__FunctionCallbackInfo__Length(info) > 1) {
        const init_val = c.v8__FunctionCallbackInfo__INDEX(info, 1);
        if (c.v8__Value__IsObject(init_val)) {
            const method_val = c.v8__Object__Get(@ptrCast(init_val), context, c.v8__String__NewFromUtf8(isolate, "method", 0, -1));
            if (method_val != null and !c.v8__Value__IsUndefined(method_val)) {
                if (extractStringFromVal(isolate, method_val)) |m| {
                    gpa.free(data.method);
                    data.method = m;
                }
            }

            parseHeadersInitFromObj(isolate, context, init_val, &data.headers);

            const body_val = c.v8__Object__Get(@ptrCast(init_val), context, c.v8__String__NewFromUtf8(isolate, "body", 0, -1));
            if (body_val != null and !c.v8__Value__IsUndefined(body_val) and !c.v8__Value__IsNull(body_val)) {
                data.body = extractStringFromVal(isolate, body_val);
            }

            const cache_val = c.v8__Object__Get(@ptrCast(init_val), context, c.v8__String__NewFromUtf8(isolate, "cache", 0, -1));
            if (extractStringFromVal(isolate, cache_val)) |c_val| {
                gpa.free(data.cache);
                data.cache = c_val;
            }

            const cred_val = c.v8__Object__Get(@ptrCast(init_val), context, c.v8__String__NewFromUtf8(isolate, "credentials", 0, -1));
            if (extractStringFromVal(isolate, cred_val)) |c_val| {
                gpa.free(data.credentials);
                data.credentials = c_val;
            }

            const mode_val = c.v8__Object__Get(@ptrCast(init_val), context, c.v8__String__NewFromUtf8(isolate, "mode", 0, -1));
            if (extractStringFromVal(isolate, mode_val)) |m_val| {
                gpa.free(data.mode);
                data.mode = m_val;
            }

            const redir_val = c.v8__Object__Get(@ptrCast(init_val), context, c.v8__String__NewFromUtf8(isolate, "redirect", 0, -1));
            if (extractStringFromVal(isolate, redir_val)) |r_val| {
                gpa.free(data.redirect);
                data.redirect = r_val;
            }

            const integ_val = c.v8__Object__Get(@ptrCast(init_val), context, c.v8__String__NewFromUtf8(isolate, "integrity", 0, -1));
            if (extractStringFromVal(isolate, integ_val)) |i_val| {
                gpa.free(data.integrity);
                data.integrity = i_val;
            }

            const keep_val = c.v8__Object__Get(@ptrCast(init_val), context, c.v8__String__NewFromUtf8(isolate, "keepalive", 0, -1));
            if (keep_val != null and c.v8__Value__IsTrue(keep_val)) data.keepalive = true;
        }
    }

    const obj = c.v8__Object__New(isolate);
    const ext = c.v8__External__New(isolate, @ptrCast(data));
    var out: c.MaybeBool = undefined;
    c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, "__d", 0, -1), ext, &out);

    const url_prop = c.v8__String__NewFromUtf8(isolate, "url", 0, -1);
    _ = c.v8__Object__Set(obj, context, url_prop, @ptrCast(zigStringToV8(isolate, data.url)), &out);

    const method_prop = c.v8__String__NewFromUtf8(isolate, "method", 0, -1);
    _ = c.v8__Object__Set(obj, context, method_prop, @ptrCast(zigStringToV8(isolate, data.method)), &out);

    const headers_obj = createHeadersJSObject(isolate, context, &data.headers);
    const headers_prop = c.v8__String__NewFromUtf8(isolate, "headers", 0, -1);
    _ = c.v8__Object__Set(obj, context, headers_prop, @ptrCast(headers_obj), &out);

    const fns = .{
        .{ "bodyUsed", requestBodyUsed },
        .{ "cache", requestCache },
        .{ "credentials", requestCredentials },
        .{ "mode", requestMode },
        .{ "redirect", requestRedirect },
        .{ "integrity", requestIntegrity },
        .{ "keepalive", requestKeepalive },
        .{ "text", requestText },
        .{ "json", requestJson },
        .{ "arrayBuffer", requestArrayBuffer },
        .{ "blob", requestBlob },
        .{ "formData", requestFormData },
        .{ "bytes", requestBytes },
        .{ "clone", requestClone },
        .{ "toString", requestToString },
        .{ "toJSON", requestToJSON },
    };
    inline for (fns) |entry| {
        const fn_val = c.v8__Function__New__DEFAULT(context, entry[1]);
        c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, entry[0], 0, -1), fn_val, &out);
    }

    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(obj));
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

    const fn_val = c.v8__Function__New__DEFAULT(context, requestConstructor);
    const key = c.v8__String__NewFromUtf8(isolate, "Request", 0, -1);
    _ = c.v8__Object__Set(global, context, key, fn_val, &out);
}
