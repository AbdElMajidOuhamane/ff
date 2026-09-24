const std = @import("std");
const xev = @import("xev");
const qjs = @import("../engine/quickjs_shim.zig");
const console_api = @import("../api/console.zig");
const microtasks = @import("../event/microtasks.zig");
const timers_mod = @import("../event/timers.zig");
const port_mod = @import("message_port.zig");
const serialize = @import("serialize.zig");

const gpa = std.heap.smp_allocator;

pub const MAX_WORKERS = 8;
const WORKER_STACK = 8 * 1024 * 1024;
const POLL_QUANTUM_MS: i32 = 5;

// ── Parent-side state (main thread only — worker threads never touch this) ──

var worker_class_id: qjs.ClassID = 0;
var g_parent_ctx: ?*qjs.Context = null;

const Slot = struct {
    state: enum { free, alive } = .free,
    thread: ?std.Thread = null,
    port: ?port_mod.MessagePort = null, // parent end
    js_obj: ?qjs.Value = null, // dup'd Worker instance (for onmessage lookup)
};
var slots: [MAX_WORKERS]Slot = [_]Slot{.{}} ** MAX_WORKERS;

// ── Worker-thread thread-locals (one worker per thread, set by workerMain) ──

threadlocal var tls_port: ?port_mod.MessagePort = null;
threadlocal var tls_tm: ?*timers_mod.TimerManager = null;
threadlocal var tls_perf_origin: i96 = 0;

const WorkerData = struct {
    slot: u16,
    module_path: [:0]u8, // owned
    initial_payload: ?[]u8, // owned, options.data cloned on parent thread
    channel: port_mod.MessagePort, // child end moved to the thread
};

// ── Zig 0.16 filesystem access (mirrors src/api/fs.zig) ──

fn workerIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn fileExists(path: []const u8) bool {
    return if (std.Io.Dir.cwd().access(workerIo(), path, .{})) true else |_| false;
}

// ── Registration (called once from Runtime.init on the parent context) ──

pub fn setup(ctx: ?*qjs.Context) void {
    g_parent_ctx = ctx;
    const rt = qjs.getRuntime(ctx);
    _ = qjs.newClassID(rt, &worker_class_id);
    var def = qjs.ClassDef{ .class_name = "Worker", .finalizer = workerFinalizer };
    _ = qjs.newClass(rt, worker_class_id, &def);

    const proto = qjs.newObject(ctx);
    const pm = qjs.newCFunction(ctx, jsPostMessage, "postMessage", 1);
    _ = qjs.definePropertyValueStr(ctx, proto, "postMessage", pm, qjs.PROP_C_W_E);
    const tm = qjs.newCFunction(ctx, jsTerminate, "terminate", 0);
    _ = qjs.definePropertyValueStr(ctx, proto, "terminate", tm, qjs.PROP_C_W_E);

    const ctor = qjs.newCFunction(ctx, jsConstructor, "Worker", 2);
    _ = qjs.setConstructorBit(ctx, ctor, true);
    _ = qjs.setConstructor(ctx, ctor, proto);
    qjs.setClassProto(ctx, worker_class_id, proto);

    const global = qjs.getGlobalObject(ctx);
    defer qjs.freeValue(ctx, global);
    _ = qjs.definePropertyValueStr(ctx, global, "Worker", ctor, qjs.PROP_C_W_E);
}

fn slotFromOpaque(ptr: ?*anyopaque) ?u16 {
    const p = ptr orelse return null;
    const v: usize = @intFromPtr(p);
    if (v == 0 or v > MAX_WORKERS) return null;
    return @intCast(v - 1);
}

fn workerFinalizer(rt: ?*qjs.Runtime, val: qjs.Value) callconv(.c) void {
    _ = rt;
    // No ctx in a finalizer: use the non-ctx getOpaque variant.
    const slot = slotFromOpaque(qjs.getOpaque(val, worker_class_id)) orelse return;
    terminateSlot(slot);
}

// ── Parent-side JS bindings ──

