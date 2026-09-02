const std = @import("std");
const c = @import("../c.zig").c;
const gpa = std.heap.smp_allocator;
const PoolSlice = @import("../types/pool_slice.zig").PoolSlice;

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
    block: ?*UrlBlock = null,
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
        if (data.block) |b| {
            b.release(); // embedded in a URL block
        } else {
            data.deinit();
            gpa.destroy(data); // standalone new URLSearchParams()
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
// UrlData + UrlBlock — single allocation per URL
// ============================================================
const UrlData = struct {
    block: *UrlBlock, // ownership handle — released by urlFinalizer, never freed here
    pool: [*]u8,
    port: ?u16 = null,
    scheme: []const u8 = "",
    host: []const u8 = "",
    path: []const u8 = "",
    query: []const u8 = "",
    fragment: []const u8 = "",
    username: []const u8 = "",
    password: []const u8 = "",
    href: []const u8 = "",
    origin: []const u8 = "",
    host_str: []const u8 = "",
    search: []const u8 = "",
    hash: []const u8 = "",
    port_str: []const u8 = "",

    fn protocolStr(self: *const UrlData, buf: *[256]u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}:", .{self.scheme}) catch self.scheme;
    }
};

const UrlBlock = struct {
    mem_len: u32,
    refs: u32,
    sp: URLSearchParamsData,
    url: UrlData,

    fn create(pool_len: usize) !*UrlBlock {
        const hdr = std.mem.alignForward(usize, @sizeOf(UrlBlock), 8);
        const total = hdr + pool_len;
        const mem = try gpa.alignedAlloc(u8, .of(UrlBlock), total);
        const block: *UrlBlock = @ptrCast(@alignCast(mem.ptr));
        block.* = .{
            .mem_len = @intCast(total),
            .refs = 1,
            .sp = URLSearchParamsData.init(),
            .url = .{ .block = block, .pool = mem.ptr + hdr },
        };
        return block;
    }
    fn poolSlice(self: *UrlBlock) []u8 {
        const hdr = std.mem.alignForward(usize, @sizeOf(UrlBlock), 8);
        return (@as([*]u8, @ptrCast(self)) + hdr)[0 .. self.mem_len - hdr];
    }
    fn retain(self: *UrlBlock) void {
        self.refs += 1;
    }
    fn release(self: *UrlBlock) void {
        self.refs -= 1;
        if (self.refs == 0) {
            self.sp.deinit();
            gpa.free(@as([*]u8, @ptrCast(self))[0..self.mem_len]);
        }
    }
};

comptime {
    std.debug.assert(@sizeOf(PoolSlice) == 8);
}

const PoolWriter = struct {
    pool: []u8,
    used: usize = 0,
    fn rest(self: *PoolWriter) []u8 {
        return self.pool[self.used..];
    }
    fn mark(self: *PoolWriter) usize {
        return self.used;
    }
    fn sliceFrom(self: *PoolWriter, off: usize) []const u8 {
        return self.pool[off..][0 .. self.used - off];
    }
    fn put(self: *PoolWriter, bytes: []const u8) []const u8 {
        if (bytes.len == 0) return "";
        const off = self.used;
        @memcpy(self.pool[off..][0..bytes.len], bytes);
        self.used += bytes.len;
        return self.pool[off..][0..bytes.len];
    }
    fn putUint(self: *PoolWriter, v: u16) void {
        var buf: [5]u8 = undefined;
        var n: usize = 0;
        var x = v;
        if (x == 0) {
            self.pool[self.used] = '0';
            self.used += 1;
            return;
        }
        while (x > 0) : (x /= 10) {
            buf[n] = @intCast('0' + x % 10);
            n += 1;
        }
        while (n > 0) {
            n -= 1;
            self.pool[self.used] = buf[n];
            self.used += 1;
        }
    }
    fn putComponent(self: *PoolWriter, comp: std.Uri.Component) []const u8 {
        switch (comp) {
            .raw => |raw| return self.put(raw),
            .percent_encoded => |pe| {
                const off = self.used;
                var i: usize = 0;
                while (i < pe.len) {
                    if (pe[i] == '%' and i + 2 < pe.len) {
                        if (std.fmt.parseInt(u8, pe[i + 1 .. i + 3], 16)) |byte| {
                            self.pool[self.used] = byte;
                            self.used += 1;
                            i += 3;
                            continue;
                        } else |_| {}
                    }
                    self.pool[self.used] = pe[i];
                    self.used += 1;
                    i += 1;
                }
                return self.pool[off..][0 .. self.used - off];
            },
        }
    }
};

