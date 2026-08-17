const std = @import("std");
const c = @import("../c.zig").c;

const RED = "\x1b[31m";
const YELLOW = "\x1b[33m";
const RESET = "\x1b[0m";
const GREEN = "\x1b[32m";

const LABEL_CAP = 32; // console.count distinct-label cap (documented; slot-0 reuse after)
const MAX_COLS = 32; // console.table column cap
const MAX_ROWS = 100; // console.table row cap
const CELL_MAX = 256; // single-cell render cap

// console.count state — dense Zig bytes, no V8 handles (no Global, no alloc).
var count_labels: [LABEL_CAP][128]u8 = undefined;
var count_lens: [LABEL_CAP]usize = [_]usize{0} ** LABEL_CAP;
var count_vals: [LABEL_CAP]u32 = [_]u32{0} ** LABEL_CAP;
var count_used: usize = 0;

// ---- shared primitive: color-print args[skip..] into bounded stack buffer ----
fn consolePrint(info: ?*const c.FunctionCallbackInfo, color: []const u8, skip: usize) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const argc: usize = @intCast(c.v8__FunctionCallbackInfo__Length(info));
    var i: usize = skip;
    if (color.len > 0) std.debug.print("{s}", .{color});
    while (i < argc) : (i += 1) {
        if (i > skip) std.debug.print(" ", .{});
        const val = c.v8__FunctionCallbackInfo__INDEX(info, @intCast(i));
        const context = c.v8__Isolate__GetCurrentContext(isolate);
        const str = c.v8__Value__ToString(val, context);
        if (str == null) continue;
        const utf8_len = c.v8__String__Utf8Length(str, isolate);
        if (utf8_len <= 0) continue;
        var buf: [4096]u8 = undefined;
        const len = @min(@as(usize, @intCast(utf8_len)), buf.len);
        _ = c.v8__String__WriteUtf8(str, isolate, &buf, @intCast(len), 0);
        std.debug.print("{s}", .{buf[0..len]});
    }
    if (color.len > 0) std.debug.print("{s}", .{RESET});
    std.debug.print("\n", .{});
}

// ==== existing aliases (kept) ====
fn consoleLogCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void   { consolePrint(info, "", 0); }
fn consoleSlopsCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void { consolePrint(info, YELLOW, 0); }
fn consoleRedbalCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void { consolePrint(info, RED, 0); }
fn consoleDetailCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void { consolePrint(info, GREEN, 0); }

// ==== standard methods ====
fn consoleWarnCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void   { consolePrint(info, YELLOW, 0); }
fn consoleErrorCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void  { consolePrint(info, RED, 0); }
fn consoleInfoCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void   { consolePrint(info, "", 0); }
fn consoleDebugCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void  { consolePrint(info, "", 0); }

fn consoleAssertCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const argc = c.v8__FunctionCallbackInfo__Length(info);
    const cond = if (argc >= 1) c.v8__FunctionCallbackInfo__INDEX(info, 0) else null;
    if (cond != null and c.v8__Value__BooleanValue(cond, isolate)) return;
    std.debug.print("{s}Assertion failed: {s}", .{ RED, RESET });
    consolePrint(info, RED, 1);
}

fn consoleCountCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const argc = c.v8__FunctionCallbackInfo__Length(info);
    var label_buf: [128]u8 = undefined;
    var label_len: usize = 0;

    if (argc >= 1) {
        const val = c.v8__FunctionCallbackInfo__INDEX(info, 0);
        if (val != null and c.v8__Value__IsString(val)) {
            const context = c.v8__Isolate__GetCurrentContext(isolate);
            const str = c.v8__Value__ToString(val, context);
            if (str != null) {
                const ulen = c.v8__String__Utf8Length(str, isolate);
                if (ulen > 0) label_len = @min(@as(usize, @intCast(ulen)), label_buf.len);
                if (label_len > 0) _ = c.v8__String__WriteUtf8(str, isolate, &label_buf, @intCast(label_len), 0);
            }
        }
    }
    if (label_len == 0) {
        const def = "default";
        @memcpy(label_buf[0..def.len], def);
        label_len = def.len;
    }

    var found: usize = LABEL_CAP;
    var i: usize = 0;
    while (i < count_used) : (i += 1) {
        const a = count_labels[i][0..count_lens[i]];
        const b = label_buf[0..label_len];
        if (std.mem.eql(u8, a, b)) { // vectorized by the compiler in ReleaseFast
            found = i;
            break;
        }
    }
    if (found == LABEL_CAP) {
        if (count_used < LABEL_CAP) {
            @memcpy(count_labels[count_used][0..label_len], label_buf[0..label_len]);
            count_lens[count_used] = label_len;
            count_vals[count_used] = 0;
            found = count_used;
            count_used += 1;
        } else {
            found = 0; // cap reached: reuse slot 0 (documented)
        }
    }

    count_vals[found] +%= 1;
    std.debug.print("{s}: {d}\n", .{ label_buf[0..label_len], count_vals[found] });
}

