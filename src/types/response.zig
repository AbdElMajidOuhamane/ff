const std = @import("std");
const c = @import("../c.zig").c;
const headers_mod = @import("headers.zig");
const pool_slice_mod = @import("pool_slice.zig");
const blob_mod = @import("blob.zig");
const formdata_mod = @import("formdata.zig");
const gpa = std.heap.smp_allocator;
const perm = @import("../security/permissions.zig");
const deny = @import("../security/deny.zig");
const readable_stream = @import("readable_stream.zig");

fn guessContentType(path: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "application/octet-stream";
    const ext = path[dot..];
    if (std.ascii.eqlIgnoreCase(ext, ".html") or std.ascii.eqlIgnoreCase(ext, ".htm")) return "text/html; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(ext, ".css")) return "text/css; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(ext, ".js") or std.ascii.eqlIgnoreCase(ext, ".mjs")) return "application/javascript; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(ext, ".json")) return "application/json";
    if (std.ascii.eqlIgnoreCase(ext, ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(ext, ".svg")) return "image/svg+xml";
    if (std.ascii.eqlIgnoreCase(ext, ".txt")) return "text/plain; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(ext, ".wasm")) return "application/wasm";
    return "application/octet-stream";
}

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

fn extractIntFromVal(ctx: ?*c.Context, val: c.Value, default: u16) u16 {
    if (c.isUndefined(val) != 0 or c.isNull(val) != 0) return default;
    var out: i32 = 0;
    if (c.toInt32(ctx, &out, val) == -1) return default; // exception
    // Bounded cast: a negative or >3-digit status traps in safe builds and
    // wraps to 65535 in ReleaseFast (new Response("x", { status: -1 })).
    if (out < 100 or out > 999) return default;
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
    basic,
    cors,
    default,
    err,
    opaque_type,
    opaqueredirect,
    other,
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
            .basic => "basic",
            .cors => "cors",
            .default => "default",
            .err => "error",
            .opaque_type => "opaque",
            .opaqueredirect => "opaqueredirect",
            .other => "other",
        };
    }
};

const PoolSlice = pool_slice_mod.PoolSlice;

pub const ResponseDataCold = struct {
    response_type_other: PoolSlice,
    stream: ?c.Value = null,
};

// C1 FIX: ResponseData shell freelist — one `gpa.create` per fetch() result
// (async_fetch.runJob) and per `new Response()` otherwise. The ~96B shell is
// pooled; pools/bodies are freed by deinit, so idle RSS never grows. Safe:
// every call site overwrites the shell with init()/initWithHeaders right
// after acquiring, so no stale fields survive.
// THREAD SAFETY: async_fetch settles jobs on 16 worker threads and each job
// acquires/releases a shell there, so the pool index is shared state. It used
// to say "JS-thread-only", which let two workers pop one shell. The mutex
// guards the index only: a popped shell is owned exclusively, so resource
// frees stay outside the critical section.
const RESP_POOL_MAX: usize = 32;
const RESP_RETAIN_POOL_BYTES: usize = 4096;
var resp_pool: [RESP_POOL_MAX]*ResponseData = undefined;
var resp_pool_n: usize = 0;
var resp_pool_mutex: std.atomic.Mutex = .unlocked;

inline fn respPoolLock() void {
    while (!resp_pool_mutex.tryLock()) std.atomic.spinLoopHint();
}
inline fn respPoolUnlock() void {
    resp_pool_mutex.unlock();
}

/// Pooled shell (caller must assign initWithPool() or init()/initWithHeaders()).
/// Null only on OOM.
pub fn acquire() ?*ResponseData {
    respPoolLock();
    const pooled: ?*ResponseData = if (resp_pool_n > 0) blk: {
        resp_pool_n -= 1;
        break :blk resp_pool[resp_pool_n];
    } else null;
    respPoolUnlock();
    if (pooled) |d| return d;
    const d = gpa.create(ResponseData) catch return null;
    d.pool = std.ArrayList(u8).empty;
    return d;
}

/// deinit + return shell to the pool (destroy when full).
/// Retains `pool` capacity (up to RESP_RETAIN_POOL_BYTES) so repeated
/// `new Response(body)` calls are zero-alloc on the Zig heap.
pub fn releaseData(d: *ResponseData) void {
    // The caller owns `d` exclusively, so release its resources before
    // contending for the shared index.
    if (d.owned_body) |b| {
        gpa.free(b);
        d.owned_body = null;
    }
    if (d.cold) |cd| {
        gpa.destroy(cd);
        d.cold = null;
    }
    d.headers.release();
    if (d.pool.capacity > RESP_RETAIN_POOL_BYTES) {
        d.pool.deinit(gpa);
        d.pool = std.ArrayList(u8).empty;
    } else {
        d.pool.clearRetainingCapacity();
    }
    respPoolLock();
    if (resp_pool_n < RESP_POOL_MAX) {
        resp_pool[resp_pool_n] = d;
        resp_pool_n += 1;
        respPoolUnlock();
        return;
    }
    respPoolUnlock();
    gpa.destroy(d);
}

