const std = @import("std");
const c = @import("../c.zig").c;
const sqlite_c = @import("sqlite_c");

const gpa = std.heap.smp_allocator;

var db_class_id: c.ClassID = 0;

// SQLITE_TRANSIENT is ((destructor_fn)-1) in C. translateC's comptime
// @ptrFromInt(-1) into ?*fn fails Zig 0.16's alignment check, so hold the
// address in a module-level var (runtime → no comptime check; fn alignment
// is 1 at runtime so 0xFFFF... passes).
var g_transient_addr: usize = undefined;

fn initTransient() void {
    g_transient_addr = @bitCast(@as(isize, -1));
}

fn transientDestructor() sqlite_c.sqlite3_destructor_type {
    return @ptrFromInt(g_transient_addr);
}

// ── Helpers ──────────────────────────────────────────────────────

fn throwErr(ctx: ?*c.Context, msg: []const u8) void {
    const msg_val = c.newStringLen(ctx, msg.ptr, msg.len);
    _ = c.throw(ctx, msg_val);
}

fn throwSqliteErr(ctx: ?*c.Context, db: ?*sqlite_c.sqlite3) void {
    const err_msg = sqlite_c.sqlite3_errmsg(db);
    if (err_msg != null) {
        const len = std.mem.span(err_msg).len;
        throwErr(ctx, err_msg[0..len]);
    } else {
        throwErr(ctx, "sqlite3 error");
    }
}

fn getDbOpaque(ctx: ?*c.Context, this_val: c.Value) ?*sqlite_c.sqlite3 {
    const ptr = c.getOpaque2(ctx, this_val, db_class_id) orelse return null;
    const db: *sqlite_c.sqlite3 = @ptrCast(@alignCast(ptr));
    return db;
}

// Helper: run sqlite3_exec with a [*c]u8 errmsg out-param.
fn execSimple(db: ?*sqlite_c.sqlite3, sql: [*c]const u8) c_int {
    var err: [*c]u8 = null;
    const rc = sqlite_c.sqlite3_exec(db, sql, null, null, &err);
    if (err != null) sqlite_c.sqlite3_free(@ptrCast(err));
    return rc;
}

// ── JS value → SQLite bind (runtime type dispatch) ───────────────

fn jsValueToBind(
    ctx: ?*c.Context,
    stmt: *sqlite_c.sqlite3_stmt,
    index: c_int,
    val: c.Value,
) !void {
    const tag = c.getTag(val);

    if (tag == c.TAG_INT) {
        var i: i64 = 0;
        _ = c.toInt64(ctx, &i, val);
        const rc = sqlite_c.sqlite3_bind_int64(stmt, index, i);
        if (rc != sqlite_c.SQLITE_OK) return error.BindFailed;
    } else if (tag == c.TAG_FLOAT64) {
        var f: f64 = 0;
        _ = c.toFloat64(ctx, &f, val);
        const rc = sqlite_c.sqlite3_bind_double(stmt, index, f);
        if (rc != sqlite_c.SQLITE_OK) return error.BindFailed;
    } else if (c.isString(val) != 0) {
        var len: usize = 0;
        const ptr = c.toCStringLen(ctx, &len, val) orelse return error.BindFailed;
        defer c.freeCString(ctx, ptr);
        const rc = sqlite_c.sqlite3_bind_text(stmt, index, ptr, @intCast(len), transientDestructor());
        if (rc != sqlite_c.SQLITE_OK) return error.BindFailed;
    } else if (c.isNull(val) != 0) {
        const rc = sqlite_c.sqlite3_bind_null(stmt, index);
        if (rc != sqlite_c.SQLITE_OK) return error.BindFailed;
    } else if (c.isBool(val) != 0) {
        const b = c.toBool(ctx, val);
        const rc = sqlite_c.sqlite3_bind_int64(stmt, index, if (b != 0) 1 else 0);
        if (rc != sqlite_c.SQLITE_OK) return error.BindFailed;
    } else if (c.isObject(val) != 0) {
        // Check for ArrayBuffer / Uint8Array (blob binding).
        var ab_size: usize = 0;
        if (c.getArrayBuffer(ctx, &ab_size, val)) |ab_ptr| {
            const rc = sqlite_c.sqlite3_bind_blob(stmt, index, @ptrCast(ab_ptr), @intCast(ab_size), transientDestructor());
            if (rc != sqlite_c.SQLITE_OK) return error.BindFailed;
            return;
        }
        if (c.hasException(ctx)) {
            const exc = c.getException(ctx);
            c.freeValue(ctx, exc);
        }
        var u8_size: usize = 0;
        if (c.getUint8Array(ctx, &u8_size, val)) |u8_ptr| {
            const rc = sqlite_c.sqlite3_bind_blob(stmt, index, @ptrCast(u8_ptr), @intCast(u8_size), transientDestructor());
            if (rc != sqlite_c.SQLITE_OK) return error.BindFailed;
            return;
        }
        if (c.hasException(ctx)) {
            const exc = c.getException(ctx);
            c.freeValue(ctx, exc);
        }
        const rc = sqlite_c.sqlite3_bind_null(stmt, index);
        if (rc != sqlite_c.SQLITE_OK) return error.BindFailed;
    } else {
        const rc = sqlite_c.sqlite3_bind_null(stmt, index);
        if (rc != sqlite_c.SQLITE_OK) return error.BindFailed;
    }
}