// ==== table helpers ====
fn cellText(isolate: ?*c.Isolate, context: ?*c.Context, val: ?*const c.Value, buf: []u8) usize {
    if (val == null) return 0;
    const str = c.v8__Value__ToDetailString(val, context) orelse return 0;
    const ulen = c.v8__String__Utf8Length(str, isolate);
    if (ulen <= 0) return 0;
    const n = @min(@as(usize, @intCast(ulen)), buf.len);
    _ = c.v8__String__WriteUtf8(str, isolate, buf.ptr, @intCast(n), 0);
    return n;
}

fn printRow(cells: []const []const u8, widths: []const usize) void {
    var i: usize = 0;
    while (i < cells.len) : (i += 1) {
        if (i > 0) std.debug.print("  ", .{});
        std.debug.print("{s}", .{cells[i]});
        var pad: usize = if (cells[i].len < widths[i]) widths[i] - cells[i].len else 0;
        while (pad > 0) : (pad -= 1) std.debug.print(" ", .{});
    }
    std.debug.print("\n", .{});
}

/// Row's value for a given per-row property name, or null. Matches raw bytes
/// against GetPropertyNames keys (no string alloc).
fn hasOwnKey(isolate: ?*c.Isolate, context: ?*c.Context, obj: ?*const c.Object, key_buf: []const u8) ?*const c.Value {
    const names_arr = c.v8__Object__GetPropertyNames(obj, context) orelse return null;
    const nlen: usize = @intCast(c.v8__Array__Length(names_arr));
    var i: usize = 0;
    while (i < nlen) : (i += 1) {
        const idx = c.v8__Integer__NewFromUnsigned(isolate, @intCast(i));
        const key_val = c.v8__Object__Get(@ptrCast(names_arr), context, idx) orelse continue;
        var kb: [128]u8 = undefined;
        const klen = cellText(isolate, context, key_val, &kb);
        if (klen == key_buf.len and std.mem.eql(u8, kb[0..klen], key_buf)) {
            return c.v8__Object__Get(obj, context, key_val);
        }
    }
    return null;
}

