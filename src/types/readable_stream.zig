const std = @import("std");
const c = @import("../c.zig").c;
const interrupt = @import("../engine/interrupt.zig");

pub const MAX_STREAMS = 1024;
pub const QCAP = 8; // queue capacity per stream
pub const MAX_PENDING_READERS = 4;

pub const StreamState = enum(u8) {
    free = 0,
    readable = 1,
    closed = 2,
    errored = 3,
};

pub const SourceType = enum(u8) {
    none = 0,
    js_pull = 1,
    native_push = 2,
};

// Hot columns (accessed per chunk push/pull)
pub var st_state: [MAX_STREAMS]StreamState = [_]StreamState{.free} ** MAX_STREAMS;
pub var st_gen: [MAX_STREAMS]u16 = [_]u16{0} ** MAX_STREAMS;
pub var st_head: [MAX_STREAMS]u8 = [_]u8{0} ** MAX_STREAMS;
pub var st_len: [MAX_STREAMS]u8 = [_]u8{0} ** MAX_STREAMS;
pub var st_queue: [MAX_STREAMS][QCAP]c.Value = undefined;

// Reader FIFO per stream
pub const PendingReader = struct {
    resolve: c.Value,
    reject: c.Value,
};

pub var st_readers: [MAX_STREAMS][MAX_PENDING_READERS]PendingReader = undefined;
pub var st_r_head: [MAX_STREAMS]u8 = [_]u8{0} ** MAX_STREAMS;
pub var st_r_len: [MAX_STREAMS]u8 = [_]u8{0} ** MAX_STREAMS;
pub var st_error: [MAX_STREAMS]c.Value = [_]c.Value{c.JS_UNDEFINED} ** MAX_STREAMS;
pub var st_locked: [MAX_STREAMS]bool = [_]bool{false} ** MAX_STREAMS;
pub var st_pull_fn: [MAX_STREAMS]c.Value = [_]c.Value{c.JS_UNDEFINED} ** MAX_STREAMS;
pub var st_http_conn: [MAX_STREAMS]?u16 = [_]?u16{null} ** MAX_STREAMS;
pub var on_stream_ready: ?*const fn (conn_id: u16) void = null;

// Cold columns
pub var st_source: [MAX_STREAMS]SourceType = [_]SourceType{.none} ** MAX_STREAMS;
var st_free: [MAX_STREAMS]u16 = undefined;
var st_free_count: usize = 0;
var initialized: bool = false;

var stream_class_id: c.ClassID = 0;
var reader_class_id: c.ClassID = 0;
var controller_class_id: c.ClassID = 0;

inline fn packHandle(slot: u16, gen: u16) ?*anyopaque {
    const raw = (@as(usize, gen) << 16) | @as(usize, slot);
    return @ptrFromInt(raw + 1);
}

inline fn unpackHandle(ptr: ?*anyopaque) struct { slot: u16, gen: u16 } {
    const raw = @intFromPtr(ptr) - 1;
    return .{
        .slot = @truncate(raw),
        .gen = @truncate(raw >> 16),
    };
}

fn liveSlot(ctx: ?*c.Context, this_val: c.Value, class_id: c.ClassID) ?u16 {
    const ptr = c.getOpaque2(ctx, this_val, class_id) orelse return null;
    const h = unpackHandle(ptr);
    if (h.slot >= MAX_STREAMS) return null;
    if (st_state[h.slot] == .free) return null;
    if (st_gen[h.slot] != h.gen) return null;
    return h.slot;
}

pub fn init() void {
    if (initialized) return;
    initialized = true;
    for (0..MAX_STREAMS) |i| {
        st_free[i] = @intCast(i);
        st_state[i] = .free;
        st_gen[i] = 1;
        st_head[i] = 0;
        st_len[i] = 0;
        st_r_head[i] = 0;
        st_r_len[i] = 0;
        st_error[i] = c.JS_UNDEFINED;
        st_locked[i] = false;
        st_pull_fn[i] = c.JS_UNDEFINED;
        st_http_conn[i] = null;
    }
    st_free_count = MAX_STREAMS;
}

