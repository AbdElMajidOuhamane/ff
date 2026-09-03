const std = @import("std");
const c = @import("../c.zig").c;
const headers_mod = @import("headers.zig");
const pool_slice_mod = @import("pool_slice.zig");
const gpa = std.heap.smp_allocator;

var response_class_id: c.ClassID = 0;

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

fn extractStringFromVal(ctx: ?*c.Context, val: c.Value) ?[:0]const u8 {
    var stack_buf: [256]u8 = undefined;
    const ex = extractStringAuto(ctx, val, &stack_buf) orelse return null;
    if (ex.heap) |h| return h;
    const buf = gpa.allocSentinel(u8, ex.slice.len, 0) catch return null;
    @memcpy(buf[0..ex.slice.len], ex.slice);
    buf[ex.slice.len] = 0;
    return buf;
}

fn extractIntFromVal(ctx: ?*c.Context, val: c.Value, default: u16) u16 {
    if (c.isUndefined(val) != 0 or c.isNull(val) != 0) return default;
    var out: i32 = 0;
    _ = c.toInt32(ctx, &out, val);
    return @intCast(out);
}

fn extractResponseData(ctx: ?*c.Context, this_val: c.Value) ?*ResponseData {
    const ptr = c.getOpaque2(ctx, this_val, response_class_id) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

pub fn dataFromJS(ctx: ?*c.Context, val: c.Value) ?*ResponseData {
    if (c.isObject(val) == 0) return null;
    const ptr = c.getOpaque2(ctx, val, response_class_id) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

pub const ResponseType = enum(u8) {
    basic, cors, default, err, opaque_type, opaqueredirect, other,
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
            .basic => "basic", .cors => "cors", .default => "default",
            .err => "error", .opaque_type => "opaque",
            .opaqueredirect => "opaqueredirect", .other => unreachable,
        };
    }
};

const PoolSlice = pool_slice_mod.PoolSlice;

pub const ResponseDataCold = struct {
    response_type_other: PoolSlice,
};

pub const ResponseData = struct {
    pool: std.ArrayList(u8),
    headers: *headers_mod.HeadersData,
    owned_body: ?[]u8 = null,
    cold: ?*ResponseDataCold,
    status: u16,
    response_type: ResponseType,
    status_text: PoolSlice,
    _body: PoolSlice,
    _url: PoolSlice,
    has_body: bool,
    body_used: bool,
    redirected: bool,
    comptime {
        std.debug.assert(@sizeOf(PoolSlice) == 8);
        std.debug.assert(@alignOf(ResponseData) >= 8);
    }
  
    pub fn init() ResponseData {
        const h = gpa.create(headers_mod.HeadersData) catch @panic("OOM HeadersData");
        h.* = headers_mod.HeadersData.init();
        var self = ResponseData{
            .pool = std.ArrayList(u8).empty,
            .status = 200,
            .status_text = .{},
            .headers = h,
            ._body = .{},
            .has_body = false,
            .body_used = false,
            ._url = .{},
            .redirected = false,
            .response_type = .basic,
            .cold = null,
        };
        self.storeString("OK", &self.status_text);
        return self;
    }
    pub fn deinit(self: *ResponseData) void {
        if (self.owned_body) |b| gpa.free(b);
        self.pool.deinit(gpa);
        if (self.cold) |cd| gpa.destroy(cd);
        self.headers.release();
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
            const cd = self.cold orelse return "";
            return self.pool.items[cd.response_type_other.off .. cd.response_type_other.off + cd.response_type_other.len];
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
        dst.* = .{ .off = @intCast(off), .len = @intCast(s.len) };
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
    fn ensureCold(self: *ResponseData) ?*ResponseDataCold {
        if (self.cold) |cd| return cd;
        const cd = gpa.create(ResponseDataCold) catch return null;
        cd.* = .{ .response_type_other = .{} };
        self.cold = cd;
        return cd;
    }
    pub fn setResponseType(self: *ResponseData, s: []const u8) void {
        const t = ResponseType.fromSlice(s);
        self.response_type = t;
        if (t == .other) {
            if (self.ensureCold()) |cd| self.storeString(s, &cd.response_type_other);
        }
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
        self.pool.ensureTotalCapacity(gpa, self.pool.items.len + src.pool.items.len) catch {};
        self.headers.reserve(src.headers.len(), src.headers.names.items.len, src.headers.values.items.len);
        self.owned_body = if (src.owned_body) |b| gpa.dupe(u8, b) catch null else null;
        if (src.cold) |sc| {
            if (self.ensureCold()) |dc| {
                dc.response_type_other = sc.response_type_other;
            }
        }
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
        var i: c_uint = 0;
        while (i < @as(c_uint, @intCast(len))) : (i += 1) {
            const item = c.getPropertyUint32(ctx, init_val, i);
            if (c.isObject(item) == 0) continue;
            const name_val = c.getPropertyUint32(ctx, item, 0);
            const val_val = c.getPropertyUint32(ctx, item, 1);
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
        c.freePropertyEnum(ctx, p, count);
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

fn setResponseProps(ctx: ?*c.Context, obj: c.Value, data: *ResponseData) void {
    _ = c.definePropertyValueStr(ctx, obj, "bodyUsed", if (data.body_used) c.JS_TRUE else c.JS_FALSE, c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "ok", if (data.status >= 200 and data.status <= 299) c.JS_TRUE else c.JS_FALSE, c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "redirected", if (data.redirected) c.JS_TRUE else c.JS_FALSE, c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "status", c.newInt32(ctx, @intCast(data.status)), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "statusText", zigStringToJS(ctx, data.statusText()), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "url", zigStringToJS(ctx, data.url()), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "type", zigStringToJS(ctx, data.responseType()), c.PROP_C_W_E);
    const hdr_obj = createEmbeddedHeaders(ctx, data.headers);
    _ = c.definePropertyValueStr(ctx, obj, "headers", hdr_obj, c.PROP_C_W_E);
}

fn responseText(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc; _ = argv;
    const data = extractResponseData(ctx, this_val) orelse return c.JS_EXCEPTION;
    data.body_used = true;
    const body_text = data.body() orelse "";
    var cap: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &cap);
    var result = zigStringToJS(ctx, body_text);
    _ = c.call(ctx, cap[0], c.JS_UNDEFINED, 1, &result);
    return promise;
}

fn responseJson(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc; _ = argv;
    const data = extractResponseData(ctx, this_val) orelse return c.JS_EXCEPTION;
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

fn responseArrayBuffer(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc; _ = argv;
    const data = extractResponseData(ctx, this_val) orelse return c.JS_EXCEPTION;
    data.body_used = true;
    const body_bytes = data.body() orelse "";
    var cap: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &cap);
    var ab = c.newArrayBufferCopy(ctx, body_bytes.ptr, body_bytes.len);
    _ = c.call(ctx, cap[0], c.JS_UNDEFINED, 1, &ab);
    return promise;
}

fn responseBlob(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc; _ = argv; _ = this_val;
    var cap: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &cap);
    var msg = zigStringToJS(ctx, "Blob not supported");
    _ = c.call(ctx, cap[1], c.JS_UNDEFINED, 1, &msg);
    return promise;
}

fn responseFormData(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc; _ = argv; _ = this_val;
    var cap: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &cap);
    var msg = zigStringToJS(ctx, "FormData not supported");
    _ = c.call(ctx, cap[1], c.JS_UNDEFINED, 1, &msg);
    return promise;
}

fn responseBytes(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc; _ = argv;
    const data = extractResponseData(ctx, this_val) orelse return c.JS_EXCEPTION;
    data.body_used = true;
    const body_bytes = data.body() orelse "";
    var cap: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &cap);
    var ab = c.newArrayBufferCopy(ctx, body_bytes.ptr, body_bytes.len);
    _ = c.call(ctx, cap[0], c.JS_UNDEFINED, 1, &ab);
    return promise;
}