fn jsConstructor(ctx: ?*qjs.Context, this_val: qjs.Value, argc: c_int, argv: [*c]qjs.Value) callconv(.c) qjs.Value {
    _ = this_val;
    if (argc < 1) {
        _ = qjs.throwTypeError(ctx, "Worker requires a module path");
        return qjs.JS_EXCEPTION;
    }
    const path_c = qjs.toCString(ctx, argv[0]) orelse return qjs.JS_EXCEPTION;
    defer qjs.freeCString(ctx, path_c);
    const path = std.mem.span(path_c);

    var initial: ?[]u8 = null;
    if (argc >= 2 and qjs.isObject(argv[1]) != 0) {
        const d = qjs.getPropertyStr(ctx, argv[1], "data");
        if (qjs.isUndefined(d) == 0 and qjs.isException(d) == 0) {
            initial = serialize.stringify(ctx, d) catch {
                // stringify left "value could not be cloned" pending — propagate.
                qjs.freeValue(ctx, d);
                return qjs.JS_EXCEPTION;
            };
        }
        qjs.freeValue(ctx, d);
    }
    errdefer if (initial) |b| gpa.free(b);

    const slot = allocSlot() orelse {
        _ = qjs.throwTypeError(ctx, "too many workers (max 8)");
        return qjs.JS_EXCEPTION;
    };

    const abs = resolveWorkerPath(path) catch {
        freeSlot(slot);
        _ = qjs.throwTypeError(ctx, "Worker module not found");
        return qjs.JS_EXCEPTION;
    };
    errdefer gpa.free(abs);

    var ch = port_mod.MessagePort.create() catch {
        freeSlot(slot);
        _ = qjs.throwInternalError(ctx, "Worker pipe creation failed");
        return qjs.JS_EXCEPTION;
    };
    errdefer ch.closeAll();

    const wdata = gpa.create(WorkerData) catch {
        _ = qjs.throwOutOfMemory(ctx);
        return qjs.JS_EXCEPTION;
    };
    wdata.* = .{ .slot = slot, .module_path = abs, .initial_payload = initial, .channel = ch.child };

    slots[slot].thread = std.Thread.spawn(.{ .stack_size = WORKER_STACK }, workerMain, .{wdata}) catch {
        gpa.destroy(wdata);
        _ = qjs.throwInternalError(ctx, "Worker thread spawn failed");
        return qjs.JS_EXCEPTION;
    };
    slots[slot].port = ch.parent;
    slots[slot].state = .alive;

    const obj = qjs.newObjectClass(ctx, worker_class_id);
    qjs.setOpaque(obj, @ptrFromInt(slot + 1));
    slots[slot].js_obj = qjs.dupValue(ctx, obj);
    return qjs.dupValue(ctx, obj);
}

fn slotFromThis(ctx: ?*qjs.Context, this_val: qjs.Value) ?u16 {
    return slotFromOpaque(qjs.getOpaque2(ctx, this_val, worker_class_id));
}

fn jsPostMessage(ctx: ?*qjs.Context, this_val: qjs.Value, argc: c_int, argv: [*c]qjs.Value) callconv(.c) qjs.Value {
    const slot = slotFromThis(ctx, this_val) orelse {
        _ = qjs.throwTypeError(ctx, "postMessage called on invalid Worker");
        return qjs.JS_EXCEPTION;
    };
    if (slots[slot].state != .alive) {
        _ = qjs.throwInternalError(ctx, "postMessage on terminated Worker");
        return qjs.JS_EXCEPTION;
    }
    if (argc < 1) {
        _ = qjs.throwTypeError(ctx, "postMessage requires an argument");
        return qjs.JS_EXCEPTION;
    }
    // FIX (DOD §12): engine-owned view, zero Zig heap per send. The pipe
    // write is synchronous, so the buffer outlives the send by construction.
    const payload = serialize.stringifyView(ctx, argv[0]) catch {
        // stringifyView already threw "value could not be cloned" — propagate.
        return qjs.JS_EXCEPTION;
    };
    defer payload.deinit();
    var port = slots[slot].port orelse {
        _ = qjs.throwInternalError(ctx, "Worker channel closed");
        return qjs.JS_EXCEPTION;
    };
    port.sendMessage(payload.slice()) catch {
        _ = qjs.throwInternalError(ctx, "failed to send message to worker");
        return qjs.JS_EXCEPTION;
    };
    return qjs.JS_UNDEFINED;
}

fn jsTerminate(ctx: ?*qjs.Context, this_val: qjs.Value, argc: c_int, argv: [*c]qjs.Value) callconv(.c) qjs.Value {
    _ = argc;
    _ = argv;
    const slot = slotFromThis(ctx, this_val) orelse return qjs.JS_UNDEFINED;
    terminateSlot(slot);
    return qjs.JS_UNDEFINED;
}

