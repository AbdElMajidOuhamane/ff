//! SQL tag / SQL class / Tx class — full zig-data-oriented-design compliance:
//! §Hot path (runTag/runUnsafe/jsConnect): Job freelist + job arena ONLY —
//!   0 Zig-gpa after acquireJob; encodeParam/query/params/oids all arena-backed.
//! §Encode (Phase 3): JS null→NULL(oid 0); bool→16; safe ints→int8(20);
//!   bigint(tag check)→decimal text oid 20; JS Array→PG literal {..} with oid
//!   1016(int8[])/1022(float8[])/1000(bool[])/1009(text[]), nested recurse,
//!   objects→JSON.stringify oid 114(json); Uint8Array→bytea(17) as before.
//! §Tx: begin() pins a conn (Phase 3, pg_client); Tx is tag-callable with
//!   commit()/rollback()/unsafe(); in-flight jobs dup the Tx object so the
//!   finalizer only ever sees idle conns; dead tx → sync TypeError.
//! §Cold: loadConfig/parseDsn/sqlCtor Config dupes; default_pool_fail message.
//! §Batch: hands whole query+params to pg_client.sendQuery (frame batch → 1 write).
//! §Hot/cold: this file stages Job only; I/O + rows live in pg_client.
//! §SIMD: N/A (string template assembly).
//! QuickJS heap (promise, JS strings for parts) required by API — not Zig-gpa.

const std = @import("std");
const c = @import("../c.zig").c;
const pg = @import("../net/pg_client.zig");

const gpa = std.heap.smp_allocator;

var sql_class_id: c.ClassID = 0;
var tx_class_id: c.ClassID = 0;
var default_pool: ?*pg.Pool = null;
var default_pool_fail: ?[]u8 = null;

pub fn setup(ctx: ?*c.Context) void {
    if (ctx) |c0| pg.setCtx(c0);
    {
        var def = c.ClassDef{
            .class_name = "SQL",
            .finalizer = sqlFinalizer,
            .call = sqlTagCall,
        };
        _ = c.newClassID(c.getRuntime(ctx), &sql_class_id);
        _ = c.newClass(c.getRuntime(ctx), sql_class_id, &def);
        const proto = c.newObject(ctx);
        const unsafe_fn = c.newCFunction(ctx, jsUnsafe, "unsafe", 2);
        _ = c.definePropertyValueStr(ctx, proto, "unsafe", unsafe_fn, c.PROP_C_W_E);
        const close_fn = c.newCFunction(ctx, jsClose, "close", 1);
        _ = c.definePropertyValueStr(ctx, proto, "close", close_fn, c.PROP_C_W_E);
        const connect_fn = c.newCFunction(ctx, jsConnect, "connect", 0);
        _ = c.definePropertyValueStr(ctx, proto, "connect", connect_fn, c.PROP_C_W_E);
        const begin_fn = c.newCFunction(ctx, jsBegin, "begin", 0);
        _ = c.definePropertyValueStr(ctx, proto, "begin", begin_fn, c.PROP_C_W_E);
        c.setClassProto(ctx, sql_class_id, proto);
    }
    {
        var tx_def = c.ClassDef{
            .class_name = "Tx",
            .finalizer = txFinalizer,
            .call = txTagCall,
        };
        _ = c.newClassID(c.getRuntime(ctx), &tx_class_id);
        _ = c.newClass(c.getRuntime(ctx), tx_class_id, &tx_def);
        const tx_proto = c.newObject(ctx);
        const commit_fn = c.newCFunction(ctx, txCommit, "commit", 0);
        _ = c.definePropertyValueStr(ctx, tx_proto, "commit", commit_fn, c.PROP_C_W_E);
        const rollback_fn = c.newCFunction(ctx, txRollback, "rollback", 0);
        _ = c.definePropertyValueStr(ctx, tx_proto, "rollback", rollback_fn, c.PROP_C_W_E);
        const unsafe_fn = c.newCFunction(ctx, txUnsafe, "unsafe", 2);
        _ = c.definePropertyValueStr(ctx, tx_proto, "unsafe", unsafe_fn, c.PROP_C_W_E);
        c.setClassProto(ctx, tx_class_id, tx_proto);
    }
    pg.tx_factory = makeTx;
    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);
    const sql_fn = c.newCFunction(ctx, sqlTagGlobal, "sql", 1);
    const unsafe_fn = c.newCFunction(ctx, jsUnsafe, "unsafe", 2);
    _ = c.definePropertyValueStr(ctx, sql_fn, "unsafe", unsafe_fn, c.PROP_C_W_E);
    const close_fn = c.newCFunction(ctx, jsClose, "close", 1);
    _ = c.definePropertyValueStr(ctx, sql_fn, "close", close_fn, c.PROP_C_W_E);
    const connect_fn = c.newCFunction(ctx, jsConnect, "connect", 0);
    _ = c.definePropertyValueStr(ctx, sql_fn, "connect", connect_fn, c.PROP_C_W_E);
    const begin_fn = c.newCFunction(ctx, jsBegin, "begin", 0);
    _ = c.definePropertyValueStr(ctx, sql_fn, "begin", begin_fn, c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, global, "sql", sql_fn, c.PROP_C_W_E);
    const ctor_fn = c.newCFunction2(ctx, sqlCtor, "SQL", 1, c.JS_CFUNC_constructor, 0);
    _ = c.definePropertyValueStr(ctx, global, "SQL", ctor_fn, c.PROP_C_W_E);
}

