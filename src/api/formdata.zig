const std = @import("std");
const c = @import("../c.zig").c;
const iterables = @import("./iterables.zig");

const gpa = std.heap.page_allocator;

var defer_resolver: c.Global = .{ .data_ptr = 0 };

fn throw(isolate: ?*c.Isolate, msg: []const u8) void {
    const v8_msg = c.v8__String__NewFromUtf8(isolate, @ptrCast(msg.ptr), 0, @intCast(msg.len));
    const exc = c.v8__Exception__Error(v8_msg);
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

pub const FormDataData = struct {
    names: std.ArrayList([]const u8), // owned slices
    values: std.ArrayList([]const u8),
    filenames: std.ArrayList(?[]const u8), // non-null when a file

    pub fn init() FormDataData {
        return .{
            .names = std.ArrayList([]const u8).empty,
            .values = std.ArrayList([]const u8).empty,
            .filenames = std.ArrayList(?[]const u8).empty,
        };
    }

    pub fn deinit(self: *FormDataData) void {
        for (self.names.items) |n| gpa.free(n);
        for (self.values.items) |v| gpa.free(v);
        for (self.filenames.items) |f| {
            if (f) |s| gpa.free(s);
        }
        self.names.deinit(gpa);
        self.values.deinit(gpa);
        self.filenames.deinit(gpa);
    }

    pub fn len(self: *const FormDataData) usize {
        return self.names.items.len;
    }

    pub fn append(self: *FormDataData, name: []const u8, value: []const u8, filename: ?[]const u8) void {
        self.names.append(gpa, gpa.dupe(u8, name) catch return) catch {
            return;
        };
        self.values.append(gpa, gpa.dupe(u8, value) catch return) catch {
            gpa.free((self.names.pop() orelse unreachable));
            return;
        };
        const fdup: ?[]const u8 = if (filename) |fn_| gpa.dupe(u8, fn_) catch null else null;
        self.filenames.append(gpa, fdup) catch {
            gpa.free((self.names.pop() orelse unreachable));
            gpa.free((self.values.pop() orelse unreachable));
            if (fdup) |f| gpa.free(f);
            return;
        };
    }

    fn removeSwap(self: *FormDataData, i: usize) void {
        const last = self.names.items.len - 1;
        gpa.free(self.names.items[i]);
        gpa.free(self.values.items[i]);
        if (self.filenames.items[i]) |f| gpa.free(f);
        if (i != last) {
            self.names.items[i] = self.names.items[last];
            self.values.items[i] = self.values.items[last];
            self.filenames.items[i] = self.filenames.items[last];
        }
        self.names.items.len -= 1;
        self.values.items.len -= 1;
        self.filenames.items.len -= 1;
    }

    fn firstIndex(self: *const FormDataData, name: []const u8) ?usize {
        for (self.names.items, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return i;
        }
        return null;
    }
};

pub fn destroyData(data: *FormDataData) void {
    data.deinit();
    gpa.destroy(data);
}

fn extractFormData(info: ?*const c.FunctionCallbackInfo) ?*FormDataData {
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

fn argString(isolate: ?*c.Isolate, info: ?*const c.FunctionCallbackInfo, i: c_int) ?[:0]const u8 {
    if (c.v8__FunctionCallbackInfo__Length(info) <= i) return null;
    return extractStringFromVal(isolate, c.v8__FunctionCallbackInfo__INDEX(info, i));
}

fn formDataValueFor(data: *const FormDataData, i: usize) []const u8 {
    return if (data.filenames.items[i]) |f| f else data.values.items[i];
}

fn formDataConstructor(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);

    const data = gpa.create(FormDataData) catch {
        throw(isolate, "out of memory");
        return;
    };
    data.* = FormDataData.init();

    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    if (makeFormDataObject(isolate, context, data)) |obj| {
        c.v8__ReturnValue__Set(ret, obj);
    }
}

pub fn formDataAppend(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const data = extractFormData(info) orelse return;
    const name = argString(isolate, info, 0) orelse return;
    defer gpa.free(name);
    const value = argString(isolate, info, 1) orelse return;
    defer gpa.free(value);
    data.append(name[0..name.len], value[0..value.len], null);
}

pub fn formDataGet(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractFormData(info) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Null(isolate)));
        return;
    };
    const name = argString(isolate, info, 0) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Null(isolate)));
        return;
    };
    defer gpa.free(name);
    if (data.firstIndex(name[0..name.len])) |i| {
        c.v8__ReturnValue__Set(ret, @ptrCast(zigStringToV8(isolate, formDataValueFor(data, i))));
    } else {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Null(isolate)));
    }
}

