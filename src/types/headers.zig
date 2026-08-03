const std = @import("std");
const c = @import("../c.zig").c;

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

fn lowerCaseAlloc(input: []const u8) ![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(gpa, input.len);
    for (input) |b| {
        buf.appendAssumeCapacity(std.ascii.toLower(b));
    }
    return try buf.toOwnedSlice(gpa);
}

// ============================================================
// HeadersData — pure Zig, no V8 types
// ============================================================

const Pair = struct { name: []const u8, value: []const u8 };

pub const HeadersData = struct {
    pairs: std.ArrayList(Pair),

    pub fn init() HeadersData {
        return .{ .pairs = std.ArrayList(Pair).empty };
    }

    pub fn deinit(self: *HeadersData) void {
        for (self.pairs.items) |pair| {
            gpa.free(pair.name);
            gpa.free(pair.value);
        }
        self.pairs.deinit(gpa);
    }

    pub fn appendEntry(self: *HeadersData, name: []const u8, value: []const u8) void {
        const n = lowerCaseAlloc(name) catch return;
        const v = gpa.dupe(u8, value) catch {
            gpa.free(n);
            return;
        };
        self.pairs.append(gpa, .{ .name = n, .value = v }) catch {
            gpa.free(n);
            gpa.free(v);
        };
    }

    pub fn setEntry(self: *HeadersData, name: []const u8, value: []const u8) void {
        const ln = lowerCaseAlloc(name) catch return;
        const v = gpa.dupe(u8, value) catch {
            gpa.free(ln);
            return;
        };

        var found = false;
        var i: usize = 0;
        while (i < self.pairs.items.len) {
            if (std.mem.eql(u8, self.pairs.items[i].name, ln)) {
                if (!found) {
                    gpa.free(self.pairs.items[i].value);
                    self.pairs.items[i].value = v;
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
        if (!found) {
            self.pairs.append(gpa, .{ .name = ln, .value = v }) catch {
                gpa.free(ln);
                gpa.free(v);
            };
        } else {
            gpa.free(ln);
        }
    }

    pub fn deleteEntry(self: *HeadersData, name: []const u8, value: ?[]const u8) void {
        const ln = lowerCaseAlloc(name) catch return;
        defer gpa.free(ln);
        var i: usize = 0;
        while (i < self.pairs.items.len) {
            if (std.mem.eql(u8, self.pairs.items[i].name, ln)) {
                if (value == null or std.mem.eql(u8, self.pairs.items[i].value, value.?)) {
                    gpa.free(self.pairs.items[i].name);
                    gpa.free(self.pairs.items[i].value);
                    _ = self.pairs.orderedRemove(i);
                    if (value != null) return;
                    continue;
                }
            }
            i += 1;
        }
    }

    pub fn getFirst(self: *const HeadersData, name: []const u8) ?[]const u8 {
        const ln = lowerCaseAlloc(name) catch return null;
        defer gpa.free(ln);

        var first_val: ?[]const u8 = null;
        var count: usize = 0;
        for (self.pairs.items) |pair| {
            if (std.mem.eql(u8, pair.name, ln)) {
                if (count == 0) first_val = pair.value;
                count += 1;
            }
        }
        if (count == 0) return null;
        if (count == 1) return gpa.dupe(u8, first_val.?) catch null;

        var result = std.ArrayList(u8).empty;
        result.appendSlice(gpa, first_val.?) catch return gpa.dupe(u8, first_val.?) catch null;
        var skipped_first = false;
        for (self.pairs.items) |pair| {
            if (std.mem.eql(u8, pair.name, ln)) {
                if (!skipped_first) {
                    skipped_first = true;
                    continue;
                }
                result.appendSlice(gpa, ", ") catch break;
                result.appendSlice(gpa, pair.value) catch break;
            }
        }
        return result.toOwnedSlice(gpa) catch gpa.dupe(u8, first_val.?) catch null;
    }

    pub fn getAllValues(self: *const HeadersData, name: []const u8) [][]const u8 {
        const ln = lowerCaseAlloc(name) catch return &.{};
        defer gpa.free(ln);
        var result = std.ArrayList([]const u8).empty;
        for (self.pairs.items) |pair| {
            if (std.mem.eql(u8, pair.name, ln)) {
                result.append(gpa, pair.value) catch break;
            }
        }
        return result.toOwnedSlice(gpa) catch &.{};
    }

    pub fn hasEntry(self: *const HeadersData, name: []const u8, value: ?[]const u8) bool {
        const ln = lowerCaseAlloc(name) catch return false;
        defer gpa.free(ln);
        for (self.pairs.items) |pair| {
            if (std.mem.eql(u8, pair.name, ln)) {
                if (value == null or std.mem.eql(u8, pair.value, value.?)) return true;
            }
        }
        return false;
    }

    pub fn getUniqueNames(self: *const HeadersData) [][]const u8 {
        var result = std.ArrayList([]const u8).empty;
        for (self.pairs.items) |pair| {
            var found = false;
            for (result.items) |existing| {
                if (std.mem.eql(u8, existing, pair.name)) {
                    found = true;
                    break;
                }
            }
            if (!found) result.append(gpa, pair.name) catch break;
        }
        return result.toOwnedSlice(gpa) catch &.{};
    }

    pub fn serialize(self: *const HeadersData) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        for (self.pairs.items, 0..) |pair, i| {
            if (i > 0) try result.appendSlice(gpa, "\r\n");
            try result.appendSlice(gpa, pair.name);
            try result.appendSlice(gpa, ": ");
            try result.appendSlice(gpa, pair.value);
        }
        return try result.toOwnedSlice(gpa);
    }

    pub fn fromPairs(self: *HeadersData, pairs: []const Pair) void {
        for (pairs) |pair| self.appendEntry(pair.name, pair.value);
    }

    pub fn fromRawHeaderString(self: *HeadersData, raw: []const u8) void {
        var lines = std.mem.splitSequence(u8, raw, "\r\n");
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (std.mem.indexOf(u8, line, ":")) |colon| {
                const name = std.mem.trim(u8, line[0..colon], " \t");
                const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
                if (name.len > 0) self.appendEntry(name, value);
            }
        }
    }
};

// ============================================================
// Extract HeadersData from JS this.__d
// ============================================================

fn extractHeadersData(info: ?*const c.FunctionCallbackInfo) ?*HeadersData {
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
// JS Callbacks — all V8 interaction lives here
// ============================================================

fn headersConstructor(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);

    const data = gpa.create(HeadersData) catch {
        throw(isolate, "out of memory");
        return;
    };
    data.* = HeadersData.init();

    if (c.v8__FunctionCallbackInfo__Length(info) > 0) {
        const init_val = c.v8__FunctionCallbackInfo__INDEX(info, 0);
        if (init_val == null or c.v8__Value__IsUndefined(init_val) or c.v8__Value__IsNull(init_val)) {
            // empty
        } else if (c.v8__Value__IsObject(init_val)) {
            const data_key = c.v8__String__NewFromUtf8(isolate, "__d", 0, -1);
            const ext_val = c.v8__Object__Get(@ptrCast(init_val), context, data_key);
            if (ext_val != null and c.v8__Value__IsExternal(ext_val)) {
                const src: *HeadersData = @ptrCast(@alignCast(c.v8__External__Value(@ptrCast(ext_val))));
                for (src.pairs.items) |pair| data.appendEntry(pair.name, pair.value);
            } else if (c.v8__Value__IsArray(init_val)) {
                var pairs_buf = std.ArrayList(Pair).empty;
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
                            pairs_buf.append(gpa, .{ .name = n, .value = v }) catch {
                                gpa.free(n);
                                gpa.free(v);
                            };
                        } else {
                            gpa.free(n);
                        }
                    }
                }
                if (pairs_buf.items.len > 0) {
                    data.fromPairs(pairs_buf.items);
                }
                for (pairs_buf.items) |pair| {
                    gpa.free(pair.name);
                    gpa.free(pair.value);
                }
                pairs_buf.deinit(gpa);
            } else {
                var pairs_buf = std.ArrayList(Pair).empty;
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
                                pairs_buf.append(gpa, .{ .name = n, .value = v }) catch {
                                    gpa.free(n);
                                    gpa.free(v);
                                };
                            } else {
                                gpa.free(n);
                            }
                        }
                    }
                }
                if (pairs_buf.items.len > 0) {
                    data.fromPairs(pairs_buf.items);
                }
                for (pairs_buf.items) |pair| {
                    gpa.free(pair.name);
                    gpa.free(pair.value);
                }
                pairs_buf.deinit(gpa);
            }
        }
    }

    const obj = c.v8__Object__New(isolate);
    const ext = c.v8__External__New(isolate, @ptrCast(data));
    var out: c.MaybeBool = undefined;
    c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, "__d", 0, -1), ext, &out);

    const fns = .{
        .{ "get", headersGet },
        .{ "getAll", headersGetAll },
        .{ "has", headersHas },
        .{ "set", headersSet },
        .{ "append", headersAppend },
        .{ "delete", headersDelete },
        .{ "entries", headersEntries },
        .{ "keys", headersKeys },
        .{ "values", headersValues },
        .{ "forEach", headersForEach },
        .{ "toString", headersToString },
        .{ "size", headersSize },
    };
    inline for (fns) |entry| {
        const fn_val = c.v8__Function__New__DEFAULT(context, entry[1]);
        c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, entry[0], 0, -1), fn_val, &out);
    }

    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(obj));
}