// ── Parent-side lifecycle ──

fn allocSlot() ?u16 {
    for (0..MAX_WORKERS) |i| {
        if (slots[i].state == .free) return @intCast(i);
    }
    return null;
}

fn freeSlot(slot: u16) void {
    slots[slot] = .{};
}

/// terminate() is idempotent. Closing the parent write end makes the
/// worker's pipe read return EOF, which breaks its loop; join() then reaps
/// the thread (bounded by the 5 ms poll quantum — never hangs on timers
/// because the worker loop only ever blocks in poll, never in xev).
fn terminateSlot(slot: u16) void {
    if (slot >= MAX_WORKERS or slots[slot].state != .alive) return;
    slots[slot].state = .free;
    if (slots[slot].port) |*port| {
        port.closeSend();
    }
    if (slots[slot].thread) |*t| {
        t.join();
        slots[slot].thread = null;
    }
    if (slots[slot].port) |*port| {
        port.closeRecv();
        slots[slot].port = null;
    }
    if (slots[slot].js_obj) |o| {
        if (g_parent_ctx) |pctx| qjs.freeValue(pctx, o);
        slots[slot].js_obj = null;
    }
}

fn resolveWorkerPath(path: []const u8) ![:0]u8 {
    // access() handles absolute and relative paths alike; the process
    // never chdirs, so returning the path as-given is stable.
    if (fileExists(path)) return gpa.dupeZ(u8, path);
    const with_js = try std.fmt.allocPrint(gpa, "{s}.js", .{path});
    defer gpa.free(with_js);
    if (fileExists(with_js)) return gpa.dupeZ(u8, with_js);
    return error.FileNotFound;
}

// ── Parent-side drain (called from the main event loop) ──

pub fn liveCount() usize {
    var n: usize = 0;
    for (slots) |s| {
        if (s.state == .alive) n += 1;
    }
    return n;
}

pub fn drainCompleted(ctx: *qjs.Context) void {
    for (0..MAX_WORKERS) |s| {
        if (slots[s].state != .alive) continue;
        var port = slots[s].port orelse continue;
        // FIX (DOD §12): payload is thread-local scratch — borrowed, not
        // owned. No per-frame free; valid until the next recv on this thread.
        while (port.tryRecvFrame()) |fr| {
            deliverToParent(ctx, @intCast(s), fr);
        }
    }
}

fn deliverToParent(ctx: *qjs.Context, slot: u16, fr: port_mod.Frame) void {
    const obj = slots[slot].js_obj orelse return;
    const is_err = fr.ftype == port_mod.FRAME_ERROR;
    const handler = qjs.getPropertyStr(ctx, obj, if (is_err) "onerror" else "onmessage");
    defer qjs.freeValue(ctx, handler);
    if (qjs.isFunction(ctx, handler) == 0) {
        if (is_err) std.debug.print("[worker] unhandled error: {s}\n", .{fr.payload});
        return;
    }
    const arg = if (is_err) makeErrorEvent(ctx, fr.payload) else blk: {
        const data = serialize.parse(ctx, fr.payload) catch return;
        const ev = qjs.newObject(ctx);
        _ = qjs.definePropertyValueStr(ctx, ev, "data", data, qjs.PROP_C_W_E);
        break :blk ev;
    };
    defer qjs.freeValue(ctx, arg);
    var args = [_]qjs.Value{arg};
    const ret = qjs.call(ctx, handler, obj, 1, &args[0]);
    if (qjs.isException(ret) != 0) {
        const exc = qjs.getException(ctx);
        defer qjs.freeValue(ctx, exc);
        const m = qjs.toCString(ctx, exc);
        if (m) |s| {
            defer qjs.freeCString(ctx, s);
            std.debug.print("worker onmessage error: {s}\n", .{s});
        }
    } else qjs.freeValue(ctx, ret);
}

fn makeErrorEvent(ctx: ?*qjs.Context, msg: []const u8) qjs.Value {
    const m = if (msg.len > 0) msg else "(unknown worker error)";
    const ev = qjs.newObject(ctx);
    const s = qjs.newStringLen(ctx, m.ptr, m.len);
    _ = qjs.definePropertyValueStr(ctx, ev, "message", s, qjs.PROP_C_W_E);
    return ev;
}

// ── Worker thread main ──