fn consoleTableCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate);
    const argc = c.v8__FunctionCallbackInfo__Length(info);
    if (argc < 1) return;
    const arg = c.v8__FunctionCallbackInfo__INDEX(info, 0) orelse return;

    // ---- arrays ----
    if (c.v8__Value__IsArray(arg)) {
        const arr: *const c.Array = @ptrCast(arg);
        const nlen: usize = @intCast(c.v8__Array__Length(arr));
        if (nlen == 0) return;
        const row_count = @min(nlen, MAX_ROWS);

        const first_val = c.v8__Object__Get(@ptrCast(arr), context, c.v8__Integer__NewFromUnsigned(isolate, 0)) orelse return;
        const objects = c.v8__Value__IsObject(first_val) and !c.v8__Value__IsArray(first_val);

        if (objects) {
            // ---- array of objects: union-keyed grid (3 passes, zero alloc) ----
            var cols: [MAX_COLS][128]u8 = undefined;
            var col_lens: [MAX_COLS]usize = [_]usize{0} ** MAX_COLS;
            var colw: [MAX_COLS]usize = [_]usize{0} ** MAX_COLS;
            colw[0] = 7; // "(index)"
            var col_count: usize = 1;

            // pass 1: discover columns (first-seen order)
            var r: usize = 0;
            while (r < row_count) : (r += 1) {
                const row_value = c.v8__Object__Get(@ptrCast(arr), context, c.v8__Integer__NewFromUnsigned(isolate, @intCast(r)));
                if (row_value == null or !c.v8__Value__IsObject(row_value)) continue;
                const names_arr = c.v8__Object__GetPropertyNames(@ptrCast(row_value), context) orelse continue;
                const kcount: usize = @intCast(c.v8__Array__Length(names_arr));
                var k: usize = 0;
                while (k < kcount) : (k += 1) {
                    const key_val = c.v8__Object__Get(@ptrCast(names_arr), context, c.v8__Integer__NewFromUnsigned(isolate, @intCast(k))) orelse continue;
                    var kb: [128]u8 = undefined;
                    const kl = cellText(isolate, context, key_val, &kb);
                    if (kl == 0) continue;
                    var found: usize = col_count;
                    var c_i: usize = 1;
                    while (c_i < col_count) : (c_i += 1) {
                        if (col_lens[c_i] == kl and std.mem.eql(u8, cols[c_i][0..col_lens[c_i]], kb[0..kl])) {
                            found = c_i;
                            break;
                        }
                    }
                    if (found == col_count and col_count < MAX_COLS) {
                        @memcpy(cols[col_count][0..kl], kb[0..kl]);
                        col_lens[col_count] = kl;
                        colw[col_count] = kl;
                        col_count += 1;
                    }
                }
            }
            if (col_count == 1) {
                consolePrint(info, "", 0);
                return;
            }

            // pass 2: measure widths
            r = 0;
            while (r < row_count) : (r += 1) {
                var ib: [128]u8 = undefined;
                const ilen = (std.fmt.bufPrint(&ib, "{d}", .{r}) catch return).len;
                if (ilen > colw[0]) colw[0] = ilen;
                const row_value = c.v8__Object__Get(@ptrCast(arr), context, c.v8__Integer__NewFromUnsigned(isolate, @intCast(r)));
                if (row_value == null or !c.v8__Value__IsObject(row_value)) continue;
                var cb: [CELL_MAX]u8 = undefined;
                var c_i: usize = 1;
                while (c_i < col_count) : (c_i += 1) {
                    if (hasOwnKey(isolate, context, @ptrCast(row_value), cols[c_i][0..col_lens[c_i]])) |cell| {
                        const cl = cellText(isolate, context, cell, &cb);
                        if (cl > colw[c_i]) colw[c_i] = cl;
                    }
                }
            }

            // pass 3: print
            var h: [MAX_COLS][]const u8 = undefined;
            h[0] = "(index)";
            var c_i: usize = 1;
            while (c_i < col_count) : (c_i += 1) h[c_i] = cols[c_i][0..col_lens[c_i]];
            printRow(h[0..col_count], &colw);

            r = 0;
            while (r < row_count) : (r += 1) {
                var ib: [128]u8 = undefined;
                const ilen = (std.fmt.bufPrint(&ib, "{d}", .{r}) catch return).len;
                const row_value = c.v8__Object__Get(@ptrCast(arr), context, c.v8__Integer__NewFromUnsigned(isolate, @intCast(r)));
                var row: [MAX_COLS][]const u8 = undefined;
                var row_bufs: [MAX_COLS][CELL_MAX]u8 = undefined; // per-column cell buffers (no aliasing)
                row[0] = ib[0..ilen];
                c_i = 1;
                while (c_i < col_count) : (c_i += 1) {
                    if (row_value != null and c.v8__Value__IsObject(row_value)) {
                        if (hasOwnKey(isolate, context, @ptrCast(row_value), cols[c_i][0..col_lens[c_i]])) |cell| {
                            const cl = cellText(isolate, context, cell, &row_bufs[c_i]);
                            row[c_i] = row_bufs[c_i][0..cl];
                            continue;
                        }
                    }
                    row[c_i] = "";
                }
                printRow(row[0..col_count], &colw);
            }
            return;
        }

        // ---- array of scalars: (index) | Value ----
        const header = [_][]const u8{ "(index)", "Value" };
        var colw = [_]usize{ 7, 5 };
        var r: usize = 0;
        while (r < row_count) : (r += 1) {
            var ib: [128]u8 = undefined;
            const ilen = (std.fmt.bufPrint(&ib, "{d}", .{r}) catch return).len;
            if (ilen > colw[0]) colw[0] = ilen;
            const v = c.v8__Object__Get(@ptrCast(arr), context, c.v8__Integer__NewFromUnsigned(isolate, @intCast(r)));
            if (v != null) {
                var vb: [CELL_MAX]u8 = undefined;
                const vl = cellText(isolate, context, v, &vb);
                if (vl > colw[1]) colw[1] = vl;
            }
        }
        printRow(header[0..2], &colw);
        r = 0;
        while (r < row_count) : (r += 1) {
            var ib: [128]u8 = undefined;
            const ilen = (std.fmt.bufPrint(&ib, "{d}", .{r}) catch return).len;
            var vb: [CELL_MAX]u8 = undefined;
            var val_text: []const u8 = "";
            const v = c.v8__Object__Get(@ptrCast(arr), context, c.v8__Integer__NewFromUnsigned(isolate, @intCast(r)));
            if (v != null) val_text = vb[0..cellText(isolate, context, v, &vb)];
            var row = [_][]const u8{ ib[0..ilen], val_text };
            printRow(row[0..2], &colw);
        }
        return;
    }

    // ---- flat object: Key | Value ----
    if (c.v8__Value__IsObject(arg)) {
        const obj: *const c.Object = @ptrCast(arg);
        const names_arr = c.v8__Object__GetPropertyNames(obj, context) orelse return;
        const nlen: usize = @intCast(c.v8__Array__Length(names_arr));
        const rows = @min(nlen, MAX_ROWS);
        if (rows == 0) return;

        const header = [_][]const u8{ "Key", "Value" };
        var colw = [_]usize{ 3, 5 };
        var r: usize = 0;
        while (r < rows) : (r += 1) {
            const key_val = c.v8__Object__Get(@ptrCast(names_arr), context, c.v8__Integer__NewFromUnsigned(isolate, @intCast(r))) orelse continue;
            const val = c.v8__Object__Get(obj, context, key_val) orelse continue;
            var kb: [128]u8 = undefined;
            var vb: [CELL_MAX]u8 = undefined;
            const kl = cellText(isolate, context, key_val, &kb);
            const vl = cellText(isolate, context, val, &vb);
            if (kl > colw[0]) colw[0] = kl;
            if (vl > colw[1]) colw[1] = vl;
        }
        printRow(header[0..2], &colw);
        r = 0;
        while (r < rows) : (r += 1) {
            const key_val = c.v8__Object__Get(@ptrCast(names_arr), context, c.v8__Integer__NewFromUnsigned(isolate, @intCast(r))) orelse continue;
            const val = c.v8__Object__Get(obj, context, key_val) orelse continue;
            var kb: [128]u8 = undefined;
            var vb: [CELL_MAX]u8 = undefined;
            var row = [_][]const u8{
                kb[0..cellText(isolate, context, key_val, &kb)],
                vb[0..cellText(isolate, context, val, &vb)],
            };
            printRow(row[0..2], &colw);
        }
        return;
    }

    // ---- primitive ----
    var buf: [CELL_MAX]u8 = undefined;
    const bl = cellText(isolate, context, arg, &buf);
    std.debug.print("{s}\n", .{buf[0..bl]});
}

