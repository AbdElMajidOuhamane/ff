const std = @import("std");
const c = @import("../c.zig").c;

const gpa = std.heap.page_allocator;

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

fn isAlphaNum(c2: u8) bool {
    return (c2 >= 'a' and c2 <= 'z') or (c2 >= 'A' and c2 <= 'Z') or (c2 >= '0' and c2 <= '9');
}

fn isFormUnreserved(c2: u8) bool {
    return isAlphaNum(c2) or c2 == '*' or c2 == '-' or c2 == '.' or c2 == '_';
}

fn formUrlEncode(input: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    for (input) |b| {
        if (b == ' ') {
            try result.append(gpa, '+');
        } else if (isFormUnreserved(b)) {
            try result.append(gpa, b);
        } else {
            try result.append(gpa, '%');
            try result.print(gpa, "{X:0>2}", .{b});
        }
    }
    return try result.toOwnedSlice(gpa);
}

fn formUrlDecode(input: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '+') {
            try result.append(gpa, ' ');
            i += 1;
        } else if (input[i] == '%' and i + 2 < input.len) {
            const hi = std.fmt.charToDigit(input[i + 1], 16) catch {
                try result.append(gpa, input[i]);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(input[i + 2], 16) catch {
                try result.append(gpa, input[i]);
                i += 1;
                continue;
            };
            try result.append(gpa, hi * 16 + lo);
            i += 3;
        } else {
            try result.append(gpa, input[i]);
            i += 1;
        }
    }
    return try result.toOwnedSlice(gpa);
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
    const data_key = c.v8__String__NewFromUtf8(isolate, "__d", 0, -1);
    const ext_val = c.v8__Object__Get(@ptrCast(this), context, data_key);
    if (ext_val == null or !c.v8__Value__IsExternal(ext_val)) return null;
    const ptr = c.v8__External__Value(@ptrCast(ext_val));
    return @ptrCast(@alignCast(ptr));
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
            const str = extractStringFromVal(isolate, init_val);
            if (str) |s| {
                defer gpa.free(s);
                data.parseFromString(s);
            }
        }
    }

    const obj = c.v8__Object__New(isolate);
    const ext = c.v8__External__New(isolate, @ptrCast(data));
    var out: c.MaybeBool = undefined;
    c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, "__d", 0, -1), ext, &out);

    const fns = .{
        .{ "get", spGet },
        .{ "getAll", spGetAll },
        .{ "has", spHas },
        .{ "set", spSet },
        .{ "append", spAppend },
        .{ "delete", spDelete },
        .{ "sort", spSort },
        .{ "toString", spToString },
        .{ "entries", spEntries },
        .{ "keys", spKeys },
        .{ "values", spValues },
        .{ "forEach", spForEach },
        .{ "size", spSize },
    };
    inline for (fns) |entry| {
        const fn_val = c.v8__Function__New__DEFAULT(context, entry[1]);
        c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, entry[0], 0, -1), fn_val, &out);
    }

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
    const name = extractStringFromVal(isolate, c.v8__FunctionCallbackInfo__INDEX(info, 0)) orelse return;
    defer gpa.free(name);
    if (data.getFirst(name)) |v| {
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
    const name = extractStringFromVal(isolate, c.v8__FunctionCallbackInfo__INDEX(info, 0)) orelse return;
    defer gpa.free(name);
    const vals = data.getAllValues(name);
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
    const name = extractStringFromVal(isolate, c.v8__FunctionCallbackInfo__INDEX(info, 0)) orelse return;
    defer gpa.free(name);
    var val: ?[]const u8 = null;
    var val_buf: ?[:0]const u8 = null;
    if (c.v8__FunctionCallbackInfo__Length(info) > 1) {
        const v = c.v8__FunctionCallbackInfo__INDEX(info, 1);
        if (!c.v8__Value__IsUndefined(v)) {
            val_buf = extractStringFromVal(isolate, v);
            val = val_buf;
        }
    }
    defer if (val_buf) |vb| gpa.free(vb);
    const result = data.hasEntry(name, val);
    c.v8__ReturnValue__Set(ret, if (result) @ptrCast(c.v8__True(isolate)) else @ptrCast(c.v8__False(isolate)));
}