fn bindJsParams(
    ctx: ?*c.Context,
    stmt: *sqlite_c.sqlite3_stmt,
    params_val: c.Value,
) !void {
    const len_val = c.getPropertyStr(ctx, params_val, "length");
    if (c.isException(len_val) != 0) return error.BindFailed;
    defer c.freeValue(ctx, len_val);

    var arr_len: i32 = 0;
    if (c.toInt32(ctx, &arr_len, len_val) != 0) return error.BindFailed;

    var i: i32 = 0;
    while (i < arr_len) : (i += 1) {
        const elem = c.getPropertyUint32(ctx, params_val, @intCast(i));
        defer c.freeValue(ctx, elem);
        try jsValueToBind(ctx, stmt, i + 1, elem); // SQLite uses 1-based index.
    }
}

// ── SQLite column → JS value ─────────────────────────────────────

fn sqliteColumnToJs(
    ctx: ?*c.Context,
    stmt: *sqlite_c.sqlite3_stmt,
    col: c_int,
) c.Value {
    const col_type = sqlite_c.sqlite3_column_type(stmt, col);
    switch (col_type) {
        sqlite_c.SQLITE_INTEGER => {
            const v = sqlite_c.sqlite3_column_int64(stmt, col);
            return c.newInt64(ctx, v);
        },
        sqlite_c.SQLITE_FLOAT => {
            const v = sqlite_c.sqlite3_column_double(stmt, col);
            return c.newFloat64(ctx, v);
        },
        sqlite_c.SQLITE_TEXT => {
            const ptr = sqlite_c.sqlite3_column_text(stmt, col);
            const len = sqlite_c.sqlite3_column_bytes(stmt, col);
            if (ptr != null) return c.newStringLen(ctx, ptr, @intCast(len));
            return c.JS_NULL;
        },
        sqlite_c.SQLITE_BLOB => {
            const ptr = sqlite_c.sqlite3_column_blob(stmt, col);
            const len = sqlite_c.sqlite3_column_bytes(stmt, col);
            if (ptr != null) return c.newArrayBufferCopy(ctx, @ptrCast(ptr), @intCast(len));
            return c.JS_NULL;
        },
        sqlite_c.SQLITE_NULL => return c.JS_NULL,
        else => return c.JS_NULL,
    }
}