pub fn deinit() void {
    if (default_pool) |p| {
        p.destroy();
        default_pool = null;
    }
    if (default_pool_fail) |s| {
        gpa.free(s);
        default_pool_fail = null;
    }
}

fn sqlFinalizer(rt: ?*c.Runtime, val: c.Value) callconv(.c) void {
    _ = rt;
    const ptr = c.getOpaque(val, sql_class_id);
    if (ptr != null) {
        const pool: *pg.Pool = @ptrCast(@alignCast(ptr));
        pool.destroy();
    }
}

fn txFinalizer(rt: ?*c.Runtime, val: c.Value) callconv(.c) void {
    _ = rt;
    const ptr = c.getOpaque(val, tx_class_id);
    if (ptr != null) {
        const tx: *pg.Tx = @ptrCast(@alignCast(ptr));
        pg.destroyTx(tx);
    }
}

fn poolFromThis(ctx: ?*c.Context, this_val: c.Value) ?*pg.Pool {
    if (c.isObject(this_val) != 0) {
        if (c.getOpaque2(ctx, this_val, sql_class_id)) |p| {
            return @ptrCast(@alignCast(p));
        }
    }
    return null;
}

fn txFromValue(ctx: ?*c.Context, v: c.Value) ?*pg.Tx {
    if (c.getOpaque2(ctx, v, tx_class_id)) |p| {
        return @ptrCast(@alignCast(p));
    }
    return null;
}

fn makeTx(ctx: ?*c.Context, tx: *pg.Tx) c.Value {
    const obj = c.newObjectClass(ctx, tx_class_id);
    if (c.isException(obj) != 0) return obj;
    c.setOpaque(obj, @ptrCast(tx));
    return obj;
}

fn getDefaultPool() !*pg.Pool {
    if (default_pool) |p| return p;
    if (default_pool_fail) |msg| {
        std.debug.print("sql: {s}\n", .{msg});
        return error.PoolFailed;
    }
    const cfg = loadConfig() catch |err| {
        default_pool_fail = gpa.dupe(u8, @errorName(err)) catch null;
        return err;
    };
    default_pool = pg.Pool.create(cfg) catch |err| {
        freeLooseConfig(cfg);
        default_pool_fail = gpa.dupe(u8, @errorName(err)) catch null;
        return err;
    };
    freeLooseConfig(cfg);
    return default_pool.?;
}

fn loadConfig() !pg.Config {
    var cfg = pg.Config{};
    cfg.host = try gpa.dupe(u8, cfg.host);
    errdefer gpa.free(cfg.host);
    cfg.user = try gpa.dupe(u8, cfg.user);
    errdefer gpa.free(cfg.user);
    cfg.password = try gpa.dupe(u8, cfg.password);
    errdefer gpa.free(cfg.password);
    cfg.database = try gpa.dupe(u8, cfg.database);
    errdefer gpa.free(cfg.database);
    if (std.c.getenv("PG_TEST_DSN")) |url| {
        try parseDsn(std.mem.span(url), &cfg);
        return cfg;
    }
    if (std.c.getenv("DATABASE_URL")) |url| {
        try parseDsn(std.mem.span(url), &cfg);
        return cfg;
    }
    if (std.c.getenv("PGHOST")) |v| {
        gpa.free(cfg.host);
        cfg.host = try gpa.dupe(u8, std.mem.span(v));
    }
    if (std.c.getenv("PGPORT")) |v| {
        cfg.port = std.fmt.parseInt(u16, std.mem.span(v), 10) catch 5432;
    }
    if (std.c.getenv("PGUSER")) |v| {
        gpa.free(cfg.user);
        cfg.user = try gpa.dupe(u8, std.mem.span(v));
    }
    if (std.c.getenv("PGPASSWORD")) |v| {
        gpa.free(cfg.password);
        cfg.password = try gpa.dupe(u8, std.mem.span(v));
    }
    if (std.c.getenv("PGDATABASE")) |v| {
        gpa.free(cfg.database);
        cfg.database = try gpa.dupe(u8, std.mem.span(v));
    }
    return cfg;
}

fn parseDsn(url: []const u8, cfg: *pg.Config) !void {
    const scheme = std.mem.indexOf(u8, url, "://") orelse return error.BadDsn;
    var rest = url[scheme + 3 ..];
    if (std.mem.indexOfScalar(u8, rest, '@')) |at| {
        const auth = rest[0..at];
        rest = rest[at + 1 ..];
        if (std.mem.indexOfScalar(u8, auth, ':')) |colon| {
            gpa.free(cfg.user);
            cfg.user = try gpa.dupe(u8, auth[0..colon]);
            gpa.free(cfg.password);
            cfg.password = try gpa.dupe(u8, auth[colon + 1 ..]);
        } else {
            gpa.free(cfg.user);
            cfg.user = try gpa.dupe(u8, auth);
        }
    }
    var hostport = rest;
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
        const db = rest[slash + 1 ..];
        if (db.len > 0) {
            gpa.free(cfg.database);
            cfg.database = try gpa.dupe(u8, db);
        }
        hostport = rest[0..slash];
    }
    if (std.mem.startsWith(u8, hostport, "[")) {
        const end = std.mem.indexOfScalar(u8, hostport, ']') orelse return error.BadDsn;
        gpa.free(cfg.host);
        cfg.host = try gpa.dupe(u8, hostport[1..end]);
        if (end + 1 < hostport.len and hostport[end + 1] == ':') {
            cfg.port = try std.fmt.parseInt(u16, hostport[end + 2 ..], 10);
        }
    } else if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |colon| {
        gpa.free(cfg.host);
        cfg.host = try gpa.dupe(u8, hostport[0..colon]);
        cfg.port = try std.fmt.parseInt(u16, hostport[colon + 1 ..], 10);
    } else if (hostport.len > 0) {
        gpa.free(cfg.host);
        cfg.host = try gpa.dupe(u8, hostport);
    }
}

