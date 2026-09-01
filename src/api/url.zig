const std = @import("std");
const c = @import("../c.zig").c;
const gpa = std.heap.smp_allocator;

var url_class_id: c.ClassID = 0;
var sp_class_id: c.ClassID = 0;

// ============================================================
// Helpers
// ============================================================
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
// URLSearchParamsData
// ============================================================
const Pair = struct { name: []const u8, value: []const u8 };
const SPEntry = struct {
    name_off: u32,
    name_len: u32,
    val_off: u32,
    val_len: u32,
};
comptime {
    std.debug.assert(@sizeOf(SPEntry) == 16);
}
const URLSearchParamsData = struct {
    names: std.ArrayList(u8),
    values: std.ArrayList(u8),
    entries: std.ArrayList(SPEntry),
    merge_buf: std.ArrayList(u8),
    view_buf: std.ArrayList([]const u8),
    ser_buf: std.ArrayList(u8),
    owned: bool = true,
    fn init() URLSearchParamsData {
        return .{
            .names = std.ArrayList(u8).empty,
            .values = std.ArrayList(u8).empty,
            .entries = std.ArrayList(SPEntry).empty,
            .merge_buf = std.ArrayList(u8).empty,
            .view_buf = std.ArrayList([]const u8).empty,
            .ser_buf = std.ArrayList(u8).empty,
        };
    }
    fn deinit(self: *URLSearchParamsData) void {
        self.names.deinit(gpa);
        self.values.deinit(gpa);
        self.entries.deinit(gpa);
        self.merge_buf.deinit(gpa);
        self.view_buf.deinit(gpa);
        self.ser_buf.deinit(gpa);
    }
    fn nameOf(self: *const URLSearchParamsData, e: SPEntry) []const u8 {
        return self.names.items[e.name_off .. e.name_off + e.name_len];
    }
    fn valueOf(self: *const URLSearchParamsData, e: SPEntry) []const u8 {
        return self.values.items[e.val_off .. e.val_off + e.val_len];
    }
    fn appendEntry(self: *URLSearchParamsData, name: []const u8, value: []const u8) void {
        const nbase = self.names.items.len;
        self.names.appendSlice(gpa, name) catch return;
        const vbase = self.values.items.len;
        self.values.appendSlice(gpa, value) catch {
            self.names.items.len = nbase;
            return;
        };
        self.entries.append(gpa, .{
            .name_off = @intCast(nbase),
            .name_len = @intCast(name.len),
            .val_off = @intCast(vbase),
            .val_len = @intCast(value.len),
        }) catch {
            self.names.items.len = nbase;
            self.values.items.len = vbase;
            return;
        };
    }
    fn parseFromString(self: *URLSearchParamsData, str: []const u8) void {
        if (str.len == 0) return;
        var rest = str;
        while (rest.len > 0) {
            const amp = std.mem.indexOf(u8, rest, "&");
            const pair_str = if (amp) |a| rest[0..a] else rest;
            const eq = std.mem.indexOf(u8, pair_str, "=");
            self.appendEntry(
                pair_str[0 .. eq orelse pair_str.len],
                if (eq) |e| pair_str[e + 1 ..] else "",
            );
            if (amp) |a| {
                rest = rest[a + 1 ..];
            } else {
                break;
            }
        }
    }
    fn removeSwap(self: *URLSearchParamsData, i: usize) void {
        const last = self.entries.items.len - 1;
        if (i != last) self.entries.items[i] = self.entries.items[last];
        self.entries.items.len -= 1;
    }
    fn deleteEntry(self: *URLSearchParamsData, name: []const u8, value: ?[]const u8) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const e = self.entries.items[i];
            if (std.mem.eql(u8, self.nameOf(e), name)) {
                if (value == null or std.mem.eql(u8, self.valueOf(e), value.?)) {
                    self.removeSwap(i);
                    continue;
                }
            }
            i += 1;
        }
    }
    fn getFirst(self: *const URLSearchParamsData, name: []const u8) ?[]const u8 {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, self.nameOf(e), name)) return self.valueOf(e);
        }
        return null;
    }
    fn getAllValues(self: *URLSearchParamsData, name: []const u8) [][]const u8 {
        self.view_buf.clearRetainingCapacity();
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, self.nameOf(e), name)) {
                self.view_buf.append(gpa, self.valueOf(e)) catch break;
            }
        }
        return self.view_buf.items;
    }
    fn hasEntry(self: *const URLSearchParamsData, name: []const u8, value: ?[]const u8) bool {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, self.nameOf(e), name)) {
                if (value == null or std.mem.eql(u8, self.valueOf(e), value.?)) return true;
            }
        }
        return false;
    }
    fn setEntry(self: *URLSearchParamsData, name: []const u8, value: []const u8) void {
        var found = false;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (std.mem.eql(u8, self.nameOf(self.entries.items[i]), name)) {
                if (!found) {
                    const vbase = self.values.items.len;
                    self.values.appendSlice(gpa, value) catch return;
                    self.entries.items[i].val_off = @intCast(vbase);
                    self.entries.items[i].val_len = @intCast(value.len);
                    found = true;
                    i += 1;
                } else {
                    self.removeSwap(i);
                }
            } else {
                i += 1;
            }
        }
        if (!found) self.appendEntry(name, value);
    }
    fn appendPair(self: *URLSearchParamsData, name: []const u8, value: []const u8) void {
        self.appendEntry(name, value);
    }
    fn sortPairs(self: *URLSearchParamsData) void {
        std.mem.sort(SPEntry, self.entries.items, self, struct {
            fn lessThan(ctx: *URLSearchParamsData, a: SPEntry, b: SPEntry) bool {
                return std.mem.order(u8, ctx.nameOf(a), ctx.nameOf(b)) == .lt;
            }
        }.lessThan);
    }
    fn serialize(self: *URLSearchParamsData) []const u8 {
        self.ser_buf.clearRetainingCapacity();
        for (self.entries.items, 0..) |pair, i| {
            if (i > 0) self.ser_buf.append(gpa, '&') catch break;
            self.ser_buf.appendSlice(gpa, self.nameOf(pair)) catch break;
            self.ser_buf.append(gpa, '=') catch break;
            self.ser_buf.appendSlice(gpa, self.valueOf(pair)) catch break;
        }
        return self.ser_buf.items;
    }
};