fn buildRowObject(
    ctx: ?*c.Context,
    stmt: *sqlite_c.sqlite3_stmt,
) !c.Value {
    const obj = c.newObject(ctx);
    const col_count = sqlite_c.sqlite3_data_count(stmt);
    var i: c_int = 0;
    while (i < col_count) : (i += 1) {
        const name_ptr = sqlite_c.sqlite3_column_name(stmt, i);
        if (name_ptr == null) continue;
        const val = sqliteColumnToJs(ctx, stmt, i);
        _ = c.setPropertyStr(ctx, obj, name_ptr, val);
    }
    return obj;
}

// ── JS callback: db.exec(sql, params?) ───────────────────────────

fn jsExec(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    if (argc < 1) {
        _ = c.throwTypeError(ctx, "exec requires a SQL string");
        return c.JS_EXCEPTION;
    }

    const db = getDbOpaque(ctx, this_val) orelse {
        _ = c.throwTypeError(ctx, "exec: invalid database");
        return c.JS_EXCEPTION;
    };

    var sql_len: usize = 0;
    const sql_ptr = c.toCStringLen(ctx, &sql_len, argv[0]) orelse return c.JS_EXCEPTION;
    defer c.freeCString(ctx, sql_ptr);

    var n_stmt: ?*sqlite_c.sqlite3_stmt = null;
    var rc = sqlite_c.sqlite3_prepare_v2(db, sql_ptr, @intCast(sql_len), &n_stmt, null);
    if (rc != sqlite_c.SQLITE_OK) {
        throwSqliteErr(ctx, db);
        return c.JS_EXCEPTION;
    }
    const stmt = n_stmt.?;
    defer _ = sqlite_c.sqlite3_finalize(stmt);

    if (argc >= 2) {
        bindJsParams(ctx, stmt, argv[1]) catch {
            throwSqliteErr(ctx, db);
            return c.JS_EXCEPTION;
        };
    }

    while (true) {
        rc = sqlite_c.sqlite3_step(stmt);
        if (rc == sqlite_c.SQLITE_DONE) break;
        if (rc == sqlite_c.SQLITE_ROW) continue;
        throwSqliteErr(ctx, db);
        return c.JS_EXCEPTION;
    }

    return c.JS_UNDEFINED;
}

// ── JS callback: db.row(sql, params?) ────────────────────────────

fn jsRow(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    if (argc < 1) {
        _ = c.throwTypeError(ctx, "row requires a SQL string");
        return c.JS_EXCEPTION;
    }

    const db = getDbOpaque(ctx, this_val) orelse {
        _ = c.throwTypeError(ctx, "row: invalid database");
        return c.JS_EXCEPTION;
    };

    var sql_len: usize = 0;
    const sql_ptr = c.toCStringLen(ctx, &sql_len, argv[0]) orelse return c.JS_EXCEPTION;
    defer c.freeCString(ctx, sql_ptr);

    var n_stmt: ?*sqlite_c.sqlite3_stmt = null;
    var rc = sqlite_c.sqlite3_prepare_v2(db, sql_ptr, @intCast(sql_len), &n_stmt, null);
    if (rc != sqlite_c.SQLITE_OK) {
        throwSqliteErr(ctx, db);
        return c.JS_EXCEPTION;
    }
    const stmt = n_stmt.?;
    defer _ = sqlite_c.sqlite3_finalize(stmt);

    if (argc >= 2) {
        bindJsParams(ctx, stmt, argv[1]) catch {
            throwSqliteErr(ctx, db);
            return c.JS_EXCEPTION;
        };
    }

    rc = sqlite_c.sqlite3_step(stmt);
    if (rc == sqlite_c.SQLITE_ROW) {
        return buildRowObject(ctx, stmt) catch {
            throwSqliteErr(ctx, db);
            return c.JS_EXCEPTION;
        };
    }
    if (rc != sqlite_c.SQLITE_DONE) {
        throwSqliteErr(ctx, db);
        return c.JS_EXCEPTION;
    }
    return c.JS_NULL;
}

