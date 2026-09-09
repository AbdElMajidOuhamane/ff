const std = @import("std");
const c = @import("../c.zig").c;
const pool_slice_mod = @import("pool_slice.zig");
const blob_mod = @import("blob.zig");
const gpa = std.heap.smp_allocator;

pub var formdata_class_id: c.ClassID = 0;

// ── DOD note ──
// Cold JS-bridge object, NOT hot I/O path (same reasoning as RequestData in
// request.zig:9-13 and the HeadersData note in headers.zig:8-16).
// Dense ArrayList(Entry) + single byte pool. std.MultiArrayList rejected for
// the same reason as Headers: variable-length pool bytes addressed by stable
// off/len, per-object count is small, lifetime is JS-GC bound.
const PoolSlice = pool_slice_mod.PoolSlice;

pub const Entry = struct {
    name: PoolSlice,
    value: PoolSlice, // text OR file bytes (into pool)
    filename: PoolSlice, // empty for plain text entries
    content_type: PoolSlice, // file MIME only
    is_file: bool,
    _pad: u8 = 0,

    comptime {
        std.debug.assert(@sizeOf(Entry) == 36);
    }
};

pub const FormData = struct {
    pool: std.ArrayList(u8),
    entries: std.ArrayList(Entry),

    comptime {
        std.debug.assert(@sizeOf(FormData) == 48);
        std.debug.assert(@alignOf(FormData) >= 8);
    }

    pub fn init() FormData {
        return .{
            .pool = std.ArrayList(u8).empty,
            .entries = std.ArrayList(Entry).empty,
        };
    }
    pub fn deinit(self: *FormData) void {
        self.pool.deinit(gpa);
        self.entries.deinit(gpa);
    }
    pub fn len(self: *const FormData) usize {
        return self.entries.items.len;
    }
    fn store(self: *FormData, s: []const u8) PoolSlice {
        if (s.len == 0) return .{};
        const off = self.pool.items.len;
        self.pool.appendSlice(gpa, s) catch return .{};
        return .{ .off = @intCast(off), .len = @intCast(s.len) };
    }
    fn bytesOf(self: *const FormData, ps: PoolSlice) []const u8 {
        if (ps.len == 0) return "";
        return self.pool.items[ps.off .. ps.off + ps.len];
    }
    pub fn nameOf(self: *const FormData, e: Entry) []const u8 {
        return self.bytesOf(e.name);
    }
    pub fn valueOf(self: *const FormData, e: Entry) []const u8 {
        return self.bytesOf(e.value);
    }
    pub fn appendText(self: *FormData, name: []const u8, value: []const u8) void {
        self.entries.append(gpa, .{
            .name = self.store(name),
            .value = self.store(value),
            .filename = .{},
            .content_type = .{},
            .is_file = false,
        }) catch {};
    }
    pub fn appendFile(self: *FormData, name: []const u8, bytes: []const u8, filename: []const u8, content_type: []const u8) void {
        // WHATWG type normalize, same rule as BlobData.setTypeNormalized.
        var ct = content_type;
        if (std.mem.indexOfScalar(u8, ct, ';')) |i| ct = ct[0..i];
        self.entries.append(gpa, .{
            .name = self.store(name),
            .value = self.store(bytes),
            .filename = self.store(filename),
            .content_type = self.storeLower(ct),
            .is_file = true,
        }) catch {};
    }
    fn storeLower(self: *FormData, s: []const u8) PoolSlice {
        var t = s;
        while (t.len > 0 and (t[0] == ' ' or t[0] == '\t')) t = t[1..];
        while (t.len > 0 and (t[t.len - 1] == ' ' or t[t.len - 1] == '\t')) t = t[0 .. t.len - 1];
        if (t.len == 0) return .{};
        const off = self.pool.items.len;
        self.pool.ensureTotalCapacity(gpa, off + t.len) catch return .{};
        for (t) |ch| self.pool.appendAssumeCapacity(if (ch >= 'A' and ch <= 'Z') ch + 32 else ch);
        return .{ .off = @intCast(off), .len = @intCast(t.len) };
    }
    pub fn deleteAll(self: *FormData, name: []const u8) void {
        // Swap-remove, same tradeoff as HeadersData.deleteEntry
        // (headers.zig:236 removeSwap) — order not preserved.
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (std.mem.eql(u8, self.nameOf(self.entries.items[i]), name)) {
                _ = self.entries.swapRemove(i);
            } else i += 1;
        }
    }
    /// Replace all entries with `name` by a single text entry (set()).
    pub fn setText(self: *FormData, name: []const u8, value: []const u8) void {
        self.deleteAll(name);
        self.appendText(name, value);
    }
    pub fn firstIndex(self: *const FormData, name: []const u8) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, self.nameOf(e), name)) return i;
        }
        return null;
    }
};

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