fn responseClone(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc; _ = argv;
    const data = extractResponseData(ctx, this_val) orelse return c.JS_EXCEPTION;
    const new_data = gpa.create(ResponseData) catch return c.throwOutOfMemory(ctx);
    new_data.* = ResponseData.init();
    new_data.cloneFrom(data);
    return buildResponseJSObject(ctx, new_data);
}

fn responseStaticJson(ctx: ?*c.Context, _: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    var scratch: [256]u8 = undefined;
    const data = gpa.create(ResponseData) catch return c.throwOutOfMemory(ctx);
    data.* = ResponseData.init();
    if (argc > 0) {
        const json_str = c.jsonStringify(ctx, argv[0], c.JS_UNDEFINED, c.JS_UNDEFINED);
        if (c.isException(json_str) != 0) {
            gpa.destroy(data);
            return c.JS_EXCEPTION;
        }
        defer c.freeValue(ctx, json_str);
        if (extractStringAuto(ctx, json_str, &scratch)) |owned| {
            defer owned.deinit();
            data.setBody(owned.slice);
        }
        data.headers.appendEntry("content-type", "application/json");
    }
    if (argc > 1 and c.isObject(argv[1]) != 0) {
        const init_val = argv[1];
        const status_val = c.getPropertyStr(ctx, init_val, "status");
        defer c.freeValue(ctx, status_val);
        data.status = extractIntFromVal(ctx, status_val, 200);
        const status_text_val = c.getPropertyStr(ctx, init_val, "statusText");
        defer c.freeValue(ctx, status_text_val);
        if (c.isUndefined(status_text_val) == 0 and c.isNull(status_text_val) == 0) {
            if (extractStringAuto(ctx, status_text_val, &scratch)) |st| {
                defer st.deinit();
                data.setStatusText(st.slice);
            }
        }
        parseHeadersInitFromObj(ctx, init_val, data.headers);
    }
    return buildResponseJSObject(ctx, data);
}