pub fn createStream(ctx: ?*c.Context, src_type: SourceType) ?u16 {
    init();
    if (st_free_count == 0) return null;
    st_free_count -= 1;
    const idx = st_free[st_free_count];
    st_state[idx] = .readable;
    st_head[idx] = 0;
    st_len[idx] = 0;
    st_r_head[idx] = 0;
    st_r_len[idx] = 0;
    st_error[idx] = c.JS_UNDEFINED;
    st_locked[idx] = false;
    st_pull_fn[idx] = c.JS_UNDEFINED;
    st_http_conn[idx] = null;
    st_source[idx] = src_type;
    _ = ctx;
    return idx;
}

pub fn closeStream(ctx: ?*c.Context, idx: u16) void {
    if (idx >= MAX_STREAMS or st_state[idx] == .free) return;
    st_state[idx] = .closed;

    // If readers are waiting and queue is empty, resolve all with { done: true }
    if (st_len[idx] == 0) {
        while (st_r_len[idx] > 0) {
            const pr = st_readers[idx][st_r_head[idx]];
            st_r_head[idx] = (st_r_head[idx] + 1) % MAX_PENDING_READERS;
            st_r_len[idx] -= 1;
            defer c.freeValue(ctx, pr.resolve);
            defer c.freeValue(ctx, pr.reject);

            const res_obj = c.newObject(ctx);
            _ = c.definePropertyValueStr(ctx, res_obj, "value", c.JS_UNDEFINED, c.PROP_C_W_E);
            _ = c.definePropertyValueStr(ctx, res_obj, "done", c.JS_TRUE, c.PROP_C_W_E);
            var argv = [_]c.Value{res_obj};
            _ = c.call(ctx, pr.resolve, c.JS_UNDEFINED, 1, &argv);
            c.freeValue(ctx, res_obj);
        }
    }
    if (st_http_conn[idx]) |conn_id| {
        if (on_stream_ready) |cb| cb(conn_id);
    }
}

pub fn pushChunk(ctx: ?*c.Context, idx: u16, val: c.Value) bool {
    if (idx >= MAX_STREAMS or st_state[idx] != .readable) return false;

    // Check if any reader is waiting in FIFO
    if (st_r_len[idx] > 0) {
        const pr = st_readers[idx][st_r_head[idx]];
        st_r_head[idx] = (st_r_head[idx] + 1) % MAX_PENDING_READERS;
        st_r_len[idx] -= 1;
        defer c.freeValue(ctx, pr.resolve);
        defer c.freeValue(ctx, pr.reject);

        const res_obj = c.newObject(ctx);
        _ = c.definePropertyValueStr(ctx, res_obj, "value", c.dupValue(ctx, val), c.PROP_C_W_E);
        _ = c.definePropertyValueStr(ctx, res_obj, "done", c.JS_FALSE, c.PROP_C_W_E);
        var argv = [_]c.Value{res_obj};
        _ = c.call(ctx, pr.resolve, c.JS_UNDEFINED, 1, &argv);
        c.freeValue(ctx, res_obj);
        return true;
    }

    if (st_len[idx] >= QCAP) return false; // backpressure: queue full
    const slot = (st_head[idx] + st_len[idx]) % QCAP;
    st_queue[idx][slot] = c.dupValue(ctx, val);
    st_len[idx] += 1;
    if (st_http_conn[idx]) |conn_id| {
        if (on_stream_ready) |cb| cb(conn_id);
    }
    return true;
}

pub fn popChunk(idx: u16) ?c.Value {
    if (idx >= MAX_STREAMS or st_len[idx] == 0) return null;
    const val = st_queue[idx][st_head[idx]];
    st_head[idx] = (st_head[idx] + 1) % QCAP;
    st_len[idx] -= 1;
    return val;
}