pub fn formDataGetAll(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractFormData(info) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Array__New(isolate, 0)));
        return;
    };
    const name = argString(isolate, info, 0) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Array__New(isolate, 0)));
        return;
    };
    defer gpa.free(name);

    var count: usize = 0;
    for (data.names.items) |n| {
        if (std.mem.eql(u8, n, name[0..name.len])) count += 1;
    }
    const arr = c.v8__Array__New(isolate, @intCast(count));
    var filled: usize = 0;
    for (data.names.items, 0..) |n, i| {
        if (std.mem.eql(u8, n, name[0..name.len])) {
            var out: c.MaybeBool = undefined;
            _ = c.v8__Object__Set(@ptrCast(arr), context, c.v8__Integer__NewFromUnsigned(isolate, @intCast(filled)), @ptrCast(zigStringToV8(isolate, formDataValueFor(data, i))), &out);
            filled += 1;
        }
    }
    c.v8__ReturnValue__Set(ret, @ptrCast(arr));
}

pub fn formDataSet(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const data = extractFormData(info) orelse return;
    const name = argString(isolate, info, 0) orelse return;
    defer gpa.free(name);
    const value = argString(isolate, info, 1) orelse return;
    defer gpa.free(value);

    var i: usize = 0;
    var found = false;
    while (i < data.len()) {
        if (std.mem.eql(u8, data.names.items[i], name[0..name.len])) {
            if (!found) {
                gpa.free(data.values.items[i]);
                data.values.items[i] = gpa.dupe(u8, value[0..value.len]) catch return;
                if (data.filenames.items[i]) |f| gpa.free(f);
                data.filenames.items[i] = null;
                found = true;
                i += 1;
            } else {
                data.removeSwap(i);
            }
        } else {
            i += 1;
        }
    }
    if (!found) data.append(name[0..name.len], value[0..value.len], null);
}

pub fn formDataDelete(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const data = extractFormData(info) orelse return;
    const name = argString(isolate, info, 0) orelse return;
    defer gpa.free(name);
    var i: usize = 0;
    while (i < data.len()) {
        if (std.mem.eql(u8, data.names.items[i], name[0..name.len])) {
            data.removeSwap(i);
        } else {
            i += 1;
        }
    }
}

pub fn formDataHas(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractFormData(info) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__False(isolate)));
        return;
    };
    const name = argString(isolate, info, 0) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__False(isolate)));
        return;
    };
    defer gpa.free(name);
    c.v8__ReturnValue__Set(ret, if (data.firstIndex(name[0..name.len]) != null)
        @ptrCast(c.v8__True(isolate))
    else
        @ptrCast(c.v8__False(isolate)));
}

pub fn formDataEntries(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractFormData(info) orelse return;

    const pairs_arr = c.v8__Array__New(isolate, @intCast(data.len()));
    for (0..data.len()) |i| {
        const inner = c.v8__Array__New(isolate, 2);
        var out: c.MaybeBool = undefined;
        _ = c.v8__Object__Set(@ptrCast(inner), context, c.v8__Integer__NewFromUnsigned(isolate, 0), @ptrCast(zigStringToV8(isolate, data.names.items[i])), &out);
        _ = c.v8__Object__Set(@ptrCast(inner), context, c.v8__Integer__NewFromUnsigned(isolate, 1), @ptrCast(zigStringToV8(isolate, formDataValueFor(data, i))), &out);
        var out2: c.MaybeBool = undefined;
        _ = c.v8__Object__Set(@ptrCast(pairs_arr), context, c.v8__Integer__NewFromUnsigned(isolate, @intCast(i)), @ptrCast(inner), &out2);
    }
    c.v8__ReturnValue__Set(ret, @ptrCast(pairs_arr));
}

pub fn formDataKeys(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractFormData(info) orelse return;

    var names = std.ArrayList([]const u8).empty;
    for (data.names.items) |n| {
        var found = false;
        for (names.items) |existing| {
            if (std.mem.eql(u8, existing, n)) {
                found = true;
                break;
            }
        }
        if (!found) names.append(gpa, n) catch break;
    }
    defer names.deinit(gpa);

    const arr = c.v8__Array__New(isolate, @intCast(names.items.len));
    for (names.items, 0..) |name, i| {
        var out: c.MaybeBool = undefined;
        _ = c.v8__Object__Set(@ptrCast(arr), context, c.v8__Integer__NewFromUnsigned(isolate, @intCast(i)), @ptrCast(zigStringToV8(isolate, name)), &out);
    }
    c.v8__ReturnValue__Set(ret, @ptrCast(arr));
}