fn sqlTagGlobal(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    const pool = getDefaultPool() catch |err| {
        _ = c.throwTypeError(ctx, @errorName(err));
        return c.JS_EXCEPTION;
    };
    return runTag(ctx, pool, null, c.JS_UNDEFINED, argc, argv);
}

fn sqlTagCall(ctx: ?*c.Context, func_obj: c.Value, this_val: c.Value, argc: c_int, argv: [*c]c.Value, flags: c_int) callconv(.c) c.Value {
    _ = this_val;
    _ = flags;
    const pool = poolFromThis(ctx, func_obj) orelse {
        _ = c.throwTypeError(ctx, "SQL instance required");
        return c.JS_EXCEPTION;
    };
    return runTag(ctx, pool, null, c.JS_UNDEFINED, argc, argv);
}

fn txTagCall(ctx: ?*c.Context, func_obj: c.Value, this_val: c.Value, argc: c_int, argv: [*c]c.Value, flags: c_int) callconv(.c) c.Value {
    _ = this_val;
    _ = flags;
    const tx = txFromValue(ctx, func_obj) orelse {
        _ = c.throwTypeError(ctx, "Tx instance required");
        return c.JS_EXCEPTION;
    };
    if (!pg.txAlive(tx)) {
        _ = c.throwTypeError(ctx, "transaction is closed");
        return c.JS_EXCEPTION;
    }
    return runTag(ctx, pg.txPool(tx), tx, func_obj, argc, argv);
}

const EncodedParam = struct {
    val: ?[]const u8,
    oid: u32,
};

fn runTag(ctx: ?*c.Context, pool: *pg.Pool, tx: ?*pg.Tx, tx_obj: c.Value, argc: c_int, argv: [*c]c.Value) c.Value {
    if (argc < 1) {
        _ = c.throwTypeError(ctx, "sql must be used as a template tag");
        return c.JS_EXCEPTION;
    }
    const parts_val = argv[0];
    if (c.isArray(ctx, parts_val) == 0) {
        _ = c.throwTypeError(ctx, "sql must be used as a template tag");
        return c.JS_EXCEPTION;
    }
    const len_val = c.getPropertyStr(ctx, parts_val, "length");
    if (c.isException(len_val) != 0) return c.JS_EXCEPTION;
    var nparts: i32 = 0;
    if (c.toInt32(ctx, &nparts, len_val) != 0) {
        c.freeValue(ctx, len_val);
        return c.JS_EXCEPTION;
    }
    c.freeValue(ctx, len_val);
    if (nparts < 1) {
        _ = c.throwTypeError(ctx, "empty template");
        return c.JS_EXCEPTION;
    }
    const nparams = nparts - 1;
    if (argc - 1 != nparams) {
        _ = c.throwTypeError(ctx, "template arity mismatch");
        return c.JS_EXCEPTION;
    }

    var cap: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &cap);
    if (c.isException(promise) != 0) return promise;

    const job = pool.acquireJob() orelse {
        c.freeValue(ctx, cap[0]);
        c.freeValue(ctx, cap[1]);
        c.freeValue(ctx, promise);
        return oom(ctx);
    };
    job.resolve = c.dupValue(ctx, cap[0]);
    job.reject = c.dupValue(ctx, cap[1]);
    c.freeValue(ctx, cap[0]);
    c.freeValue(ctx, cap[1]);
    job.tx = tx;
    if (tx != null) job.tx_obj = c.dupValue(ctx, tx_obj);

    const alloc = job.allocator();
    var query: std.ArrayList(u8) = .empty;
    var params_list: std.ArrayList(?[]const u8) = .empty;
    var oids_list: std.ArrayList(u32) = .empty;

    var i: i32 = 0;
    while (i < nparts) : (i += 1) {
        const part = c.getPropertyUint32(ctx, parts_val, @intCast(i));
        if (c.isException(part) != 0) {
            job.release();
            c.freeValue(ctx, promise);
            return c.JS_EXCEPTION;
        }
        defer c.freeValue(ctx, part);
        var plen: usize = 0;
        const pptr = c.toCStringLen(ctx, &plen, part) orelse {
            job.release();
            c.freeValue(ctx, promise);
            return c.JS_EXCEPTION;
        };
        defer c.freeCString(ctx, pptr);
        query.appendSlice(alloc, pptr[0..plen]) catch {
            job.release();
            c.freeValue(ctx, promise);
            return oom(ctx);
        };
        if (i == nparams) break;
        var nbuf: [16]u8 = undefined;
        const ns = std.fmt.bufPrint(&nbuf, "${d}", .{i + 1}) catch {
            job.release();
            c.freeValue(ctx, promise);
            return oom(ctx);
        };
        query.appendSlice(alloc, ns) catch {
            job.release();
            c.freeValue(ctx, promise);
            return oom(ctx);
        };
        const pv = argv[@as(usize, @intCast(1 + i))];
        const enc = encodeParam(ctx, alloc, pv) catch |err| {
            job.release();
            c.freeValue(ctx, promise);
            if (err == error.EncodeFailed) {
                _ = c.throwTypeError(ctx, "cannot encode query parameter");
                return c.JS_EXCEPTION;
            }
            return oom(ctx);
        };
        params_list.append(alloc, enc.val) catch {
            job.release();
            c.freeValue(ctx, promise);
            return oom(ctx);
        };
        oids_list.append(alloc, enc.oid) catch {
            job.release();
            c.freeValue(ctx, promise);
            return oom(ctx);
        };
    }

    job.sql = query.items;
    job.params = params_list.items;
    job.param_oids = oids_list.items;
    pool.query(job);
    return promise;
}

