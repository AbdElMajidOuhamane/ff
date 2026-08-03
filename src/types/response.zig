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

fn extractIntFromVal(isolate: ?*c.Isolate, context: ?*c.Context, val: ?*const c.Value, default: u16) u16 {
    _ = isolate;
    const v = val orelse return default;
    if (c.v8__Value__IsUndefined(v) or c.v8__Value__IsNull(v)) return default;
    var out: c.MaybeI32 = undefined;
    c.v8__Value__Int32Value(v, context, &out);
    return @intCast(out.value);
}

// ============================================================
// ResponseData — pure Zig, no V8 types
// ============================================================

pub const ResponseData = struct {
    status: u16,
    status_text: []const u8,
    headers: headers_mod.HeadersData,
    body: ?[]const u8,
    body_used: bool,
    url: []const u8,
    redirected: bool,
    response_type: []const u8,

    pub fn init() ResponseData {
        return .{
            .status = 200,
            .status_text = "OK",
            .headers = headers_mod.HeadersData.init(),
            .body = null,
            .body_used = false,
            .url = "",
            .redirected = false,
            .response_type = "basic",
        };
    }

    pub fn deinit(self: *ResponseData) void {
        self.headers.deinit();
        if (self.body) |b| gpa.free(b);
        if (self.status_text.len > 0 and !std.mem.eql(u8, self.status_text, "OK")) gpa.free(self.status_text);
        if (self.url.len > 0) gpa.free(self.url);
        if (self.response_type.len > 0 and !std.mem.eql(u8, self.response_type, "basic")) gpa.free(self.response_type);
    }

    pub fn cloneFrom(self: *ResponseData, src: *const ResponseData) void {
        self.status = src.status;
        self.status_text = if (std.mem.eql(u8, src.status_text, "OK")) "OK" else (gpa.dupe(u8, src.status_text) catch "OK");
        for (src.headers.pairs.items) |pair| {
            self.headers.appendEntry(pair.name, pair.value);
        }
        self.body = if (src.body) |b| gpa.dupe(u8, b) catch null else null;
        self.body_used = false;
        self.url = if (src.url.len > 0) (gpa.dupe(u8, src.url) catch "") else "";
        self.redirected = src.redirected;
        self.response_type = if (std.mem.eql(u8, src.response_type, "basic")) "basic" else (gpa.dupe(u8, src.response_type) catch "basic");
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
// Headers stubs
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
// Headers init parsing
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
// JS Callbacks — Instance property functions
// ============================================================

fn responseBodyUsed(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractResponseData(info) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__False(isolate)));
        return;
    };
    c.v8__ReturnValue__Set(ret, if (data.body_used) @ptrCast(c.v8__True(isolate)) else @ptrCast(c.v8__False(isolate)));
}

fn responseOk(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractResponseData(info) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__False(isolate)));
        return;
    };
    c.v8__ReturnValue__Set(ret, if (data.status >= 200 and data.status <= 299) @ptrCast(c.v8__True(isolate)) else @ptrCast(c.v8__False(isolate)));
}

fn responseStatus(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractResponseData(info) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Integer__NewFromUnsigned(isolate, 0)));
        return;
    };
    c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Integer__NewFromUnsigned(isolate, data.status)));
}

fn responseStatusText(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractResponseData(info) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(zigStringToV8(isolate, "")));
        return;
    };
    c.v8__ReturnValue__Set(ret, @ptrCast(zigStringToV8(isolate, data.status_text)));
}

fn responseUrl(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractResponseData(info) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(zigStringToV8(isolate, "")));
        return;
    };
    c.v8__ReturnValue__Set(ret, @ptrCast(zigStringToV8(isolate, data.url)));
}

fn responseType(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractResponseData(info) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(zigStringToV8(isolate, "basic")));
        return;
    };
    c.v8__ReturnValue__Set(ret, @ptrCast(zigStringToV8(isolate, data.response_type)));
}