// ── JS callback: db.rows(sql, params?) ───────────────────────────

fn jsRows(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    if (argc < 1) {
        _ = c.throwTypeError(ctx, "rows requires a SQL string");
        return c.JS_EXCEPTION;
    }

    const db = getDbOpaque(ctx, this_val) orelse {
        _ = c.throwTypeError(ctx, "rows: invalid database");
        return c.JS_EXCEPTION;
    };

    var sql_len: usize = 0;
    const sql_ptr = c.toCStringLen(ctx, &sql_len, argv[0]) orelse return c.JS_EXCEPTION;
    defer c.freeCString(ctx, sql_ptr);

    var n_stmt: ?*sqlite_c.sqlite3_stmt = null;
    var rc = sqlite_c.sqlite3_prepare_v2(db, sql_ptr, @intCast(sql_len), &n_stmt, null);
    if (rc != sqlite_c.SQLITE_OK) {
        throwSqliteErr(ctx, db);
        return c.JS_EXCEPTION;
    }
    const stmt = n_stmt.?;
    defer _ = sqlite_c.sqlite3_finalize(stmt);

    if (argc >= 2) {
        bindJsParams(ctx, stmt, argv[1]) catch {
            throwSqliteErr(ctx, db);
            return c.JS_EXCEPTION;
        };
    }

    const arr = c.newArray(ctx);
    var idx: u32 = 0;

    while (true) {
        rc = sqlite_c.sqlite3_step(stmt);
        if (rc == sqlite_c.SQLITE_DONE) break;
        if (rc != sqlite_c.SQLITE_ROW) {
            throwSqliteErr(ctx, db);
            return c.JS_EXCEPTION;
        }
        const row_obj = buildRowObject(ctx, stmt) catch {
            throwSqliteErr(ctx, db);
            return c.JS_EXCEPTION;
        };
        _ = c.setPropertyUint32(ctx, arr, idx, row_obj);
        idx += 1;
    }

    return arr;
}

// ── JS callback: db.close() ──────────────────────────────────────

fn jsClose(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;

    const db = getDbOpaque(ctx, this_val) orelse {
        _ = c.throwTypeError(ctx, "close: invalid database");
        return c.JS_EXCEPTION;
    };

    _ = sqlite_c.sqlite3_close_v2(db);
    c.setOpaque(this_val, null);
    return c.JS_UNDEFINED;
}

// ── JS callback: db.changes() ────────────────────────────────────

fn jsChanges(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;

    const db = getDbOpaque(ctx, this_val) orelse return c.newInt32(ctx, 0);
    const changes = sqlite_c.sqlite3_changes(db);
    return c.newInt32(ctx, changes);
}

// ── JS callback: db.lastInsertRowId() ────────────────────────────

fn jsLastInsertRowId(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;

    const db = getDbOpaque(ctx, this_val) orelse return c.newInt64(ctx, 0);
    const rowid = sqlite_c.sqlite3_last_insert_rowid(db);
    return c.newInt64(ctx, rowid);
}

// ── JS callback: db.busyTimeout(ms) ──────────────────────────────

fn jsBusyTimeout(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    if (argc < 1) {
        _ = c.throwTypeError(ctx, "busyTimeout requires a millisecond argument");
        return c.JS_EXCEPTION;
    }

    const db = getDbOpaque(ctx, this_val) orelse {
        _ = c.throwTypeError(ctx, "busyTimeout: invalid database");
        return c.JS_EXCEPTION;
    };

    var ms: i64 = 0;
    _ = c.toInt64(ctx, &ms, argv[0]);
    _ = sqlite_c.sqlite3_busy_timeout(db, @intCast(ms));
    return c.JS_UNDEFINED;
}

// ── JS callback: db.transaction(fn) ──────────────────────────────