fn spSet(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const data = extractSPData(info) orelse return;
    if (c.v8__FunctionCallbackInfo__Length(info) < 2) return;
    const name = extractStringFromVal(isolate, c.v8__FunctionCallbackInfo__INDEX(info, 0)) orelse return;
    defer gpa.free(name);
    const value = extractStringFromVal(isolate, c.v8__FunctionCallbackInfo__INDEX(info, 1)) orelse return;
    defer gpa.free(value);
    data.setEntry(name, value);
}

fn spAppend(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const data = extractSPData(info) orelse return;
    if (c.v8__FunctionCallbackInfo__Length(info) < 2) return;
    const name = extractStringFromVal(isolate, c.v8__FunctionCallbackInfo__INDEX(info, 0)) orelse return;
    defer gpa.free(name);
    const value = extractStringFromVal(isolate, c.v8__FunctionCallbackInfo__INDEX(info, 1)) orelse return;
    defer gpa.free(value);
    data.appendPair(name, value);
}

fn spDelete(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const data = extractSPData(info) orelse return;
    if (c.v8__FunctionCallbackInfo__Length(info) < 1) return;
    const name = extractStringFromVal(isolate, c.v8__FunctionCallbackInfo__INDEX(info, 0)) orelse return;
    defer gpa.free(name);
    var val: ?[]const u8 = null;
    var val_buf: ?[:0]const u8 = null;
    if (c.v8__FunctionCallbackInfo__Length(info) > 1) {
        const v = c.v8__FunctionCallbackInfo__INDEX(info, 1);
        if (!c.v8__Value__IsUndefined(v)) {
            val_buf = extractStringFromVal(isolate, v);
            val = val_buf;
        }
    }
    defer if (val_buf) |vb| gpa.free(vb);
    data.deleteEntry(name, val);
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

    const base_scheme = base.scheme;
    const base_host = if (base.host) |h| (try h.toRawMaybeAlloc(gpa)) else "";
    defer if (base_host.len > 0 and base.host == null) {};
    const base_path = try base.path.toRawMaybeAlloc(gpa);
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
            result_scheme = try gpa.dupe(u8, base_scheme);
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

    result_scheme = try gpa.dupe(u8, base_scheme);
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
        } else if (std.mem.eql(u8, rest, "..")) {
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
    const data_key = c.v8__String__NewFromUtf8(isolate, "__d", 0, -1);
    const ext_val = c.v8__Object__Get(@ptrCast(this), context, data_key);
    if (ext_val == null or !c.v8__Value__IsExternal(ext_val)) return null;
    const ptr = c.v8__External__Value(@ptrCast(ext_val));
    return @ptrCast(@alignCast(ptr));
}

fn setUrlProp(isolate: ?*c.Isolate, context: ?*c.Context, obj: *const c.Value, name: []const u8, val: []const u8) void {
    var out: c.MaybeBool = undefined;
    c.v8__Object__Set(@ptrCast(obj), context, c.v8__String__NewFromUtf8(isolate, @ptrCast(name.ptr), 0, @intCast(name.len)), zigStringToV8(isolate, val), &out);
}

fn createUrlJsObject(isolate: ?*c.Isolate, context: ?*c.Context, data: *UrlData) ?*const c.Value {
    const obj = c.v8__Object__New(isolate) orelse return null;
    const ext = c.v8__External__New(isolate, @ptrCast(data));
    var out: c.MaybeBool = undefined;
    c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, "__d", 0, -1), ext, &out);

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

    setUrlProp(isolate, context, obj, "href", href_val);
    setUrlProp(isolate, context, obj, "origin", origin_val);
    setUrlProp(isolate, context, obj, "host", host_val);
    setUrlProp(isolate, context, obj, "hostname", data.host);
    setUrlProp(isolate, context, obj, "port", port_val);
    setUrlProp(isolate, context, obj, "pathname", data.path);
    setUrlProp(isolate, context, obj, "search", search_val);
    setUrlProp(isolate, context, obj, "hash", hash_val);
    setUrlProp(isolate, context, obj, "username", data.username);
    setUrlProp(isolate, context, obj, "password", data.password);
    setUrlProp(isolate, context, obj, "protocol", protocol_val);
    const fns = .{
        .{ "toString", urlToString },
        .{ "toJSON", urlToJSON },
    };
    inline for (fns) |entry| {
        const fn_val = c.v8__Function__New__DEFAULT(context, entry[1]);
        c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, entry[0], 0, -1), fn_val, &out);
    }

    const sp_obj = createSPJsObject(isolate, context, data.search_params);
    c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, "searchParams", 0, -1), sp_obj, &out);

    return obj;
}