pub fn headersGet(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);

    const data = extractHeadersData(info) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Null(isolate)));
        return;
    };
    const arg0 = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    const name = extractStringFromVal(isolate, arg0) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Null(isolate)));
        return;
    };
    defer gpa.free(name);

    if (data.getFirst(name)) |val| {
        defer gpa.free(val);
        c.v8__ReturnValue__Set(ret, @ptrCast(zigStringToV8(isolate, val)));
    } else {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Null(isolate)));
    }
}

pub fn headersGetAll(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);

    const data = extractHeadersData(info) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Array__New(isolate, 0)));
        return;
    };
    const arg0 = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    const name = extractStringFromVal(isolate, arg0) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Array__New(isolate, 0)));
        return;
    };
    defer gpa.free(name);

    const vals = data.getAllValues(name);
    defer gpa.free(vals);
    const arr = c.v8__Array__New(isolate, @intCast(vals.len));
    for (vals, 0..) |v, i| {
        var out: c.MaybeBool = undefined;
        _ = c.v8__Object__Set(@ptrCast(arr), context, c.v8__Integer__NewFromUnsigned(isolate, @intCast(i)), @ptrCast(zigStringToV8(isolate, v)), &out);
    }
    c.v8__ReturnValue__Set(ret, @ptrCast(arr));
}