fn responseRedirected(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractResponseData(info) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__False(isolate)));
        return;
    };
    c.v8__ReturnValue__Set(ret, if (data.redirected) @ptrCast(c.v8__True(isolate)) else @ptrCast(c.v8__False(isolate)));
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
    const body_text = data.body orelse "";
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

    const data = gpa.create(ResponseData) catch {
        throw(isolate, "out of memory");
        return;
    };
    data.* = ResponseData.init();

    if (c.v8__FunctionCallbackInfo__Length(info) > 0) {
        const arg0 = c.v8__FunctionCallbackInfo__INDEX(info, 0);
        const json_str = c.v8__JSON__Stringify(context, arg0, null);
        if (json_str != null) {
            data.body = extractStringFromVal(isolate, json_str);
        }
        data.headers.appendEntry("content-type", "application/json");
    }

    if (c.v8__FunctionCallbackInfo__Length(info) > 1) {
        const init_val = c.v8__FunctionCallbackInfo__INDEX(info, 1);
        if (c.v8__Value__IsObject(init_val)) {
            const status_val = c.v8__Object__Get(@ptrCast(init_val), context, c.v8__String__NewFromUtf8(isolate, "status", 0, -1));
            data.status = extractIntFromVal(isolate, context, status_val, 200);
            const status_text_val = c.v8__Object__Get(@ptrCast(init_val), context, c.v8__String__NewFromUtf8(isolate, "statusText", 0, -1));
            if (extractStringFromVal(isolate, status_text_val)) |st| {
                data.status_text = st;
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

    const data = gpa.create(ResponseData) catch {
        throw(isolate, "out of memory");
        return;
    };
    data.* = ResponseData.init();

    const url_val = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    data.url = extractStringFromVal(isolate, url_val) orelse "";
    data.status = 302;
    data.status_text = "Found";
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
    data.status_text = "";
    data.response_type = "error";

    const obj = buildResponseJSObject(isolate, context, data);
    if (obj) |o| c.v8__ReturnValue__Set(ret, @ptrCast(o));
}

// ============================================================
// Helper: build JS object from ResponseData
// ============================================================

fn buildResponseJSObject(isolate: ?*c.Isolate, context: ?*c.Context, data: *ResponseData) ?*const c.Object {
    const obj = c.v8__Object__New(isolate);
    const ext = c.v8__External__New(isolate, @ptrCast(data));
    var out: c.MaybeBool = undefined;
    c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, "__d", 0, -1), ext, &out);

    const headers_obj = createHeadersJSObject(isolate, context, &data.headers);
    _ = c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, "headers", 0, -1), @ptrCast(headers_obj), &out);

    const fns = .{
        .{ "bodyUsed", responseBodyUsed },
        .{ "ok", responseOk },
        .{ "status", responseStatus },
        .{ "statusText", responseStatusText },
        .{ "url", responseUrl },
        .{ "type", responseType },
        .{ "redirected", responseRedirected },
        .{ "text", responseText },
        .{ "json", responseJson },
        .{ "arrayBuffer", responseArrayBuffer },
        .{ "blob", responseBlob },
        .{ "formData", responseFormData },
        .{ "bytes", responseBytes },
        .{ "clone", responseClone },
    };
    inline for (fns) |entry| {
        const fn_val = c.v8__Function__New__DEFAULT(context, entry[1]);
        c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, entry[0], 0, -1), fn_val, &out);
    }

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

    const data = gpa.create(ResponseData) catch {
        throw(isolate, "out of memory");
        return;
    };
    data.* = ResponseData.init();

    if (c.v8__FunctionCallbackInfo__Length(info) > 0) {
        const body_val = c.v8__FunctionCallbackInfo__INDEX(info, 0);
        if (!c.v8__Value__IsUndefined(body_val) and !c.v8__Value__IsNull(body_val)) {
            data.body = extractStringFromVal(isolate, body_val);
        }
    }

    if (c.v8__FunctionCallbackInfo__Length(info) > 1) {
        const init_val = c.v8__FunctionCallbackInfo__INDEX(info, 1);
        if (c.v8__Value__IsObject(init_val)) {
            const status_val = c.v8__Object__Get(@ptrCast(init_val), context, c.v8__String__NewFromUtf8(isolate, "status", 0, -1));
            data.status = extractIntFromVal(isolate, context, status_val, 200);
            const status_text_val = c.v8__Object__Get(@ptrCast(init_val), context, c.v8__String__NewFromUtf8(isolate, "statusText", 0, -1));
            if (extractStringFromVal(isolate, status_text_val)) |st| {
                data.status_text = st;
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