fn streamFinalizer(rt: ?*c.Runtime, val: c.Value) callconv(.c) void {
    const opaque_ptr = c.getOpaque(val, stream_class_id);
    if (opaque_ptr) |ptr| {
        const h = unpackHandle(ptr);
        const idx = h.slot;
        if (idx < MAX_STREAMS and st_state[idx] != .free and st_gen[idx] == h.gen) {
            while (st_len[idx] > 0) {
                const item = popChunk(idx) orelse break;
                c.freeValueRT(rt, item);
            }
            while (st_r_len[idx] > 0) {
                const pr = st_readers[idx][st_r_head[idx]];
                st_r_head[idx] = (st_r_head[idx] + 1) % MAX_PENDING_READERS;
                st_r_len[idx] -= 1;
                c.freeValueRT(rt, pr.resolve);
                c.freeValueRT(rt, pr.reject);
            }
            if (c.isUndefined(st_error[idx]) == 0) {
                c.freeValueRT(rt, st_error[idx]);
                st_error[idx] = c.JS_UNDEFINED;
            }
            if (c.isUndefined(st_pull_fn[idx]) == 0) {
                c.freeValueRT(rt, st_pull_fn[idx]);
                st_pull_fn[idx] = c.JS_UNDEFINED;
            }
            st_http_conn[idx] = null;
            st_locked[idx] = false;
            st_state[idx] = .free;
            st_gen[idx] +%= 1;
            st_free[st_free_count] = idx;
            st_free_count += 1;
        }
    }
}

pub fn maybePull(ctx: ?*c.Context, idx: u16) void {
    if (idx >= MAX_STREAMS or st_state[idx] != .readable) return;
    if (st_len[idx] > 0 or c.isUndefined(st_pull_fn[idx]) != 0) return;
    const c_ctx = ctx orelse return;
    const ctrl = c.newObjectClass(c_ctx, controller_class_id);
    _ = c.setOpaque(ctrl, packHandle(idx, st_gen[idx]));
    defer c.freeValue(c_ctx, ctrl);
    var pull_args = [_]c.Value{ctrl};
    const rt_idx = interrupt.getRuntimeIdx(c.getRuntime(c_ctx)) orelse 0;
    interrupt.enterJs(rt_idx, interrupt.monotonicNowMs());
    defer interrupt.leaveJs(rt_idx);
    const p_res = c.call(c_ctx, st_pull_fn[idx], c.JS_UNDEFINED, 1, &pull_args);
    if (c.isException(p_res) != 0) {
        const exc = c.getException(c_ctx);
        var err_argv = [_]c.Value{exc};
        _ = controllerErrorCallback(c_ctx, ctrl, 1, &err_argv);
        c.freeValue(c_ctx, exc);
    }
    c.freeValue(c_ctx, p_res);
}

fn readerReadCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const idx = liveSlot(ctx, this_val, reader_class_id) orelse {
        return c.throwTypeError(ctx, "Stream is closed, released, or invalid");
    };

    var resolving_funcs: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &resolving_funcs);
    if (c.isException(promise) != 0) return promise;

    // If queue is empty and pull callback exists, invoke pull(controller)
    maybePull(ctx, idx);

    // If stream is in errored state, reject immediately
    if (st_state[idx] == .errored) {
        defer c.freeValue(ctx, resolving_funcs[0]);
        defer c.freeValue(ctx, resolving_funcs[1]);
        const err = if (c.isUndefined(st_error[idx]) == 0) st_error[idx] else c.newError(ctx);
        var r_argv = [_]c.Value{err};
        _ = c.call(ctx, resolving_funcs[1], c.JS_UNDEFINED, 1, &r_argv);
        if (c.isUndefined(st_error[idx]) != 0) c.freeValue(ctx, err);
        return promise;
    }

    // If items are in queue, resolve immediately
    if (st_len[idx] > 0) {
        defer c.freeValue(ctx, resolving_funcs[1]);
        const val = popChunk(idx).?;
        defer c.freeValue(ctx, val); // popChunk transferred queue ref to us
        const res_obj = c.newObject(ctx);
        _ = c.definePropertyValueStr(ctx, res_obj, "value", c.dupValue(ctx, val), c.PROP_C_W_E);
        _ = c.definePropertyValueStr(ctx, res_obj, "done", c.JS_FALSE, c.PROP_C_W_E);
        var r_argv = [_]c.Value{res_obj};
        _ = c.call(ctx, resolving_funcs[0], c.JS_UNDEFINED, 1, &r_argv);
        c.freeValue(ctx, res_obj);
        c.freeValue(ctx, resolving_funcs[0]);
        return promise;
    }

    // If stream is closed and empty, resolve with { done: true }
    if (st_state[idx] == .closed) {
        defer c.freeValue(ctx, resolving_funcs[1]);
        const res_obj = c.newObject(ctx);
        _ = c.definePropertyValueStr(ctx, res_obj, "value", c.JS_UNDEFINED, c.PROP_C_W_E);
        _ = c.definePropertyValueStr(ctx, res_obj, "done", c.JS_TRUE, c.PROP_C_W_E);
        var r_argv = [_]c.Value{res_obj};
        _ = c.call(ctx, resolving_funcs[0], c.JS_UNDEFINED, 1, &r_argv);
        c.freeValue(ctx, res_obj);
        c.freeValue(ctx, resolving_funcs[0]);
        return promise;
    }

    // Otherwise enqueue into pending reader FIFO
    if (st_r_len[idx] < MAX_PENDING_READERS) {
        const r_slot = (st_r_head[idx] + st_r_len[idx]) % MAX_PENDING_READERS;
        st_readers[idx][r_slot] = .{
            .resolve = resolving_funcs[0],
            .reject = resolving_funcs[1],
        };
        st_r_len[idx] += 1;
    } else {
        c.freeValue(ctx, resolving_funcs[0]);
        c.freeValue(ctx, resolving_funcs[1]);
        return c.throwTypeError(ctx, "Max concurrent reads exceeded");
    }

    return promise;
}