fn jsTransaction(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    if (argc < 1 or c.isFunction(ctx, argv[0]) == 0) {
        _ = c.throwTypeError(ctx, "transaction requires a function argument");
        return c.JS_EXCEPTION;
    }

    const db = getDbOpaque(ctx, this_val) orelse {
        _ = c.throwTypeError(ctx, "transaction: invalid database");
        return c.JS_EXCEPTION;
    };

    {
        var err: [*c]u8 = null;
        _ = sqlite_c.sqlite3_exec(db, "BEGIN", null, null, &err);
        if (err != null) {
            const len = std.mem.span(err).len;
            throwErr(ctx, err[0..len]);
            sqlite_c.sqlite3_free(@ptrCast(err));
            return c.JS_EXCEPTION;
        }
    }

    const ret = c.call(ctx, argv[0], this_val, 0, null);

    if (c.isException(ret) != 0) {
        var err: [*c]u8 = null;
        _ = sqlite_c.sqlite3_exec(db, "ROLLBACK", null, null, &err);
        if (err != null) sqlite_c.sqlite3_free(@ptrCast(err));
        return ret;
    }

    {
        var err: [*c]u8 = null;
        _ = sqlite_c.sqlite3_exec(db, "COMMIT", null, null, &err);
        if (err != null) {
            const len = std.mem.span(err).len;
            throwErr(ctx, err[0..len]);
            sqlite_c.sqlite3_free(@ptrCast(err));
            c.freeValue(ctx, ret);
            return c.JS_EXCEPTION;
        }
    }

    return ret;
}

// ── JS callback: db.execNoArgs(sql) ──────────────────────────────

fn jsExecNoArgs(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    if (argc < 1) {
        _ = c.throwTypeError(ctx, "execNoArgs requires a SQL string");
        return c.JS_EXCEPTION;
    }

    const db = getDbOpaque(ctx, this_val) orelse {
        _ = c.throwTypeError(ctx, "execNoArgs: invalid database");
        return c.JS_EXCEPTION;
    };

    var sql_len: usize = 0;
    const sql_ptr = c.toCStringLen(ctx, &sql_len, argv[0]) orelse return c.JS_EXCEPTION;
    defer c.freeCString(ctx, sql_ptr);

    const sql_z = gpa.allocSentinel(u8, sql_len, 0) catch return c.throwOutOfMemory(ctx);
    defer gpa.free(sql_z);
    @memcpy(sql_z[0..sql_len], sql_ptr[0..sql_len]);

    var err: [*c]u8 = null;
    const rc = sqlite_c.sqlite3_exec(db, sql_z.ptr, null, null, &err);
    if (rc != sqlite_c.SQLITE_OK) {
        if (err != null) {
            const len = std.mem.span(err).len;
            throwErr(ctx, err[0..len]);
            sqlite_c.sqlite3_free(@ptrCast(err));
        } else {
            throwSqliteErr(ctx, db);
        }
        return c.JS_EXCEPTION;
    }
    return c.JS_UNDEFINED;
}

// ── Database finalizer ───────────────────────────────────────────

fn dbFinalizer(rt: ?*c.Runtime, val: c.Value) callconv(.c) void {
    _ = rt;
    const ptr = c.getOpaque(val, db_class_id);
    if (ptr != null) {
        const db: ?*sqlite_c.sqlite3 = @ptrCast(@alignCast(ptr));
        _ = sqlite_c.sqlite3_close_v2(db);
    }
}

// ── Constructor: Database.open(path) ─────────────────────────────

