const std = @import("std");
const c = @import("../c.zig").c;
const gpa = std.heap.page_allocator;
const simd = std.simd;
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
// Heap-allocating extraction, retained for setup-time paths (constructor).
fn extractStringFromVal(isolate: ?*c.Isolate, val: ?*const c.Value) ?[:0]const u8 {
    const v = val orelse return null;
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    const str = c.v8__Value__ToDetailString(v, context);
    if (str == null) return null;
    const utf8_len: usize = @intCast(c.v8__String__Utf8Length(str, isolate));
    const buf = gpa.allocSentinel(u8, utf8_len, 0) catch return null;
    _ = c.v8__String__WriteUtf8(str, isolate, buf.ptr, utf8_len, 0);
    return buf;
}
// Hot-path extraction: writes into the caller-provided stack buffer when the
// string fits (virtually all header names/values), falling back to a single
// heap allocation otherwise. Callers must deinit() the result.
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
// Vectorized ASCII lowercase: lanes in 'A'..'Z' get += 0x20.
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
// ============================================================
// HeadersData — DOD / SoA: contiguous string log + offset index
//
//   names   : one contiguous buffer of lowercase names (append-only)
//   values  : one contiguous buffer of values (append-only)
//   entries : dense index of {offset,len} pairs into the two buffers
//
// Per-pair heap allocations are gone: insert = amortized buffer
// appends. Removed/replaced bytes are left in the log (garbage
// reclaimed once at deinit) — the classic append-log tradeoff,
// cache-friendly and allocation-free in the hot path.
//
// Lookups are zero-allocation: stored names are lowercase, so queries
// match via case-insensitive compare against the raw query string.
// Multi-value merges and getAllValues reuse internal scratch buffers
// (cleared per call); returned slices are borrowed and valid until the
// next mutating call on the same HeadersData.
// ============================================================
pub const Pair = struct { name: []const u8, value: []const u8 };
const Entry = struct {
    name_off: usize,
    name_len: usize,
    val_off: usize,
    val_len: usize,
};
pub const HeadersData = struct {
    names: std.ArrayList(u8),
    values: std.ArrayList(u8),
    entries: std.ArrayList(Entry),
    // Reusable scratch (buffer-reuse rule): merge output for multi-value
    // getFirst and the view list for getAllValues.
    merge_buf: std.ArrayList(u8),
    view_buf: std.ArrayList([]const u8),
    pub const PairView = struct { name: []const u8, value: []const u8 };
    pub fn init() HeadersData {
        return .{
            .names = std.ArrayList(u8).empty,
            .values = std.ArrayList(u8).empty,
            .entries = std.ArrayList(Entry).empty,
            .merge_buf = std.ArrayList(u8).empty,
            .view_buf = std.ArrayList([]const u8).empty,
        };
    }
    pub fn deinit(self: *HeadersData) void {
        self.names.deinit(gpa);
        self.values.deinit(gpa);
        self.entries.deinit(gpa);
        self.merge_buf.deinit(gpa);
        self.view_buf.deinit(gpa);
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
    // O(1) removal: swap the last entry into the removed slot.
    // Bytes stay in the append-only log until deinit.
    fn removeSwap(self: *HeadersData, i: usize) void {
        const last = self.entries.items.len - 1;
        if (i != last) self.entries.items[i] = self.entries.items[last];
        self.entries.items.len -= 1;
    }
    // Append an already-lowercased name. Zero heap allocations beyond
    // amortized buffer growth.
    fn appendLowered(self: *HeadersData, ln: []const u8, value: []const u8) void {
        const nbase = self.names.items.len;
        self.names.appendSlice(gpa, ln) catch return;
        const vbase = self.values.items.len;
        self.values.appendSlice(gpa, value) catch {
            self.names.items.len = nbase;
            return;
        };
        self.entries.append(gpa, .{
            .name_off = nbase,
            .name_len = ln.len,
            .val_off = vbase,
            .val_len = value.len,
        }) catch {
            self.names.items.len = nbase;
            self.values.items.len = vbase;
            return;
        };
    }
    // Hot path: lowercases in place inside the names buffer — no temp alloc.
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
            .name_off = nbase,
            .name_len = name.len,
            .val_off = vbase,
            .val_len = value.len,
        }) catch {
            self.names.items.len = nbase;
            self.values.items.len = vbase;
            return;
        };
    }
    // Replace-first semantics with duplicate collapse, zero temp allocations:
    // matches against raw query name via CI compare; new entries go through
    // the in-place-lowering append path.
    pub fn setEntry(self: *HeadersData, name: []const u8, value: []const u8) void {
        var first: ?usize = null;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (std.ascii.eqlIgnoreCase(self.nameOf(self.entries.items[i]), name)) {
                if (first == null) {
                    first = i;
                    const vbase = self.values.items.len;
                    self.values.appendSlice(gpa, value) catch return;
                    self.entries.items[i].val_off = vbase;
                    self.entries.items[i].val_len = value.len;
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
    // Returns a borrowed slice into the log (single value) or into the
    // reusable merge buffer (joined multi-value). Valid until the next
    // mutating call on this HeadersData.
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
    // Returns borrowed views into the reusable view list. Valid until the
    // next mutating call on this HeadersData.
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
                for (0..src.len()) |i| {
                    const p = src.getPair(i);
                    data.appendEntry(p.name, p.value);
                }
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
    var name_buf: [64]u8 = undefined;
    const name = extractStringAuto(isolate, arg0, &name_buf) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Null(isolate)));
        return;
    };
    defer name.deinit();
    if (data.getFirst(name.slice)) |val| {
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
    var name_buf: [64]u8 = undefined;
    const name = extractStringAuto(isolate, arg0, &name_buf) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Array__New(isolate, 0)));
        return;
    };
    defer name.deinit();
    const vals = data.getAllValues(name.slice);
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
    var name_buf: [64]u8 = undefined;
    const name = extractStringAuto(isolate, arg0, &name_buf) orelse {
        c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__False(isolate)));
        return;
    };
    defer name.deinit();
    c.v8__ReturnValue__Set(ret, if (data.hasEntry(name.slice, null))
        @ptrCast(c.v8__True(isolate))
    else
        @ptrCast(c.v8__False(isolate)));
}
pub fn headersSet(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const data = extractHeadersData(info) orelse return;
    const arg0 = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    const arg1 = c.v8__FunctionCallbackInfo__INDEX(info, 1);
    var name_buf: [64]u8 = undefined;
    var value_buf: [128]u8 = undefined;
    const name = extractStringAuto(isolate, arg0, &name_buf) orelse return;
    defer name.deinit();
    const value = extractStringAuto(isolate, arg1, &value_buf) orelse return;
    defer value.deinit();
    data.setEntry(name.slice, value.slice);
}
pub fn headersAppend(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const data = extractHeadersData(info) orelse return;
    const arg0 = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    const arg1 = c.v8__FunctionCallbackInfo__INDEX(info, 1);
    var name_buf: [64]u8 = undefined;
    var value_buf: [128]u8 = undefined;
    const name = extractStringAuto(isolate, arg0, &name_buf) orelse return;
    defer name.deinit();
    const value = extractStringAuto(isolate, arg1, &value_buf) orelse return;
    defer value.deinit();
    data.appendEntry(name.slice, value.slice);
}
pub fn headersDelete(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const data = extractHeadersData(info) orelse return;
    const arg0 = c.v8__FunctionCallbackInfo__INDEX(info, 0);
    var name_buf: [64]u8 = undefined;
    var val_buf: [128]u8 = undefined;
    const name = extractStringAuto(isolate, arg0, &name_buf) orelse return;
    defer name.deinit();
    var val: ?ExtractedStr = null;
    if (c.v8__FunctionCallbackInfo__Length(info) > 1) {
        const arg1 = c.v8__FunctionCallbackInfo__INDEX(info, 1);
        if (arg1 != null and !c.v8__Value__IsUndefined(arg1) and !c.v8__Value__IsNull(arg1)) {
            val = extractStringAuto(isolate, arg1, &val_buf);
        }
    }
    defer if (val) |v| v.deinit();
    data.deleteEntry(name.slice, if (val) |v| v.slice else null);
}
pub fn headersEntries(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    const data = extractHeadersData(info) orelse return;
    const pairs_arr = c.v8__Array__New(isolate, 0);
    for (0..data.len()) |i| {
        const p = data.getPair(i);
        const inner = c.v8__Array__New(isolate, 2);
        var out: c.MaybeBool = undefined;
        _ = c.v8__Object__Set(@ptrCast(inner), context, c.v8__Integer__NewFromUnsigned(isolate, 0), @ptrCast(zigStringToV8(isolate, p.name)), &out);
        _ = c.v8__Object__Set(@ptrCast(inner), context, c.v8__Integer__NewFromUnsigned(isolate, 1), @ptrCast(zigStringToV8(isolate, p.value)), &out);
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
    const arr = c.v8__Array__New(isolate, @intCast(data.len()));
    for (0..data.len()) |i| {
        const p = data.getPair(i);
        var out: c.MaybeBool = undefined;
        _ = c.v8__Object__Set(@ptrCast(arr), context, c.v8__Integer__NewFromUnsigned(isolate, @intCast(i)), @ptrCast(zigStringToV8(isolate, p.value)), &out);
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
    for (0..data.len()) |i| {
        const p = data.getPair(i);
        var argv: [3]?*const c.Value = .{
            zigStringToV8(isolate, p.value),
            zigStringToV8(isolate, p.name),
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
    c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Integer__New(isolate, @intCast(data.len()))));
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