fn streamGetReaderCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const idx = liveSlot(ctx, this_val, stream_class_id) orelse {
        return c.throwTypeError(ctx, "Stream is closed or invalid");
    };
    if (st_locked[idx]) {
        return c.throwTypeError(ctx, "ReadableStream is already locked by a reader");
    }
    st_locked[idx] = true;
    const reader_obj = c.newObjectClass(ctx, reader_class_id);
    _ = c.setOpaque(reader_obj, packHandle(idx, st_gen[idx]));
    return reader_obj;
}

fn streamLockedGetter(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const idx = liveSlot(ctx, this_val, stream_class_id) orelse return c.JS_FALSE;
    return if (st_locked[idx]) c.JS_TRUE else c.JS_FALSE;
}

fn streamCancelCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const idx = liveSlot(ctx, this_val, stream_class_id) orelse {
        return c.throwTypeError(ctx, "Stream is closed or invalid");
    };
    if (st_locked[idx]) {
        return c.throwTypeError(ctx, "Cannot cancel a locked stream");
    }
    closeStream(ctx, idx);
    while (st_len[idx] > 0) {
        const item = popChunk(idx) orelse break;
        c.freeValue(ctx, item);
    }
    var resolving_funcs: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &resolving_funcs);
    if (c.isException(promise) != 0) return promise;
    defer c.freeValue(ctx, resolving_funcs[1]);
    defer c.freeValue(ctx, resolving_funcs[0]);
    var r_argv = [_]c.Value{c.JS_UNDEFINED};
    _ = c.call(ctx, resolving_funcs[0], c.JS_UNDEFINED, 1, &r_argv);
    return promise;
}

fn readerReleaseLockCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const idx = liveSlot(ctx, this_val, reader_class_id) orelse {
        return c.throwTypeError(ctx, "Reader is closed or already released");
    };
    if (st_r_len[idx] > 0) {
        return c.throwTypeError(ctx, "Cannot release lock with pending reads");
    }
    st_locked[idx] = false;
    _ = c.setOpaque(this_val, null);
    return c.JS_UNDEFINED;
}

fn readerCancelCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const idx = liveSlot(ctx, this_val, reader_class_id) orelse {
        return c.throwTypeError(ctx, "Reader is closed or already released");
    };
    closeStream(ctx, idx);
    while (st_len[idx] > 0) {
        const item = popChunk(idx) orelse break;
        c.freeValue(ctx, item);
    }
    st_locked[idx] = false;
    _ = c.setOpaque(this_val, null);

    var resolving_funcs: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &resolving_funcs);
    if (c.isException(promise) != 0) return promise;
    defer c.freeValue(ctx, resolving_funcs[1]);
    defer c.freeValue(ctx, resolving_funcs[0]);
    var r_argv = [_]c.Value{c.JS_UNDEFINED};
    _ = c.call(ctx, resolving_funcs[0], c.JS_UNDEFINED, 1, &r_argv);
    return promise;
}

fn controllerEnqueueCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const idx = liveSlot(ctx, this_val, controller_class_id) orelse return c.throwTypeError(ctx, "Controller is closed or invalid");
    if (argc < 1) return c.JS_UNDEFINED;
    if (!pushChunk(ctx, idx, argv[0])) {
        return c.throwTypeError(ctx, "Stream queue full or stream not readable");
    }
    return c.JS_UNDEFINED;
}