fn createSPJsObject(isolate: ?*c.Isolate, context: ?*c.Context, data: *URLSearchParamsData) ?*const c.Value {
    const obj = c.v8__Object__New(isolate) orelse return null;
    const ext = c.v8__External__New(isolate, @ptrCast(data));
    var out: c.MaybeBool = undefined;
    c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, "__d", 0, -1), ext, &out);

    const fns = .{
        .{ "get", spGet },
        .{ "getAll", spGetAll },
        .{ "has", spHas },
        .{ "set", spSet },
        .{ "append", spAppend },
        .{ "delete", spDelete },
        .{ "sort", spSort },
        .{ "toString", spToString },
        .{ "entries", spEntries },
        .{ "keys", spKeys },
        .{ "values", spValues },
        .{ "forEach", spForEach },
        .{ "size", spSize },
    };
    inline for (fns) |entry| {
        const fn_val = c.v8__Function__New__DEFAULT(context, entry[1]);
        c.v8__Object__Set(obj, context, c.v8__String__NewFromUtf8(isolate, entry[0], 0, -1), fn_val, &out);
    }

    return obj;
}

fn urlConstructor(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);

    if (c.v8__FunctionCallbackInfo__Length(info) < 1) {
        throwTypeError(isolate, "URL constructor requires at least 1 argument");
        return;
    }

    const input_val = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    const input = extractStringFromVal(isolate, input_val) orelse return;
    defer gpa.free(input);

    var base: ?[:0]const u8 = null;
    defer if (base) |b| gpa.free(b);

    if (c.v8__FunctionCallbackInfo__Length(info) > 1) {
        const base_val = c.v8__FunctionCallbackInfo__INDEX(info, 1);
        if (!c.v8__Value__IsUndefined(base_val) and !c.v8__Value__IsNull(base_val)) {
            base = extractStringFromVal(isolate, base_val);
        }
    }

    const data_ptr = gpa.create(UrlData) catch {
        throw(isolate, "out of memory");
        return;
    };
    data_ptr.* = if (base) |b|
        parseUrlRelative(input, b) catch {
            gpa.destroy(data_ptr);
            throwTypeError(isolate, "Invalid URL");
            return;
        }
    else
        parseUrlAbsolute(input) catch {
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

    const input_val = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    const input = extractStringFromVal(isolate, input_val) orelse return;
    defer gpa.free(input);

    var base: ?[:0]const u8 = null;
    defer if (base) |b| gpa.free(b);

    if (c.v8__FunctionCallbackInfo__Length(info) > 1) {
        const base_val = c.v8__FunctionCallbackInfo__INDEX(info, 1);
        if (!c.v8__Value__IsUndefined(base_val) and !c.v8__Value__IsNull(base_val)) {
            base = extractStringFromVal(isolate, base_val);
        }
    }

    const data_ptr = gpa.create(UrlData) catch return;
    data_ptr.* = if (base) |b|
        parseUrlRelative(input, b) catch {
            gpa.destroy(data_ptr);
            c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Null(isolate)));
            return;
        }
    else
        parseUrlAbsolute(input) catch {
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

    const input_val = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    const input = extractStringFromVal(isolate, input_val) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__False(isolate)));
        return;
    };
    defer gpa.free(input);

    var base: ?[:0]const u8 = null;
    defer if (base) |b| gpa.free(b);

    if (c.v8__FunctionCallbackInfo__Length(info) > 1) {
        const base_val = c.v8__FunctionCallbackInfo__INDEX(info, 1);
        if (!c.v8__Value__IsUndefined(base_val) and !c.v8__Value__IsNull(base_val)) {
            base = extractStringFromVal(isolate, base_val);
        }
    }

    const valid = if (base) |b|
        parseUrlRelative(input, b) catch null
    else
        parseUrlAbsolute(input) catch null;

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