fn oom(ctx: ?*c.Context) c.Value {
    _ = c.throwOutOfMemory(ctx);
    return c.JS_EXCEPTION;
}

fn isBigInt(v: c.Value) bool {
    const tag = c.getTag(v);
    return tag == c.TAG_BIG_INT or tag == c.TAG_SHORT_BIG_INT;
}

fn encodeParam(ctx: ?*c.Context, alloc: std.mem.Allocator, val: c.Value) !EncodedParam {
    if (c.isNull(val) != 0 or c.isUndefined(val) != 0) {
        return .{ .val = null, .oid = 0 };
    }
    if (c.isBool(val) != 0) {
        if (c.toBool(ctx, val) != 0) {
            return .{ .val = try alloc.dupe(u8, "true"), .oid = 16 };
        }
        return .{ .val = try alloc.dupe(u8, "false"), .oid = 16 };
    }
    if (isBigInt(val)) {
        const s = c.toString(ctx, val);
        if (c.isException(s) != 0) return error.EncodeFailed;
        defer c.freeValue(ctx, s);
        var len: usize = 0;
        const ptr = c.toCStringLen(ctx, &len, s) orelse return error.EncodeFailed;
        defer c.freeCString(ctx, ptr);
        return .{ .val = try alloc.dupe(u8, ptr[0..len]), .oid = 20 };
    }
    if (c.isNumber(val) != 0) {
        var i: i64 = 0;
        if (c.toInt64(ctx, &i, val) == 0) {
            var buf: [32]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{d}", .{i});
            return .{ .val = try alloc.dupe(u8, s), .oid = 20 };
        }
        var f: f64 = 0;
        if (c.toFloat64(ctx, &f, val) == 0) {
            var buf: [64]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{d}", .{f});
            return .{ .val = try alloc.dupe(u8, s), .oid = 701 };
        }
    }
    if (c.isString(val) != 0) {
        var len: usize = 0;
        const ptr = c.toCStringLen(ctx, &len, val) orelse return error.EncodeFailed;
        defer c.freeCString(ctx, ptr);
        return .{ .val = try alloc.dupe(u8, ptr[0..len]), .oid = 25 };
    }
    if (c.isArray(ctx, val) != 0) {
        return encodeArrayParam(ctx, alloc, val);
    }
    if (c.isObject(val) != 0) {
        var sz: usize = 0;
        if (c.getUint8Array(ctx, &sz, val)) |bytes| {
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(alloc, "\\x");
            const digits = "0123456789abcdef";
            for (bytes[0..sz]) |b| {
                try out.append(alloc, digits[b >> 4]);
                try out.append(alloc, digits[b & 0xf]);
            }
            return .{ .val = out.items, .oid = 17 };
        }
        if (c.hasException(ctx)) {
            const exc = c.getException(ctx);
            c.freeValue(ctx, exc);
        }
        // Plain object (incl. Date, nested): JSON.stringify → json (114).
        const js = c.jsonStringify(ctx, val, c.JS_UNDEFINED, c.JS_UNDEFINED);
        if (c.isException(js) != 0) return error.EncodeFailed;
        defer c.freeValue(ctx, js);
        if (c.isUndefined(js) == 0) {
            var len: usize = 0;
            const ptr = c.toCStringLen(ctx, &len, js) orelse return error.EncodeFailed;
            defer c.freeCString(ctx, ptr);
            return .{ .val = try alloc.dupe(u8, ptr[0..len]), .oid = 114 };
        }
    }
    const str_val = c.toString(ctx, val);
    if (c.isException(str_val) != 0) return error.EncodeFailed;
    defer c.freeValue(ctx, str_val);
    var len: usize = 0;
    const ptr = c.toCStringLen(ctx, &len, str_val) orelse return error.EncodeFailed;
    defer c.freeCString(ctx, ptr);
    return .{ .val = try alloc.dupe(u8, ptr[0..len]), .oid = 25 };
}

const ArrKind = enum { int8, float8, boolean, text };

fn mergeKind(a: ArrKind, b: ArrKind) ArrKind {
    if (a == b) return a;
    if ((a == .int8 and b == .float8) or (a == .float8 and b == .int8)) return .float8;
    return .text;
}

fn isIntVal(ctx: ?*c.Context, v: c.Value) bool {
    var i: i64 = 0;
    if (c.toInt64(ctx, &i, v) != 0) return false;
    var f: f64 = 0;
    _ = c.toFloat64(ctx, &f, v);
    return f == @as(f64, @floatFromInt(i));
}