fn controllerCloseCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const idx = liveSlot(ctx, this_val, controller_class_id) orelse return c.throwTypeError(ctx, "Controller is closed or invalid");
    closeStream(ctx, idx);
    return c.JS_UNDEFINED;
}

fn controllerErrorCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const idx = liveSlot(ctx, this_val, controller_class_id) orelse return c.throwTypeError(ctx, "Controller is closed or invalid");
    const err_val = if (argc > 0) argv[0] else c.newError(ctx);
    if (c.isUndefined(st_error[idx]) == 0) {
        c.freeValue(ctx, st_error[idx]);
    }
    st_error[idx] = c.dupValue(ctx, err_val);
    st_state[idx] = .errored;

    // Reject all pending readers
    while (st_r_len[idx] > 0) {
        const pr = st_readers[idx][st_r_head[idx]];
        st_r_head[idx] = (st_r_head[idx] + 1) % MAX_PENDING_READERS;
        st_r_len[idx] -= 1;
        defer c.freeValue(ctx, pr.resolve);
        defer c.freeValue(ctx, pr.reject);

        var r_argv = [_]c.Value{st_error[idx]};
        _ = c.call(ctx, pr.reject, c.JS_UNDEFINED, 1, &r_argv);
    }
    return c.JS_UNDEFINED;
}

fn controllerDesiredSizeGetter(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const idx = liveSlot(ctx, this_val, controller_class_id) orelse return c.JS_NULL;
    if (st_state[idx] != .readable) return c.newInt32(ctx, 0);
    const sz: i32 = @as(i32, QCAP) - @as(i32, st_len[idx]);
    return c.newInt32(ctx, sz);
}

fn streamConstructor(ctx: ?*c.Context, new_target: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = new_target;
    const idx = createStream(ctx, .js_pull) orelse {
        return c.throwTypeError(ctx, "Max ReadableStreams exceeded");
    };

    const obj = c.newObjectClass(ctx, stream_class_id);
    _ = c.setOpaque(obj, packHandle(idx, st_gen[idx]));

    if (argc > 0 and c.isObject(argv[0]) != 0) {
        const pull_fn = c.getPropertyStr(ctx, argv[0], "pull");
        if (c.isFunction(ctx, pull_fn) != 0) {
            st_pull_fn[idx] = pull_fn;
        } else {
            c.freeValue(ctx, pull_fn);
        }

        const start_fn = c.getPropertyStr(ctx, argv[0], "start");
        defer c.freeValue(ctx, start_fn);
        if (c.isFunction(ctx, start_fn) != 0) {
            const ctrl = c.newObjectClass(ctx, controller_class_id);
            _ = c.setOpaque(ctrl, packHandle(idx, st_gen[idx]));
            var start_args = [_]c.Value{ctrl};
            const res = c.call(ctx, start_fn, argv[0], 1, &start_args);
            c.freeValue(ctx, res);
            c.freeValue(ctx, ctrl);
        }
    }

    return obj;
}

pub fn isStream(ctx: ?*c.Context, val: c.Value) bool {
    if (c.isObject(val) == 0) return false;
    return c.getOpaque2(ctx, val, stream_class_id) != null;
}

pub fn getStreamSlot(ctx: ?*c.Context, val: c.Value) ?u16 {
    return liveSlot(ctx, val, stream_class_id);
}

pub fn setHttpConn(idx: u16, conn_id: ?u16) void {
    if (idx < MAX_STREAMS) {
        st_http_conn[idx] = conn_id;
    }
}

pub fn createJsStream(ctx: ?*c.Context, idx: u16) c.Value {
    const obj = c.newObjectClass(ctx, stream_class_id);
    _ = c.setOpaque(obj, packHandle(idx, st_gen[idx]));
    return obj;
}