fn responseStaticRedirect(ctx: ?*c.Context, _: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    if (argc < 1) {
        _ = c.throwTypeError(ctx, "Response.redirect requires a URL");
        return c.JS_EXCEPTION;
    }
    var url_buf: [512]u8 = undefined;
    const data = gpa.create(ResponseData) catch return c.throwOutOfMemory(ctx);
    data.* = ResponseData.init();
    if (extractStringAuto(ctx, argv[0], &url_buf)) |u| {
        defer u.deinit();
        data.setUrl(u.slice);
    }
    data.status = 302;
    data.setStatusText("Found");
    data.redirected = true;
    if (argc > 1) {
        data.status = extractIntFromVal(ctx, argv[1], 302);
    }
    return buildResponseJSObject(ctx, data);
}

fn responseStaticError(ctx: ?*c.Context, _: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc; _ = argv;
    const data = gpa.create(ResponseData) catch return c.throwOutOfMemory(ctx);
    data.* = ResponseData.init();
    data.status = 0;
    data.setStatusText("");
    data.setResponseType("error");
    return buildResponseJSObject(ctx, data);
}

fn responseFinalizer(rt: ?*c.Runtime, val: c.Value) callconv(.c) void {
    _ = rt;
    if (c.getOpaque(val, response_class_id)) |ptr| {
        const data: *ResponseData = @ptrCast(@alignCast(ptr));
        data.deinit();
        gpa.destroy(data);
    }
}

fn responseConstructor(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    var body_buf: [512]u8 = undefined;
    var scratch: [128]u8 = undefined;
    const data = gpa.create(ResponseData) catch return c.throwOutOfMemory(ctx);
    data.* = ResponseData.init();

    if (argc > 0 and c.isUndefined(argv[0]) == 0 and c.isNull(argv[0]) == 0) {
        if (extractStringAuto(ctx, argv[0], &body_buf)) |owned| {
            defer owned.deinit();
            data.setBody(owned.slice);
        }
    }
    if (argc > 1 and c.isObject(argv[1]) != 0) {
        const init_val = argv[1];
        const status_val = c.getPropertyStr(ctx, init_val, "status");
        defer c.freeValue(ctx, status_val);
        data.status = extractIntFromVal(ctx, status_val, 200);
        const status_text_val = c.getPropertyStr(ctx, init_val, "statusText");
        defer c.freeValue(ctx, status_text_val);
        if (c.isUndefined(status_text_val) == 0 and c.isNull(status_text_val) == 0) {
            if (extractStringAuto(ctx, status_text_val, &scratch)) |st| {
                defer st.deinit();
                data.setStatusText(st.slice);
            }
        }
        parseHeadersInitFromObj(ctx, init_val, data.headers);
    }

    const obj = c.newObjectClass(ctx, @intCast(response_class_id));
    c.setOpaque(obj, data);
    setResponseProps(ctx, obj, data);
    return obj;
}

pub fn buildResponseJSObject(ctx: ?*c.Context, data: *ResponseData) c.Value {
    const obj = c.newObjectClass(ctx, @intCast(response_class_id));
    c.setOpaque(obj, data);
    setResponseProps(ctx, obj, data);
    return obj;
}

pub fn setup(ctx: ?*c.Context) void {
    var class_def = c.ClassDef{
        .class_name = "Response",
        .finalizer = responseFinalizer,
    };
    _ = c.newClassID(c.getRuntime(ctx), &response_class_id);
    _ = c.newClass(c.getRuntime(ctx), response_class_id, &class_def);

    const proto = c.newObject(ctx);
    const methods = [_]struct { name: [*:0]const u8, func: *const c.CFunction, len: c_int }{
        .{ .name = "text", .func = &responseText, .len = 0 },
        .{ .name = "json", .func = &responseJson, .len = 0 },
        .{ .name = "arrayBuffer", .func = &responseArrayBuffer, .len = 0 },
        .{ .name = "blob", .func = &responseBlob, .len = 0 },
        .{ .name = "formData", .func = &responseFormData, .len = 0 },
        .{ .name = "bytes", .func = &responseBytes, .len = 0 },
        .{ .name = "clone", .func = &responseClone, .len = 0 },
    };
    for (methods) |m| {
        const fn_val = c.newCFunction(ctx, m.func, m.name, m.len);
        _ = c.definePropertyValueStr(ctx, proto, m.name, fn_val, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
    }
    c.setClassProto(ctx, response_class_id, proto);

    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);
    const ctor = c.newCFunction2(ctx, &responseConstructor, "Response", 2, c.JS_CFUNC_constructor, 0);
    _ = c.definePropertyValueStr(ctx, global, "Response", ctor, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);

    const static_json = c.newCFunction(ctx, &responseStaticJson, "json", 2);
    _ = c.definePropertyValueStr(ctx, ctor, "json", static_json, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
    const static_redirect = c.newCFunction(ctx, &responseStaticRedirect, "redirect", 2);
    _ = c.definePropertyValueStr(ctx, ctor, "redirect", static_redirect, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
    const static_error = c.newCFunction(ctx, &responseStaticError, "error", 0);
    _ = c.definePropertyValueStr(ctx, ctor, "error", static_error, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
}