fn arrayLength(ctx: ?*c.Context, v: c.Value) !usize {
    const lv = c.getPropertyStr(ctx, v, "length");
    if (c.isException(lv) != 0) return error.EncodeFailed;
    defer c.freeValue(ctx, lv);
    var n: i32 = 0;
    if (c.toInt32(ctx, &n, lv) != 0) return error.EncodeFailed;
    if (n < 0) return error.EncodeFailed;
    return @intCast(n);
}

fn classifyValue(ctx: ?*c.Context, v: c.Value, kind: *ArrKind, decided: *bool) !void {
    if (c.isNull(v) != 0 or c.isUndefined(v) != 0) return;
    if (c.isArray(ctx, v) != 0) {
        const n = try arrayLength(ctx, v);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const el = c.getPropertyUint32(ctx, v, @intCast(i));
            if (c.isException(el) != 0) return error.EncodeFailed;
            defer c.freeValue(ctx, el);
            try classifyValue(ctx, el, kind, decided);
            if (decided.* and kind.* == .text) return;
        }
        return;
    }
    const k: ArrKind = if (c.isBool(v) != 0) .boolean else if (isBigInt(v)) .int8 else if (c.isNumber(v) != 0) (if (isIntVal(ctx, v)) .int8 else .float8) else .text;
    if (!decided.*) {
        kind.* = k;
        decided.* = true;
    } else {
        kind.* = mergeKind(kind.*, k);
    }
}

fn appendQuoted(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(alloc, '"');
    for (s) |ch| {
        if (ch == '"' or ch == '\\') try buf.append(alloc, '\\');
        try buf.append(alloc, ch);
    }
    try buf.append(alloc, '"');
}

/// Raw (unquoted) text form of a scalar element for text[] encoding.
fn scalarRawText(ctx: ?*c.Context, alloc: std.mem.Allocator, el: c.Value) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    if (c.isString(el) != 0) {
        var len: usize = 0;
        const ptr = c.toCStringLen(ctx, &len, el) orelse return error.EncodeFailed;
        defer c.freeCString(ctx, ptr);
        try out.appendSlice(alloc, ptr[0..len]);
    } else if (c.isNumber(el) != 0) {
        var i: i64 = 0;
        if (c.toInt64(ctx, &i, el) == 0) {
            var f: f64 = 0;
            _ = c.toFloat64(ctx, &f, el);
            var tmp: [32]u8 = undefined;
            if (f == @as(f64, @floatFromInt(i))) {
                try out.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "{d}", .{i}));
            } else {
                try out.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "{d}", .{f}));
            }
        } else {
            var f: f64 = 0;
            if (c.toFloat64(ctx, &f, el) != 0) return error.EncodeFailed;
            var tmp: [32]u8 = undefined;
            try out.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "{d}", .{f}));
        }
    } else if (c.isBool(el) != 0) {
        try out.appendSlice(alloc, if (c.toBool(ctx, el) != 0) "true" else "false");
    } else if (isBigInt(el)) {
        const s = c.toString(ctx, el);
        if (c.isException(s) != 0) return error.EncodeFailed;
        defer c.freeValue(ctx, s);
        var len: usize = 0;
        const ptr = c.toCStringLen(ctx, &len, s) orelse return error.EncodeFailed;
        defer c.freeCString(ctx, ptr);
        try out.appendSlice(alloc, ptr[0..len]);
    } else if (c.isObject(el) != 0) {
        const js = c.jsonStringify(ctx, el, c.JS_UNDEFINED, c.JS_UNDEFINED);
        if (c.isException(js) != 0) return error.EncodeFailed;
        defer c.freeValue(ctx, js);
        if (c.isUndefined(js) == 0) {
            var len: usize = 0;
            const ptr = c.toCStringLen(ctx, &len, js) orelse return error.EncodeFailed;
            defer c.freeCString(ctx, ptr);
            try out.appendSlice(alloc, ptr[0..len]);
        } else {
            const s = c.toString(ctx, el);
            if (c.isException(s) != 0) return error.EncodeFailed;
            defer c.freeValue(ctx, s);
            var len: usize = 0;
            const ptr = c.toCStringLen(ctx, &len, s) orelse return error.EncodeFailed;
            defer c.freeCString(ctx, ptr);
            try out.appendSlice(alloc, ptr[0..len]);
        }
    } else {
        const s = c.toString(ctx, el);
        if (c.isException(s) != 0) return error.EncodeFailed;
        defer c.freeValue(ctx, s);
        var len: usize = 0;
        const ptr = c.toCStringLen(ctx, &len, s) orelse return error.EncodeFailed;
        defer c.freeCString(ctx, ptr);
        try out.appendSlice(alloc, ptr[0..len]);
    }
    return out.items;
}