pub fn setup(ctx: *c.Context) void {
    init();
    const rt = c.getRuntime(ctx);

    if (stream_class_id == 0) {
        _ = c.newClassID(rt, &stream_class_id);
        const class_def: c.ClassDef = .{
            .class_name = "ReadableStream",
            .finalizer = streamFinalizer,
            .gc_mark = null,
            .call = null,
            .exotic = null,
        };
        _ = c.newClass(rt, stream_class_id, &class_def);

        _ = c.newClassID(rt, &reader_class_id);
        const reader_def: c.ClassDef = .{
            .class_name = "ReadableStreamDefaultReader",
            .finalizer = null,
            .gc_mark = null,
            .call = null,
            .exotic = null,
        };
        _ = c.newClass(rt, reader_class_id, &reader_def);

        _ = c.newClassID(rt, &controller_class_id);
        const ctrl_def: c.ClassDef = .{
            .class_name = "ReadableStreamDefaultController",
            .finalizer = null,
            .gc_mark = null,
            .call = null,
            .exotic = null,
        };
        _ = c.newClass(rt, controller_class_id, &ctrl_def);
    }

    const proto = c.newObject(ctx);
    defer c.freeValue(ctx, proto);
    const get_reader_fn = c.newCFunction(ctx, streamGetReaderCallback, "getReader", 0);
    _ = c.definePropertyValueStr(ctx, proto, "getReader", get_reader_fn, c.PROP_C_W_E);
    const cancel_fn = c.newCFunction(ctx, streamCancelCallback, "cancel", 1);
    _ = c.definePropertyValueStr(ctx, proto, "cancel", cancel_fn, c.PROP_C_W_E);
    const locked_atom = c.newAtom(ctx, "locked");
    defer c.freeAtom(ctx, locked_atom);
    _ = c.definePropertyGetSet(ctx, proto, locked_atom, c.newCFunction(ctx, streamLockedGetter, "locked", 0), c.JS_UNDEFINED, c.PROP_CONFIGURABLE | c.PROP_ENUMERABLE);
    c.setClassProto(ctx, stream_class_id, c.dupValue(ctx, proto));

    const reader_proto = c.newObject(ctx);
    defer c.freeValue(ctx, reader_proto);
    const read_fn = c.newCFunction(ctx, readerReadCallback, "read", 0);
    _ = c.definePropertyValueStr(ctx, reader_proto, "read", read_fn, c.PROP_C_W_E);
    const release_fn = c.newCFunction(ctx, readerReleaseLockCallback, "releaseLock", 0);
    _ = c.definePropertyValueStr(ctx, reader_proto, "releaseLock", release_fn, c.PROP_C_W_E);
    const r_cancel_fn = c.newCFunction(ctx, readerCancelCallback, "cancel", 1);
    _ = c.definePropertyValueStr(ctx, reader_proto, "cancel", r_cancel_fn, c.PROP_C_W_E);
    c.setClassProto(ctx, reader_class_id, c.dupValue(ctx, reader_proto));

    const ctrl_proto = c.newObject(ctx);
    defer c.freeValue(ctx, ctrl_proto);
    const enq_fn = c.newCFunction(ctx, controllerEnqueueCallback, "enqueue", 1);
    _ = c.definePropertyValueStr(ctx, ctrl_proto, "enqueue", enq_fn, c.PROP_C_W_E);
    const close_fn = c.newCFunction(ctx, controllerCloseCallback, "close", 0);
    _ = c.definePropertyValueStr(ctx, ctrl_proto, "close", close_fn, c.PROP_C_W_E);
    const err_fn = c.newCFunction(ctx, controllerErrorCallback, "error", 1);
    _ = c.definePropertyValueStr(ctx, ctrl_proto, "error", err_fn, c.PROP_C_W_E);

    const ds_atom = c.newAtom(ctx, "desiredSize");
    defer c.freeAtom(ctx, ds_atom);
    _ = c.definePropertyGetSet(ctx, ctrl_proto, ds_atom, c.newCFunction(ctx, controllerDesiredSizeGetter, "desiredSize", 0), c.JS_UNDEFINED, c.PROP_CONFIGURABLE | c.PROP_ENUMERABLE);

    c.setClassProto(ctx, controller_class_id, c.dupValue(ctx, ctrl_proto));

    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);

    const ctor = c.newCFunction2(ctx, streamConstructor, "ReadableStream", 1, c.JS_CFUNC_constructor, 0);
    _ = c.definePropertyValueStr(ctx, ctor, "prototype", c.dupValue(ctx, proto), c.PROP_CONFIGURABLE);
    _ = c.definePropertyValueStr(ctx, global, "ReadableStream", ctor, c.PROP_C_W_E);
}