// ==== console.trace: args + real Error.stack (via NewInstance; fallback args-only) ====
fn consoleTraceCallback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate) orelse return;
    std.debug.print("Trace:\n", .{});
    consolePrint(info, "", 0);

    const global = c.v8__Context__Global(context) orelse return;
    const err_key = c.v8__String__NewFromUtf8(isolate, "Error", 0, -1) orelse return;
    const err_val = c.v8__Object__Get(@ptrCast(global), context, err_key) orelse return;
    if (!c.v8__Value__IsFunction(err_val)) return;
    const err_fn: *const c.Function = @ptrCast(err_val);
    const no_args = [_]?*const c.Value{null};
    const err_obj = c.v8__Function__NewInstance(err_fn, context, 0, &no_args) orelse return;
    const stack_key = c.v8__String__NewFromUtf8(isolate, "stack", 0, -1) orelse return;
    const stack_val = c.v8__Object__Get(err_obj, context, stack_key) orelse return;
    const str = c.v8__Value__ToDetailString(stack_val, context) orelse return;
    const utf8_len = c.v8__String__Utf8Length(str, isolate);
    if (utf8_len <= 0) return;
    var buf: [8192]u8 = undefined;
    const len = @min(@as(usize, @intCast(utf8_len)), buf.len);
    _ = c.v8__String__WriteUtf8(str, isolate, &buf, @intCast(len), 0);
    std.debug.print("{s}", .{buf[0..len]});
}

pub fn setup(isolate: ?*c.Isolate, context: ?*c.Context) void {
    var hs: c.HandleScope = undefined;
    c.v8__HandleScope__CONSTRUCT(&hs, isolate);
    defer c.v8__HandleScope__DESTRUCT(&hs);

    const global = c.v8__Context__Global(context);
    const console_obj = c.v8__Object__New(isolate);
    var out: c.MaybeBool = undefined;

    const cur = .{
        .{ "log", consoleLogCallback },        .{ "slops", consoleSlopsCallback },
        .{ "redbal", consoleRedbalCallback }, .{ "detail", consoleDetailCallback },
        .{ "warn", consoleWarnCallback },     .{ "error", consoleErrorCallback },
        .{ "info", consoleInfoCallback },     .{ "debug", consoleDebugCallback },
        .{ "assert", consoleAssertCallback }, .{ "count", consoleCountCallback },
        .{ "table", consoleTableCallback },   .{ "trace", consoleTraceCallback },
    };
    inline for (cur) |entry| {
        const fn_val = c.v8__Function__New__DEFAULT(context, entry[1]);
        _ = c.v8__Object__Set(
            console_obj,
            context,
            c.v8__String__NewFromUtf8(isolate, entry[0], 0, -1),
            fn_val,
            &out,
        );
    }

    const console_key = c.v8__String__NewFromUtf8(isolate, "console", 0, -1);
    _ = c.v8__Object__Set(global, context, console_key, console_obj, &out);
}