fn workerMain(data: *WorkerData) void {
    defer gpa.destroy(data);
    defer gpa.free(data.module_path);
    defer {
        if (data.initial_payload) |b| gpa.free(b);
    }
    defer data.channel.closeAll();
    tls_port = data.channel;
    defer tls_port = null;

    const rt = qjs.newRuntime() orelse return;
    defer qjs.freeRuntime(rt);
    qjs.setMaxStackSize(rt, 1024 * 1024);
    qjs.setMemoryLimit(rt, 32 * 1024 * 1024);

    const ctx = qjs.newContext(rt) orelse return;
    defer qjs.freeContext(ctx);

    console_api.setup(ctx);
    setupWorkerGlobals(ctx, data.initial_payload);

    const src = std.Io.Dir.cwd().readFileAlloc(workerIo(), data.module_path, gpa, .limited(10 * 1024 * 1024)) catch {
        sendErrorToParent("could not read worker module");
        return;
    };
    defer gpa.free(src);
    const src_z = gpa.dupeZ(u8, src) catch {
        sendErrorToParent("out of memory");
        return;
    };
    defer gpa.free(src_z);

    const res = qjs.eval(ctx, src_z.ptr, src.len, data.module_path.ptr, qjs.EVAL_TYPE_GLOBAL);
    if (qjs.isException(res) != 0) {
        const exc = qjs.getException(ctx);
        defer qjs.freeValue(ctx, exc);
        const m = qjs.toCString(ctx, exc);
        if (m) |s| {
            defer qjs.freeCString(ctx, s);
            const span = std.mem.span(s);
            sendErrorToParent(span);
            std.debug.print("[worker] error: {s}\n", .{span});
        }
        qjs.freeValue(ctx, res);
        return;
    }
    qjs.freeValue(ctx, res);
    microtasks.pumpMicrotasks(ctx);

    runWorkerLoop(ctx, &data.channel);
}

fn sendErrorToParent(msg: []const u8) void {
    if (tls_port) |*p| {
        p.sendError(msg) catch {};
    }
}

// ── Worker-side globals: postMessage / onmessage / self / workerData /
//    timers (numeric IDs — no Timeout class: class IDs are per-runtime) ──

fn setupWorkerGlobals(ctx: *qjs.Context, initial_payload: ?[]u8) void {
    const global = qjs.getGlobalObject(ctx);
    defer qjs.freeValue(ctx, global);

    const pm = qjs.newCFunction(ctx, jsWorkerPostMessage, "postMessage", 1);
    _ = qjs.definePropertyValueStr(ctx, global, "postMessage", pm, qjs.PROP_C_W_E);

    _ = qjs.definePropertyValueStr(ctx, global, "self", qjs.dupValue(ctx, global), qjs.PROP_C_W_E);

    const wd = if (initial_payload) |j| serialize.parse(ctx, j) catch qjs.JS_UNDEFINED else qjs.JS_UNDEFINED;
    _ = qjs.definePropertyValueStr(ctx, global, "workerData", wd, qjs.PROP_C_W_E);

    const st = qjs.newCFunction(ctx, wSetTimeout, "setTimeout", 2);
    _ = qjs.definePropertyValueStr(ctx, global, "setTimeout", st, qjs.PROP_C_W_E);
    const si = qjs.newCFunction(ctx, wSetInterval, "setInterval", 2);
    _ = qjs.definePropertyValueStr(ctx, global, "setInterval", si, qjs.PROP_C_W_E);
    const ct = qjs.newCFunction(ctx, wClearTimeout, "clearTimeout", 1);
    _ = qjs.definePropertyValueStr(ctx, global, "clearTimeout", ct, qjs.PROP_C_W_E);
    const ci = qjs.newCFunction(ctx, wClearInterval, "clearInterval", 1);
    _ = qjs.definePropertyValueStr(ctx, global, "clearInterval", ci, qjs.PROP_C_W_E);
    const qm = qjs.newCFunction(ctx, wQueueMicrotask, "queueMicrotask", 1);
    _ = qjs.definePropertyValueStr(ctx, global, "queueMicrotask", qm, qjs.PROP_C_W_E);

    const perf = qjs.newObject(ctx);
    const now_fn = qjs.newCFunction(ctx, wPerformanceNow, "now", 0);
    _ = qjs.definePropertyValueStr(ctx, perf, "now", now_fn, qjs.PROP_C_W_E);
    _ = qjs.definePropertyValueStr(ctx, global, "performance", perf, qjs.PROP_C_W_E);
}

