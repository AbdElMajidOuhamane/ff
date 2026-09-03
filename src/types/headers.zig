const std = @import("std");
const c = @import("../c.zig").c;
const gpa = std.heap.smp_allocator;
const simd = std.simd;

pub var headers_class_id: c.ClassID = 0;

fn throwTypeError(ctx: ?*c.Context, msg: []const u8) void {
    _ = c.throwTypeError(ctx, "%.*s", @as(c_int, @intCast(msg.len)), msg.ptr);
}

fn zigStringToJS(ctx: ?*c.Context, str: []const u8) c.Value {
    return c.newStringLen(ctx, str.ptr, @intCast(str.len));
}

fn extractStringFromVal(ctx: ?*c.Context, val: c.Value) ?[:0]const u8 {
    var stack_buf: [256]u8 = undefined;
    return extractStringAuto(ctx, val, &stack_buf) orelse null;
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

fn lowerAsciiSimd(buf: []u8) void {
    const N = simd.suggestVectorLength(u8) orelse 16;
    const V = @Vector(N, u8);
    const spl_a: V = @splat('A');
    const spl_z: V = @splat('Z');
    const spl_32: V = @splat(0x20);
    const spl_0: V = @splat(0);
    var i: usize = 0;
    const tail = buf.len % N;
    const main_end = buf.len - tail;
    while (i < main_end) : (i += N) {
        var v: V = buf[i..][0..N].*;
        const upper = (v >= spl_a) & (v <= spl_z);
        v += @select(u8, upper, spl_32, spl_0);
        const arr: [N]u8 = v;
        buf[i..][0..N].* = arr;
    }
    while (i < buf.len) : (i += 1) {
        buf[i] = std.ascii.toLower(buf[i]);
    }
}

pub const Pair = struct { name: []const u8, value: []const u8 };
const Entry = struct {
    name_off: u32,
    name_len: u32,
    val_off: u32,
    val_len: u32,
};
comptime {
    std.debug.assert(@sizeOf(Entry) == 16);
}

// DOD-FIX 1: refcounted HeadersData. Strict-compliance layout assertion.
pub const HeadersData = struct {
    names: std.ArrayList(u8),
    values: std.ArrayList(u8),
    entries: std.ArrayList(Entry),
    merge_buf: std.ArrayList(u8),
    view_buf: std.ArrayList([]const u8),
    refcount: std.atomic.Value(usize),
    pub const PairView = struct { name: []const u8, value: []const u8 };

    pub fn init() HeadersData {
        return .{
            .names = std.ArrayList(u8).empty,
            .values = std.ArrayList(u8).empty,
            .entries = std.ArrayList(Entry).empty,
            .merge_buf = std.ArrayList(u8).empty,
            .view_buf = std.ArrayList([]const u8).empty,
            .refcount = .{ .raw = 1 },
        };
    }
    pub fn deinit(self: *HeadersData) void {
        self.names.deinit(gpa);
        self.values.deinit(gpa);
        self.entries.deinit(gpa);
        self.merge_buf.deinit(gpa);
        self.view_buf.deinit(gpa);
    }
    pub fn retain(self: *HeadersData) void {
        _ = self.refcount.fetchAdd(1, .acq_rel);
    }
    pub fn release(self: *HeadersData) void {
        if (self.refcount.fetchSub(1, .acq_rel) == 1) {
            self.deinit();
            gpa.destroy(self);
        }
    }
    fn nameOf(self: *const HeadersData, e: Entry) []const u8 {
        return self.names.items[e.name_off .. e.name_off + e.name_len];
    }
    fn valueOf(self: *const HeadersData, e: Entry) []const u8 {
        return self.values.items[e.val_off .. e.val_off + e.val_len];
    }
    pub fn len(self: *const HeadersData) usize {
        return self.entries.items.len;
    }
    pub fn getPair(self: *const HeadersData, i: usize) PairView {
        return .{
            .name = self.nameOf(self.entries.items[i]),
            .value = self.valueOf(self.entries.items[i]),
        };
    }
    fn removeSwap(self: *HeadersData, i: usize) void {
        const last = self.entries.items.len - 1;
        if (i != last) self.entries.items[i] = self.entries.items[last];
        self.entries.items.len -= 1;
    }
    pub fn appendEntry(self: *HeadersData, name: []const u8, value: []const u8) void {
        const nbase = self.names.items.len;
        self.names.appendSlice(gpa, name) catch return;
        lowerAsciiSimd(self.names.items[nbase..]);
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
    pub fn setEntry(self: *HeadersData, name: []const u8, value: []const u8) void {
        var first: ?usize = null;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (std.ascii.eqlIgnoreCase(self.nameOf(self.entries.items[i]), name)) {
                if (first == null) {
                    first = i;
                    const vbase = self.values.items.len;
                    self.values.appendSlice(gpa, value) catch return;
                    self.entries.items[i].val_off = @intCast(vbase);
                    self.entries.items[i].val_len = @intCast(value.len);
                    i += 1;
                } else {
                    self.removeSwap(i);
                }
            } else {
                i += 1;
            }
        }
        if (first == null) self.appendEntry(name, value);
    }
    pub fn deleteEntry(self: *HeadersData, name: []const u8, value: ?[]const u8) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const e = self.entries.items[i];
            if (std.ascii.eqlIgnoreCase(self.nameOf(e), name)) {
                if (value == null or std.mem.eql(u8, self.valueOf(e), value.?)) {
                    self.removeSwap(i);
                    if (value != null) return;
                    continue;
                }
            }
            i += 1;
        }
    }
    pub fn getFirst(self: *HeadersData, name: []const u8) ?[]const u8 {
        var first: ?usize = null;
        var count: usize = 0;
        var joined_len: usize = 0;
        for (self.entries.items, 0..) |e, i| {
            if (std.ascii.eqlIgnoreCase(self.nameOf(e), name)) {
                if (first == null) first = i;
                joined_len += self.valueOf(e).len + 2;
                count += 1;
            }
        }
        if (count == 0) return null;
        if (count == 1) return self.valueOf(self.entries.items[first.?]);
        self.merge_buf.clearRetainingCapacity();
        self.merge_buf.ensureTotalCapacity(gpa, joined_len - 2) catch {};
        var skipped = false;
        for (self.entries.items) |e| {
            if (!std.ascii.eqlIgnoreCase(self.nameOf(e), name)) continue;
            if (!skipped) {
                skipped = true;
            } else {
                self.merge_buf.appendSlice(gpa, ", ") catch break;
            }
            self.merge_buf.appendSlice(gpa, self.valueOf(e)) catch break;
        }
        return self.merge_buf.items;
    }
    pub fn getAllValues(self: *HeadersData, name: []const u8) [][]const u8 {
        self.view_buf.clearRetainingCapacity();
        for (self.entries.items) |e| {
            if (std.ascii.eqlIgnoreCase(self.nameOf(e), name)) {
                self.view_buf.append(gpa, self.valueOf(e)) catch break;
            }
        }
        return self.view_buf.items;
    }
    pub fn hasEntry(self: *const HeadersData, name: []const u8, value: ?[]const u8) bool {
        for (self.entries.items) |e| {
            if (std.ascii.eqlIgnoreCase(self.nameOf(e), name)) {
                if (value == null or std.mem.eql(u8, self.valueOf(e), value.?)) return true;
            }
        }
        return false;
    }
    pub fn getUniqueNames(self: *const HeadersData) [][]const u8 {
        var result = std.ArrayList([]const u8).empty;
        for (self.entries.items) |e| {
            const n = self.nameOf(e);
            var found = false;
            for (result.items) |existing| {
                if (std.mem.eql(u8, existing, n)) {
                    found = true;
                    break;
                }
            }
            if (!found) result.append(gpa, n) catch break;
        }
        return result.toOwnedSlice(gpa) catch &.{};
    }
    pub fn serialize(self: *const HeadersData) ![]const u8 {
        var total: usize = 0;
        for (self.entries.items) |e| {
            total += self.nameOf(e).len + self.valueOf(e).len + 4;
        }
        var result = std.ArrayList(u8).empty;
        try result.ensureTotalCapacity(gpa, total);
        errdefer result.deinit(gpa);
        for (self.entries.items, 0..) |e, i| {
            if (i > 0) try result.appendSlice(gpa, "\r\n");
            try result.appendSlice(gpa, self.nameOf(e));
            try result.appendSlice(gpa, ": ");
            try result.appendSlice(gpa, self.valueOf(e));
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
fn extractHeadersData(ctx: ?*c.Context, this_val: c.Value) ?*HeadersData {
    const ptr = c.getOpaque2(ctx, this_val, headers_class_id) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

pub fn headersGet(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    const data = extractHeadersData(ctx, this_val) orelse return c.JS_NULL;
    var name_buf: [64]u8 = undefined;
    const name = extractStringAuto(ctx, argv[0], &name_buf) orelse return c.JS_NULL;
    defer name.deinit();
    if (data.getFirst(name.slice)) |val| {
        return zigStringToJS(ctx, val);
    }
    return c.JS_NULL;
}

pub fn headersGetAll(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    const data = extractHeadersData(ctx, this_val) orelse return c.newArray(ctx);
    var name_buf: [64]u8 = undefined;
    const name = extractStringAuto(ctx, argv[0], &name_buf) orelse return c.newArray(ctx);
    defer name.deinit();
    const vals = data.getAllValues(name.slice);
    const arr = c.newArray(ctx);
    for (vals, 0..) |v, i| {
        const s = zigStringToJS(ctx, v);
        _ = c.definePropertyValueUint32(ctx, arr, @intCast(i), s, c.PROP_C_W_E);
    }
    return arr;
}

pub fn headersHas(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    const data = extractHeadersData(ctx, this_val) orelse return c.JS_FALSE;
    var name_buf: [64]u8 = undefined;
    const name = extractStringAuto(ctx, argv[0], &name_buf) orelse return c.JS_FALSE;
    defer name.deinit();
    return if (data.hasEntry(name.slice, null)) c.JS_TRUE else c.JS_FALSE;
}

pub fn headersSet(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    const data = extractHeadersData(ctx, this_val) orelse return c.JS_UNDEFINED;
    var name_buf: [64]u8 = undefined;
    var value_buf: [128]u8 = undefined;
    const name = extractStringAuto(ctx, argv[0], &name_buf) orelse return c.JS_UNDEFINED;
    defer name.deinit();
    const value = extractStringAuto(ctx, argv[1], &value_buf) orelse return c.JS_UNDEFINED;
    defer value.deinit();
    data.setEntry(name.slice, value.slice);
    return c.JS_UNDEFINED;
}

pub fn headersAppend(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    const data = extractHeadersData(ctx, this_val) orelse return c.JS_UNDEFINED;
    var name_buf: [64]u8 = undefined;
    var value_buf: [128]u8 = undefined;
    const name = extractStringAuto(ctx, argv[0], &name_buf) orelse return c.JS_UNDEFINED;
    defer name.deinit();
    const value = extractStringAuto(ctx, argv[1], &value_buf) orelse return c.JS_UNDEFINED;
    defer value.deinit();
    data.appendEntry(name.slice, value.slice);
    return c.JS_UNDEFINED;
}

pub fn headersDelete(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    const data = extractHeadersData(ctx, this_val) orelse return c.JS_UNDEFINED;
    var name_buf: [64]u8 = undefined;
    const name = extractStringAuto(ctx, argv[0], &name_buf) orelse return c.JS_UNDEFINED;
    defer name.deinit();
    var val: ?ExtractedStr = null;
    var vbuf: [128]u8 = undefined;
    if (c.isUndefined(argv[1]) == 0 and c.isNull(argv[1]) == 0) {
        val = extractStringAuto(ctx, argv[1], &vbuf);
    }
    defer if (val) |v| v.deinit();
    data.deleteEntry(name.slice, if (val) |v| v.slice else null);
    return c.JS_UNDEFINED;
}

pub fn headersEntries(ctx: ?*c.Context, this_val: c.Value, _: c_int, _: [*c]c.Value) callconv(.c) c.Value {
    const data = extractHeadersData(ctx, this_val) orelse return c.newArray(ctx);
    const pairs_arr = c.newArray(ctx);
    for (0..data.len()) |i| {
        const p = data.getPair(i);
        const inner = c.newArray(ctx);
        _ = c.definePropertyValueUint32(ctx, inner, 0, zigStringToJS(ctx, p.name), c.PROP_C_W_E);
        _ = c.definePropertyValueUint32(ctx, inner, 1, zigStringToJS(ctx, p.value), c.PROP_C_W_E);
        _ = c.definePropertyValueUint32(ctx, pairs_arr, @intCast(i), inner, c.PROP_C_W_E);
    }
    return pairs_arr;
}

pub fn headersKeys(ctx: ?*c.Context, this_val: c.Value, _: c_int, _: [*c]c.Value) callconv(.c) c.Value {
    const data = extractHeadersData(ctx, this_val) orelse return c.newArray(ctx);
    const names = data.getUniqueNames();
    defer gpa.free(names);
    const arr = c.newArray(ctx);
    for (names, 0..) |name, i| {
        _ = c.definePropertyValueUint32(ctx, arr, @intCast(i), zigStringToJS(ctx, name), c.PROP_C_W_E);
    }
    return arr;
}

pub fn headersValues(ctx: ?*c.Context, this_val: c.Value, _: c_int, _: [*c]c.Value) callconv(.c) c.Value {
    const data = extractHeadersData(ctx, this_val) orelse return c.newArray(ctx);
    const arr = c.newArray(ctx);
    for (0..data.len()) |i| {
        const p = data.getPair(i);
        _ = c.definePropertyValueUint32(ctx, arr, @intCast(i), zigStringToJS(ctx, p.value), c.PROP_C_W_E);
    }
    return arr;
}

pub fn headersForEach(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const data = extractHeadersData(ctx, this_val) orelse return c.JS_UNDEFINED;
    if (argc < 1) return c.JS_UNDEFINED;
    const callback = argv[0];
    for (0..data.len()) |i| {
        const p = data.getPair(i);
        var args = [_]c.Value{
            zigStringToJS(ctx, p.value),
            zigStringToJS(ctx, p.name),
            this_val,
        };
        _ = c.call(ctx, callback, this_val, 3, &args);
    }
    return c.JS_UNDEFINED;
}

pub fn headersToString(ctx: ?*c.Context, this_val: c.Value, _: c_int, _: [*c]c.Value) callconv(.c) c.Value {
    const data = extractHeadersData(ctx, this_val) orelse return zigStringToJS(ctx, "");
    const serialized = data.serialize() catch return zigStringToJS(ctx, "");
    defer gpa.free(serialized);
    return zigStringToJS(ctx, serialized);
}

pub fn headersSize(ctx: ?*c.Context, this_val: c.Value, _: c_int, _: [*c]c.Value) callconv(.c) c.Value {
    const data = extractHeadersData(ctx, this_val) orelse return c.newInt32(ctx, 0);
    return c.newInt32(ctx, @intCast(data.len()));
}

fn headersFinalizer(rt: ?*c.Runtime, val: c.Value) callconv(.c) void {
    _ = rt;
    if (c.getOpaque(val, headers_class_id)) |ptr| {
        const data: *HeadersData = @ptrCast(@alignCast(ptr));
        data.release();
    }
}

fn headersConstructor(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    const data = gpa.create(HeadersData) catch return c.throwOutOfMemory(ctx);
    data.* = HeadersData.init();

    if (argc > 0) {
        const init_val = argv[0];
        if (c.isUndefined(init_val) != 0 or c.isNull(init_val) != 0) {
        } else if (c.isObject(init_val) != 0) {
            if (c.getOpaque2(ctx, init_val, headers_class_id)) |ptr| {
                const src: *HeadersData = @ptrCast(@alignCast(ptr));
                for (0..src.len()) |i| {
                    const p = src.getPair(i);
                    data.appendEntry(p.name, p.value);
                }
            } else if (c.isArray(ctx, init_val) != 0) {
                var pairs_buf = std.ArrayList(Pair).empty;
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
                    const name_z = extractStringAuto(ctx, name_val, &nbuf);
                    const val_z = extractStringAuto(ctx, val_val, &vbuf);
                    if (name_z) |n| {
                        defer n.deinit();
                        if (val_z) |v| {
                            defer v.deinit();
                            pairs_buf.append(gpa, .{ .name = n.slice, .value = v.slice }) catch {};
                        }
                    }
                }
                if (pairs_buf.items.len > 0) {
                    data.fromPairs(pairs_buf.items);
                }
                pairs_buf.deinit(gpa);
            } else {
                var pairs_buf = std.ArrayList(Pair).empty;
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
                        const name_z = extractStringAuto(ctx, name_val, &nbuf);
                        const val_z = extractStringAuto(ctx, val_val, &vbuf);
                        if (name_z) |n| {
                            defer n.deinit();
                            if (val_z) |v| {
                                defer v.deinit();
                                pairs_buf.append(gpa, .{ .name = n.slice, .value = v.slice }) catch {};
                            }
                        }
                    }
                    c.freePropertyEnum(ctx, p, count);
                }
                if (pairs_buf.items.len > 0) {
                    data.fromPairs(pairs_buf.items);
                }
                pairs_buf.deinit(gpa);
            }
        }
    }

    const obj = c.newObjectClass(ctx, @intCast(headers_class_id));
    c.setOpaque(obj, data);
    return obj;
}

