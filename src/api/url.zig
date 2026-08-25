const std = @import("std");
const c = @import("../c.zig").c;
const gpa = std.heap.smp_allocator;

// ---- V8 cached strings + functions (rooted once in setup). Previously
// every URLSearchParams/URL instance created its own "__d" key, all method
// key strings, and 13 brand-new JSFunction objects — twice over for nested
// searchParams. Instances now share one rooted set. ----
var str___d: c.Global = .{ .data_ptr = 0 };
var str_get: c.Global = .{ .data_ptr = 0 };
var str_getAll: c.Global = .{ .data_ptr = 0 };
var str_has: c.Global = .{ .data_ptr = 0 };
var str_set: c.Global = .{ .data_ptr = 0 };
var str_append: c.Global = .{ .data_ptr = 0 };
var str_delete: c.Global = .{ .data_ptr = 0 };
var str_sort: c.Global = .{ .data_ptr = 0 };
var str_toString: c.Global = .{ .data_ptr = 0 };
var str_entries: c.Global = .{ .data_ptr = 0 };
var str_keys: c.Global = .{ .data_ptr = 0 };
var str_values: c.Global = .{ .data_ptr = 0 };
var str_forEach: c.Global = .{ .data_ptr = 0 };
var str_size: c.Global = .{ .data_ptr = 0 };
var str_toJSON: c.Global = .{ .data_ptr = 0 };
var str_href: c.Global = .{ .data_ptr = 0 };
var str_origin: c.Global = .{ .data_ptr = 0 };
var str_host: c.Global = .{ .data_ptr = 0 };
var str_hostname: c.Global = .{ .data_ptr = 0 };
var str_port: c.Global = .{ .data_ptr = 0 };
var str_pathname: c.Global = .{ .data_ptr = 0 };
var str_search: c.Global = .{ .data_ptr = 0 };
var str_hash: c.Global = .{ .data_ptr = 0 };
var str_username: c.Global = .{ .data_ptr = 0 };
var str_password: c.Global = .{ .data_ptr = 0 };
var str_protocol: c.Global = .{ .data_ptr = 0 };
var str_searchParams: c.Global = .{ .data_ptr = 0 };
var fn_spGet: c.Global = .{ .data_ptr = 0 };
var fn_spGetAll: c.Global = .{ .data_ptr = 0 };
var fn_spHas: c.Global = .{ .data_ptr = 0 };
var fn_spSet: c.Global = .{ .data_ptr = 0 };
var fn_spAppend: c.Global = .{ .data_ptr = 0 };
var fn_spDelete: c.Global = .{ .data_ptr = 0 };
var fn_spSort: c.Global = .{ .data_ptr = 0 };
var fn_spToString: c.Global = .{ .data_ptr = 0 };
var fn_spEntries: c.Global = .{ .data_ptr = 0 };
var fn_spKeys: c.Global = .{ .data_ptr = 0 };
var fn_spValues: c.Global = .{ .data_ptr = 0 };
var fn_spForEach: c.Global = .{ .data_ptr = 0 };
var fn_spSize: c.Global = .{ .data_ptr = 0 };
var fn_urlToString: c.Global = .{ .data_ptr = 0 };
var fn_urlToJSON: c.Global = .{ .data_ptr = 0 };

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
/// Cached-Global accessor with an inline fallback so a missing root can
/// never turn a hot path into a null-deref.
fn globalStr(g: *c.Global, isolate: ?*c.Isolate, comptime fallback: []const u8) *const c.Value {
    return @ptrCast(c.v8__Global__Get(g, isolate) orelse zigStringToV8(isolate, fallback));
}
// Hot-path string extraction: writes into the caller-provided stack buffer
// when the string fits (typical searchParams names/values), falling back to
// one direct heap allocation otherwise. Replaces the previous 8KB stack
// staging buffer + dupeZ, which silently truncated strings >8192 bytes and
// paid an extra copy per call.
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
fn defaultPortForScheme(scheme: []const u8) ?u16 {
    if (std.mem.eql(u8, scheme, "http")) return 80;
    if (std.mem.eql(u8, scheme, "https")) return 443;
    if (std.mem.eql(u8, scheme, "ws")) return 80;
    if (std.mem.eql(u8, scheme, "wss")) return 443;
    if (std.mem.eql(u8, scheme, "ftp")) return 21;
    return null;
}
fn isSpecialScheme(scheme: []const u8) bool {
    return defaultPortForScheme(scheme) != null or std.mem.eql(u8, scheme, "file");
}
// ============================================================
// URLSearchParams
// ============================================================
const Pair = struct { name: []const u8, value: []const u8 };
const URLSearchParamsData = struct {
    pairs: std.ArrayList(Pair),
    fn init() URLSearchParamsData {
        return .{ .pairs = std.ArrayList(Pair).empty };
    }
    fn deinit(self: *URLSearchParamsData) void {
        for (self.pairs.items) |pair| {
            gpa.free(pair.name);
            gpa.free(pair.value);
        }
        self.pairs.deinit(gpa);
    }
    fn parseFromString(self: *URLSearchParamsData, str: []const u8) void {
        if (str.len == 0) return;
        var rest = str;
        while (rest.len > 0) {
            const amp = std.mem.indexOf(u8, rest, "&");
            const pair_str = if (amp) |a| rest[0..a] else rest;
            const eq = std.mem.indexOf(u8, pair_str, "=");
            const name = gpa.dupe(u8, pair_str[0 .. eq orelse pair_str.len]) catch return;
            const value = if (eq) |e|
                gpa.dupe(u8, pair_str[e + 1 ..]) catch return
            else
                gpa.dupe(u8, "") catch return;
            self.pairs.append(gpa, .{ .name = name, .value = value }) catch return;
            if (amp) |a| {
                rest = rest[a + 1 ..];
            } else {
                break;
            }
        }
    }
    fn appendPair(self: *URLSearchParamsData, name: []const u8, value: []const u8) void {
        const n = gpa.dupe(u8, name) catch return;
        const v = gpa.dupe(u8, value) catch return;
        self.pairs.append(gpa, .{ .name = n, .value = v }) catch return;
    }
    fn deleteEntry(self: *URLSearchParamsData, name: []const u8, value: ?[]const u8) void {
        var i: usize = 0;
        while (i < self.pairs.items.len) {
            if (std.mem.eql(u8, self.pairs.items[i].name, name)) {
                if (value == null or std.mem.eql(u8, self.pairs.items[i].value, value.?)) {
                    gpa.free(self.pairs.items[i].name);
                    gpa.free(self.pairs.items[i].value);
                    _ = self.pairs.orderedRemove(i);
                    continue;
                }
            }
            i += 1;
        }
    }
    fn getFirst(self: *const URLSearchParamsData, name: []const u8) ?[]const u8 {
        for (self.pairs.items) |pair| {
            if (std.mem.eql(u8, pair.name, name)) return pair.value;
        }
        return null;
    }
    fn getAllValues(self: *const URLSearchParamsData, name: []const u8) [][]const u8 {
        var result = std.ArrayList([]const u8).empty;
        for (self.pairs.items) |pair| {
            if (std.mem.eql(u8, pair.name, name)) {
                result.append(gpa, pair.value) catch break;
            }
        }
        return result.toOwnedSlice(gpa) catch &.{};
    }
    fn hasEntry(self: *const URLSearchParamsData, name: []const u8, value: ?[]const u8) bool {
        for (self.pairs.items) |pair| {
            if (std.mem.eql(u8, pair.name, name)) {
                if (value == null or std.mem.eql(u8, pair.value, value.?)) return true;
            }
        }
        return false;
    }
    fn setEntry(self: *URLSearchParamsData, name: []const u8, value: []const u8) void {
        var found = false;
        var i: usize = 0;
        while (i < self.pairs.items.len) {
            if (std.mem.eql(u8, self.pairs.items[i].name, name)) {
                if (!found) {
                    gpa.free(self.pairs.items[i].value);
                    self.pairs.items[i].value = gpa.dupe(u8, value) catch return;
                    found = true;
                    i += 1;
                } else {
                    gpa.free(self.pairs.items[i].name);
                    gpa.free(self.pairs.items[i].value);
                    _ = self.pairs.orderedRemove(i);
                }
            } else {
                i += 1;
            }
        }
        if (!found) self.appendPair(name, value);
    }
    fn sortPairs(self: *URLSearchParamsData) void {
        std.mem.sort(Pair, self.pairs.items, {}, struct {
            fn lessThan(_: void, a: Pair, b: Pair) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lessThan);
    }
    fn serialize(self: *const URLSearchParamsData) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        for (self.pairs.items, 0..) |pair, i| {
            if (i > 0) try result.append(gpa, '&');
            try result.appendSlice(gpa, pair.name);
            try result.append(gpa, '=');
            try result.appendSlice(gpa, pair.value);
        }
        return try result.toOwnedSlice(gpa);
    }
};
fn extractSPData(info: ?*const c.FunctionCallbackInfo) ?*URLSearchParamsData {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    const this = c.v8__FunctionCallbackInfo__This(info);
    if (this == null) return null;
    const ext_val = c.v8__Object__Get(@ptrCast(this), context, globalStr(&str___d, isolate, "__d"));
    if (ext_val == null or !c.v8__Value__IsExternal(ext_val)) return null;
    const ptr = c.v8__External__Value(@ptrCast(ext_val));
    return @ptrCast(@alignCast(ptr));
}
/// Shared by spConstructor and createSPJsObject: attaches the single rooted
/// function set under the single rooted key set (was: 13 fresh JSFunctions +
/// 13 fresh key strings per instance, duplicated in two places).
fn attachSPMethods(isolate: ?*c.Isolate, context: ?*c.Context, obj: ?*const c.Value) void {
    var out: c.MaybeBool = undefined;
    const pairs = .{
        .{ &fn_spGet, &str_get, "get" },
        .{ &fn_spGetAll, &str_getAll, "getAll" },
        .{ &fn_spHas, &str_has, "has" },
        .{ &fn_spSet, &str_set, "set" },
        .{ &fn_spAppend, &str_append, "append" },
        .{ &fn_spDelete, &str_delete, "delete" },
        .{ &fn_spSort, &str_sort, "sort" },
        .{ &fn_spToString, &str_toString, "toString" },
        .{ &fn_spEntries, &str_entries, "entries" },
        .{ &fn_spKeys, &str_keys, "keys" },
        .{ &fn_spValues, &str_values, "values" },
        .{ &fn_spForEach, &str_forEach, "forEach" },
        .{ &fn_spSize, &str_size, "size" },
    };
    inline for (pairs) |pair| {
        c.v8__Object__Set(
            obj,
            context,
            globalStr(pair[1], isolate, pair[2]),
            @ptrCast(c.v8__Global__Get(pair[0], isolate)),
            &out,
        );
    }
}
fn spConstructor(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    const data = gpa.create(URLSearchParamsData) catch {
        throw(isolate, "out of memory");
        return;
    };
    data.* = URLSearchParamsData.init();
    if (c.v8__FunctionCallbackInfo__Length(info) > 0) {
        const init_val = c.v8__FunctionCallbackInfo__INDEX(info, 0);
        if (c.v8__Value__IsString(init_val)) {
            var str_buf: [512]u8 = undefined;
            if (extractStringAuto(isolate, init_val, &str_buf)) |s| {
                defer s.deinit();
                data.parseFromString(s.slice);
            }
        }
    }
    const obj = c.v8__Object__New(isolate);
    const ext = c.v8__External__New(isolate, @ptrCast(data));
    var out: c.MaybeBool = undefined;
    c.v8__Object__Set(obj, context, globalStr(&str___d, isolate, "__d"), ext, &out);
    attachSPMethods(isolate, context, obj);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(obj));
}
fn spGet(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const data = extractSPData(info) orelse return;
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    if (c.v8__FunctionCallbackInfo__Length(info) < 1) {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Null(isolate)));
        return;
    }
    var name_buf: [128]u8 = undefined;
    const name = extractStringAuto(isolate, c.v8__FunctionCallbackInfo__INDEX(info, 0), &name_buf) orelse return;
    defer name.deinit();
    if (data.getFirst(name.slice)) |v| {
        c.v8__ReturnValue__Set(ret, zigStringToV8(isolate, v));
    } else {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Null(isolate)));
    }
}
fn spGetAll(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    const data = extractSPData(info) orelse return;
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    if (c.v8__FunctionCallbackInfo__Length(info) < 1) {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Array__New(isolate, 0)));
        return;
    }
    var name_buf: [128]u8 = undefined;
    const name = extractStringAuto(isolate, c.v8__FunctionCallbackInfo__INDEX(info, 0), &name_buf) orelse return;
    defer name.deinit();
    const vals = data.getAllValues(name.slice);
    defer gpa.free(vals);
    const arr = c.v8__Array__New(isolate, @intCast(vals.len));
    for (vals, 0..) |v, i| {
        var el_out: c.MaybeBool = undefined;
        c.v8__Object__SetAtIndex(@ptrCast(arr), context, @intCast(i), zigStringToV8(isolate, v), &el_out);
    }
    c.v8__ReturnValue__Set(ret, @ptrCast(arr));
}
fn spHas(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const data = extractSPData(info) orelse return;
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    if (c.v8__FunctionCallbackInfo__Length(info) < 1) {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__False(isolate)));
        return;
    }
    var name_buf: [128]u8 = undefined;
    var val_stack: [256]u8 = undefined;
    const name = extractStringAuto(isolate, c.v8__FunctionCallbackInfo__INDEX(info, 0), &name_buf) orelse return;
    defer name.deinit();
    var val: ?[]const u8 = null;
    var val_ex: ?ExtractedStr = null;
    if (c.v8__FunctionCallbackInfo__Length(info) > 1) {
        const v = c.v8__FunctionCallbackInfo__INDEX(info, 1);
        if (!c.v8__Value__IsUndefined(v)) {
            val_ex = extractStringAuto(isolate, v, &val_stack);
            if (val_ex) |ex| val = ex.slice;
        }
    }
    defer if (val_ex) |ex| ex.deinit();
    const result = data.hasEntry(name.slice, val);
    c.v8__ReturnValue__Set(ret, if (result) @ptrCast(c.v8__True(isolate)) else @ptrCast(c.v8__False(isolate)));
}
fn spSet(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const data = extractSPData(info) orelse return;
    if (c.v8__FunctionCallbackInfo__Length(info) < 2) return;
    var name_buf: [128]u8 = undefined;
    var value_buf: [256]u8 = undefined;
    const name = extractStringAuto(isolate, c.v8__FunctionCallbackInfo__INDEX(info, 0), &name_buf) orelse return;
    defer name.deinit();
    const value = extractStringAuto(isolate, c.v8__FunctionCallbackInfo__INDEX(info, 1), &value_buf) orelse return;
    defer value.deinit();
    data.setEntry(name.slice, value.slice);
}
fn spAppend(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const data = extractSPData(info) orelse return;
    if (c.v8__FunctionCallbackInfo__Length(info) < 2) return;
    var name_buf: [128]u8 = undefined;
    var value_buf: [256]u8 = undefined;
    const name = extractStringAuto(isolate, c.v8__FunctionCallbackInfo__INDEX(info, 0), &name_buf) orelse return;
    defer name.deinit();
    const value = extractStringAuto(isolate, c.v8__FunctionCallbackInfo__INDEX(info, 1), &value_buf) orelse return;
    defer value.deinit();
    data.appendPair(name.slice, value.slice);
}
fn spDelete(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const data = extractSPData(info) orelse return;
    if (c.v8__FunctionCallbackInfo__Length(info) < 1) return;
    var name_buf: [128]u8 = undefined;
    var val_stack: [256]u8 = undefined;
    const name = extractStringAuto(isolate, c.v8__FunctionCallbackInfo__INDEX(info, 0), &name_buf) orelse return;
    defer name.deinit();
    var val: ?[]const u8 = null;
    var val_ex: ?ExtractedStr = null;
    if (c.v8__FunctionCallbackInfo__Length(info) > 1) {
        const v = c.v8__FunctionCallbackInfo__INDEX(info, 1);
        if (!c.v8__Value__IsUndefined(v)) {
            val_ex = extractStringAuto(isolate, v, &val_stack);
            if (val_ex) |ex| val = ex.slice;
        }
    }
    defer if (val_ex) |ex| ex.deinit();
    data.deleteEntry(name.slice, val);
}
fn spSort(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const data = extractSPData(info) orelse return;
    data.sortPairs();
}
fn spToString(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const data = extractSPData(info) orelse return;
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const str = data.serialize() catch {
        c.v8__ReturnValue__Set(ret, zigStringToV8(isolate, ""));
        return;
    };
    defer gpa.free(str);
    c.v8__ReturnValue__Set(ret, zigStringToV8(isolate, str));
}
fn spSize(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const data = extractSPData(info) orelse return;
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const num = c.v8__Integer__NewFromUnsigned(isolate, @intCast(data.pairs.items.len));
    c.v8__ReturnValue__Set(ret, @ptrCast(num));
}
fn spEntries(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    const data = extractSPData(info) orelse return;
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const arr = c.v8__Array__New(isolate, @intCast(data.pairs.items.len));
    for (data.pairs.items, 0..) |pair, i| {
        const pair_arr = c.v8__Array__New(isolate, 2);
        var el_out: c.MaybeBool = undefined;
        c.v8__Object__SetAtIndex(@ptrCast(pair_arr), context, 0, zigStringToV8(isolate, pair.name), &el_out);
        c.v8__Object__SetAtIndex(@ptrCast(pair_arr), context, 1, zigStringToV8(isolate, pair.value), &el_out);
        c.v8__Object__SetAtIndex(@ptrCast(arr), context, @intCast(i), @ptrCast(pair_arr), &el_out);
    }
    c.v8__ReturnValue__Set(ret, @ptrCast(arr));
}
fn spKeys(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    const data = extractSPData(info) orelse return;
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const arr = c.v8__Array__New(isolate, @intCast(data.pairs.items.len));
    for (data.pairs.items, 0..) |pair, i| {
        var el_out: c.MaybeBool = undefined;
        c.v8__Object__SetAtIndex(@ptrCast(arr), context, @intCast(i), zigStringToV8(isolate, pair.name), &el_out);
    }
    c.v8__ReturnValue__Set(ret, @ptrCast(arr));
}
fn spValues(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    const data = extractSPData(info) orelse return;
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const arr = c.v8__Array__New(isolate, @intCast(data.pairs.items.len));
    for (data.pairs.items, 0..) |pair, i| {
        var el_out: c.MaybeBool = undefined;
        c.v8__Object__SetAtIndex(@ptrCast(arr), context, @intCast(i), zigStringToV8(isolate, pair.value), &el_out);
    }
    c.v8__ReturnValue__Set(ret, @ptrCast(arr));
}
fn spForEach(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    const data = extractSPData(info) orelse return;
    if (c.v8__FunctionCallbackInfo__Length(info) < 1) return;
    const callback = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    if (!c.v8__Value__IsFunction(callback)) return;
    for (data.pairs.items) |pair| {
        var argv: [3]?*const c.Value = .{
            zigStringToV8(isolate, pair.value),
            zigStringToV8(isolate, pair.name),
            @ptrCast(c.v8__FunctionCallbackInfo__This(info)),
        };
        _ = c.v8__Function__Call(@ptrCast(callback), context, @ptrCast(c.v8__Undefined(isolate)), 3, &argv);
    }
}
// ============================================================
// URL
// ============================================================
const UrlData = struct {
    scheme: []const u8,
    host: []const u8,
    port: ?u16,
    path: []const u8,
    query: []const u8,
    fragment: []const u8,
    username: []const u8,
    password: []const u8,
    search_params: *URLSearchParamsData,
    fn deinit(self: *UrlData) void {
        gpa.free(self.scheme);
        gpa.free(self.host);
        gpa.free(self.path);
        gpa.free(self.query);
        gpa.free(self.fragment);
        gpa.free(self.username);
        gpa.free(self.password);
        self.search_params.deinit();
        gpa.destroy(self.search_params);
    }
    fn serialize(self: *const UrlData) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        try result.appendSlice(gpa, self.scheme);
        try result.appendSlice(gpa, "://");
        if (self.username.len > 0 or self.password.len > 0) {
            try result.appendSlice(gpa, self.username);
            if (self.password.len > 0) {
                try result.append(gpa, ':');
                try result.appendSlice(gpa, self.password);
            }
            try result.append(gpa, '@');
        }
        try result.appendSlice(gpa, self.host);
        if (self.port) |port| {
            if (defaultPortForScheme(self.scheme)) |dp| {
                if (port != dp) {
                    try result.append(gpa, ':');
                    try result.print(gpa, "{d}", .{port});
                }
            } else {
                try result.append(gpa, ':');
                try result.print(gpa, "{d}", .{port});
            }
        }
        try result.appendSlice(gpa, self.path);
        if (self.query.len > 0) {
            try result.append(gpa, '?');
            try result.appendSlice(gpa, self.query);
        }
        if (self.fragment.len > 0) {
            try result.append(gpa, '#');
            try result.appendSlice(gpa, self.fragment);
        }
        return try result.toOwnedSlice(gpa);
    }
    fn originStr(self: *const UrlData) ![]const u8 {
        if (std.mem.eql(u8, self.scheme, "file") or !isSpecialScheme(self.scheme)) {
            return try gpa.dupe(u8, "null");
        }
        var result = std.ArrayList(u8).empty;
        try result.appendSlice(gpa, self.scheme);
        try result.appendSlice(gpa, "://");
        try result.appendSlice(gpa, self.host);
        if (self.port) |port| {
            if (defaultPortForScheme(self.scheme)) |dp| {
                if (port != dp) {
                    try result.append(gpa, ':');
                    try result.print(gpa, "{d}", .{port});
                }
            } else {
                try result.append(gpa, ':');
                try result.print(gpa, "{d}", .{port});
            }
        }
        return try result.toOwnedSlice(gpa);
    }
    fn hostStr(self: *const UrlData) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        try result.appendSlice(gpa, self.host);
        if (self.port) |port| {
            if (defaultPortForScheme(self.scheme)) |dp| {
                if (port != dp) {
                    try result.append(gpa, ':');
                    try result.print(gpa, "{d}", .{port});
                }
            } else {
                try result.append(gpa, ':');
                try result.print(gpa, "{d}", .{port});
            }
        }
        return try result.toOwnedSlice(gpa);
    }
    fn protocolStr(self: *const UrlData, buf: *[256]u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}:", .{self.scheme}) catch self.scheme;
    }
    fn portStr(self: *const UrlData) ![]const u8 {
        if (self.port) |port| {
            if (defaultPortForScheme(self.scheme)) |dp| {
                if (port == dp) return try gpa.dupe(u8, "");
            }
            return try std.fmt.allocPrint(gpa, "{d}", .{port});
        }
        return try gpa.dupe(u8, "");
    }
    fn searchStr(self: *const UrlData) ![]const u8 {
        if (self.query.len > 0) {
            return try std.fmt.allocPrint(gpa, "?{s}", .{self.query});
        }
        return try gpa.dupe(u8, "");
    }
    fn hashStr(self: *const UrlData) ![]const u8 {
        if (self.fragment.len > 0) {
            return try std.fmt.allocPrint(gpa, "#{s}", .{self.fragment});
        }
        return try gpa.dupe(u8, "");
    }
};
fn parseUrlAbsolute(input: []const u8) !UrlData {
    const uri = try std.Uri.parse(input);
    const scheme = try gpa.dupe(u8, uri.scheme);
    const host = if (uri.host) |h| (try h.toRawMaybeAlloc(gpa)) else try gpa.dupe(u8, "");
    const raw_path = try uri.path.toRawMaybeAlloc(gpa);
    const path = if (raw_path.len == 0) blk: {
        gpa.free(raw_path);
        break :blk try gpa.dupe(u8, "/");
    } else raw_path;
    const query = if (uri.query) |q| (try q.toRawMaybeAlloc(gpa)) else try gpa.dupe(u8, "");
    const fragment = if (uri.fragment) |f| (try f.toRawMaybeAlloc(gpa)) else try gpa.dupe(u8, "");
    const username = if (uri.user) |u| (try u.toRawMaybeAlloc(gpa)) else try gpa.dupe(u8, "");
    const password = if (uri.password) |p| (try p.toRawMaybeAlloc(gpa)) else try gpa.dupe(u8, "");
    const sp = gpa.create(URLSearchParamsData) catch return error.OutOfMemory;
    sp.* = URLSearchParamsData.init();
    sp.parseFromString(query);
    return .{
        .scheme = scheme,
        .host = host,
        .port = uri.port,
        .path = path,
        .query = query,
        .fragment = fragment,
        .username = username,
        .password = password,
        .search_params = sp,
    };
}
fn parseUrlRelative(input: []const u8, base_url: []const u8) !UrlData {
    const base = try std.Uri.parse(base_url);
    const base_port = base.port;
    var result_scheme: []const u8 = undefined;
    var result_host: []const u8 = undefined;
    var result_port: ?u16 = undefined;
    var result_user: []const u8 = "";
    var result_pass: []const u8 = "";
    var result_path: []const u8 = undefined;
    var result_query: []const u8 = "";
    var result_fragment: []const u8 = "";
    if (std.Uri.parse(input)) |rel| {
        if (rel.scheme.len > 0) {
            result_scheme = try gpa.dupe(u8, rel.scheme);
            result_host = if (rel.host) |h| (try h.toRawMaybeAlloc(gpa)) else try gpa.dupe(u8, "");
            result_port = rel.port;
            result_path = if (rel.path.isEmpty())
                try gpa.dupe(u8, "/")
            else
                try removeDotSegments(try rel.path.toRawMaybeAlloc(gpa));
            result_query = if (rel.query) |q| (try q.toRawMaybeAlloc(gpa)) else try gpa.dupe(u8, "");
            result_fragment = if (rel.fragment) |f| (try f.toRawMaybeAlloc(gpa)) else try gpa.dupe(u8, "");
            if (rel.user) |u| result_user = try u.toRawMaybeAlloc(gpa);
            if (rel.password) |p| result_pass = try p.toRawMaybeAlloc(gpa);
            const sp = gpa.create(URLSearchParamsData) catch return error.OutOfMemory;
            sp.* = URLSearchParamsData.init();
            sp.parseFromString(result_query);
            return .{
                .scheme = result_scheme,
                .host = result_host,
                .port = result_port,
                .path = result_path,
                .query = result_query,
                .fragment = result_fragment,
                .username = result_user,
                .password = result_pass,
                .search_params = sp,
            };
        }
        if (rel.host) |h| {
            result_scheme = try gpa.dupe(u8, base.scheme);
            result_host = try h.toRawMaybeAlloc(gpa);
            result_port = rel.port;
            result_path = if (rel.path.isEmpty())
                try gpa.dupe(u8, "/")
            else
                try removeDotSegments(try rel.path.toRawMaybeAlloc(gpa));
            result_query = if (rel.query) |q| (try q.toRawMaybeAlloc(gpa)) else try gpa.dupe(u8, "");
            result_fragment = if (rel.fragment) |f| (try f.toRawMaybeAlloc(gpa)) else try gpa.dupe(u8, "");
            const sp = gpa.create(URLSearchParamsData) catch return error.OutOfMemory;
            sp.* = URLSearchParamsData.init();
            sp.parseFromString(result_query);
            return .{
                .scheme = result_scheme,
                .host = result_host,
                .port = result_port,
                .path = result_path,
                .query = result_query,
                .fragment = result_fragment,
                .username = result_user,
                .password = result_pass,
                .search_params = sp,
            };
        }
    } else |_| {}
    // Fallthrough (path/query/fragment-only relative resolution). Base host
    // and path are allocated here rather than up front so the early-return
    // branches above cannot leak them, and defers guarantee release.
    const base_host_owned = if (base.host) |h| (try h.toRawMaybeAlloc(gpa)) else null;
    defer if (base_host_owned) |bh| gpa.free(bh);
    const base_host = base_host_owned orelse "";
    const base_path = try base.path.toRawMaybeAlloc(gpa);
    defer gpa.free(base_path);
    result_scheme = try gpa.dupe(u8, base.scheme);
    result_host = try gpa.dupe(u8, base_host);
    result_port = base_port;
    const rel_path = input;
    if (rel_path.len == 0) {
        result_path = try gpa.dupe(u8, base_path);
        result_query = if (base.query) |q| (try q.toRawMaybeAlloc(gpa)) else try gpa.dupe(u8, "");
    } else if (rel_path[0] == '?') {
        result_path = try gpa.dupe(u8, base_path);
        result_query = try gpa.dupe(u8, rel_path[1..]);
    } else if (rel_path[0] == '#') {
        result_path = try gpa.dupe(u8, base_path);
        result_query = if (base.query) |q| (try q.toRawMaybeAlloc(gpa)) else try gpa.dupe(u8, "");
        result_fragment = try gpa.dupe(u8, rel_path[1..]);
    } else if (rel_path[0] == '/') {
        result_path = try removeDotSegments(rel_path);
        result_query = "";
    } else {
        result_path = try removeDotSegments(try mergePaths(base_path, rel_path));
        result_query = "";
    }
    const sp = gpa.create(URLSearchParamsData) catch return error.OutOfMemory;
    sp.* = URLSearchParamsData.init();
    sp.parseFromString(result_query);
    return .{
        .scheme = result_scheme,
        .host = result_host,
        .port = result_port,
        .path = result_path,
        .query = result_query,
        .fragment = result_fragment,
        .username = result_user,
        .password = result_pass,
        .search_params = sp,
    };
}
fn mergePaths(base_path: []const u8, rel_path: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    try result.appendSlice(gpa, base_path);
    if (std.mem.lastIndexOfScalar(u8, result.items, '/')) |idx| {
        result.items.len = idx + 1;
    } else {
        result.items.len = 0;
    }
    try result.appendSlice(gpa, rel_path);
    return try result.toOwnedSlice(gpa);
}
fn removeDotSegments(input: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    var rest = input;
    while (rest.len > 0) {
        if (std.mem.startsWith(u8, rest, "../")) {
            rest = rest[3..];
        } else if (std.mem.startsWith(u8, rest, "./")) {
            rest = rest[2..];
        } else if (std.mem.startsWith(u8, rest, "/../")) {
            rest = rest[4..];
            while (result.items.len > 0) {
                _ = result.orderedRemove(result.items.len - 1);
                if (result.items.len > 0 and result.items[result.items.len - 1] == '/') {
                    _ = result.orderedRemove(result.items.len - 1);
                    break;
                }
                if (result.items.len == 0) break;
            }
            try result.append(gpa, '/');
        } else if (std.mem.eql(u8, rest, "/..")) {
            rest = "";
            while (result.items.len > 0) {
                _ = result.orderedRemove(result.items.len - 1);
                if (result.items.len > 0 and result.items[result.items.len - 1] == '/') {
                    _ = result.orderedRemove(result.items.len - 1);
                    break;
                }
                if (result.items.len == 0) break;
            }
            try result.append(gpa, '/');
        } else if (std.mem.startsWith(u8, rest, "/./")) {
            rest = rest[2..];
        } else if (std.mem.eql(u8, rest, "..")) {
            rest = "";
            try result.append(gpa, '/');
        } else if (std.mem.eql(u8, rest, ".")) {
            rest = "";
        } else if (rest[0] == '/') {
            try result.append(gpa, '/');
            rest = rest[1..];
        } else {
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
            try result.appendSlice(gpa, rest[0..slash]);
            rest = if (slash < rest.len) rest[slash..] else "";
        }
    }
    if (result.items.len == 0) {
        try result.append(gpa, '/');
    }
    return try result.toOwnedSlice(gpa);
}
fn extractUrlData(info: ?*const c.FunctionCallbackInfo) ?*UrlData {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    const this = c.v8__FunctionCallbackInfo__This(info);
    if (this == null) return null;
    const ext_val = c.v8__Object__Get(@ptrCast(this), context, globalStr(&str___d, isolate, "__d"));
    if (ext_val == null or !c.v8__Value__IsExternal(ext_val)) return null;
    const ptr = c.v8__External__Value(@ptrCast(ext_val));
    return @ptrCast(@alignCast(ptr));
}
fn setUrlProp(isolate: ?*c.Isolate, context: ?*c.Context, obj: *const c.Value, g: *c.Global, comptime fallback: []const u8, val: []const u8) void {
    var out: c.MaybeBool = undefined;
    c.v8__Object__Set(@ptrCast(obj), context, globalStr(g, isolate, fallback), zigStringToV8(isolate, val), &out);
}
fn createUrlJsObject(isolate: ?*c.Isolate, context: ?*c.Context, data: *UrlData) ?*const c.Value {
    const obj = c.v8__Object__New(isolate) orelse return null;
    const ext = c.v8__External__New(isolate, @ptrCast(data));
    var out: c.MaybeBool = undefined;
    c.v8__Object__Set(obj, context, globalStr(&str___d, isolate, "__d"), ext, &out);
    const href_val = data.serialize() catch "";
    defer if (href_val.len > 0) gpa.free(href_val);
    const origin_val = data.originStr() catch "";
    defer if (origin_val.len > 0) gpa.free(origin_val);
    const host_val = data.hostStr() catch "";
    defer if (host_val.len > 0) gpa.free(host_val);
    var protocol_buf: [256]u8 = undefined;
    const protocol_val = data.protocolStr(&protocol_buf);
    const port_val = data.portStr() catch "";
    defer if (port_val.len > 0) gpa.free(port_val);
    const search_val = data.searchStr() catch "";
    defer if (search_val.len > 0) gpa.free(search_val);
    const hash_val = data.hashStr() catch "";
    defer if (hash_val.len > 0) gpa.free(hash_val);
    setUrlProp(isolate, context, obj, &str_href, "href", href_val);
    setUrlProp(isolate, context, obj, &str_origin, "origin", origin_val);
    setUrlProp(isolate, context, obj, &str_host, "host", host_val);
    setUrlProp(isolate, context, obj, &str_hostname, "hostname", data.host);
    setUrlProp(isolate, context, obj, &str_port, "port", port_val);
    setUrlProp(isolate, context, obj, &str_pathname, "pathname", data.path);
    setUrlProp(isolate, context, obj, &str_search, "search", search_val);
    setUrlProp(isolate, context, obj, &str_hash, "hash", hash_val);
    setUrlProp(isolate, context, obj, &str_username, "username", data.username);
    setUrlProp(isolate, context, obj, &str_password, "password", data.password);
    setUrlProp(isolate, context, obj, &str_protocol, "protocol", protocol_val);
    const method_pairs = .{
        .{ &fn_urlToString, &str_toString, "toString" },
        .{ &fn_urlToJSON, &str_toJSON, "toJSON" },
    };
    inline for (method_pairs) |pair| {
        c.v8__Object__Set(
            obj,
            context,
            globalStr(pair[1], isolate, pair[2]),
            @ptrCast(c.v8__Global__Get(pair[0], isolate)),
            &out,
        );
    }
    const sp_obj = createSPJsObject(isolate, context, data.search_params);
    c.v8__Object__Set(obj, context, globalStr(&str_searchParams, isolate, "searchParams"), sp_obj, &out);
    return obj;
}
fn createSPJsObject(isolate: ?*c.Isolate, context: ?*c.Context, data: *URLSearchParamsData) ?*const c.Value {
    const obj = c.v8__Object__New(isolate) orelse return null;
    const ext = c.v8__External__New(isolate, @ptrCast(data));
    var out: c.MaybeBool = undefined;
    c.v8__Object__Set(obj, context, globalStr(&str___d, isolate, "__d"), ext, &out);
    attachSPMethods(isolate, context, obj);
    return obj;
}
fn urlConstructor(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    if (c.v8__FunctionCallbackInfo__Length(info) < 1) {
        throwTypeError(isolate, "URL constructor requires at least 1 argument");
        return;
    }
    var input_buf: [512]u8 = undefined;
    var base_buf: [512]u8 = undefined;
    const input_val = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    const input = extractStringAuto(isolate, input_val, &input_buf) orelse return;
    defer input.deinit();
    var base: ?ExtractedStr = null;
    if (c.v8__FunctionCallbackInfo__Length(info) > 1) {
        const base_val = c.v8__FunctionCallbackInfo__INDEX(info, 1);
        if (!c.v8__Value__IsUndefined(base_val) and !c.v8__Value__IsNull(base_val)) {
            base = extractStringAuto(isolate, base_val, &base_buf);
        }
    }
    defer if (base) |b| b.deinit();
    const data_ptr = gpa.create(UrlData) catch {
        throw(isolate, "out of memory");
        return;
    };
    data_ptr.* = if (base) |b|
        parseUrlRelative(input.slice, b.slice) catch {
            gpa.destroy(data_ptr);
            throwTypeError(isolate, "Invalid URL");
            return;
        }
    else
        parseUrlAbsolute(input.slice) catch {
            gpa.destroy(data_ptr);
            throwTypeError(isolate, "Invalid URL");
            return;
        };
    const obj = createUrlJsObject(isolate, context, data_ptr) orelse return;
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(obj));
}
fn urlToString(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const data = extractUrlData(info) orelse return;
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const str = data.serialize() catch "";
    defer if (str.len > 0) gpa.free(str);
    c.v8__ReturnValue__Set(ret, zigStringToV8(isolate, str));
}
fn urlToJSON(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    urlToString(info);
}
fn urlParseStatic(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    if (c.v8__FunctionCallbackInfo__Length(info) < 1) {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Null(isolate)));
        return;
    }
    var input_buf: [512]u8 = undefined;
    var base_buf: [512]u8 = undefined;
    const input_val = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    const input = extractStringAuto(isolate, input_val, &input_buf) orelse return;
    defer input.deinit();
    var base: ?ExtractedStr = null;
    if (c.v8__FunctionCallbackInfo__Length(info) > 1) {
        const base_val = c.v8__FunctionCallbackInfo__INDEX(info, 1);
        if (!c.v8__Value__IsUndefined(base_val) and !c.v8__Value__IsNull(base_val)) {
            base = extractStringAuto(isolate, base_val, &base_buf);
        }
    }
    defer if (base) |b| b.deinit();
    const data_ptr = gpa.create(UrlData) catch return;
    data_ptr.* = if (base) |b|
        parseUrlRelative(input.slice, b.slice) catch {
            gpa.destroy(data_ptr);
            c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Null(isolate)));
            return;
        }
    else
        parseUrlAbsolute(input.slice) catch {
            gpa.destroy(data_ptr);
            c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Null(isolate)));
            return;
        };
    const obj = createUrlJsObject(isolate, context, data_ptr) orelse return;
    c.v8__ReturnValue__Set(ret, @ptrCast(obj));
}
fn urlCanParseStatic(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    if (c.v8__FunctionCallbackInfo__Length(info) < 1) {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__False(isolate)));
        return;
    }
    var input_buf: [512]u8 = undefined;
    var base_buf: [512]u8 = undefined;
    const input_val = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    const input = extractStringAuto(isolate, input_val, &input_buf) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__False(isolate)));
        return;
    };
    defer input.deinit();
    var base: ?ExtractedStr = null;
    if (c.v8__FunctionCallbackInfo__Length(info) > 1) {
        const base_val = c.v8__FunctionCallbackInfo__INDEX(info, 1);
        if (!c.v8__Value__IsUndefined(base_val) and !c.v8__Value__IsNull(base_val)) {
            base = extractStringAuto(isolate, base_val, &base_buf);
        }
    }
    defer if (base) |b| b.deinit();
    const valid = if (base) |b|
        parseUrlRelative(input.slice, b.slice) catch null
    else
        parseUrlAbsolute(input.slice) catch null;
    if (valid) |v| {
        var data = v;
        data.deinit();
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__True(isolate)));
    } else {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__False(isolate)));
    }
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

    // Root every per-call constant once.
    inline for (.{
        .{ "__d", &str___d },
        .{ "get", &str_get },           .{ "getAll", &str_getAll },
        .{ "has", &str_has },           .{ "set", &str_set },
        .{ "append", &str_append },     .{ "delete", &str_delete },
        .{ "sort", &str_sort },         .{ "toString", &str_toString },
        .{ "entries", &str_entries },   .{ "keys", &str_keys },
        .{ "values", &str_values },     .{ "forEach", &str_forEach },
        .{ "size", &str_size },         .{ "toJSON", &str_toJSON },
        .{ "href", &str_href },         .{ "origin", &str_origin },
        .{ "host", &str_host },         .{ "hostname", &str_hostname },
        .{ "port", &str_port },         .{ "pathname", &str_pathname },
        .{ "search", &str_search },     .{ "hash", &str_hash },
        .{ "username", &str_username }, .{ "password", &str_password },
        .{ "protocol", &str_protocol }, .{ "searchParams", &str_searchParams },
    }) |entry| {
        c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, entry[0], 0, -1)), entry[1]);
    }

    // One shared function set for every instance.
    inline for (.{
        .{ spGet, &fn_spGet },           .{ spGetAll, &fn_spGetAll },
        .{ spHas, &fn_spHas },           .{ spSet, &fn_spSet },
        .{ spAppend, &fn_spAppend },     .{ spDelete, &fn_spDelete },
        .{ spSort, &fn_spSort },         .{ spToString, &fn_spToString },
        .{ spEntries, &fn_spEntries },   .{ spKeys, &fn_spKeys },
        .{ spValues, &fn_spValues },     .{ spForEach, &fn_spForEach },
        .{ spSize, &fn_spSize },         .{ urlToString, &fn_urlToString },
        .{ urlToJSON, &fn_urlToJSON },
    }) |entry| {
        c.v8__Global__New(isolate, @ptrCast(c.v8__Function__New__DEFAULT(context, entry[0])), entry[1]);
    }

    const sp_fn = c.v8__Function__New__DEFAULT(context, spConstructor);
    const sp_key = c.v8__String__NewFromUtf8(isolate, "URLSearchParams", 0, -1);
    _ = c.v8__Object__Set(global, context, sp_key, sp_fn, &out);
    const url_fn = c.v8__Function__New__DEFAULT(context, urlConstructor);
    const url_key = c.v8__String__NewFromUtf8(isolate, "URL", 0, -1);
    _ = c.v8__Object__Set(global, context, url_key, url_fn, &out);
    const parse_fn = c.v8__Function__New__DEFAULT(context, urlParseStatic);
    c.v8__Object__Set(url_fn, context, c.v8__String__NewFromUtf8(isolate, "parse", 0, -1), parse_fn, &out);
    const can_parse_fn = c.v8__Function__New__DEFAULT(context, urlCanParseStatic);
    c.v8__Object__Set(url_fn, context, c.v8__String__NewFromUtf8(isolate, "canParse", 0, -1), can_parse_fn, &out);
}