fn jsWorkerPostMessage(ctx: ?*qjs.Context, this_val: qjs.Value, argc: c_int, argv: [*c]qjs.Value) callconv(.c) qjs.Value {
    _ = this_val;
    if (argc < 1) {
        _ = qjs.throwTypeError(ctx, "postMessage requires an argument");
        return qjs.JS_EXCEPTION;
    }
    const port = tls_port orelse {
        _ = qjs.throwInternalError(ctx, "postMessage outside worker");
        return qjs.JS_EXCEPTION;
    };
    // FIX (DOD §12): same engine-owned view as the parent side.
    const payload = serialize.stringifyView(ctx, argv[0]) catch {
        // stringifyView already threw "value could not be cloned" — propagate.
        return qjs.JS_EXCEPTION;
    };
    defer payload.deinit();
    port.sendMessage(payload.slice()) catch {
        _ = qjs.throwInternalError(ctx, "failed to send message to parent");
        return qjs.JS_EXCEPTION;
    };
    return qjs.JS_UNDEFINED;
}

fn wScheduleTimeout(ctx: ?*qjs.Context, argc: c_int, argv: [*c]qjs.Value, interval: bool) qjs.Value {
    if (argc < 1 or qjs.isFunction(ctx, argv[0]) == 0) {
        _ = qjs.throwTypeError(ctx, "setTimeout requires a function as first argument");
        return qjs.JS_EXCEPTION;
    }
    var ms: i64 = 0;
    if (argc >= 2) _ = qjs.toInt64(ctx, &ms, argv[1]);
    if (ms < 0) ms = 0;
    var nargs: usize = 0;
    if (argc > 2) {
        nargs = @intCast(argc - 2);
        if (nargs > 8) {
            _ = qjs.throwTypeError(ctx, "setTimeout accepts at most 8 callback arguments");
            return qjs.JS_EXCEPTION;
        }
    }
    const tm = tls_tm orelse return qjs.JS_UNDEFINED;
    const args_slice: []const qjs.Value = if (nargs > 0) argv[2..][0..nargs] else &.{};
    const id = if (interval)
        tm.setInterval(ctx.?, argv[0], @intCast(ms), args_slice)
    else
        tm.setTimeout(ctx.?, argv[0], @intCast(ms), args_slice);
    const slot = id catch {
        _ = qjs.throwTypeError(ctx, "too many timers (max 128)");
        return qjs.JS_EXCEPTION;
    };
    return qjs.newInt32(ctx, @intCast(slot));
}

fn wSetTimeout(ctx: ?*qjs.Context, this_val: qjs.Value, argc: c_int, argv: [*c]qjs.Value) callconv(.c) qjs.Value {
    _ = this_val;
    return wScheduleTimeout(ctx, argc, argv, false);
}

fn wSetInterval(ctx: ?*qjs.Context, this_val: qjs.Value, argc: c_int, argv: [*c]qjs.Value) callconv(.c) qjs.Value {
    _ = this_val;
    return wScheduleTimeout(ctx, argc, argv, true);
}

fn wClearTimeout(ctx: ?*qjs.Context, this_val: qjs.Value, argc: c_int, argv: [*c]qjs.Value) callconv(.c) qjs.Value {
    _ = this_val;
    const tm = tls_tm orelse return qjs.JS_UNDEFINED;
    if (argc < 1) return qjs.JS_UNDEFINED;
    var id: i32 = 0;
    _ = qjs.toInt32(ctx, &id, argv[0]);
    if (id < 0 or id >= 128) return qjs.JS_UNDEFINED;
    tm.clear(@intCast(id));
    return qjs.JS_UNDEFINED;
}

fn wClearInterval(ctx: ?*qjs.Context, this_val: qjs.Value, argc: c_int, argv: [*c]qjs.Value) callconv(.c) qjs.Value {
    _ = this_val;
    const tm = tls_tm orelse return qjs.JS_UNDEFINED;
    if (argc < 1) return qjs.JS_UNDEFINED;
    var id: i32 = 0;
    _ = qjs.toInt32(ctx, &id, argv[0]);
    if (id < 0 or id >= 128) return qjs.JS_UNDEFINED;
    tm.clear(@intCast(id));
    return qjs.JS_UNDEFINED;
}