fn extractSPData(ctx: ?*c.Context, this_val: c.Value) ?*URLSearchParamsData {
    const ptr = c.getOpaque2(ctx, this_val, sp_class_id) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

// ============================================================
// URLSearchParams callbacks
// ============================================================
fn spGet(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const data = extractSPData(ctx, this_val) orelse return c.JS_NULL;
    if (argc < 1) return c.JS_NULL;
    var name_buf: [128]u8 = undefined;
    const name = extractStringAuto(ctx, argv[0], &name_buf) orelse return c.JS_NULL;
    defer name.deinit();
    if (data.getFirst(name.slice)) |v| {
        return zigStringToJS(ctx, v);
    }
    return c.JS_NULL;
}

fn spGetAll(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const data = extractSPData(ctx, this_val) orelse return c.newArray(ctx);
    if (argc < 1) return c.newArray(ctx);
    var name_buf: [128]u8 = undefined;
    const name = extractStringAuto(ctx, argv[0], &name_buf) orelse return c.newArray(ctx);
    defer name.deinit();
    const vals = data.getAllValues(name.slice);
    const arr = c.newArray(ctx);
    for (vals, 0..) |v, i| {
        _ = c.definePropertyValueUint32(ctx, arr, @intCast(i), zigStringToJS(ctx, v), c.PROP_C_W_E);
    }
    return arr;
}

fn spHas(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const data = extractSPData(ctx, this_val) orelse return c.JS_FALSE;
    if (argc < 1) return c.JS_FALSE;
    var name_buf: [128]u8 = undefined;
    var val_stack: [256]u8 = undefined;
    const name = extractStringAuto(ctx, argv[0], &name_buf) orelse return c.JS_FALSE;
    defer name.deinit();
    var val: ?[]const u8 = null;
    var val_ex: ?ExtractedStr = null;
    if (argc > 1) {
        if (c.isUndefined(argv[1]) == 0) {
            val_ex = extractStringAuto(ctx, argv[1], &val_stack);
            if (val_ex) |ex| val = ex.slice;
        }
    }
    defer if (val_ex) |ex| ex.deinit();
    return if (data.hasEntry(name.slice, val)) c.JS_TRUE else c.JS_FALSE;
}

fn spSet(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    
    const data = extractSPData(ctx, this_val) orelse return c.JS_UNDEFINED;
    if (argc < 2) return c.JS_UNDEFINED;
    var name_buf: [128]u8 = undefined;
    var value_buf: [256]u8 = undefined;
    const name = extractStringAuto(ctx, argv[0], &name_buf) orelse return c.JS_UNDEFINED;
    defer name.deinit();
    const value = extractStringAuto(ctx, argv[1], &value_buf) orelse return c.JS_UNDEFINED;
    defer value.deinit();
    data.setEntry(name.slice, value.slice);
    return c.JS_UNDEFINED;
}

fn spAppend(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    
    const data = extractSPData(ctx, this_val) orelse return c.JS_UNDEFINED;
    if (argc < 2) return c.JS_UNDEFINED;
    var name_buf: [128]u8 = undefined;
    var value_buf: [256]u8 = undefined;
    const name = extractStringAuto(ctx, argv[0], &name_buf) orelse return c.JS_UNDEFINED;
    defer name.deinit();
    const value = extractStringAuto(ctx, argv[1], &value_buf) orelse return c.JS_UNDEFINED;
    defer value.deinit();
    data.appendPair(name.slice, value.slice);
    return c.JS_UNDEFINED;
}

fn spDelete(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    
    const data = extractSPData(ctx, this_val) orelse return c.JS_UNDEFINED;
    if (argc < 1) return c.JS_UNDEFINED;
    var name_buf: [128]u8 = undefined;
    var val_stack: [256]u8 = undefined;
    const name = extractStringAuto(ctx, argv[0], &name_buf) orelse return c.JS_UNDEFINED;
    defer name.deinit();
    var val: ?[]const u8 = null;
    var val_ex: ?ExtractedStr = null;
    if (argc > 1) {
        if (c.isUndefined(argv[1]) == 0) {
            val_ex = extractStringAuto(ctx, argv[1], &val_stack);
            if (val_ex) |ex| val = ex.slice;
        }
    }
    defer if (val_ex) |ex| ex.deinit();
    data.deleteEntry(name.slice, val);
    return c.JS_UNDEFINED;
}

fn spSort(ctx: ?*c.Context, this_val: c.Value, _: c_int, _: [*c]c.Value) callconv(.c) c.Value {
    const data = extractSPData(ctx, this_val) orelse return c.JS_UNDEFINED;
    data.sortPairs();
    return c.JS_UNDEFINED;
}

fn spToString(ctx: ?*c.Context, this_val: c.Value, _: c_int, _: [*c]c.Value) callconv(.c) c.Value {
    const data = extractSPData(ctx, this_val) orelse return zigStringToJS(ctx, "");
    return zigStringToJS(ctx, data.serialize());
}

fn spSize(ctx: ?*c.Context, this_val: c.Value, _: c_int, _: [*c]c.Value) callconv(.c) c.Value {
    const data = extractSPData(ctx, this_val) orelse return c.newInt32(ctx, 0);
    return c.newInt32(ctx, @intCast(data.entries.items.len));
}

fn spEntries(ctx: ?*c.Context, this_val: c.Value, _: c_int, _: [*c]c.Value) callconv(.c) c.Value {
    const data = extractSPData(ctx, this_val) orelse return c.newArray(ctx);
    const arr = c.newArray(ctx);
    for (data.entries.items, 0..) |e, i| {
        const pair_arr = c.newArray(ctx);
        _ = c.definePropertyValueUint32(ctx, pair_arr, 0, zigStringToJS(ctx, data.nameOf(e)), c.PROP_C_W_E);
        _ = c.definePropertyValueUint32(ctx, pair_arr, 1, zigStringToJS(ctx, data.valueOf(e)), c.PROP_C_W_E);
        _ = c.definePropertyValueUint32(ctx, arr, @intCast(i), pair_arr, c.PROP_C_W_E);
    }
    return arr;
}

fn spKeys(ctx: ?*c.Context, this_val: c.Value, _: c_int, _: [*c]c.Value) callconv(.c) c.Value {
    const data = extractSPData(ctx, this_val) orelse return c.newArray(ctx);
    const arr = c.newArray(ctx);
    for (data.entries.items, 0..) |e, i| {
        _ = c.definePropertyValueUint32(ctx, arr, @intCast(i), zigStringToJS(ctx, data.nameOf(e)), c.PROP_C_W_E);
    }
    return arr;
}

fn spValues(ctx: ?*c.Context, this_val: c.Value, _: c_int, _: [*c]c.Value) callconv(.c) c.Value {
    const data = extractSPData(ctx, this_val) orelse return c.newArray(ctx);
    const arr = c.newArray(ctx);
    for (data.entries.items, 0..) |e, i| {
        _ = c.definePropertyValueUint32(ctx, arr, @intCast(i), zigStringToJS(ctx, data.valueOf(e)), c.PROP_C_W_E);
    }
    return arr;
}

fn spForEach(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const data = extractSPData(ctx, this_val) orelse return c.JS_UNDEFINED;
    if (argc < 1) return c.JS_UNDEFINED;
    const callback = argv[0];
    if (c.isFunction(ctx, callback) == 0) return c.JS_UNDEFINED;
    for (data.entries.items) |e| {
        var args = [_]c.Value{
            zigStringToJS(ctx, data.valueOf(e)),
            zigStringToJS(ctx, data.nameOf(e)),
            this_val,
        };
        _ = c.call(ctx, callback, c.JS_UNDEFINED, 3, &args);
    }
    return c.JS_UNDEFINED;
}

fn spFinalizer(rt: ?*c.Runtime, val: c.Value) callconv(.c) void {
    _ = rt;
    if (c.getOpaque(val, sp_class_id)) |ptr| {
        const data: *URLSearchParamsData = @ptrCast(@alignCast(ptr));
        if (data.owned) {
            data.deinit();
            gpa.destroy(data);
        }
    }
}

fn spConstructor(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    const data = gpa.create(URLSearchParamsData) catch return c.throwOutOfMemory(ctx);
    data.* = URLSearchParamsData.init();
    if (argc > 0) {
        if (c.isString(argv[0]) != 0) {
            var str_buf: [512]u8 = undefined;
            if (extractStringAuto(ctx, argv[0], &str_buf)) |s| {
                defer s.deinit();
                data.parseFromString(s.slice);
            }
        }
    }
    const obj = c.newObjectClass(ctx, @intCast(sp_class_id));
    c.setOpaque(obj, data);
    return obj;
}

// ============================================================
// UrlData
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
    owned: bool = true,
        fn deinit(self: *UrlData) void {
        gpa.free(self.scheme);
        gpa.free(self.host);
        gpa.free(self.path);
        gpa.free(self.query);
        gpa.free(self.fragment);
        gpa.free(self.username);
        gpa.free(self.password);
        // search_params is owned by its URLSearchParams JS object
        // (spFinalizer frees it — do NOT free it here).
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

fn extractUrlData(ctx: ?*c.Context, this_val: c.Value) ?*UrlData {
    const ptr = c.getOpaque2(ctx, this_val, url_class_id) orelse return null;
    return @ptrCast(@alignCast(ptr));
}


fn parseUrlAbsolute(input: []const u8) !UrlData {
    const uri = try std.Uri.parse(input);
    const scheme = try gpa.dupe(u8, uri.scheme);
    // toRawMaybeAlloc may return a VIEW into `input` (stack memory) when the
    // component has no '%' escapes — UrlData must own heap copies.
    const host = if (uri.host) |h| (try gpa.dupe(u8, try h.toRawMaybeAlloc(gpa))) else try gpa.dupe(u8, "");
    const raw_path = try gpa.dupe(u8, try uri.path.toRawMaybeAlloc(gpa));
    const path = if (raw_path.len == 0) blk: {
        gpa.free(raw_path);
        break :blk try gpa.dupe(u8, "/");
    } else raw_path;
    const query = if (uri.query) |q| (try gpa.dupe(u8, try q.toRawMaybeAlloc(gpa))) else try gpa.dupe(u8, "");
    const fragment = if (uri.fragment) |f| (try gpa.dupe(u8, try f.toRawMaybeAlloc(gpa))) else try gpa.dupe(u8, "");
    const username = if (uri.user) |u| (try gpa.dupe(u8, try u.toRawMaybeAlloc(gpa))) else try gpa.dupe(u8, "");
    const password = if (uri.password) |p| (try gpa.dupe(u8, try p.toRawMaybeAlloc(gpa))) else try gpa.dupe(u8, "");
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
            result_host = if (rel.host) |h| (try gpa.dupe(u8, try h.toRawMaybeAlloc(gpa))) else try gpa.dupe(u8, "");
            result_port = rel.port;
            result_path = if (rel.path.isEmpty())
                try gpa.dupe(u8, "/")
            else
                try removeDotSegments(try rel.path.toRawMaybeAlloc(gpa));
            result_query = if (rel.query) |q| (try gpa.dupe(u8, try q.toRawMaybeAlloc(gpa))) else try gpa.dupe(u8, "");
            result_fragment = if (rel.fragment) |f| (try gpa.dupe(u8, try f.toRawMaybeAlloc(gpa))) else try gpa.dupe(u8, "");
            if (rel.user) |u| result_user = try gpa.dupe(u8, try u.toRawMaybeAlloc(gpa));
            if (rel.password) |p| result_pass = try gpa.dupe(u8, try p.toRawMaybeAlloc(gpa));
            const sp = gpa.create(URLSearchParamsData) catch return error.OutOfMemory;
            sp.* = URLSearchParamsData.init();
            sp.parseFromString(result_query);
            return .{
                .scheme = result_scheme, .host = result_host, .port = result_port,
                .path = result_path, .query = result_query, .fragment = result_fragment,
                .username = result_user, .password = result_pass, .search_params = sp,
            };
        }
        if (rel.host) |h| {
            result_scheme = try gpa.dupe(u8, base.scheme);
            result_host = try gpa.dupe(u8, try h.toRawMaybeAlloc(gpa));
            result_port = rel.port;
            result_path = if (rel.path.isEmpty())
                try gpa.dupe(u8, "/")
            else
                try removeDotSegments(try rel.path.toRawMaybeAlloc(gpa));
            result_query = if (rel.query) |q| (try gpa.dupe(u8, try q.toRawMaybeAlloc(gpa))) else try gpa.dupe(u8, "");
            result_fragment = if (rel.fragment) |f| (try gpa.dupe(u8, try f.toRawMaybeAlloc(gpa))) else try gpa.dupe(u8, "");
            const sp = gpa.create(URLSearchParamsData) catch return error.OutOfMemory;
            sp.* = URLSearchParamsData.init();
            sp.parseFromString(result_query);
            return .{
                .scheme = result_scheme, .host = result_host, .port = result_port,
                .path = result_path, .query = result_query, .fragment = result_fragment,
                .username = result_user, .password = result_pass, .search_params = sp,
            };
        }
    } else |_| {}
    const base_host_owned = try gpa.dupe(u8, if (base.host) |h| (try h.toRawMaybeAlloc(gpa)) else "");
    defer gpa.free(base_host_owned);
    const base_host = base_host_owned;
    const base_path = try gpa.dupe(u8, try base.path.toRawMaybeAlloc(gpa));
    defer gpa.free(base_path);
    result_scheme = try gpa.dupe(u8, base.scheme);
    result_host = try gpa.dupe(u8, base_host);
    result_port = base_port;
    const rel_path = input;
    if (rel_path.len == 0) {
        result_path = try gpa.dupe(u8, base_path);
        result_query = if (base.query) |q| (try gpa.dupe(u8, try q.toRawMaybeAlloc(gpa))) else try gpa.dupe(u8, "");
    } else if (rel_path[0] == '?') {
        result_path = try gpa.dupe(u8, base_path);
        result_query = try gpa.dupe(u8, rel_path[1..]);
    } else if (rel_path[0] == '#') {
        result_path = try gpa.dupe(u8, base_path);
        result_query = if (base.query) |q| (try gpa.dupe(u8, try q.toRawMaybeAlloc(gpa))) else try gpa.dupe(u8, "");
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
        .scheme = result_scheme, .host = result_host, .port = result_port,
        .path = result_path, .query = result_query, .fragment = result_fragment,
        .username = result_user, .password = result_pass, .search_params = sp,
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

// ============================================================
// Build URLSearchParams JS object
// ============================================================
fn createSPJsObject(ctx: ?*c.Context, data: *URLSearchParamsData) c.Value {
    const obj = c.newObjectClass(ctx, @intCast(sp_class_id));
    c.setOpaque(obj, data);
    return obj;
}

// ============================================================
// Build URL JS object
// ============================================================
fn createUrlJsObject(ctx: ?*c.Context, data: *UrlData) c.Value {
    const obj = c.newObjectClass(ctx, @intCast(url_class_id));
    c.setOpaque(obj, data);

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

    _ = c.definePropertyValueStr(ctx, obj, "href", zigStringToJS(ctx, href_val), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "origin", zigStringToJS(ctx, origin_val), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "host", zigStringToJS(ctx, host_val), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "hostname", zigStringToJS(ctx, data.host), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "port", zigStringToJS(ctx, port_val), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "pathname", zigStringToJS(ctx, data.path), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "search", zigStringToJS(ctx, search_val), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "hash", zigStringToJS(ctx, hash_val), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "username", zigStringToJS(ctx, data.username), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "password", zigStringToJS(ctx, data.password), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "protocol", zigStringToJS(ctx, protocol_val), c.PROP_C_W_E);
    data.search_params.owned = false;
    const sp_obj = createSPJsObject(ctx, data.search_params);
    _ = c.definePropertyValueStr(ctx, obj, "searchParams", sp_obj, c.PROP_C_W_E);
    return obj;
}

// ============================================================
// URL callbacks
// ============================================================
fn urlToString(ctx: ?*c.Context, this_val: c.Value, _: c_int, _: [*c]c.Value) callconv(.c) c.Value {
    const data = extractUrlData(ctx, this_val) orelse return zigStringToJS(ctx, "");
    const str = data.serialize() catch return zigStringToJS(ctx, "");
    defer if (str.len > 0) gpa.free(str);
    return zigStringToJS(ctx, str);
}

fn urlToJSON(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    return urlToString(ctx, this_val, argc, argv);
}

fn urlFinalizer(rt: ?*c.Runtime, val: c.Value) callconv(.c) void {
    _ = rt;
    if (c.getOpaque(val, url_class_id)) |ptr| {
        const data: *UrlData = @ptrCast(@alignCast(ptr));
        if (data.owned) {
            data.deinit();
            gpa.destroy(data);
        }
    }
}

fn urlConstructor(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _=this_val;
    if (argc < 1) {
        _ = c.throwTypeError(ctx, "URL constructor requires at least 1 argument");
        return c.JS_EXCEPTION;
    }
    var input_buf: [512]u8 = undefined;
    var base_buf: [512]u8 = undefined;
    const input = extractStringAuto(ctx, argv[0], &input_buf) orelse return c.JS_EXCEPTION;
    defer input.deinit();
    var base: ?ExtractedStr = null;
    if (argc > 1 and c.isUndefined(argv[1]) == 0 and c.isNull(argv[1]) == 0) {
        base = extractStringAuto(ctx, argv[1], &base_buf);
    }
    defer if (base) |b| b.deinit();
    const data_ptr = gpa.create(UrlData) catch return c.throwOutOfMemory(ctx);
    data_ptr.* = if (base) |b|
        parseUrlRelative(input.slice, b.slice) catch {
            gpa.destroy(data_ptr);
            _ = c.throwTypeError(ctx, "Invalid URL");
            return c.JS_EXCEPTION;
        }
    else
        parseUrlAbsolute(input.slice) catch {
            gpa.destroy(data_ptr);
            _ = c.throwTypeError(ctx, "Invalid URL");
            return c.JS_EXCEPTION;
        };
    const obj = c.newObjectClass(ctx, @intCast(url_class_id)); // CHANGED
    c.setOpaque(obj, data_ptr);                                // CHANGED
    data_ptr.search_params.owned = false;
    const sp_obj = createSPJsObject(ctx, data_ptr.search_params);

    const href_val = data_ptr.serialize() catch "";
    defer if (href_val.len > 0) gpa.free(href_val);
    const origin_val = data_ptr.originStr() catch "";
    defer if (origin_val.len > 0) gpa.free(origin_val);
    const host_val = data_ptr.hostStr() catch "";
    defer if (host_val.len > 0) gpa.free(host_val);
    var protocol_buf: [256]u8 = undefined;
    const protocol_val = data_ptr.protocolStr(&protocol_buf);
    const port_val = data_ptr.portStr() catch "";
    defer if (port_val.len > 0) gpa.free(port_val);
    const search_val = data_ptr.searchStr() catch "";
    defer if (search_val.len > 0) gpa.free(search_val);
    const hash_val = data_ptr.hashStr() catch "";
    defer if (hash_val.len > 0) gpa.free(hash_val);

    _ = c.definePropertyValueStr(ctx, obj, "href", zigStringToJS(ctx, href_val), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "origin", zigStringToJS(ctx, origin_val), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "host", zigStringToJS(ctx, host_val), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "hostname", zigStringToJS(ctx, data_ptr.host), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "port", zigStringToJS(ctx, port_val), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "pathname", zigStringToJS(ctx, data_ptr.path), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "search", zigStringToJS(ctx, search_val), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "hash", zigStringToJS(ctx, hash_val), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "username", zigStringToJS(ctx, data_ptr.username), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "password", zigStringToJS(ctx, data_ptr.password), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "protocol", zigStringToJS(ctx, protocol_val), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "searchParams", sp_obj, c.PROP_C_W_E);
    return obj; // CHANGED
}

fn urlParseStatic(ctx: ?*c.Context, _: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    if (argc < 1) return c.JS_NULL;
    var input_buf: [512]u8 = undefined;
    var base_buf: [512]u8 = undefined;
    const input = extractStringAuto(ctx, argv[0], &input_buf) orelse return c.JS_NULL;
    defer input.deinit();
    var base: ?ExtractedStr = null;
    if (argc > 1 and c.isUndefined(argv[1]) == 0 and c.isNull(argv[1]) == 0) {
        base = extractStringAuto(ctx, argv[1], &base_buf);
    }
    defer if (base) |b| b.deinit();
    const data_ptr = gpa.create(UrlData) catch return c.JS_NULL;
    data_ptr.* = if (base) |b|
        parseUrlRelative(input.slice, b.slice) catch {
            gpa.destroy(data_ptr);
            return c.JS_NULL;
        }
    else
        parseUrlAbsolute(input.slice) catch {
            gpa.destroy(data_ptr);
            return c.JS_NULL;
        };
    return createUrlJsObject(ctx, data_ptr);
}

fn urlCanParseStatic(ctx: ?*c.Context, _: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    if (argc < 1) return c.JS_FALSE;
    var input_buf: [512]u8 = undefined;
    var base_buf: [512]u8 = undefined;
    const input = extractStringAuto(ctx, argv[0], &input_buf) orelse return c.JS_FALSE;
    defer input.deinit();
    var base: ?ExtractedStr = null;
    if (argc > 1 and c.isUndefined(argv[1]) == 0 and c.isNull(argv[1]) == 0) {
        base = extractStringAuto(ctx, argv[1], &base_buf);
    }
    defer if (base) |b| b.deinit();
    const valid = if (base) |b|
        parseUrlRelative(input.slice, b.slice) catch null
    else
        parseUrlAbsolute(input.slice) catch null;
    if (valid) |v| {
        var data = v;
        data.deinit();
        return c.JS_TRUE;
    }
    return c.JS_FALSE;
}

// ============================================================
// Setup
// ============================================================
pub fn setup(ctx: ?*c.Context) void {
    {
        var sp_def = c.ClassDef{
            .class_name = "URLSearchParams",
            .finalizer = spFinalizer,
        };
        _ = c.newClassID(&sp_class_id);
        _ = c.newClass(c.getRuntime(ctx), sp_class_id, &sp_def);
        const sp_proto = c.newObject(ctx);
        const sp_methods = [_]struct { name: [*:0]const u8, func: *const c.CFunction, len: c_int }{
            .{ .name = "get", .func = &spGet, .len = 1 },
            .{ .name = "getAll", .func = &spGetAll, .len = 1 },
            .{ .name = "has", .func = &spHas, .len = 1 },
            .{ .name = "set", .func = &spSet, .len = 2 },
            .{ .name = "append", .func = &spAppend, .len = 2 },
            .{ .name = "delete", .func = &spDelete, .len = 1 },
            .{ .name = "sort", .func = &spSort, .len = 0 },
            .{ .name = "toString", .func = &spToString, .len = 0 },
            .{ .name = "entries", .func = &spEntries, .len = 0 },
            .{ .name = "keys", .func = &spKeys, .len = 0 },
            .{ .name = "values", .func = &spValues, .len = 0 },
            .{ .name = "forEach", .func = &spForEach, .len = 1 },
            .{ .name = "size", .func = &spSize, .len = 0 },
        };
        for (sp_methods) |m| {
            const fn_val = c.newCFunction(ctx, m.func, m.name, m.len);
            _ = c.definePropertyValueStr(ctx, sp_proto, m.name, fn_val, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
        }
        c.setClassProto(ctx, sp_class_id, sp_proto);
    }

    {
        var url_def = c.ClassDef{
            .class_name = "URL",
            .finalizer = urlFinalizer,
        };
        _ = c.newClassID(&url_class_id);
        _ = c.newClass(c.getRuntime(ctx), url_class_id, &url_def);
        const url_proto = c.newObject(ctx);
        const url_methods = [_]struct { name: [*:0]const u8, func: *const c.CFunction, len: c_int }{
            .{ .name = "toString", .func = &urlToString, .len = 0 },
            .{ .name = "toJSON", .func = &urlToJSON, .len = 0 },
        };
        for (url_methods) |m| {
            const fn_val = c.newCFunction(ctx, m.func, m.name, m.len);
            _ = c.definePropertyValueStr(ctx, url_proto, m.name, fn_val, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
        }
        c.setClassProto(ctx, url_class_id, url_proto);
    }

    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);

    const sp_ctor = c.newCFunction2(ctx, &spConstructor, "URLSearchParams", 1, c.JS_CFUNC_constructor, 0);
    _ = c.definePropertyValueStr(ctx, global, "URLSearchParams", sp_ctor, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);

    const url_ctor = c.newCFunction2(ctx, &urlConstructor, "URL", 2, c.JS_CFUNC_constructor, 0);
    _ = c.definePropertyValueStr(ctx, global, "URL", url_ctor, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);

    const parse_fn = c.newCFunction(ctx, &urlParseStatic, "parse", 2);
    _ = c.definePropertyValueStr(ctx, url_ctor, "parse", parse_fn, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
    const can_parse_fn = c.newCFunction(ctx, &urlCanParseStatic, "canParse", 2);
    _ = c.definePropertyValueStr(ctx, url_ctor, "canParse", can_parse_fn, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
}