fn appendArrayElem(ctx: ?*c.Context, alloc: std.mem.Allocator, buf: *std.ArrayList(u8), el: c.Value, kind: ArrKind, depth: u8) !void {
    if (depth > 8) return error.EncodeFailed;
    if (c.isNull(el) != 0 or c.isUndefined(el) != 0) {
        try buf.appendSlice(alloc, "NULL");
        return;
    }
    if (c.isArray(ctx, el) != 0) {
        const n = try arrayLength(ctx, el);
        try buf.append(alloc, '{');
        var j: usize = 0;
        while (j < n) : (j += 1) {
            if (j > 0) try buf.append(alloc, ',');
            const sub = c.getPropertyUint32(ctx, el, @intCast(j));
            if (c.isException(sub) != 0) return error.EncodeFailed;
            defer c.freeValue(ctx, sub);
            try appendArrayElem(ctx, alloc, buf, sub, kind, depth + 1);
        }
        try buf.append(alloc, '}');
        return;
    }
    switch (kind) {
        .int8 => {
            if (c.isNumber(el) != 0) {
                var i: i64 = 0;
                if (c.toInt64(ctx, &i, el) == 0) {
                    var tmp: [32]u8 = undefined;
                    try buf.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "{d}", .{i}));
                    return;
                }
            }
            if (isBigInt(el)) {
                const s = c.toString(ctx, el);
                if (c.isException(s) != 0) return error.EncodeFailed;
                defer c.freeValue(ctx, s);
                var len: usize = 0;
                const ptr = c.toCStringLen(ctx, &len, s) orelse return error.EncodeFailed;
                defer c.freeCString(ctx, ptr);
                try buf.appendSlice(alloc, ptr[0..len]);
                return;
            }
            try appendQuoted(alloc, buf, try scalarRawText(ctx, alloc, el));
        },
        .float8 => {
            if (c.isNumber(el) != 0) {
                var f: f64 = 0;
                if (c.toFloat64(ctx, &f, el) == 0) {
                    var tmp: [32]u8 = undefined;
                    try buf.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "{d}", .{f}));
                    return;
                }
            }
            if (isBigInt(el)) {
                const s = c.toString(ctx, el);
                if (c.isException(s) != 0) return error.EncodeFailed;
                defer c.freeValue(ctx, s);
                var len: usize = 0;
                const ptr = c.toCStringLen(ctx, &len, s) orelse return error.EncodeFailed;
                defer c.freeCString(ctx, ptr);
                try buf.appendSlice(alloc, ptr[0..len]);
                return;
            }
            try appendQuoted(alloc, buf, try scalarRawText(ctx, alloc, el));
        },
        .boolean => {
            try buf.appendSlice(alloc, if (c.toBool(ctx, el) != 0) "true" else "false");
        },
        .text => {
            try appendQuoted(alloc, buf, try scalarRawText(ctx, alloc, el));
        },
    }
}

fn encodeArrayParam(ctx: ?*c.Context, alloc: std.mem.Allocator, arr: c.Value) !EncodedParam {
    const n = try arrayLength(ctx, arr);
    var kind: ArrKind = .text;
    var decided = false;
    {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const el = c.getPropertyUint32(ctx, arr, @intCast(i));
            if (c.isException(el) != 0) return error.EncodeFailed;
            defer c.freeValue(ctx, el);
            try classifyValue(ctx, el, &kind, &decided);
            if (decided and kind == .text) break;
        }
    }
    var buf: std.ArrayList(u8) = .empty;
    try buf.append(alloc, '{');
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (i > 0) try buf.append(alloc, ',');
        const el = c.getPropertyUint32(ctx, arr, @intCast(i));
        if (c.isException(el) != 0) return error.EncodeFailed;
        defer c.freeValue(ctx, el);
        try appendArrayElem(ctx, alloc, &buf, el, kind, 0);
    }
    try buf.append(alloc, '}');
    const oid: u32 = switch (kind) {
        .int8 => 1016,
        .float8 => 1022,
        .boolean => 1000,
        .text => 1009,
    };
    return .{ .val = buf.items, .oid = oid };
}

fn jsUnsafe(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const pool = poolFromThis(ctx, this_val) orelse getDefaultPool() catch {
        _ = c.throwTypeError(ctx, "no database pool");
        return c.JS_EXCEPTION;
    };
    return runUnsafe(ctx, pool, null, c.JS_UNDEFINED, argc, argv);
}

fn txUnsafe(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const tx = txFromValue(ctx, this_val) orelse {
        _ = c.throwTypeError(ctx, "not a transaction");
        return c.JS_EXCEPTION;
    };
    if (!pg.txAlive(tx)) {
        _ = c.throwTypeError(ctx, "transaction is closed");
        return c.JS_EXCEPTION;
    }
    return runUnsafe(ctx, pg.txPool(tx), tx, this_val, argc, argv);
}