fn appendPort(url: *UrlData, w: *PoolWriter) void {
    const p = url.port orelse return;
    if (defaultPortForScheme(url.scheme)) |dp| {
        if (p == dp) return;
    }
    _ = w.put(":");
    w.putUint(p);
}

fn deriveStrings(url: *UrlData, w: *PoolWriter) void {
    var m = w.mark();
    if (url.query.len > 0) {
        _ = w.put("?");
        _ = w.put(url.query);
        url.search = w.sliceFrom(m);
    } else {
        url.search = "";
    }
    m = w.mark();
    if (url.fragment.len > 0) {
        _ = w.put("#");
        _ = w.put(url.fragment);
        url.hash = w.sliceFrom(m);
    } else {
        url.hash = "";
    }
    m = w.mark();
    _ = w.put(url.host);
    appendPort(url, w);
    url.host_str = w.sliceFrom(m);
    if (url.port != null and blk: {
        const dp = defaultPortForScheme(url.scheme) orelse break :blk true;
        break :blk url.port.? != dp;
    }) {
        m = w.mark();
        w.putUint(url.port.?);
        url.port_str = w.sliceFrom(m);
    }
    if (std.mem.eql(u8, url.scheme, "file") or !isSpecialScheme(url.scheme)) {
        url.origin = w.put("null");
    } else {
        m = w.mark();
        _ = w.put(url.scheme);
        _ = w.put("://");
        _ = w.put(url.host_str);
        url.origin = w.sliceFrom(m);
    }
    m = w.mark();
    _ = w.put(url.scheme);
    _ = w.put("://");
    if (url.username.len > 0 or url.password.len > 0) {
        _ = w.put(url.username);
        if (url.password.len > 0) {
            _ = w.put(":");
            _ = w.put(url.password);
        }
        _ = w.put("@");
    }
    _ = w.put(url.host_str);
    _ = w.put(url.path);
    _ = w.put(url.search);
    _ = w.put(url.hash);
    url.href = w.sliceFrom(m);
}