pub fn formDataValues(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractFormData(info) orelse return;

    const arr = c.v8__Array__New(isolate, @intCast(data.len()));
    for (0..data.len()) |i| {
        var out: c.MaybeBool = undefined;
        _ = c.v8__Object__Set(@ptrCast(arr), context, c.v8__Integer__NewFromUnsigned(isolate, @intCast(i)), @ptrCast(zigStringToV8(isolate, formDataValueFor(data, i))), &out);
    }
    c.v8__ReturnValue__Set(ret, @ptrCast(arr));
}

pub fn makeFormDataObject(isolate: ?*c.Isolate, context: ?*c.Context, data: *FormDataData) ?*const c.Value {
    const obj = c.v8__Object__New(isolate);
    const ext = c.v8__External__New(isolate, @ptrCast(data));
    var out: c.MaybeBool = undefined;
    _ = c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, "__d", 0, -1), ext, &out);
    const fns = .{
        .{ "append", formDataAppend },
        .{ "get", formDataGet },
        .{ "getAll", formDataGetAll },
        .{ "set", formDataSet },
        .{ "delete", formDataDelete },
        .{ "has", formDataHas },
        .{ "entries", formDataEntries },
        .{ "keys", formDataKeys },
        .{ "values", formDataValues },
    };
    inline for (fns) |e| {
        const fn_val = c.v8__Function__New__DEFAULT(context, e[1]);
        _ = c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, e[0], 0, -1), fn_val, &out);
    }
    iterables.attach(isolate, context, obj, .formdata);
    return @ptrCast(obj);
}

fn startsWithFold(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    for (haystack[0..needle.len], needle) |h, n| {
        if (std.ascii.toLower(h) != std.ascii.toLower(n)) return false;
    }
    return true;
}

fn percentDecode(input: []const u8) []const u8 {
    const hexVal = struct {
        fn val(b: u8) ?u8 {
            return switch (b) {
                '0'...'9' => b - '0',
                'a'...'f' => b - 'a' + 10,
                'A'...'F' => b - 'A' + 10,
                else => null,
            };
        }
    }.val;

    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const ch = input[i];
        if (ch == '+') {
            _ = out.append(gpa, ' ') catch return &.{};
        } else if (ch == '%' and i + 2 < input.len) {
            if (hexVal(input[i + 1])) |hi| {
                if (hexVal(input[i + 2])) |lo| {
                    _ = out.append(gpa, hi * 16 + lo) catch return &.{};
                    i += 2;
                    continue;
                }
            }
            _ = out.append(gpa, ch) catch return &.{};
        } else {
            _ = out.append(gpa, ch) catch return &.{};
        }
    }
    return out.toOwnedSlice(gpa) catch &.{};
}

fn parseUrlEncoded(data: *FormDataData, body: []const u8) void {
    var it = std.mem.splitSequence(u8, body, "&");
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        var it2 = std.mem.splitScalar(u8, pair, '=');
        const name_raw = it2.next() orelse continue;
        const value_raw = it2.next() orelse "";
        const name = percentDecode(name_raw);
        defer gpa.free(@constCast(name));
        const value = percentDecode(value_raw);
        defer gpa.free(@constCast(value));
        data.append(name, value, null);
    }
}

fn contentParam(headers: []const u8, param: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, headers, ";");
    while (it.next()) |tok_raw| {
        const tok = std.mem.trim(u8, tok_raw, " \t\r\n");
        if (tok.len > param.len and std.mem.eql(u8, tok[0..param.len], param) and tok[param.len] == '=') {
            var val = tok[param.len + 1 ..];
            val = std.mem.trim(u8, val, " \t");
            if (val.len >= 2 and val[0] == '"') {
                const rest = val[1..];
                if (std.mem.indexOfScalar(u8, rest, '"')) |end| {
                    if (end > 0) return rest[0..end];
                }
            }
            if (val.len > 0) return val;
        }
    }
    return null;
}