fn runUnsafe(ctx: ?*c.Context, pool: *pg.Pool, tx: ?*pg.Tx, tx_obj: c.Value, argc: c_int, argv: [*c]c.Value) c.Value {
    if (argc < 1) {
        _ = c.throwTypeError(ctx, "sql.unsafe requires a string");
        return c.JS_EXCEPTION;
    }
    if (c.isString(argv[0]) == 0) {
        _ = c.throwTypeError(ctx, "sql.unsafe requires a string");
        return c.JS_EXCEPTION;
    }
    var qlen: usize = 0;
    const qptr = c.toCStringLen(ctx, &qlen, argv[0]) orelse return c.JS_EXCEPTION;
    defer c.freeCString(ctx, qptr);

    var cap: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &cap);
    if (c.isException(promise) != 0) return promise;

    const job = pool.acquireJob() orelse {
        c.freeValue(ctx, cap[0]);
        c.freeValue(ctx, cap[1]);
        c.freeValue(ctx, promise);
        return oom(ctx);
    };
    job.resolve = c.dupValue(ctx, cap[0]);
    job.reject = c.dupValue(ctx, cap[1]);
    c.freeValue(ctx, cap[0]);
    c.freeValue(ctx, cap[1]);
    job.tx = tx;
    if (tx != null) job.tx_obj = c.dupValue(ctx, tx_obj);

    const alloc = job.allocator();
    job.sql = alloc.dupe(u8, qptr[0..qlen]) catch {
        job.release();
        c.freeValue(ctx, promise);
        return oom(ctx);
    };

    if (argc >= 2 and c.isArray(ctx, argv[1]) != 0) {
        const len_val = c.getPropertyStr(ctx, argv[1], "length");
        if (c.isException(len_val) != 0) {
            job.release();
            c.freeValue(ctx, promise);
            return c.JS_EXCEPTION;
        }
        var n: i32 = 0;
        if (c.toInt32(ctx, &n, len_val) != 0) {
            c.freeValue(ctx, len_val);
            job.release();
            c.freeValue(ctx, promise);
            return c.JS_EXCEPTION;
        }
        c.freeValue(ctx, len_val);
        if (n > 0) {
            var params_list: std.ArrayList(?[]const u8) = .empty;
            var oids_list: std.ArrayList(u32) = .empty;
            var i: i32 = 0;
            while (i < n) : (i += 1) {
                const pv = c.getPropertyUint32(ctx, argv[1], @intCast(i));
                if (c.isException(pv) != 0) {
                    job.release();
                    c.freeValue(ctx, promise);
                    return c.JS_EXCEPTION;
                }
                defer c.freeValue(ctx, pv);
                const enc = encodeParam(ctx, alloc, pv) catch |err| {
                    job.release();
                    c.freeValue(ctx, promise);
                    if (err == error.EncodeFailed) {
                        _ = c.throwTypeError(ctx, "cannot encode query parameter");
                        return c.JS_EXCEPTION;
                    }
                    return oom(ctx);
                };
                params_list.append(alloc, enc.val) catch {
                    job.release();
                    c.freeValue(ctx, promise);
                    return oom(ctx);
                };
                oids_list.append(alloc, enc.oid) catch {
                    job.release();
                    c.freeValue(ctx, promise);
                    return oom(ctx);
                };
            }
            job.params = params_list.items;
            job.param_oids = oids_list.items;
        }
    }
    pool.query(job);
    return promise;
}

fn jsBegin(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const pool = poolFromThis(ctx, this_val) orelse getDefaultPool() catch {
        _ = c.throwTypeError(ctx, "no database pool");
        return c.JS_EXCEPTION;
    };
    var cap: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &cap);
    if (c.isException(promise) != 0) return promise;
    const job = pool.acquireJob() orelse {
        c.freeValue(ctx, cap[0]);
        c.freeValue(ctx, cap[1]);
        c.freeValue(ctx, promise);
        return oom(ctx);
    };
    job.resolve = c.dupValue(ctx, cap[0]);
    job.reject = c.dupValue(ctx, cap[1]);
    c.freeValue(ctx, cap[0]);
    c.freeValue(ctx, cap[1]);
    job.tx_op = .begin;
    job.sql = job.dupe("BEGIN") catch {
        job.release();
        c.freeValue(ctx, promise);
        return oom(ctx);
    };
    pool.query(job);
    return promise;
}

fn txCommit(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    return txEnd(ctx, this_val, true);
}

fn txRollback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    return txEnd(ctx, this_val, false);
}

fn txEnd(ctx: ?*c.Context, this_val: c.Value, commit: bool) c.Value {
    const tx = txFromValue(ctx, this_val) orelse {
        _ = c.throwTypeError(ctx, "not a transaction");
        return c.JS_EXCEPTION;
    };
    if (!pg.txAlive(tx)) {
        _ = c.throwTypeError(ctx, "transaction is closed");
        return c.JS_EXCEPTION;
    }
    const pool = pg.txPool(tx);
    var cap: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &cap);
    if (c.isException(promise) != 0) return promise;
    const job = pool.acquireJob() orelse {
        c.freeValue(ctx, cap[0]);
        c.freeValue(ctx, cap[1]);
        c.freeValue(ctx, promise);
        return oom(ctx);
    };
    job.resolve = c.dupValue(ctx, cap[0]);
    job.reject = c.dupValue(ctx, cap[1]);
    c.freeValue(ctx, cap[0]);
    c.freeValue(ctx, cap[1]);
    job.tx = tx;
    job.tx_obj = c.dupValue(ctx, this_val);
    job.tx_op = if (commit) .commit else .rollback;
    job.sql = job.dupe(if (commit) "COMMIT" else "ROLLBACK") catch {
        job.release();
        c.freeValue(ctx, promise);
        return oom(ctx);
    };
    pool.query(job);
    return promise;
}

fn jsClose(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const pool = poolFromThis(ctx, this_val) orelse default_pool orelse {
        return c.JS_UNDEFINED;
    };
    if (poolFromThis(ctx, this_val) == null and default_pool != null) {
        pool.closeNow();
        default_pool = null;
    } else {
        pool.closeNow();
        if (poolFromThis(ctx, this_val) == null) default_pool = null;
    }
    return c.JS_UNDEFINED;
}