pub fn headersHas(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);

    const data = extractHeadersData(info) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__False(isolate)));
        return;
    };
    const arg0 = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    const name = extractStringFromVal(isolate, arg0) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__False(isolate)));
        return;
    };
    defer gpa.free(name);

    c.v8__ReturnValue__Set(ret, if (data.hasEntry(name, null))
        @ptrCast(c.v8__True(isolate))
    else
        @ptrCast(c.v8__False(isolate)));
}

pub fn headersSet(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const data = extractHeadersData(info) orelse return;
    const arg0 = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    const arg1 = c.v8__FunctionCallbackInfo__INDEX(info, 1);
    const name = extractStringFromVal(isolate, arg0) orelse return;
    defer gpa.free(name);
    const value = extractStringFromVal(isolate, arg1) orelse return;
    defer gpa.free(value);
    data.setEntry(name, value);
}

pub fn headersAppend(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const data = extractHeadersData(info) orelse return;
    const arg0 = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    const arg1 = c.v8__FunctionCallbackInfo__INDEX(info, 1);
    const name = extractStringFromVal(isolate, arg0) orelse return;
    defer gpa.free(name);
    const value = extractStringFromVal(isolate, arg1) orelse return;
    defer gpa.free(value);
    data.appendEntry(name, value);
}