fn extractUrlData(ctx: ?*c.Context, this_val: c.Value) ?*UrlData {
    const ptr = c.getOpaque2(ctx, this_val, url_class_id) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

// ── URL property accessors (CHANGED: proto get/set pairs, block swap) ──
// Every setter: recompose the full URL → reparse into a NEW single-alloc
// block → repoint the searchParams object → release the old block.
const UrlField = enum { href, protocol, host, hostname, port, pathname, search, hash, username, password };

fn setUrlField(ctx: ?*c.Context, this_val: c.Value, field: UrlField, raw: []const u8) void {
    const old = extractUrlData(ctx, this_val) orelse return;
    var buf: [8192]u8 = undefined;
    var n: usize = 0;
    switch (field) {
        .href => {
            if (raw.len > buf.len) return;
            @memcpy(buf[0..raw.len], raw);
            n = raw.len;
        },
        .protocol => {
            const s = if (std.mem.endsWith(u8, raw, ":")) raw[0 .. raw.len - 1] else raw;
            const sep = std.mem.indexOf(u8, old.href, "://") orelse return;
            const rest = old.href[sep + 3 ..];
            if (s.len + 3 + rest.len > buf.len) return;
            @memcpy(buf[0..s.len], s);
            n = s.len;
            @memcpy(buf[n..][0..3], "://");
            n += 3;
            @memcpy(buf[n..][0..rest.len], rest);
            n += rest.len;
        },
        .host, .hostname => {
            var host_part: []const u8 = raw;
            var port_part: []const u8 = if (field == .hostname) old.port_str else "";
            if (field == .host) {
                if (std.mem.lastIndexOfScalar(u8, raw, ':')) |ci| {
                    host_part = raw[0..ci];
                    port_part = raw[ci + 1 ..];
                }
            }
            const sep = std.mem.indexOf(u8, old.href, "://") orelse return;
            const after_scheme = old.href[sep + 3 ..];
            const auth_end = std.mem.indexOfScalar(u8, after_scheme, '/') orelse after_scheme.len;
            const rest = after_scheme[auth_end..];
            if (sep + 3 + host_part.len + 1 + port_part.len + rest.len > buf.len) return;
            @memcpy(buf[0 .. sep + 3], old.href[0 .. sep + 3]);
            n = sep + 3;
            if (old.username.len > 0 or old.password.len > 0) {
                _ = std.fmt.bufPrint(buf[n..], "{s}:{s}@", .{ old.username, old.password }) catch return;
                n += old.username.len + 1 + old.password.len + 1;
            }
            @memcpy(buf[n..][0..host_part.len], host_part);
            n += host_part.len;
            if (port_part.len > 0) {
                buf[n] = ':';
                n += 1;
                @memcpy(buf[n..][0..port_part.len], port_part);
                n += port_part.len;
            }
            @memcpy(buf[n..][0..rest.len], rest);
            n += rest.len;
        },
        .port => {
            var new_port_str: []const u8 = raw;
            if (raw.len > 0) {
                const p = std.fmt.parseInt(u16, raw, 10) catch return;
                if (defaultPortForScheme(old.scheme)) |dp| {
                    if (p == dp) new_port_str = "";
                }
            }
            const sep = std.mem.indexOf(u8, old.href, "://") orelse return;
            const after_scheme = old.href[sep + 3 ..];
            const auth_end = std.mem.indexOfScalar(u8, after_scheme, '/') orelse after_scheme.len;
            const authority = after_scheme[0..auth_end];
            const rest = after_scheme[auth_end..];
            var host_part: []const u8 = authority;
            if (std.mem.lastIndexOfScalar(u8, authority, ':')) |ci| {
                if (std.mem.indexOfScalar(u8, authority[ci..], ']') == null) {
                    host_part = authority[0..ci];
                }
            }
            var userinfo: []const u8 = "";
            if (std.mem.indexOfScalar(u8, host_part, '@')) |at| {
                userinfo = host_part[0 .. at + 1];
                host_part = host_part[at + 1 ..];
            }
            if (sep + 3 + userinfo.len + host_part.len + 1 + new_port_str.len + rest.len > buf.len) return;
            @memcpy(buf[0 .. sep + 3], old.href[0 .. sep + 3]);
            n = sep + 3;
            @memcpy(buf[n..][0..userinfo.len], userinfo);
            n += userinfo.len;
            @memcpy(buf[n..][0..host_part.len], host_part);
            n += host_part.len;
            if (new_port_str.len > 0) {
                buf[n] = ':';
                n += 1;
                @memcpy(buf[n..][0..new_port_str.len], new_port_str);
                n += new_port_str.len;
            }
            @memcpy(buf[n..][0..rest.len], rest);
            n += rest.len;
        },
        .pathname => {
            var p: []const u8 = raw;
            if (p.len == 0 or p[0] != '/') {
                if (p.len + 1 > buf.len) return;
                buf[0] = '/';
                @memcpy(buf[1..][0..p.len], p);
                p = buf[0 .. p.len + 1];
            }
            const sep = std.mem.indexOf(u8, old.href, "://") orelse return;
            const after_scheme = old.href[sep + 3 ..];
            const auth_end = std.mem.indexOfScalar(u8, after_scheme, '/') orelse after_scheme.len;
            const keep = after_scheme[0..auth_end];
            if (sep + 3 + keep.len + p.len + old.search.len + old.hash.len > buf.len) return;
            @memcpy(buf[0 .. sep + 3], old.href[0 .. sep + 3]);
            n = sep + 3;
            @memcpy(buf[n..][0..keep.len], keep);
            n += keep.len;
            @memcpy(buf[n..][0..p.len], p);
            n += p.len;
            @memcpy(buf[n..][0..old.search.len], old.search);
            n += old.search.len;
            @memcpy(buf[n..][0..old.hash.len], old.hash);
            n += old.hash.len;
        },
        .search, .hash => {
            var v: []const u8 = raw;
            const lead: u8 = if (field == .search) '?' else '#';
            if (v.len > 0 and v[0] == lead) v = v[1..];
            const cut = if (field == .search)
                (std.mem.indexOfScalar(u8, old.href, '?') orelse (std.mem.indexOfScalar(u8, old.href, '#') orelse old.href.len))
            else
                (std.mem.indexOfScalar(u8, old.href, '#') orelse old.href.len);
            if (cut + 1 + v.len > buf.len) return;
            @memcpy(buf[0..cut], old.href[0..cut]);
            n = cut;
            if (v.len > 0) {
                buf[n] = lead;
                n += 1;
                @memcpy(buf[n..][0..v.len], v);
                n += v.len;
            }
        },
        .username, .password => {
            const sep = std.mem.indexOf(u8, old.href, "://") orelse return;
            const after_scheme = old.href[sep + 3 ..];
            const auth_end = std.mem.indexOfScalar(u8, after_scheme, '/') orelse after_scheme.len;
            const authority = after_scheme[0..auth_end];
            const rest = after_scheme[auth_end..];
            var userinfo: []const u8 = "";
            var hostport: []const u8 = authority;
            if (std.mem.indexOfScalar(u8, authority, '@')) |at| {
                userinfo = authority[0..at];
                hostport = authority[at + 1 ..];
            }
            var user_part: []const u8 = "";
            var pass_part: []const u8 = "";
            if (std.mem.indexOfScalar(u8, userinfo, ':')) |ci| {
                user_part = userinfo[0..ci];
                pass_part = userinfo[ci + 1 ..];
            } else if (userinfo.len > 0) {
                user_part = userinfo;
            }
            const new_user = if (field == .username) raw else user_part;
            const new_pass = if (field == .password) raw else pass_part;
            if (sep + 3 + new_user.len + 1 + new_pass.len + 1 + hostport.len + rest.len > buf.len) return;
            @memcpy(buf[0 .. sep + 3], old.href[0 .. sep + 3]);
            n = sep + 3;
            if (new_user.len > 0 or new_pass.len > 0) {
                @memcpy(buf[n..][0..new_user.len], new_user);
                n += new_user.len;
                if (new_pass.len > 0) {
                    buf[n] = ':';
                    n += 1;
                    @memcpy(buf[n..][0..new_pass.len], new_pass);
                    n += new_pass.len;
                }
                buf[n] = '@';
                n += 1;
            }
            @memcpy(buf[n..][0..hostport.len], hostport);
            n += hostport.len;
            @memcpy(buf[n..][0..rest.len], rest);
            n += rest.len;
        },
    }
    const new_full = buf[0..n];
    const block = parseUrlAbsolute(new_full) catch return;
    // repoint the existing searchParams JS object to the new block 
    const sp_obj = c.getPropertyStr(ctx, this_val, "searchParams");
    defer c.freeValue(ctx, sp_obj);
    if (c.getOpaque2(ctx, sp_obj, sp_class_id) != null) {
        block.sp.block = block;
        block.retain(); // sp object's ref on the new block
        c.setOpaque(sp_obj, &block.sp);
        old.block.release(); // old url ref (transferred)
        old.block.release(); // old sp ref (transferred)
    } else {
        old.block.release();
    }
    c.setOpaque(this_val, &block.url);
}

fn getHref(ctx: ?*c.Context, this_val: c.Value) callconv(.c) c.Value {
    const data = extractUrlData(ctx, this_val) orelse return c.JS_UNDEFINED;
    return zigStringToJS(ctx, data.href);
}
fn getOrigin(ctx: ?*c.Context, this_val: c.Value) callconv(.c) c.Value {
    const data = extractUrlData(ctx, this_val) orelse return c.JS_UNDEFINED;
    return zigStringToJS(ctx, data.origin);
}
fn getProtocol(ctx: ?*c.Context, this_val: c.Value) callconv(.c) c.Value {
    const data = extractUrlData(ctx, this_val) orelse return c.JS_UNDEFINED;
    var buf: [256]u8 = undefined;
    return zigStringToJS(ctx, data.protocolStr(&buf));
}
fn getHost(ctx: ?*c.Context, this_val: c.Value) callconv(.c) c.Value {
    const data = extractUrlData(ctx, this_val) orelse return c.JS_UNDEFINED;
    return zigStringToJS(ctx, data.host_str);
}
fn getHostname(ctx: ?*c.Context, this_val: c.Value) callconv(.c) c.Value {
    const data = extractUrlData(ctx, this_val) orelse return c.JS_UNDEFINED;
    return zigStringToJS(ctx, data.host);
}
fn getPort(ctx: ?*c.Context, this_val: c.Value) callconv(.c) c.Value {
    const data = extractUrlData(ctx, this_val) orelse return c.JS_UNDEFINED;
    return zigStringToJS(ctx, data.port_str);
}
fn getPathname(ctx: ?*c.Context, this_val: c.Value) callconv(.c) c.Value {
    const data = extractUrlData(ctx, this_val) orelse return c.JS_UNDEFINED;
    return zigStringToJS(ctx, data.path);
}
fn getSearch(ctx: ?*c.Context, this_val: c.Value) callconv(.c) c.Value {
    const data = extractUrlData(ctx, this_val) orelse return c.JS_UNDEFINED;
    return zigStringToJS(ctx, data.search);
}
fn getHash(ctx: ?*c.Context, this_val: c.Value) callconv(.c) c.Value {
    const data = extractUrlData(ctx, this_val) orelse return c.JS_UNDEFINED;
    return zigStringToJS(ctx, data.hash);
}
fn getUsername(ctx: ?*c.Context, this_val: c.Value) callconv(.c) c.Value {
    const data = extractUrlData(ctx, this_val) orelse return c.JS_UNDEFINED;
    return zigStringToJS(ctx, data.username);
}
fn getPassword(ctx: ?*c.Context, this_val: c.Value) callconv(.c) c.Value {
    const data = extractUrlData(ctx, this_val) orelse return c.JS_UNDEFINED;
    return zigStringToJS(ctx, data.password);
}

fn setHref(ctx: ?*c.Context, this_val: c.Value, val: c.Value) callconv(.c) c.Value {
    var buf: [512]u8 = undefined;
    const v = extractStringAuto(ctx, val, &buf) orelse return c.JS_EXCEPTION;
    defer v.deinit();
    setUrlField(ctx, this_val, .href, v.slice);
    return c.JS_UNDEFINED;
}
fn setProtocol(ctx: ?*c.Context, this_val: c.Value, val: c.Value) callconv(.c) c.Value {
    var buf: [512]u8 = undefined;
    const v = extractStringAuto(ctx, val, &buf) orelse return c.JS_EXCEPTION;
    defer v.deinit();
    setUrlField(ctx, this_val, .protocol, v.slice);
    return c.JS_UNDEFINED;
}
fn setHost(ctx: ?*c.Context, this_val: c.Value, val: c.Value) callconv(.c) c.Value {
    var buf: [512]u8 = undefined;
    const v = extractStringAuto(ctx, val, &buf) orelse return c.JS_EXCEPTION;
    defer v.deinit();
    setUrlField(ctx, this_val, .host, v.slice);
    return c.JS_UNDEFINED;
}
fn setHostname(ctx: ?*c.Context, this_val: c.Value, val: c.Value) callconv(.c) c.Value {
    var buf: [512]u8 = undefined;
    const v = extractStringAuto(ctx, val, &buf) orelse return c.JS_EXCEPTION;
    defer v.deinit();
    setUrlField(ctx, this_val, .hostname, v.slice);
    return c.JS_UNDEFINED;
}
fn setPort(ctx: ?*c.Context, this_val: c.Value, val: c.Value) callconv(.c) c.Value {
    var buf: [512]u8 = undefined;
    const v = extractStringAuto(ctx, val, &buf) orelse return c.JS_EXCEPTION;
    defer v.deinit();
    setUrlField(ctx, this_val, .port, v.slice);
    return c.JS_UNDEFINED;
}
fn setPathname(ctx: ?*c.Context, this_val: c.Value, val: c.Value) callconv(.c) c.Value {
    var buf: [512]u8 = undefined;
    const v = extractStringAuto(ctx, val, &buf) orelse return c.JS_EXCEPTION;
    defer v.deinit();
    setUrlField(ctx, this_val, .pathname, v.slice);
    return c.JS_UNDEFINED;
}
fn setSearch(ctx: ?*c.Context, this_val: c.Value, val: c.Value) callconv(.c) c.Value {
    var buf: [512]u8 = undefined;
    const v = extractStringAuto(ctx, val, &buf) orelse return c.JS_EXCEPTION;
    defer v.deinit();
    setUrlField(ctx, this_val, .search, v.slice);
    return c.JS_UNDEFINED;
}
fn setHash(ctx: ?*c.Context, this_val: c.Value, val: c.Value) callconv(.c) c.Value {
    var buf: [512]u8 = undefined;
    const v = extractStringAuto(ctx, val, &buf) orelse return c.JS_EXCEPTION;
    defer v.deinit();
    setUrlField(ctx, this_val, .hash, v.slice);
    return c.JS_UNDEFINED;
}
fn setUsername(ctx: ?*c.Context, this_val: c.Value, val: c.Value) callconv(.c) c.Value {
    var buf: [512]u8 = undefined;
    const v = extractStringAuto(ctx, val, &buf) orelse return c.JS_EXCEPTION;
    defer v.deinit();
    setUrlField(ctx, this_val, .username, v.slice);
    return c.JS_UNDEFINED;
}
fn setPassword(ctx: ?*c.Context, this_val: c.Value, val: c.Value) callconv(.c) c.Value {
    var buf: [512]u8 = undefined;
    const v = extractStringAuto(ctx, val, &buf) orelse return c.JS_EXCEPTION;
    defer v.deinit();
    setUrlField(ctx, this_val, .password, v.slice);
    return c.JS_UNDEFINED;
}

fn parseUrlAbsolute(input: []const u8) !*UrlBlock {
    const uri = try std.Uri.parse(input);
    const block = try UrlBlock.create(input.len + 256);
    errdefer block.release();
    var w = PoolWriter{ .pool = block.poolSlice() };
    const url = &block.url;
    url.port = uri.port;
    url.scheme = w.put(uri.scheme);
    url.host = if (uri.host) |h| w.putComponent(h) else "";
    url.path = blk: {
        if (uri.path.isEmpty()) break :blk w.put("/");
        const raw = w.putComponent(uri.path);
        const off = w.used;
        w.used += try removeDotSegmentsInto(w.rest(), raw);
        break :blk w.pool[off..][0 .. w.used - off];
    };
    url.query = if (uri.query) |q| w.putComponent(q) else "";
    url.fragment = if (uri.fragment) |f| w.putComponent(f) else "";
    url.username = if (uri.user) |u| w.putComponent(u) else "";
    url.password = if (uri.password) |p| w.putComponent(p) else "";
    block.sp.parseFromString(url.query);
    deriveStrings(url, &w);
    return block;
}

fn parseUrlRelative(input: []const u8, base_url: []const u8) !*UrlBlock {
    const base = try std.Uri.parse(base_url);
    const block = try UrlBlock.create(input.len + base_url.len + 256);
    errdefer block.release();
    var w = PoolWriter{ .pool = block.poolSlice() };
    const url = &block.url;
    if (std.Uri.parse(input)) |rel| {
        if (rel.scheme.len > 0) {
            url.port = rel.port;
            url.scheme = w.put(rel.scheme);
            url.host = if (rel.host) |h| w.putComponent(h) else "";
            url.path = if (rel.path.isEmpty()) w.put("/") else blk: {
                const raw = w.putComponent(rel.path);
                const off = w.used;
                w.used += try removeDotSegmentsInto(w.rest(), raw);
                break :blk w.pool[off..][0 .. w.used - off];
            };
            url.query = if (rel.query) |q| w.putComponent(q) else "";
            url.fragment = if (rel.fragment) |f| w.putComponent(f) else "";
            url.username = if (rel.user) |u| w.putComponent(u) else "";
            url.password = if (rel.password) |p| w.putComponent(p) else "";
            block.sp.parseFromString(url.query);
            deriveStrings(url, &w);
            return block;
        }
        if (rel.host) |h| {
            url.port = rel.port;
            url.scheme = w.put(base.scheme);
            url.host = w.putComponent(h);
            url.path = if (rel.path.isEmpty()) w.put("/") else blk: {
                const raw = w.putComponent(rel.path);
                const off = w.used;
                w.used += try removeDotSegmentsInto(w.rest(), raw);
                break :blk w.pool[off..][0 .. w.used - off];
            };
            url.query = if (rel.query) |q| w.putComponent(q) else "";
            url.fragment = if (rel.fragment) |f| w.putComponent(f) else "";
            block.sp.parseFromString(url.query);
            deriveStrings(url, &w);
            return block;
        }
    } else |_| {}
    url.port = base.port;
    url.scheme = w.put(base.scheme);
    url.host = if (base.host) |h| w.putComponent(h) else "";
    url.username = if (base.user) |u| w.putComponent(u) else "";
    url.password = if (base.password) |p| w.putComponent(p) else "";
    const base_path = w.putComponent(base.path);
    const rel_path = input;
    if (rel_path.len == 0) {
        url.path = w.put(base_path);
        url.query = if (base.query) |q| w.putComponent(q) else "";
    } else if (rel_path[0] == '?') {
        url.path = w.put(base_path);
        url.query = w.put(rel_path[1..]);
    } else if (rel_path[0] == '#') {
        url.path = w.put(base_path);
        url.query = if (base.query) |q| w.putComponent(q) else "";
        url.fragment = w.put(rel_path[1..]);
    } else if (rel_path[0] == '/') {
        const off = w.used;
        w.used += try removeDotSegmentsInto(w.rest(), rel_path);
        url.path = w.pool[off..][0 .. w.used - off];
        url.query = "";
    } else {
        var tmp: [4096]u8 = undefined;
        const n = mergePathsInto(&tmp, base_path, rel_path);
        const off = w.used;
        w.used += try removeDotSegmentsInto(w.rest(), tmp[0..n]);
        url.path = w.pool[off..][0 .. w.used - off];
        url.query = "";
    }
    block.sp.parseFromString(url.query);
    deriveStrings(url, &w);
    return block;
}

fn removeDotSegmentsInto(out: []u8, input: []const u8) !usize {
    var n: usize = 0;
    var rest = input;
    while (rest.len > 0) {
        if (std.mem.startsWith(u8, rest, "../")) {
            rest = rest[3..];
        } else if (std.mem.startsWith(u8, rest, "./")) {
            rest = rest[2..];
        } else if (std.mem.startsWith(u8, rest, "/../")) {
            rest = rest[4..];
            while (n > 0) {
                n -= 1;
                if (n > 0 and out[n - 1] == '/') {
                    n -= 1;
                    break;
                }
                if (n == 0) break;
            }
            out[n] = '/';
            n += 1;
        } else if (std.mem.eql(u8, rest, "/..")) {
            rest = "";
            while (n > 0) {
                n -= 1;
                if (n > 0 and out[n - 1] == '/') {
                    n -= 1;
                    break;
                }
                if (n == 0) break;
            }
            out[n] = '/';
            n += 1;
        } else if (std.mem.startsWith(u8, rest, "/./")) {
            rest = rest[2..];
        } else if (std.mem.eql(u8, rest, "..")) {
            rest = "";
            out[n] = '/';
            n += 1;
        } else if (std.mem.eql(u8, rest, ".")) {
            rest = "";
        } else if (rest[0] == '/') {
            out[n] = '/';
            n += 1;
            rest = rest[1..];
        } else {
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
            @memcpy(out[n..][0..slash], rest[0..slash]);
            n += slash;
            rest = if (slash < rest.len) rest[slash..] else "";
        }
    }
    if (n == 0) {
        out[n] = '/';
        n += 1;
    }
    return n;
}

fn mergePathsInto(out: []u8, base_path: []const u8, rel_path: []const u8) usize {
    var n: usize = 0;
    @memcpy(out[n..][0..base_path.len], base_path);
    n += base_path.len;
    if (std.mem.lastIndexOfScalar(u8, out[0..n], '/')) |idx| {
        n = idx + 1;
    } else {
        n = 0;
    }
    @memcpy(out[n..][0..rel_path.len], rel_path);
    n += rel_path.len;
    return n;
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
fn createUrlJsObject(ctx: ?*c.Context, data: *UrlData) c.Value { // CHANGED
    const obj = c.newObjectClass(ctx, @intCast(url_class_id));
    c.setOpaque(obj, data);
    data.block.sp.block = data.block;
    data.block.retain();
    const sp_obj = createSPJsObject(ctx, &data.block.sp);
    _ = c.definePropertyValueStr(ctx, obj, "searchParams", sp_obj, c.PROP_C_W_E);
    return obj;
}

// ============================================================
// URL callbacks
// ============================================================
fn urlToString(ctx: ?*c.Context, this_val: c.Value, _: c_int, _: [*c]c.Value) callconv(.c) c.Value {
    const data = extractUrlData(ctx, this_val) orelse return zigStringToJS(ctx, "");
    return zigStringToJS(ctx, data.href);
}

fn urlToJSON(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    return urlToString(ctx, this_val, argc, argv);
}

fn urlFinalizer(rt: ?*c.Runtime, val: c.Value) callconv(.c) void {
    _ = rt;
    if (c.getOpaque(val, url_class_id)) |ptr| {
        const data: *UrlData = @ptrCast(@alignCast(ptr));
        data.block.release();
    }
}

fn urlConstructor(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
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
    const block = if (base) |b|
        parseUrlRelative(input.slice, b.slice) catch {
            _ = c.throwTypeError(ctx, "Invalid URL");
            return c.JS_EXCEPTION;
        }
    else
        parseUrlAbsolute(input.slice) catch {
            _ = c.throwTypeError(ctx, "Invalid URL");
            return c.JS_EXCEPTION;
        };
    return createUrlJsObject(ctx, &block.url);
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
    const block = if (base) |b|
        parseUrlRelative(input.slice, b.slice) catch return c.JS_NULL
    else
        parseUrlAbsolute(input.slice) catch return c.JS_NULL;
    return createUrlJsObject(ctx, &block.url);
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
        v.release();
        return c.JS_TRUE;
    }
    return c.JS_FALSE;
}

// ============================================================
// Setup
// ============================================================
pub fn setup(ctx: *c.Context) void {
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
        // CHANGED: property get/set pairs (all reads are live-field accessors)
        const GetSet = struct {
            name: [*:0]const u8,
            get: *const fn (?*c.Context, c.Value) callconv(.c) c.Value,
            set: ?*const fn (?*c.Context, c.Value, c.Value) callconv(.c) c.Value,
        };
        const url_getsets = [_]GetSet{
            .{ .name = "href", .get = &getHref, .set = &setHref },
            .{ .name = "origin", .get = &getOrigin, .set = null },
            .{ .name = "protocol", .get = &getProtocol, .set = &setProtocol },
            .{ .name = "host", .get = &getHost, .set = &setHost },
            .{ .name = "hostname", .get = &getHostname, .set = &setHostname },
            .{ .name = "port", .get = &getPort, .set = &setPort },
            .{ .name = "pathname", .get = &getPathname, .set = &setPathname },
            .{ .name = "search", .get = &getSearch, .set = &setSearch },
            .{ .name = "hash", .get = &getHash, .set = &setHash },
            .{ .name = "username", .get = &getUsername, .set = &setUsername },
            .{ .name = "password", .get = &getPassword, .set = &setPassword },
        };
        for (url_getsets) |gs| {
            const get_val = c.newCFunction2(ctx, @ptrCast(gs.get), gs.name, 0, c.JS_CFUNC_getter, 0);
            const set_val = if (gs.set) |sf|
                c.newCFunction2(ctx, @ptrCast(sf), gs.name, 1, c.JS_CFUNC_setter, 0)
            else
                c.JS_UNDEFINED;
            _ = c.definePropertyGetSet(ctx, url_proto, c.newAtomLen(ctx, gs.name, std.mem.len(gs.name)), get_val, set_val, c.PROP_CONFIGURABLE | c.PROP_WRITABLE);
           
        }
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