fn extractFormData(ctx: ?*c.Context, this_val: c.Value) ?*FormData {
    const ptr = c.getOpaque2(ctx, this_val, formdata_class_id) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

pub fn buildFormDataJSObject(ctx: ?*c.Context, data: *FormData) c.Value {
    const obj = c.newObjectClass(ctx, @intCast(formdata_class_id));
    c.setOpaque(obj, data);
    return obj;
}

/// Wrap an entry value as JS: string for text, Blob for files.
fn entryValueToJS(ctx: ?*c.Context, fd: *FormData, e: Entry) c.Value {
    if (!e.is_file) return zigStringToJS(ctx, fd.valueOf(e));
    const b = gpa.create(blob_mod.BlobData) catch return c.JS_UNDEFINED;
    b.* = blob_mod.BlobData.init();
    b.setBytes(fd.valueOf(e));
    b.setTypeNormalized(fd.bytesOf(e.content_type));
    return blob_mod.buildBlobJSObject(ctx, b);
}

fn formDataAppend(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const fd = extractFormData(ctx, this_val) orelse return c.JS_EXCEPTION;
    if (argc < 2) {
        _ = c.throwTypeError(ctx, "FormData.append requires a name and a value");
        return c.JS_EXCEPTION;
    }
    var nbuf: [256]u8 = undefined;
    var vbuf: [512]u8 = undefined;
    const n = extractStringAuto(ctx, argv[0], &nbuf) orelse return c.JS_UNDEFINED;
    defer n.deinit();
    if (c.isObject(argv[1]) != 0) {
        if (blob_mod.dataFromJS(ctx, argv[1])) |b| {
            var fbuf: [256]u8 = undefined;
            var fname: []const u8 = "";
            var fheld: ?ExtractedStr = null;
            if (argc > 2 and c.isString(argv[2]) != 0) {
                if (extractStringAuto(ctx, argv[2], &fbuf)) |f| {
                    fheld = f;
                    fname = f.slice;
                }
            }
            defer if (fheld) |*f| f.deinit();
            fd.appendFile(n.slice, b.bytes(), fname, b.mimeType());
            return c.JS_UNDEFINED;
        }
    }
    const v = extractStringAuto(ctx, argv[1], &vbuf) orelse return c.JS_UNDEFINED;
    defer v.deinit();
    fd.appendText(n.slice, v.slice);
    return c.JS_UNDEFINED;
}

fn formDataSet(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const fd = extractFormData(ctx, this_val) orelse return c.JS_EXCEPTION;
    if (argc < 2) {
        _ = c.throwTypeError(ctx, "FormData.set requires a name and a value");
        return c.JS_EXCEPTION;
    }
    var nbuf: [256]u8 = undefined;
    var vbuf: [512]u8 = undefined;
    const n = extractStringAuto(ctx, argv[0], &nbuf) orelse return c.JS_UNDEFINED;
    defer n.deinit();
    // Blob-valued set(): replace with file entry (spec behavior).
    if (c.isObject(argv[1]) != 0) {
        if (blob_mod.dataFromJS(ctx, argv[1])) |b| {
            fd.deleteAll(n.slice);
            fd.appendFile(n.slice, b.bytes(), "", b.mimeType());
            return c.JS_UNDEFINED;
        }
    }
    const v = extractStringAuto(ctx, argv[1], &vbuf) orelse return c.JS_UNDEFINED;
    defer v.deinit();
    fd.setText(n.slice, v.slice);
    return c.JS_UNDEFINED;
}

fn formDataGet(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const fd = extractFormData(ctx, this_val) orelse return c.JS_EXCEPTION;
    if (argc < 1) return c.JS_NULL;
    var nbuf: [256]u8 = undefined;
    const n = extractStringAuto(ctx, argv[0], &nbuf) orelse return c.JS_NULL;
    defer n.deinit();
    const i = fd.firstIndex(n.slice) orelse return c.JS_NULL;
    return entryValueToJS(ctx, fd, fd.entries.items[i]);
}

fn formDataGetAll(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const fd = extractFormData(ctx, this_val) orelse return c.newArray(ctx);
    if (argc < 1) return c.newArray(ctx);
    var nbuf: [256]u8 = undefined;
    const n = extractStringAuto(ctx, argv[0], &nbuf) orelse return c.newArray(ctx);
    defer n.deinit();
    const arr = c.newArray(ctx);
    var out: u32 = 0;
    for (fd.entries.items) |e| {
        if (!std.mem.eql(u8, fd.nameOf(e), n.slice)) continue;
        _ = c.definePropertyValueUint32(ctx, arr, out, entryValueToJS(ctx, fd, e), c.PROP_C_W_E);
        out += 1;
    }
    return arr;
}

fn formDataHas(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const fd = extractFormData(ctx, this_val) orelse return c.JS_EXCEPTION;
    if (argc < 1) return c.JS_FALSE;
    var nbuf: [256]u8 = undefined;
    const n = extractStringAuto(ctx, argv[0], &nbuf) orelse return c.JS_FALSE;
    defer n.deinit();
    return if (fd.firstIndex(n.slice) != null) c.JS_TRUE else c.JS_FALSE;
}

fn formDataDelete(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const fd = extractFormData(ctx, this_val) orelse return c.JS_EXCEPTION;
    if (argc < 1) return c.JS_UNDEFINED;
    var nbuf: [256]u8 = undefined;
    const n = extractStringAuto(ctx, argv[0], &nbuf) orelse return c.JS_UNDEFINED;
    defer n.deinit();
    fd.deleteAll(n.slice);
    return c.JS_UNDEFINED;
}

fn formDataEntries(ctx: ?*c.Context, this_val: c.Value, _: c_int, _: [*c]c.Value) callconv(.c) c.Value {
    const fd = extractFormData(ctx, this_val) orelse return c.newArray(ctx);
    const pairs_arr = c.newArray(ctx);
    for (fd.entries.items, 0..) |e, i| {
        const inner = c.newArray(ctx);
        _ = c.definePropertyValueUint32(ctx, inner, 0, zigStringToJS(ctx, fd.nameOf(e)), c.PROP_C_W_E);
        _ = c.definePropertyValueUint32(ctx, inner, 1, entryValueToJS(ctx, fd, e), c.PROP_C_W_E);
        _ = c.definePropertyValueUint32(ctx, pairs_arr, @intCast(i), inner, c.PROP_C_W_E);
    }
    return pairs_arr;
}

fn formDataKeys(ctx: ?*c.Context, this_val: c.Value, _: c_int, _: [*c]c.Value) callconv(.c) c.Value {
    const fd = extractFormData(ctx, this_val) orelse return c.newArray(ctx);
    const arr = c.newArray(ctx);
    for (fd.entries.items, 0..) |e, i| {
        _ = c.definePropertyValueUint32(ctx, arr, @intCast(i), zigStringToJS(ctx, fd.nameOf(e)), c.PROP_C_W_E);
    }
    return arr;
}

fn formDataValues(ctx: ?*c.Context, this_val: c.Value, _: c_int, _: [*c]c.Value) callconv(.c) c.Value {
    const fd = extractFormData(ctx, this_val) orelse return c.newArray(ctx);
    const arr = c.newArray(ctx);
    for (fd.entries.items, 0..) |e, i| {
        _ = c.definePropertyValueUint32(ctx, arr, @intCast(i), entryValueToJS(ctx, fd, e), c.PROP_C_W_E);
    }
    return arr;
}

fn formDataForEach(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const fd = extractFormData(ctx, this_val) orelse return c.JS_UNDEFINED;
    if (argc < 1) return c.JS_UNDEFINED;
    const callback = argv[0];
    for (fd.entries.items) |e| {
        var args = [_]c.Value{
            entryValueToJS(ctx, fd, e),
            zigStringToJS(ctx, fd.nameOf(e)),
            this_val,
        };
        _ = c.call(ctx, callback, this_val, 3, &args);
    }
    return c.JS_UNDEFINED;
}

fn formDataSize(ctx: ?*c.Context, this_val: c.Value, _: c_int, _: [*c]c.Value) callconv(.c) c.Value {
    const fd = extractFormData(ctx, this_val) orelse return c.newInt32(ctx, 0);
    return c.newInt32(ctx, @intCast(fd.len()));
}

fn formDataFinalizer(rt: ?*c.Runtime, val: c.Value) callconv(.c) void {
    _ = rt;
    if (c.getOpaque(val, formdata_class_id)) |ptr| {
        const data: *FormData = @ptrCast(@alignCast(ptr));
        data.deinit();
        gpa.destroy(data);
    }
}

fn formDataConstructor(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    _ = argc;
    _ = argv;
    // No DOM — the optional HTMLFormElement argument has no meaning here.
    const data = gpa.create(FormData) catch return c.throwOutOfMemory(ctx);
    data.* = FormData.init();
    return buildFormDataJSObject(ctx, data);
}

pub fn setup(ctx: ?*c.Context) void {
    var class_def = c.ClassDef{
        .class_name = "FormData",
        .finalizer = formDataFinalizer,
    };
    _ = c.newClassID(c.getRuntime(ctx), &formdata_class_id);
    _ = c.newClass(c.getRuntime(ctx), formdata_class_id, &class_def);

    const proto = c.newObject(ctx);
    const methods = [_]struct { name: [*:0]const u8, func: *const c.CFunction, len: c_int }{
        .{ .name = "append", .func = &formDataAppend, .len = 2 },
        .{ .name = "set", .func = &formDataSet, .len = 2 },
        .{ .name = "get", .func = &formDataGet, .len = 1 },
        .{ .name = "getAll", .func = &formDataGetAll, .len = 1 },
        .{ .name = "has", .func = &formDataHas, .len = 1 },
        .{ .name = "delete", .func = &formDataDelete, .len = 1 },
        .{ .name = "entries", .func = &formDataEntries, .len = 0 },
        .{ .name = "keys", .func = &formDataKeys, .len = 0 },
        .{ .name = "values", .func = &formDataValues, .len = 0 },
        .{ .name = "forEach", .func = &formDataForEach, .len = 1 },
        .{ .name = "size", .func = &formDataSize, .len = 0 },
    };
    for (methods) |m| {
        const fn_val = c.newCFunction(ctx, m.func, m.name, m.len);
        _ = c.definePropertyValueStr(ctx, proto, m.name, fn_val, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
    }
    c.setClassProto(ctx, formdata_class_id, proto);
    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);
    const ctor = c.newCFunction2(ctx, &formDataConstructor, "FormData", 0, c.JS_CFUNC_constructor, 0);
    _ = c.definePropertyValueStr(ctx, global, "FormData", ctor, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
}

// ─── Body parsers (used by Request.formData / Response.formData) ───

fn hexVal(ch: u8) ?u8 {
    if (ch >= '0' and ch <= '9') return ch - '0';
    if (ch >= 'a' and ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' and ch <= 'F') return ch - 'A' + 10;
    return null;
}

/// Append percent-decoded `src` into the pool; `plus_as_space` for query encoding.
fn storeDecoded(fd: *FormData, src: []const u8, plus_as_space: bool) PoolSlice {
    if (src.len == 0) return .{};
    const off = fd.pool.items.len;
    fd.pool.ensureTotalCapacity(gpa, off + src.len) catch return .{};
    var i: usize = 0;
    while (i < src.len) {
        const ch = src[i];
        if (plus_as_space and ch == '+') {
            fd.pool.appendAssumeCapacity(' ');
            i += 1;
        } else if (ch == '%' and i + 2 < src.len) {
            const hi = hexVal(src[i + 1]);
            const lo = hexVal(src[i + 2]);
            if (hi != null and lo != null) {
                fd.pool.appendAssumeCapacity(hi.? * 16 + lo.?);
                i += 3;
            } else {
                fd.pool.appendAssumeCapacity('%');
                i += 1;
            }
        } else {
            fd.pool.appendAssumeCapacity(ch);
            i += 1;
        }
    }
    const wrote = fd.pool.items.len - off;
    if (wrote == 0) return .{};
    return .{ .off = @intCast(off), .len = @intCast(wrote) };
}

fn parseUrlEncoded(fd: *FormData, body: []const u8) void {
    var rest = body;
    while (rest.len > 0) {
        var pair = rest;
        if (std.mem.indexOfScalar(u8, rest, '&')) |idx| {
            pair = rest[0..idx];
            rest = rest[idx + 1 ..];
        } else rest = "";
        if (pair.len == 0) continue;
        var name = pair;
        var value: []const u8 = "";
        if (std.mem.indexOfScalar(u8, pair, '=')) |idx| {
            name = pair[0..idx];
            value = pair[idx + 1 ..];
        }
        const n = storeDecoded(fd, name, true);
        const v = storeDecoded(fd, value, true);
        fd.entries.append(gpa, .{
            .name = n,
            .value = v,
            .filename = .{},
            .content_type = .{},
            .is_file = false,
        }) catch {};
    }
}

fn trimQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    return s;
}

/// Parse one part's headers; returns body slice on success.
fn parsePart(fd: *FormData, part: []const u8) void {
    const sep = std.mem.indexOf(u8, part, "\r\n\r\n") orelse return;
    const head = part[0..sep];
    var body = part[sep + 4 ..];
    // Strip single trailing CRLF belonging to the delimiter framing.
    if (body.len >= 2 and std.mem.endsWith(u8, body, "\r\n")) body = body[0 .. body.len - 2];

    var name: []const u8 = "";
    var filename: []const u8 = "";
    var content_type: []const u8 = "text/plain";
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    while (lines.next()) |line| {
        if (line.len >= 20 and std.ascii.startsWithIgnoreCase(line, "content-disposition:")) {
            var params = std.mem.splitSequence(u8, line, ";");
            while (params.next()) |p| {
                var t = p;
                while (t.len > 0 and (t[0] == ' ' or t[0] == '\t')) t = t[1..];
                if (t.len >= 5 and std.ascii.startsWithIgnoreCase(t, "name=")) {
                    name = trimQuotes(t[5..]);
                } else if (t.len >= 9 and std.ascii.startsWithIgnoreCase(t, "filename=")) {
                    filename = trimQuotes(t[9..]);
                }
            }
        } else if (line.len >= 13 and std.ascii.startsWithIgnoreCase(line, "content-type:")) {
            var v = line[13..];
            while (v.len > 0 and (v[0] == ' ' or v[0] == '\t')) v = v[1..];
            if (v.len > 0) content_type = v;
        }
    }
    if (name.len == 0) return;
    if (filename.len > 0) {
        fd.appendFile(name, body, filename, content_type);
    } else {
        fd.entries.append(gpa, .{
            .name = fd.store(name),
            .value = fd.store(body),
            .filename = .{},
            .content_type = .{},
            .is_file = false,
        }) catch {};
    }
}

fn parseMultipart(fd: *FormData, body: []const u8, boundary: []const u8) void {
    // Delimiter per RFC 7578: "--" + boundary. Single linear scan.
    if (boundary.len == 0 or boundary.len > 256) return;
    var delim_buf: [260]u8 = undefined;
    delim_buf[0] = '-';
    delim_buf[1] = '-';
    @memcpy(delim_buf[2 .. 2 + boundary.len], boundary);
    const delim = delim_buf[0 .. 2 + boundary.len];
    var rest = body;
    // Skip preamble: first delimiter opens the first part.
    const first = std.mem.indexOf(u8, rest, delim) orelse return;
    rest = rest[first + delim.len ..];
    while (rest.len > 0) {
        // After a delimiter comes CRLF (more parts) or "--" (epilogue).
        if (rest.len >= 2 and rest[0] == '-' and rest[1] == '-') return;
        if (rest.len >= 2 and rest[0] == '\r' and rest[1] == '\n') rest = rest[2..] else return;
        const next = std.mem.indexOf(u8, rest, delim) orelse return;
        parsePart(fd, rest[0..next]);
        rest = rest[next + delim.len ..];
    }
}

/// Returns false when the content-type is unsupported (caller rejects).
pub fn parseBody(fd: *FormData, content_type: []const u8, body: []const u8) bool {
    // Empty body → empty FormData regardless of content-type (lenient).
    if (body.len == 0) return true;
    const ct = content_type;
    var semi: ?usize = null;
    if (std.mem.indexOfScalar(u8, ct, ';')) |idx| semi = idx;
    const mime = if (semi) |idx| ct[0..idx] else ct;
    // Trim trailing space of the mime token.
    var m = mime;
    while (m.len > 0 and (m[m.len - 1] == ' ' or m[m.len - 1] == '\t')) m = m[0 .. m.len - 1];
    if (m.len == 0) return false;
    if (std.ascii.startsWithIgnoreCase(m, "application/x-www-form-urlencoded")) {
        parseUrlEncoded(fd, body);
        return true;
    }
    if (std.ascii.startsWithIgnoreCase(m, "multipart/form-data")) {
        if (semi == null) return false;
        var params = ct[semi.? + 1 ..];
        while (params.len > 0) {
            var p = params;
            if (std.mem.indexOfScalar(u8, params, ';')) |idx| {
                p = params[0..idx];
                params = params[idx + 1 ..];
            } else params = "";
            while (p.len > 0 and (p[0] == ' ' or p[0] == '\t')) p = p[1..];
            if (p.len >= 9 and std.ascii.startsWithIgnoreCase(p, "boundary=")) {
                var b = p[9..];
                while (b.len > 0 and (b[b.len - 1] == ' ' or b[b.len - 1] == '\t')) b = b[0 .. b.len - 1];
                b = trimQuotes(b);
                parseMultipart(fd, body, b);
                return true;
            }
        }
        return false;
    }
    return false;
}