/// Return an *uninitialized* shell to the pool. Used when `init()` failed
/// partway: calling `deinit()` on it would touch uninitialized fields.
fn releaseShell(d: *ResponseData) void {
    respPoolLock();
    if (resp_pool_n < RESP_POOL_MAX) {
        d.pool.clearRetainingCapacity();
        resp_pool[resp_pool_n] = d;
        resp_pool_n += 1;
        respPoolUnlock();
        return;
    }
    respPoolUnlock();
    d.pool.deinit(gpa);
    gpa.destroy(d);
}

/// Pooled shell + initialized payload, or null with a JS exception pending.
/// `init()` is fallible (headers shell + the "OK" status text can OOM), and a
/// constructor that cannot report that must not abort the whole process.
fn acquireInitialized(ctx: ?*c.Context) ?*ResponseData {
    const data = acquire() orelse {
        _ = c.throwOutOfMemory(ctx);
        return null;
    };
    const retained_pool = data.pool;
    data.* = ResponseData.initWithPool(retained_pool) catch {
        data.pool = retained_pool;
        releaseShell(data);
        _ = c.throwOutOfMemory(ctx);
        return null;
    };
    return data;
}

/// Unwind a half-built response and turn `err` into the matching JS throw.
fn failResponse(ctx: ?*c.Context, data: *ResponseData, err: anyerror) c.Value {
    releaseData(data);
    return switch (err) {
        error.OutOfMemory => c.throwOutOfMemory(ctx),
        error.InvalidHeader => c.throwTypeError(ctx, "invalid header name or value"),
        error.HeadersTooLarge => c.throwTypeError(ctx, "too many headers (max 2048)"),
        else => c.throwInternalError(ctx, "response construction failed"),
    };
}

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
        // A5 FIX: size ratchet, not just align (was: align-only, so layout
        // drift went uncaught — cf. the stale "ArrayList = 16B" comment in
        // headers.zig). 24 pool + 8 headers + 16 owned_body + 8 cold + 2
        // status + 1 type + 3×8 slices + 3 bools = 88B today; 8B headroom.
        std.debug.assert(@sizeOf(ResponseData) <= 96);
        std.debug.assert(@alignOf(ResponseData) >= 8);
    }

    pub fn init() error{OutOfMemory}!ResponseData {
        return initWithPool(std.ArrayList(u8).empty);
    }
    pub fn initWithPool(retained_pool: std.ArrayList(u8)) error{OutOfMemory}!ResponseData {
        // C1 FIX: pooled headers shell (headers.zig freelist). OOM is an
        // operational error, not a programmer error: return it so the
        // constructor can throw instead of aborting the runtime.
        const h = headers_mod.acquire() orelse return error.OutOfMemory;
        var p = retained_pool;
        p.clearRetainingCapacity();
        var self = ResponseData{
            .pool = p,
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
        self.storeString("OK", &self.status_text) catch |err| {
            h.release();
            return err;
        };
        return self;
    }
    pub fn initWithHeaders(h: *headers_mod.HeadersData) ResponseData {
        return initWithHeadersAndPool(h, std.ArrayList(u8).empty);
    }
    pub fn initWithHeadersAndPool(h: *headers_mod.HeadersData, retained_pool: std.ArrayList(u8)) ResponseData {
        var p = retained_pool;
        p.clearRetainingCapacity();
        return ResponseData{
            .pool = p,
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
    fn storeString(self: *ResponseData, s: []const u8, dst: *PoolSlice) error{OutOfMemory}!void {
        if (s.len == 0) {
            dst.* = .{};
            return;
        }
        const off = self.pool.items.len;
        try self.pool.appendSlice(gpa, s);
        dst.* = .{ .off = @intCast(off), .len = @intCast(s.len) };
    }
    pub fn setStatusText(self: *ResponseData, s: []const u8) error{OutOfMemory}!void {
        try self.storeString(s, &self.status_text);
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
    pub fn setBody(self: *ResponseData, s: ?[]const u8) error{OutOfMemory}!void {
        if (s) |b| {
            // Reserve the body and JS_ParseJSON's NUL before retaining either.
            if (b.len > 0) try self.pool.ensureUnusedCapacity(gpa, b.len + 1);
        }
        if (self.owned_body) |old| gpa.free(old);
        self.owned_body = null;
        self._body = .{};
        if (s) |b| {
            self.has_body = b.len > 0;
            if (self.has_body) {
                const off = self.pool.items.len;
                self.pool.appendSliceAssumeCapacity(b);
                self.pool.appendAssumeCapacity(0);
                self._body = .{ .off = @intCast(off), .len = @intCast(b.len) };
            }
        } else {
            self.has_body = false;
        }
    }
    pub fn setUrl(self: *ResponseData, s: []const u8) error{OutOfMemory}!void {
        try self.storeString(s, &self._url);
    }
    fn ensureCold(self: *ResponseData) error{OutOfMemory}!*ResponseDataCold {
        if (self.cold) |cd| return cd;
        const cd = gpa.create(ResponseDataCold) catch return error.OutOfMemory;
        cd.* = .{ .response_type_other = .{} };
        self.cold = cd;
        return cd;
    }
    pub fn setResponseType(self: *ResponseData, s: []const u8) error{OutOfMemory}!void {
        const t = ResponseType.fromSlice(s);
        self.response_type = t;
        if (t == .other) {
            const cd = try self.ensureCold();
            try self.storeString(s, &cd.response_type_other);
        }
    }
    pub fn cloneFrom(self: *ResponseData, src: *const ResponseData) !void {
        // FIX: reserve the pool BEFORE appendSlice (was after → no-op warm).
        // Single growth for the whole copy instead of per-chunk growth.
        // The pool must start EMPTY: init() writes "OK" at offset 0, and
        // src.status_text/_body are offsets into the source pool. Appending
        // after that header shifted every copied offset by 2 bytes (clone
        // returned "OK" as the body). clearRetainingCapacity keeps capacity.
        self.pool.clearRetainingCapacity();
        try self.pool.ensureTotalCapacity(gpa, src.pool.items.len);
        try self.pool.appendSlice(gpa, src.pool.items);
        self.status = src.status;
        self.status_text = src.status_text;
        self._body = src._body;
        self.has_body = src.has_body;
        self.body_used = false;
        self._url = src._url;
        self.redirected = src.redirected;
        self.response_type = src.response_type;
        self.headers.reserve(src.headers.len(), src.headers.names.items.len, src.headers.values.items.len);
        self.owned_body = if (src.owned_body) |b| try gpa.dupe(u8, b) else null;
        if (src.cold) |sc| {
            const dc = try self.ensureCold();
            dc.response_type_other = sc.response_type_other;
        }
        for (0..src.headers.len()) |i| {
            const p = src.headers.getPair(i);
            try self.headers.appendEntry(p.name, p.value);
        }
    }
};

fn parseHeadersInit(ctx: ?*c.Context, init_val: c.Value, target: *headers_mod.HeadersData) !void {
    if (c.isUndefined(init_val) != 0 or c.isNull(init_val) != 0) return;
    if (c.isObject(init_val) == 0) return;
    if (c.getOpaque2(ctx, init_val, headers_mod.headers_class_id)) |ptr| {
        const src: *headers_mod.HeadersData = @ptrCast(@alignCast(ptr));
        target.reserveEntries(src.len());
        for (0..src.len()) |i| {
            const p = src.getPair(i);
            try target.appendEntry(p.name, p.value);
        }
        return;
    }
    if (c.isArray(ctx, init_val) != 0) {
        const len_val = c.getPropertyStr(ctx, init_val, "length");
        defer c.freeValue(ctx, len_val);
        var len: c_int = 0;
        _ = c.toInt32(ctx, &len, len_val);
        // FIX: batch reserve — one growth for the whole array load. Clamp
        // before @intCast: a length above 2^31 arrives as a negative c_int,
        // which is UB to cast in ReleaseFast.
        const count: c_uint = @intCast(@max(len, 0));
        if (count > headers_mod.MAX_HEADERS_INIT) return error.HeadersTooLarge;
        if (count > 0) target.reserveEntries(count);
        var i: c_uint = 0;
        while (i < count) : (i += 1) {
            const item = c.getPropertyUint32(ctx, init_val, i);
            defer c.freeValue(ctx, item);
            if (c.isObject(item) == 0) continue;
            const name_val = c.getPropertyUint32(ctx, item, 0);
            defer c.freeValue(ctx, name_val);
            const val_val = c.getPropertyUint32(ctx, item, 1);
            defer c.freeValue(ctx, val_val);
            var nbuf: [128]u8 = undefined;
            var vbuf: [256]u8 = undefined;
            const n = extractStringAuto(ctx, name_val, &nbuf);
            const v = extractStringAuto(ctx, val_val, &vbuf);
            if (n) |nn| {
                defer nn.deinit();
                if (v) |vv| {
                    defer vv.deinit();
                    try target.appendEntry(nn.slice, vv.slice);
                }
            }
        }
        return;
    }
    var p: [*c]c.PropertyEnum = null;
    var count: c_uint = 0;
    if (c.getOwnPropertyNames(ctx, &p, &count, init_val, c.GPN_STRING_MASK | c.GPN_ENUM_ONLY) == 0) {
        defer c.freePropertyEnum(ctx, p, count);
        // FIX: batch reserve — one growth for the whole object load.
        if (count > 0) target.reserveEntries(count);
        for (0..count) |idx| {
            const name_atom = p[idx].atom;
            var nlen: usize = 0;
            const name_cstr = c.atomToCStringLen(ctx, &nlen, name_atom) orelse continue;
            defer c.freeCString(ctx, name_cstr);
            const val_val = c.getProperty(ctx, init_val, name_atom);
            defer c.freeValue(ctx, val_val);
            var vlen: usize = 0;
            if (c.toCStringLen(ctx, &vlen, val_val)) |val_cstr| {
                defer c.freeCString(ctx, val_cstr);
                try target.appendEntry(name_cstr[0..nlen], val_cstr[0..vlen]);
            }
        }
    }
}

fn parseHeadersInitFromObj(ctx: ?*c.Context, init_obj: c.Value, target: *headers_mod.HeadersData) !void {
    const headers_val = c.getPropertyStr(ctx, init_obj, "headers");
    defer c.freeValue(ctx, headers_val);
    if (c.isUndefined(headers_val) == 0 and c.isNull(headers_val) == 0) {
        try parseHeadersInit(ctx, headers_val, target);
    }
}

fn createEmbeddedHeaders(ctx: ?*c.Context, src: *headers_mod.HeadersData) c.Value {
    src.retain();
    return headers_mod.createJSObject(ctx, src);
}

fn responseBodyUsedGetter(ctx: ?*c.Context, this_val: c.Value, _: c_int, _: [*c]c.Value) callconv(.c) c.Value {
    const data = extractResponseData(ctx, this_val) orelse return c.JS_FALSE;
    return if (data.body_used) c.JS_TRUE else c.JS_FALSE;
}

fn responseOkGetter(ctx: ?*c.Context, this_val: c.Value, _: c_int, _: [*c]c.Value) callconv(.c) c.Value {
    const data = extractResponseData(ctx, this_val) orelse return c.JS_FALSE;
    return if (data.status >= 200 and data.status <= 299) c.JS_TRUE else c.JS_FALSE;
}

fn responseRedirectedGetter(ctx: ?*c.Context, this_val: c.Value, _: c_int, _: [*c]c.Value) callconv(.c) c.Value {
    const data = extractResponseData(ctx, this_val) orelse return c.JS_FALSE;
    return if (data.redirected) c.JS_TRUE else c.JS_FALSE;
}

fn responseStatusGetter(ctx: ?*c.Context, this_val: c.Value, _: c_int, _: [*c]c.Value) callconv(.c) c.Value {
    const data = extractResponseData(ctx, this_val) orelse return c.newInt32(ctx, 200);
    return c.newInt32(ctx, @intCast(data.status));
}

fn responseStatusTextGetter(ctx: ?*c.Context, this_val: c.Value, _: c_int, _: [*c]c.Value) callconv(.c) c.Value {
    const data = extractResponseData(ctx, this_val) orelse return zigStringToJS(ctx, "");
    return zigStringToJS(ctx, data.statusText());
}

fn responseUrlGetter(ctx: ?*c.Context, this_val: c.Value, _: c_int, _: [*c]c.Value) callconv(.c) c.Value {
    const data = extractResponseData(ctx, this_val) orelse return zigStringToJS(ctx, "");
    return zigStringToJS(ctx, data.url());
}

fn responseTypeGetter(ctx: ?*c.Context, this_val: c.Value, _: c_int, _: [*c]c.Value) callconv(.c) c.Value {
    const data = extractResponseData(ctx, this_val) orelse return zigStringToJS(ctx, "basic");
    return zigStringToJS(ctx, data.responseType());
}

fn responseHeadersGetter(ctx: ?*c.Context, this_val: c.Value, _: c_int, _: [*c]c.Value) callconv(.c) c.Value {
    const data = extractResponseData(ctx, this_val) orelse return c.JS_UNDEFINED;
    const hdr_obj = createEmbeddedHeaders(ctx, data.headers);
    // Memoize on the instance so repeated `res.headers` returns the same JS object
    _ = c.definePropertyValueStr(ctx, this_val, "headers", c.dupValue(ctx, hdr_obj), c.PROP_C_W_E);
    return hdr_obj;
}

fn responseBodyGetter(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const data = extractResponseData(ctx, this_val) orelse return c.JS_UNDEFINED;
    if (data.cold) |cold| {
        if (cold.stream) |st| {
            return c.dupValue(ctx, st);
        }
    }
    if (!data.has_body) return c.JS_NULL;
    const body_bytes = data.body() orelse return c.JS_NULL;
    const idx = readable_stream.createStream(ctx, .native_push) orelse return c.JS_NULL;
    const stream_obj = readable_stream.createJsStream(ctx, idx);
    const u8_buf = c.newArrayBufferCopy(ctx, body_bytes.ptr, body_bytes.len);
    _ = readable_stream.pushChunk(ctx, idx, u8_buf);
    c.freeValue(ctx, u8_buf);
    readable_stream.closeStream(ctx, idx);
    return stream_obj;
}

fn responseText(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const data = extractResponseData(ctx, this_val) orelse return c.JS_EXCEPTION;
    data.body_used = true;
    if (data.cold) |cold| {
        if (cold.stream) |st| {
            if (readable_stream.getStreamSlot(ctx, st)) |slot| {
                var str_buf: std.ArrayList(u8) = .empty;
                defer str_buf.deinit(gpa);
                while (readable_stream.popChunk(slot)) |ch| {
                    defer c.freeValue(ctx, ch);
                    var slen: usize = 0;
                    if (c.toCStringLen(ctx, &slen, ch)) |cs| {
                        defer c.freeCString(ctx, cs);
                        str_buf.appendSlice(gpa, cs[0..slen]) catch {};
                    }
                }
                var cap: [2]c.Value = .{ c.JS_UNDEFINED, c.JS_UNDEFINED };
                const promise = c.newPromiseCapability(ctx, &cap);
                defer c.freeValue(ctx, cap[0]);
                defer c.freeValue(ctx, cap[1]);
                var result = zigStringToJS(ctx, str_buf.items);
                defer c.freeValue(ctx, result);
                _ = c.call(ctx, cap[0], c.JS_UNDEFINED, 1, &result);
                return promise;
            }
        }
    }
    const body_text = data.body() orelse "";
    var cap: [2]c.Value = .{ c.JS_UNDEFINED, c.JS_UNDEFINED };
    const promise = c.newPromiseCapability(ctx, &cap);
    defer c.freeValue(ctx, cap[0]);
    defer c.freeValue(ctx, cap[1]);
    var result = zigStringToJS(ctx, body_text);
    defer c.freeValue(ctx, result);
    _ = c.call(ctx, cap[0], c.JS_UNDEFINED, 1, &result);
    return promise;
}

/// JS_ParseJSON requires buf[len] == '\0' (vendor/quickjs/quickjs.c:51193:
/// "buf must be zero terminated"; the JSON tokenizer at :23734 reads one
/// byte past buf_end). Pool-backed bodies carry the sentinel appended by
/// setBody → zero-copy. Heap-owned bodies (setBodyOwned: >64K spill,
/// ArrayBuffer ctor, clone) are exact-length → NUL-terminate a copy into
/// `scratch`, or a fresh allocation returned via `heap_out` (caller frees).
fn bodyForParse(data: *const ResponseData, scratch: []u8, heap_out: *?[]u8) error{OutOfMemory}!?[:0]const u8 {
    const body = data.body() orelse return null;
    if (data.owned_body == null) return body.ptr[0..body.len :0];
    if (body.len < scratch.len) {
        @memcpy(scratch[0..body.len], body);
        scratch[body.len] = 0;
        return scratch[0..body.len :0];
    }
    const h = try gpa.alloc(u8, body.len + 1);
    @memcpy(h[0..body.len], body);
    h[body.len] = 0;
    heap_out.* = h;
    return h[0..body.len :0];
}

fn responseJson(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const data = extractResponseData(ctx, this_val) orelse return c.JS_EXCEPTION;
    data.body_used = true;
    const body_text = data.body() orelse "";
    var cap: [2]c.Value = .{ c.JS_UNDEFINED, c.JS_UNDEFINED };
    const promise = c.newPromiseCapability(ctx, &cap);
    defer c.freeValue(ctx, cap[0]);
    defer c.freeValue(ctx, cap[1]);
    if (body_text.len == 0) {
        var msg = zigStringToJS(ctx, "Unexpected end of JSON input");
        defer c.freeValue(ctx, msg);
        _ = c.call(ctx, cap[1], c.JS_UNDEFINED, 1, &msg);
        return promise;
    }
    var scratch: [4096]u8 = undefined;
    var heap_z: ?[]u8 = null;
    defer if (heap_z) |h| gpa.free(h);
    const body_z = bodyForParse(data, &scratch, &heap_z) catch {
        var msg = zigStringToJS(ctx, "out of memory");
        defer c.freeValue(ctx, msg);
        _ = c.call(ctx, cap[1], c.JS_UNDEFINED, 1, &msg);
        return promise;
    } orelse "";
    var parsed = c.parseJSON(ctx, body_z.ptr, body_z.len, "");
    defer c.freeValue(ctx, parsed);
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
    _ = argc;
    _ = argv;
    const data = extractResponseData(ctx, this_val) orelse return c.JS_EXCEPTION;
    data.body_used = true;
    const body_bytes = data.body() orelse "";
    var cap: [2]c.Value = .{ c.JS_UNDEFINED, c.JS_UNDEFINED };
    const promise = c.newPromiseCapability(ctx, &cap);
    defer c.freeValue(ctx, cap[0]);
    defer c.freeValue(ctx, cap[1]);
    var ab = c.newArrayBufferCopy(ctx, body_bytes.ptr, body_bytes.len);
    defer c.freeValue(ctx, ab);
    _ = c.call(ctx, cap[0], c.JS_UNDEFINED, 1, &ab);
    return promise;
}

fn responseBlob(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const data = extractResponseData(ctx, this_val) orelse return c.JS_EXCEPTION;
    data.body_used = true;
    const body_bytes = data.body() orelse "";
    var cap: [2]c.Value = .{ c.JS_UNDEFINED, c.JS_UNDEFINED };
    const promise = c.newPromiseCapability(ctx, &cap);
    defer c.freeValue(ctx, cap[0]);
    defer c.freeValue(ctx, cap[1]);
    const blob = gpa.create(blob_mod.BlobData) catch {
        var msg = zigStringToJS(ctx, "out of memory");
        defer c.freeValue(ctx, msg);
        _ = c.call(ctx, cap[1], c.JS_UNDEFINED, 1, &msg);
        return promise;
    };
    blob.* = blob_mod.BlobData.init();
    blob.setBytes(body_bytes);
    if (data.headers.getFirst("content-type")) |ct| blob.setTypeNormalized(ct);
    var obj = blob_mod.buildBlobJSObject(ctx, blob);
    defer c.freeValue(ctx, obj);
    _ = c.call(ctx, cap[0], c.JS_UNDEFINED, 1, &obj);
    return promise;
}

fn responseFormData(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const data = extractResponseData(ctx, this_val) orelse return c.JS_EXCEPTION;
    data.body_used = true;
    const body_bytes = data.body() orelse "";
    var cap: [2]c.Value = .{ c.JS_UNDEFINED, c.JS_UNDEFINED };
    const promise = c.newPromiseCapability(ctx, &cap);
    defer c.freeValue(ctx, cap[0]);
    defer c.freeValue(ctx, cap[1]);
    const fd = gpa.create(formdata_mod.FormData) catch {
        var msg = zigStringToJS(ctx, "out of memory");
        defer c.freeValue(ctx, msg);
        _ = c.call(ctx, cap[1], c.JS_UNDEFINED, 1, &msg);
        return promise;
    };
    fd.* = formdata_mod.FormData.init();
    const ct = data.headers.getFirst("content-type") orelse "";
    if (!formdata_mod.parseBody(fd, ct, body_bytes)) {
        fd.deinit();
        gpa.destroy(fd);
        var msg = zigStringToJS(ctx, "FormData unsupported content-type");
        defer c.freeValue(ctx, msg);
        _ = c.call(ctx, cap[1], c.JS_UNDEFINED, 1, &msg);
        return promise;
    }
    var obj = formdata_mod.buildFormDataJSObject(ctx, fd);
    defer c.freeValue(ctx, obj);
    _ = c.call(ctx, cap[0], c.JS_UNDEFINED, 1, &obj);
    return promise;
}

fn responseBytes(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const data = extractResponseData(ctx, this_val) orelse return c.JS_EXCEPTION;
    data.body_used = true;
    const body_bytes = data.body() orelse "";
    var cap: [2]c.Value = .{ c.JS_UNDEFINED, c.JS_UNDEFINED };
    const promise = c.newPromiseCapability(ctx, &cap);
    defer c.freeValue(ctx, cap[0]);
    defer c.freeValue(ctx, cap[1]);
    var ab = c.newArrayBufferCopy(ctx, body_bytes.ptr, body_bytes.len);
    defer c.freeValue(ctx, ab);
    _ = c.call(ctx, cap[0], c.JS_UNDEFINED, 1, &ab);
    return promise;
}

fn responseClone(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const data = extractResponseData(ctx, this_val) orelse return c.JS_EXCEPTION;
    // C1 FIX: pooled shell (was gpa.create per clone).
    const new_data = acquireInitialized(ctx) orelse return c.JS_EXCEPTION;
    new_data.cloneFrom(data) catch |err| return failResponse(ctx, new_data, err);
    return buildResponseJSObject(ctx, new_data);
}

fn responseStaticJson(ctx: ?*c.Context, _: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    var scratch: [256]u8 = undefined;
    // C1 FIX: pooled shell (was gpa.create per call).
    const data = acquireInitialized(ctx) orelse return c.JS_EXCEPTION;
    if (argc > 0) {
        const json_str = c.jsonStringify(ctx, argv[0], c.JS_UNDEFINED, c.JS_UNDEFINED);
        if (c.isException(json_str) != 0) {
            // C1 FIX: return the shell to the pool (was gpa.destroy —
            // would corrupt the freelist by freeing a pooled shell).
            releaseData(data);
            return c.JS_EXCEPTION;
        }
        defer c.freeValue(ctx, json_str);
        if (extractStringAuto(ctx, json_str, &scratch)) |owned| {
            defer owned.deinit();
            data.setBody(owned.slice) catch |err|
                return failResponse(ctx, data, err);
        }
        data.headers.appendEntry("content-type", "application/json") catch |err|
            return failResponse(ctx, data, err);
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
                data.setStatusText(st.slice) catch |err|
                    return failResponse(ctx, data, err);
            }
        }
        parseHeadersInitFromObj(ctx, init_val, data.headers) catch |err|
            return failResponse(ctx, data, err);
    }
    return buildResponseJSObject(ctx, data);
}

fn responseStaticRedirect(ctx: ?*c.Context, _: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    if (argc < 1) {
        _ = c.throwTypeError(ctx, "Response.redirect requires a URL");
        return c.JS_EXCEPTION;
    }
    var url_buf: [512]u8 = undefined;
    // C1 FIX: pooled shell (was gpa.create per call).
    const data = acquireInitialized(ctx) orelse return c.JS_EXCEPTION;
    if (extractStringAuto(ctx, argv[0], &url_buf)) |u| {
        defer u.deinit();
        data.setUrl(u.slice) catch |err|
            return failResponse(ctx, data, err);
    }
    data.status = 302;
    data.setStatusText("Found") catch |err|
        return failResponse(ctx, data, err);
    data.redirected = true;
    if (argc > 1) {
        data.status = extractIntFromVal(ctx, argv[1], 302);
    }
    return buildResponseJSObject(ctx, data);
}

fn responseStaticError(ctx: ?*c.Context, _: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    // C1 FIX: pooled shell (was gpa.create per call).
    const data = acquireInitialized(ctx) orelse return c.JS_EXCEPTION;
    data.status = 0;
    data.setStatusText("") catch |err|
        return failResponse(ctx, data, err);
    data.setResponseType("error") catch |err|
        return failResponse(ctx, data, err);
    return buildResponseJSObject(ctx, data);
}

fn responseStaticFile(ctx: ?*c.Context, _: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    if (argc < 1 or c.isString(argv[0]) == 0) {
        _ = c.throwTypeError(ctx, "Response.file requires a file path");
        return c.JS_EXCEPTION;
    }
    var len: usize = 0;
    const cstr = c.toCStringLen(ctx, &len, argv[0]) orelse return c.JS_EXCEPTION;
    defer c.freeCString(ctx, cstr);
    const path = cstr[0..len];

    if (perm.global().checkPath(.read, path) == .denied) {
        return deny.throw(ctx, "Response.file", .read, path);
    }

    const data = acquireInitialized(ctx) orelse return c.JS_EXCEPTION;
    data.status = 200;
    data.setStatusText("OK") catch |err|
        return failResponse(ctx, data, err);

    const file_bytes = std.Io.Dir.cwd().readFileAllocOptions(
        std.Io.Threaded.global_single_threaded.io(),
        path,
        gpa,
        .limited(50 * 1024 * 1024),
        .of(u8),
        0,
    ) catch |err| {
        releaseData(data);
        if (err == error.FileTooBig) {
            _ = c.throwTypeError(ctx, "Response.file exceeds 50 MB cap");
        } else {
            _ = c.throwTypeError(ctx, "could not read file");
        }
        return c.JS_EXCEPTION;
    };

    data.headers.setEntry("content-type", guessContentType(path)) catch |err|
        return failResponse(ctx, data, err);
    data.setBodyOwned(file_bytes);
    return buildResponseJSObject(ctx, data);
}

fn responseFinalizer(rt: ?*c.Runtime, val: c.Value) callconv(.c) void {
    if (c.getOpaque(val, response_class_id)) |ptr| {
        const data: *ResponseData = @ptrCast(@alignCast(ptr));
        if (data.cold) |cold| {
            if (cold.stream) |s| {
                c.freeValueRT(rt, s);
                cold.stream = null;
            }
        }
        releaseData(data);
    }
}

fn responseConstructor(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    var body_buf: [512]u8 = undefined;
    var scratch: [128]u8 = undefined;
    // C1 FIX: pooled shell (was gpa.create per `new Response()`).
    const data = acquireInitialized(ctx) orelse return c.JS_EXCEPTION;

    if (argc > 0 and c.isUndefined(argv[0]) == 0 and c.isNull(argv[0]) == 0) {
        const body_val = argv[0];
        if (readable_stream.isStream(ctx, body_val)) {
            data.has_body = true;
            const cold = gpa.create(ResponseDataCold) catch
                return failResponse(ctx, data, error.OutOfMemory);
            cold.* = .{ .response_type_other = .{}, .stream = c.dupValue(ctx, body_val) };
            data.cold = cold;
        } else if (c.isObject(body_val) != 0) {
            var ab_size: usize = 0;
            if (c.getArrayBuffer(ctx, &ab_size, body_val)) |ab_ptr| {
                const bytes: []const u8 = if (ab_size == 0) "" else ab_ptr[0..ab_size];
                const owned = gpa.dupe(u8, bytes) catch
                    return failResponse(ctx, data, error.OutOfMemory);
                data.setBodyOwned(owned);
            } else {
                if (c.hasException(ctx)) {
                    const exc = c.getException(ctx);
                    c.freeValue(ctx, exc);
                }
                var u8_size: usize = 0;
                if (c.getUint8Array(ctx, &u8_size, body_val)) |u8_ptr| {
                    const bytes: []const u8 = if (u8_size == 0) "" else u8_ptr[0..u8_size];
                    const owned = gpa.dupe(u8, bytes) catch
                        return failResponse(ctx, data, error.OutOfMemory);
                    data.setBodyOwned(owned);
                } else {
                    if (c.hasException(ctx)) {
                        const exc = c.getException(ctx);
                        c.freeValue(ctx, exc);
                    }
                    if (extractStringAuto(ctx, body_val, &body_buf)) |owned| {
                        defer owned.deinit();
                        data.setBody(owned.slice) catch |err|
                            return failResponse(ctx, data, err);
                    }
                }
            }
        } else {
            var slen: usize = 0;
            if (c.toCStringLen(ctx, &slen, body_val)) |cstr| {
                defer c.freeCString(ctx, cstr);
                data.setBody(cstr[0..slen]) catch |err|
                    return failResponse(ctx, data, err);
            }
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
                data.setStatusText(st.slice) catch |err|
                    return failResponse(ctx, data, err);
            }
        }
        parseHeadersInitFromObj(ctx, init_val, data.headers) catch |err|
            return failResponse(ctx, data, err);
    }

    const obj = c.newObjectClass(ctx, @intCast(response_class_id));
    c.setOpaque(obj, data);
    return obj;
}