fn wMicrotaskJob(ctx: ?*qjs.Context, argc: c_int, argv: [*c]qjs.Value) callconv(.c) qjs.Value {
    _ = argc;
    const ret = qjs.call(ctx, argv[0], qjs.JS_UNDEFINED, 0, null);
    if (qjs.isException(ret) != 0) {
        const exc = qjs.getException(ctx);
        defer qjs.freeValue(ctx, exc);
        const msg = qjs.toCString(ctx, exc);
        if (msg) |m| {
            defer qjs.freeCString(ctx, m);
            std.debug.print("queueMicrotask error: {s}\n", .{m});
        }
        return qjs.JS_UNDEFINED;
    }
    return ret;
}

fn wQueueMicrotask(ctx: ?*qjs.Context, this_val: qjs.Value, argc: c_int, argv: [*c]qjs.Value) callconv(.c) qjs.Value {
    _ = this_val;
    if (argc < 1 or qjs.isFunction(ctx, argv[0]) == 0) {
        _ = qjs.throwTypeError(ctx, "queueMicrotask requires a function argument");
        return qjs.JS_EXCEPTION;
    }
    if (qjs.enqueueJob(ctx, wMicrotaskJob, 1, argv) != 0) return qjs.JS_EXCEPTION;
    return qjs.JS_UNDEFINED;
}

fn wPerformanceNow(ctx: ?*qjs.Context, this_val: qjs.Value, argc: c_int, argv: [*c]qjs.Value) callconv(.c) qjs.Value {
    _ = this_val;
    _ = argc;
    _ = argv;
    const io = std.Io.Threaded.global_single_threaded.io();
    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    if (tls_perf_origin == 0) tls_perf_origin = now_ns;
    const ms: f64 = @as(f64, @floatFromInt(now_ns - tls_perf_origin)) / 1e6;
    return qjs.newFloat64(ctx, ms);
}

// ── Worker event loop ──
//
// Single thread: block in poll() (never in xev), then pump xev with
// .no_wait. Blocking only in poll means terminate() → join() is bounded
// by POLL_QUANTUM_MS no matter how far out worker timers are scheduled.
// Exit condition: EOF on the pipe (parent closed its write end via
// terminate()). There is deliberately no idle-exit: the worker lives
// until terminate(), so late postMessage calls still get delivered.

fn runWorkerLoop(ctx: *qjs.Context, port: *const port_mod.MessagePort) void {
    var pool = xev.ThreadPool.init(.{ .max_threads = 2 });
    var loop = xev.Loop.init(.{ .thread_pool = &pool }) catch return;
    defer loop.deinit();
    var tm = timers_mod.TimerManager.init(&loop);
    tls_tm = &tm;
    defer tls_tm = null;

    while (true) {
        if (port.pollReadable(POLL_QUANTUM_MS)) {
            const fr = port.recvFrameBlocking() catch break; // EOF → shutdown
            deliverToWorker(ctx, fr);
        }
        loop.run(.no_wait) catch {};
        microtasks.pumpMicrotasks(ctx);
    }
    tm.cancelAll();
}

fn deliverToWorker(ctx: *qjs.Context, fr: port_mod.Frame) void {
    if (fr.ftype != port_mod.FRAME_MESSAGE) return; // parent never sends errors in v1
    const data = serialize.parse(ctx, fr.payload) catch return;
    const event = qjs.newObject(ctx);
    _ = qjs.definePropertyValueStr(ctx, event, "data", data, qjs.PROP_C_W_E);
    defer qjs.freeValue(ctx, event);
    const global = qjs.getGlobalObject(ctx);
    defer qjs.freeValue(ctx, global);
    const handler = qjs.getPropertyStr(ctx, global, "onmessage");
    defer qjs.freeValue(ctx, handler);
    if (qjs.isFunction(ctx, handler) == 0) return;
    var args = [_]qjs.Value{event};
    const ret = qjs.call(ctx, handler, global, 1, &args[0]);
    if (qjs.isException(ret) != 0) {
        const exc = qjs.getException(ctx);
        defer qjs.freeValue(ctx, exc);
        const m = qjs.toCString(ctx, exc);
        if (m) |s| {
            defer qjs.freeCString(ctx, s);
            const span = std.mem.span(s);
            sendErrorToParent(span);
            std.debug.print("[worker] onmessage error: {s}\n", .{span});
        }
    } else qjs.freeValue(ctx, ret);
}