fn jsConnect(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const pool = poolFromThis(ctx, this_val) orelse getDefaultPool() catch {
        _ = c.throwTypeError(ctx, "no database pool");
        return c.JS_EXCEPTION;
    };
    var cap: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &cap);
    if (c.isException(promise) != 0) return promise;
    const job = pool.acquireJob() orelse {
        c.freeValue(ctx, cap[0]);
        c.freeValue(ctx, cap[1]);
        c.freeValue(ctx, promise);
        return oom(ctx);
    };
    job.resolve = c.dupValue(ctx, cap[0]);
    job.reject = c.dupValue(ctx, cap[1]);
    c.freeValue(ctx, cap[0]);
    c.freeValue(ctx, cap[1]);
    job.sql = job.dupe("SELECT 1") catch {
        job.release();
        c.freeValue(ctx, promise);
        return oom(ctx);
    };
    pool.query(job);
    return promise;
}

fn sqlCtor(ctx: ?*c.Context, new_target: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = new_target;
    var cfg = pg.Config{};
    cfg.host = gpa.dupe(u8, cfg.host) catch return oom(ctx);
    cfg.user = gpa.dupe(u8, cfg.user) catch {
        gpa.free(cfg.host);
        return oom(ctx);
    };
    cfg.password = gpa.dupe(u8, cfg.password) catch {
        gpa.free(cfg.host);
        gpa.free(cfg.user);
        return oom(ctx);
    };
    cfg.database = gpa.dupe(u8, cfg.database) catch {
        gpa.free(cfg.host);
        gpa.free(cfg.user);
        gpa.free(cfg.password);
        return oom(ctx);
    };
    if (argc >= 1 and c.isString(argv[0]) != 0) {
        var len: usize = 0;
        const ptr = c.toCStringLen(ctx, &len, argv[0]) orelse {
            freeLooseConfig(cfg);
            return c.JS_EXCEPTION;
        };
        defer c.freeCString(ctx, ptr);
        parseDsn(ptr[0..len], &cfg) catch {
            freeLooseConfig(cfg);
            _ = c.throwTypeError(ctx, "invalid database URL");
            return c.JS_EXCEPTION;
        };
    } else if (argc >= 1 and c.isObject(argv[0]) != 0) {
        const host = c.getPropertyStr(ctx, argv[0], "host");
        if (c.isString(host) != 0) {
            var hl: usize = 0;
            const hp = c.toCStringLen(ctx, &hl, host) orelse {
                c.freeValue(ctx, host);
                freeLooseConfig(cfg);
                return c.JS_EXCEPTION;
            };
            gpa.free(cfg.host);
            cfg.host = gpa.dupe(u8, hp[0..hl]) catch cfg.host;
            c.freeCString(ctx, hp);
        }
        c.freeValue(ctx, host);
        const port = c.getPropertyStr(ctx, argv[0], "port");
        if (c.isNumber(port) != 0) {
            var p: i64 = 0;
            if (c.toInt64(ctx, &p, port) == 0 and p > 0 and p < 65536) cfg.port = @intCast(p);
        }
        c.freeValue(ctx, port);
        const user = c.getPropertyStr(ctx, argv[0], "user");
        if (c.isString(user) != 0) {
            var ul: usize = 0;
            const up = c.toCStringLen(ctx, &ul, user) orelse {
                c.freeValue(ctx, user);
                freeLooseConfig(cfg);
                return c.JS_EXCEPTION;
            };
            gpa.free(cfg.user);
            cfg.user = gpa.dupe(u8, up[0..ul]) catch cfg.user;
            c.freeCString(ctx, up);
        }
        c.freeValue(ctx, user);
        const password = c.getPropertyStr(ctx, argv[0], "password");
        if (c.isString(password) != 0) {
            var pl: usize = 0;
            const pp = c.toCStringLen(ctx, &pl, password) orelse {
                c.freeValue(ctx, password);
                freeLooseConfig(cfg);
                return c.JS_EXCEPTION;
            };
            gpa.free(cfg.password);
            cfg.password = gpa.dupe(u8, pp[0..pl]) catch cfg.password;
            c.freeCString(ctx, pp);
        }
        c.freeValue(ctx, password);
        const database = c.getPropertyStr(ctx, argv[0], "database");
        if (c.isString(database) != 0) {
            var dl: usize = 0;
            const dp = c.toCStringLen(ctx, &dl, database) orelse {
                c.freeValue(ctx, database);
                freeLooseConfig(cfg);
                return c.JS_EXCEPTION;
            };
            gpa.free(cfg.database);
            cfg.database = gpa.dupe(u8, dp[0..dl]) catch cfg.database;
            c.freeCString(ctx, dp);
        }
        c.freeValue(ctx, database);
        const max = c.getPropertyStr(ctx, argv[0], "max");
        if (c.isNumber(max) != 0) {
            var m: i64 = 0;
            if (c.toInt64(ctx, &m, max) == 0 and m > 0 and m <= 100) cfg.max = @intCast(m);
        }
        c.freeValue(ctx, max);
    }
    const pool = pg.Pool.create(cfg) catch {
        freeLooseConfig(cfg);
        _ = c.throwTypeError(ctx, "failed to create pool");
        return oom(ctx);
    };
    freeLooseConfig(cfg);
    const obj = c.newObjectClass(ctx, sql_class_id);
    c.setOpaque(obj, @ptrCast(pool));
    return obj;
}

fn freeLooseConfig(cfg: pg.Config) void {
    gpa.free(cfg.host);
    gpa.free(cfg.user);
    gpa.free(cfg.password);
    gpa.free(cfg.database);
}