pub fn setup(ctx: ?*c.Context) void {
    var class_def = c.ClassDef{
        .class_name = "Headers",
        .finalizer = headersFinalizer,
    };
_ = c.newClassID(c.getRuntime(ctx), &headers_class_id);
    _ = c.newClass(c.getRuntime(ctx), headers_class_id, &class_def);

    const proto = c.newObject(ctx);
    const methods = [_]struct { name: [*:0]const u8, func: *const c.CFunction, len: c_int }{
        .{ .name = "get", .func = &headersGet, .len = 1 },
        .{ .name = "getAll", .func = &headersGetAll, .len = 1 },
        .{ .name = "has", .func = &headersHas, .len = 1 },
        .{ .name = "set", .func = &headersSet, .len = 2 },
        .{ .name = "append", .func = &headersAppend, .len = 2 },
        .{ .name = "delete", .func = &headersDelete, .len = 1 },
        .{ .name = "entries", .func = &headersEntries, .len = 0 },
        .{ .name = "keys", .func = &headersKeys, .len = 0 },
        .{ .name = "values", .func = &headersValues, .len = 0 },
        .{ .name = "forEach", .func = &headersForEach, .len = 1 },
        .{ .name = "toString", .func = &headersToString, .len = 0 },
        .{ .name = "size", .func = &headersSize, .len = 0 },
    };
    for (methods) |m| {
        const fn_val = c.newCFunction(ctx, m.func, m.name, m.len);
        _ = c.definePropertyValueStr(ctx, proto, m.name, fn_val, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
    }
    c.setClassProto(ctx, headers_class_id, proto);

    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);
    const ctor = c.newCFunction2(ctx, &headersConstructor, "Headers", -1, c.JS_CFUNC_constructor, 0);
    _ = c.definePropertyValueStr(ctx, global, "Headers", ctor, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
}
pub fn createJSObject(ctx: ?*c.Context, data: *HeadersData) c.Value {
    const obj = c.newObjectClass(ctx, @intCast(headers_class_id));
    c.setOpaque(obj, data);
    return obj;
}