pub fn headersDelete(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const data = extractHeadersData(info) orelse return;
    const arg0 = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    const name = extractStringFromVal(isolate, arg0) orelse return;
    defer gpa.free(name);
    var val: ?[]const u8 = null;
    if (c.v8__FunctionCallbackInfo__Length(info) > 1) {
        const arg1 = c.v8__FunctionCallbackInfo__INDEX(info, 1);
        if (arg1 != null and !c.v8__Value__IsUndefined(arg1) and !c.v8__Value__IsNull(arg1)) {
            val = extractStringFromVal(isolate, arg1);
        }
    }
    defer if (val) |v| gpa.free(v);
    data.deleteEntry(name, val);
}

pub fn headersEntries(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);

    const data = extractHeadersData(info) orelse return;

    const pairs_arr = c.v8__Array__New(isolate, 0);
    for (data.pairs.items, 0..) |pair, i| {
        const inner = c.v8__Array__New(isolate, 2);
        var out: c.MaybeBool = undefined;
        _ = c.v8__Object__Set(@ptrCast(inner), context, c.v8__Integer__NewFromUnsigned(isolate, 0), @ptrCast(zigStringToV8(isolate, pair.name)), &out);
        _ = c.v8__Object__Set(@ptrCast(inner), context, c.v8__Integer__NewFromUnsigned(isolate, 1), @ptrCast(zigStringToV8(isolate, pair.value)), &out);
        var out2: c.MaybeBool = undefined;
        _ = c.v8__Object__Set(@ptrCast(pairs_arr), context, c.v8__Integer__NewFromUnsigned(isolate, @intCast(i)), inner, &out2);
    }
    c.v8__ReturnValue__Set(ret, @ptrCast(pairs_arr));
}

pub fn headersKeys(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);

    const data = extractHeadersData(info) orelse return;
    const names = data.getUniqueNames();
    defer gpa.free(names);

    const arr = c.v8__Array__New(isolate, @intCast(names.len));
    for (names, 0..) |name, i| {
        var out: c.MaybeBool = undefined;
        _ = c.v8__Object__Set(@ptrCast(arr), context, c.v8__Integer__NewFromUnsigned(isolate, @intCast(i)), @ptrCast(zigStringToV8(isolate, name)), &out);
    }
    c.v8__ReturnValue__Set(ret, @ptrCast(arr));
}

pub fn headersValues(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);

    const data = extractHeadersData(info) orelse return;
    const arr = c.v8__Array__New(isolate, @intCast(data.pairs.items.len));
    for (data.pairs.items, 0..) |pair, i| {
        var out: c.MaybeBool = undefined;
        _ = c.v8__Object__Set(@ptrCast(arr), context, c.v8__Integer__NewFromUnsigned(isolate, @intCast(i)), @ptrCast(zigStringToV8(isolate, pair.value)), &out);
    }
    c.v8__ReturnValue__Set(ret, @ptrCast(arr));
}

pub fn headersForEach(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);

    const data = extractHeadersData(info) orelse return;
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

pub fn headersToString(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);

    const data = extractHeadersData(info) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(zigStringToV8(isolate, "")));
        return;
    };
    const serialized = data.serialize() catch {
        c.v8__ReturnValue__Set(ret, @ptrCast(zigStringToV8(isolate, "")));
        return;
    };
    defer gpa.free(serialized);
    c.v8__ReturnValue__Set(ret, @ptrCast(zigStringToV8(isolate, serialized)));
}

pub fn headersSize(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);

    const data = extractHeadersData(info) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Integer__New(isolate, 0)));
        return;
    };
    c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Integer__New(isolate, @intCast(data.pairs.items.len))));
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

    const fn_val = c.v8__Function__New__DEFAULT(context, headersConstructor);
    const key = c.v8__String__NewFromUtf8(isolate, "Headers", 0, -1);
    _ = c.v8__Object__Set(global, context, key, fn_val, &out);
}