fn jsOpen(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;

    if (argc < 1) {
        _ = c.throwTypeError(ctx, "Database.open requires a file path");
        return c.JS_EXCEPTION;
    }

    var path_len: usize = 0;
    const path_ptr = c.toCStringLen(ctx, &path_len, argv[0]) orelse return c.JS_EXCEPTION;
    defer c.freeCString(ctx, path_ptr);

    const path_z = gpa.allocSentinel(u8, path_len, 0) catch return c.throwOutOfMemory(ctx);
    defer gpa.free(path_z);
    @memcpy(path_z[0..path_len], path_ptr[0..path_len]);

    var db: ?*sqlite_c.sqlite3 = null;
    const flags = sqlite_c.SQLITE_OPEN_READWRITE | sqlite_c.SQLITE_OPEN_CREATE | sqlite_c.SQLITE_OPEN_EXRESCODE;
    const rc = sqlite_c.sqlite3_open_v2(path_z.ptr, &db, flags, null);
    if (rc != sqlite_c.SQLITE_OK) {
        if (db) |d| {
            throwSqliteErr(ctx, d);
            _ = sqlite_c.sqlite3_close_v2(d);
        } else {
            throwErr(ctx, "failed to open database");
        }
        return c.JS_EXCEPTION;
    }

    const obj = c.newObjectClass(ctx, db_class_id);
    c.setOpaque(obj, @ptrCast(db));

    _ = execSimple(db, "PRAGMA journal_mode=WAL");
    _ = sqlite_c.sqlite3_busy_timeout(db, 5000);

    return obj;
}

// ── setup(ctx) ───────────────────────────────────────────────────

pub fn setup(ctx: *c.Context) void {
    initTransient();
    {
        var db_def = c.ClassDef{
            .class_name = "Database",
            .finalizer = dbFinalizer,
        };
        _ = c.newClassID(c.getRuntime(ctx), &db_class_id);
        _ = c.newClass(c.getRuntime(ctx), db_class_id, &db_def);

        const proto = c.newObject(ctx);

        const exec_fn = c.newCFunction(ctx, jsExec, "exec", 2);
        _ = c.definePropertyValueStr(ctx, proto, "exec", exec_fn, c.PROP_C_W_E);

        const exec_no_args_fn = c.newCFunction(ctx, jsExecNoArgs, "execNoArgs", 1);
        _ = c.definePropertyValueStr(ctx, proto, "execNoArgs", exec_no_args_fn, c.PROP_C_W_E);

        const row_fn = c.newCFunction(ctx, jsRow, "row", 2);
        _ = c.definePropertyValueStr(ctx, proto, "row", row_fn, c.PROP_C_W_E);

        const rows_fn = c.newCFunction(ctx, jsRows, "rows", 2);
        _ = c.definePropertyValueStr(ctx, proto, "rows", rows_fn, c.PROP_C_W_E);

        const close_fn = c.newCFunction(ctx, jsClose, "close", 0);
        _ = c.definePropertyValueStr(ctx, proto, "close", close_fn, c.PROP_C_W_E);

        const changes_fn = c.newCFunction(ctx, jsChanges, "changes", 0);
        _ = c.definePropertyValueStr(ctx, proto, "changes", changes_fn, c.PROP_C_W_E);

        const last_insert_fn = c.newCFunction(ctx, jsLastInsertRowId, "lastInsertRowId", 0);
        _ = c.definePropertyValueStr(ctx, proto, "lastInsertRowId", last_insert_fn, c.PROP_C_W_E);

        const busy_timeout_fn = c.newCFunction(ctx, jsBusyTimeout, "busyTimeout", 1);
        _ = c.definePropertyValueStr(ctx, proto, "busyTimeout", busy_timeout_fn, c.PROP_C_W_E);

        const transaction_fn = c.newCFunction(ctx, jsTransaction, "transaction", 1);
        _ = c.definePropertyValueStr(ctx, proto, "transaction", transaction_fn, c.PROP_C_W_E);

        c.setClassProto(ctx, db_class_id, proto);
    }

    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);

    const db_static = c.newObject(ctx);
    const open_fn = c.newCFunction(ctx, jsOpen, "open", 1);
    _ = c.definePropertyValueStr(ctx, db_static, "open", open_fn, c.PROP_C_W_E);

    _ = c.definePropertyValueStr(ctx, global, "Database", db_static, c.PROP_C_W_E);
}