fn parseMultipart(data: *FormDataData, body: []const u8, boundary: []const u8) void {
    var bkey_buf = std.ArrayList(u8).empty;
    bkey_buf.appendSlice(gpa, "--") catch return;
    bkey_buf.appendSlice(gpa, boundary) catch return;
    defer bkey_buf.deinit(gpa);
    const bkey = bkey_buf.items;

    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, body, pos, bkey)) |d1| {
        var seg = d1 + bkey.len;
        if (seg + 2 <= body.len and std.mem.eql(u8, body[seg .. seg + 2], "--")) break;

        const end_of_line = std.mem.indexOfPos(u8, body, seg, "\r\n") orelse break;
        const hdr_end = std.mem.indexOfPos(u8, body, end_of_line + 2, "\r\n\r\n") orelse break;
        const headers = body[end_of_line + 2 .. hdr_end];
        seg = hdr_end + 4;

        const next = std.mem.indexOfPos(u8, body, seg, bkey) orelse break;
        var value = body[seg..next];
        if (value.len >= 2 and std.mem.eql(u8, value[value.len - 2 ..], "\r\n")) {
            value = value[0 .. value.len - 2];
        }

        const name = contentParam(headers, "name") orelse {
            pos = next;
            continue;
        };
        const filename = contentParam(headers, "filename");
        data.append(name, value, filename);
        pos = next;
    }
}

fn boundaryFromContentType(content_type: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, content_type, ';');
    while (it.next()) |tok_raw| {
        const tok = std.mem.trim(u8, tok_raw, " \t\r\n");
        if (startsWithFold(tok, "boundary=")) {
            var v = tok["boundary=".len..];
            v = std.mem.trim(u8, v, " \t\r\n\"");
            if (v.len > 0) return v;
        }
    }
    return null;
}

// Returns a populated FormDataData for supported content types, null otherwise.
// Ownership transfers to the JS object; do NOT call destroyData on the result.
pub fn parseFromContentType(content_type: []const u8, body: []const u8) ?*FormDataData {
    const data = gpa.create(FormDataData) catch return null;
    data.* = FormDataData.init();

    if (startsWithFold(content_type, "multipart/form-data")) {
        if (boundaryFromContentType(content_type)) |boundary| {
            parseMultipart(data, body, boundary);
            if (data.len() > 0) return data;
        }
    } else if (startsWithFold(content_type, "application/x-www-form-urlencoded")) {
        parseUrlEncoded(data, body);
        return data;
    }

    destroyData(data);
    return null;
}

// Defer the "unsupported content type" rejection to a microtask so the caller's
// await/then handler attaches before V8 reports an unhandled rejection.
fn deferredRejectCb(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const ctx = c.v8__Isolate__GetCurrentContext(isolate) orelse return;
    const dv = c.v8__FunctionCallbackInfo__Data(info) orelse return;
    const gp: *c.Global = @ptrCast(@alignCast(c.v8__External__Value(@ptrCast(dv))));
    if (c.v8__Global__Get(gp, isolate)) |resolver| {
        var out: c.MaybeBool = undefined;
        _ = c.v8__Promise__Resolver__Reject(
            @ptrCast(resolver),
            ctx,
            @ptrCast(zigStringToV8(isolate, "Unsupported content type (expected multipart/form-data or application/x-www-form-urlencoded)")),
            &out,
        );
    }
    c.v8__Global__Reset(gp);
}

pub fn rejectUnsupported(isolate: ?*c.Isolate, context: ?*c.Context, resolver: ?*const c.PromiseResolver) void {
    if (defer_resolver.data_ptr != 0) c.v8__Global__Reset(&defer_resolver);
    c.v8__Global__New(isolate, @ptrCast(resolver), &defer_resolver);
    const fn_val = c.v8__Function__New__DEFAULT2(
        context,
        deferredRejectCb,
        @ptrCast(c.v8__External__New(isolate, @ptrCast(&defer_resolver))),
    ) orelse {
        c.v8__Global__Reset(&defer_resolver);
        var out: c.MaybeBool = undefined;
        _ = c.v8__Promise__Resolver__Reject(resolver, context, @ptrCast(zigStringToV8(isolate, "Unsupported content type (expected multipart/form-data or application/x-www-form-urlencoded)")), &out);
        return;
    };
    c.v8__Isolate__EnqueueMicrotaskFunc(isolate, @ptrCast(fn_val));
}

pub fn setup(isolate: ?*c.Isolate, context: ?*c.Context) void {
    var hs: c.HandleScope = undefined;
    c.v8__HandleScope__CONSTRUCT(&hs, isolate);
    defer c.v8__HandleScope__DESTRUCT(&hs);

    const global = c.v8__Context__Global(context);
    var out: c.MaybeBool = undefined;
    _ = c.v8__Object__Set(global, context, c.v8__String__NewFromUtf8(isolate, "FormData", 0, -1), c.v8__Function__New__DEFAULT(context, formDataConstructor), &out);
}