pub fn buildResponseJSObject(ctx: ?*c.Context, data: *ResponseData) c.Value {
    const obj = c.newObjectClass(ctx, @intCast(response_class_id));
    c.setOpaque(obj, data);
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
    const getters = [_]struct { name: [*:0]const u8, func: *const c.CFunction }{
        .{ .name = "body", .func = &responseBodyGetter },
        .{ .name = "bodyUsed", .func = &responseBodyUsedGetter },
        .{ .name = "ok", .func = &responseOkGetter },
        .{ .name = "redirected", .func = &responseRedirectedGetter },
        .{ .name = "status", .func = &responseStatusGetter },
        .{ .name = "statusText", .func = &responseStatusTextGetter },
        .{ .name = "url", .func = &responseUrlGetter },
        .{ .name = "type", .func = &responseTypeGetter },
        .{ .name = "headers", .func = &responseHeadersGetter },
    };
    for (getters) |g| {
        const atom = c.newAtom(ctx, g.name);
        defer c.freeAtom(ctx, atom);
        _ = c.definePropertyGetSet(ctx, proto, atom, c.newCFunction(ctx, g.func, g.name, 0), c.JS_UNDEFINED, c.PROP_CONFIGURABLE | c.PROP_ENUMERABLE);
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
    const static_file = c.newCFunction(ctx, &responseStaticFile, "file", 1);
    _ = c.definePropertyValueStr(ctx, ctor, "file", static_file, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
}

// ── Regression tests: JS_ParseJSON requires buf[len] == '\0' ──
// setBody must leave a permanent NUL right after the pool-backed body;
// bodyForParse must hand parseJSON a sentinel-terminated buffer for both
// pool-backed (zero-copy) and heap-owned (copied) bodies. Pre-fix, the
// byte after the body was stale heap data → layout-dependent
// "unexpected data at the end" (see bench/fetch.js ipify repro).
test "setBody keeps pool-backed bodies NUL-terminated" {
    var d = try ResponseData.init();
    defer d.deinit();
    try d.setBody("{\"ip\":\"1.2.3.4\"}");
    const b = d.body().?;
    try std.testing.expectEqualStrings("{\"ip\":\"1.2.3.4\"}", b);
    const end = @as(usize, d._body.off) + @as(usize, d._body.len);
    try std.testing.expectEqual(@as(u8, 0), d.pool.items[end]);
    // Sentinel is position-stable: later pool writes append past it.
    try d.setStatusText("still-ok");
    try std.testing.expectEqual(@as(u8, 0), d.pool.items[end]);
    try std.testing.expectEqualStrings("{\"ip\":\"1.2.3.4\"}", d.body().?);
    // The null branch leaves no body (covers the has_body=false path).
    try d.setBody(null);
    try std.testing.expect(d.body() == null);
    try d.setBody("");
    try std.testing.expect(d.body() == null);
}

test "bodyForParse: zero-copy pool body, NUL copy for owned body" {
    var d = try ResponseData.init();
    defer d.deinit();
    var scratch: [16]u8 = undefined;
    var heap_z: ?[]u8 = null;
    defer if (heap_z) |h| gpa.free(h);

    try d.setBody("abc");
    const pool_body = d.body().?;
    const z1 = (try bodyForParse(&d, &scratch, &heap_z)).?;
    try std.testing.expectEqualStrings("abc", z1);
    try std.testing.expectEqual(@intFromPtr(pool_body.ptr), @intFromPtr(z1.ptr));
    try std.testing.expect(heap_z == null);

    const owned = try gpa.dupe(u8, "owned-body-bytes");
    d.setBodyOwned(owned); // exact-length heap slice, no sentinel
    const z2 = (try bodyForParse(&d, &scratch, &heap_z)).?;
    try std.testing.expectEqualStrings("owned-body-bytes", z2);
    try std.testing.expect(z2.ptr != d.body().?.ptr); // copied
    try std.testing.expectEqual(@as(u8, 0), z2.ptr[z2.len]);
    try std.testing.expect(heap_z != null);

    // Owned body smaller than scratch → stack NUL-copy path.
    if (heap_z) |h| gpa.free(h);
    heap_z = null;
    const tiny = try gpa.dupe(u8, "abc");
    d.setBodyOwned(tiny);
    const z3 = (try bodyForParse(&d, &scratch, &heap_z)).?;
    try std.testing.expectEqualStrings("abc", z3);
    try std.testing.expectEqual(@intFromPtr(&scratch), @intFromPtr(z3.ptr));
    try std.testing.expect(heap_z == null);
}
