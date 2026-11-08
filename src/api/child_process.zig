// src/api/child_process.zig
// child_process global: spawn / exec / execSync.
//
// every child lifecycle step runs on the JS/loop thread, so
// there are no locks, no atomics and no extra threads. Pipe reads are evented
// xev.Stream completions on reused per-slot buffers; exit detection is a
// SIGCHLD self-pipe + waitpid(WNOHANG) per tracked pid, which decodes the raw
// wait status so {code, signal} are exact on every backend. Fixed 8-slot
// pool, hot state column scanned per drain, buffers and completions reused
// across reads and children: zero steady-state allocations.

const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const c = @import("../c.zig").c;
const perm = @import("../security/permissions.zig");
const deny = @import("../security/deny.zig");

const gpa = std.heap.smp_allocator;
const Io = std.Io;
const SIG = std.posix.SIG;

// The app Io, installed once by main.zig (init.io). std's statically
// initialized global Io uses a FAILING allocator, so std.process.spawn
// through it returns OutOfMemory; init.io also carries the real process
// environ block, so children inherit the parent env and PATH scans work.
var g_io: ?Io = null;

pub fn setIo(io: Io) void {
    g_io = io;
}

fn getIo() Io {
    return g_io orelse std.Io.Threaded.global_single_threaded.io();
}

pub const MAX_CHILDREN: usize = 8;
const CHUNK = 16 * 1024;
const DEFAULT_MAX_BUFFER: usize = 1024 * 1024;
const RESULT_RETAIN_MAX: usize = 256 * 1024;

const ST_FREE: u8 = 0;
const ST_CLAIMED: u8 = 1;
const ST_RUNNING: u8 = 2;
const ST_DONE: u8 = 3;

const Flags = packed struct(u8) {
    out_open: bool = false,
    err_open: bool = false,
    eof_out: bool = false,
    eof_err: bool = false,
    reaped: bool = false,
    exec_mode: bool = false,
    truncated: bool = false,
    capture: bool = false,
};

const Slot = struct {
    pid: std.posix.pid_t = 0,
    code: ?u8 = null,
    sig: ?SIG = null,
    flags: Flags = .{},
    out_fd: std.posix.fd_t = -1,
    err_fd: std.posix.fd_t = -1,
    out_stream: xev.Stream = undefined,
    err_stream: xev.Stream = undefined,
    read_out: xev.Completion = .{},
    read_err: xev.Completion = .{},
    out_buf: [CHUNK]u8 = undefined,
    err_buf: [CHUNK]u8 = undefined,
    out_acc: std.ArrayList(u8) = .empty,
    err_acc: std.ArrayList(u8) = .empty,
    max_buffer: usize = DEFAULT_MAX_BUFFER,
    js_obj: c.Value = c.JS_UNDEFINED,
    wait_promise: c.Value = c.JS_UNDEFINED,
    resolve: c.Value = c.JS_UNDEFINED,
    reject: c.Value = c.JS_UNDEFINED,
};
var slots: [MAX_CHILDREN]Slot = undefined; // zero-init in setup() → __bss

// Hot column: the only thing drainCompleted scans.
var states: [MAX_CHILDREN]u8 = [_]u8{ST_FREE} ** MAX_CHILDREN;
var gens: [MAX_CHILDREN]u32 = [_]u32{0} ** MAX_CHILDREN;
var live: usize = 0;

comptime {
    std.debug.assert(@sizeOf(@TypeOf(states)) == MAX_CHILDREN);
}

var child_class_id: c.ClassID = 0;
var g_loop: ?*xev.Loop = null;

// ── measurement (process.stats().child) ─────────────────────────────
pub var stat_spawned: std.atomic.Value(u64) = .{ .raw = 0 };
pub var stat_truncated: std.atomic.Value(u64) = .{ .raw = 0 };
pub var stat_out_heap: std.atomic.Value(u64) = .{ .raw = 0 };

// ── SIGCHLD self-pipe ───────────────────────────────────────────────
var sig_pipe: [2]std.posix.fd_t = .{ -1, -1 };
var sig_stream: xev.Stream = undefined;
var sig_comp: xev.Completion = .{};
var sig_scratch: [16]u8 = undefined;
var sig_installed = false;
var sig_armed = false;

// Async-signal-safe: one raw write to a nonblocking pipe.
fn onSigchld(_: SIG) callconv(.c) void {
    if (sig_pipe[1] >= 0) {
        _ = std.c.write(sig_pipe[1], &[_]u8{1}, 1);
    }
}

fn setNonblocking(fd: std.posix.fd_t) void {
    const cur: c_int = std.c.fcntl(fd, std.posix.F.GETFL);
    var flags: std.c.O = @bitCast(@as(u32, @intCast(cur)));
    flags.NONBLOCK = true;
    _ = std.c.fcntl(fd, std.posix.F.SETFL, @as(c_int, @bitCast(@as(u32, @bitCast(flags)))));
}

fn installSigchld() void {
    if (sig_installed) return;
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return;
    setNonblocking(fds[0]);
    setNonblocking(fds[1]);
    sig_pipe = fds;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onSigchld },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(.CHLD, &act, null);
    sig_installed = true;
}

fn armSigchld() void {
    if (sig_armed) return;
    const l = g_loop orelse return;
    if (sig_pipe[0] < 0) return;
    sig_armed = true;
    sig_stream = xev.Stream.initFd(sig_pipe[0]);
    sig_stream.read(l, &sig_comp, .{ .slice = sig_scratch[0..] }, anyopaque, null, sigchldCb);
}

fn drainSignalPipe() void {
    var buf: [64]u8 = undefined;
    while (true) {
        const n = std.c.read(sig_pipe[0], &buf, buf.len);
        if (n <= 0) return;
    }
}

fn sigchldCb(
    ud: ?*anyopaque,
    l: *xev.Loop,
    comp: *xev.Completion,
    stream: xev.Stream,
    buf: xev.ReadBuffer,
    r: xev.ReadError!usize,
) xev.CallbackAction {
    _ = ud;
    _ = l;
    _ = comp;
    _ = stream;
    _ = buf;
    _ = r catch {};
    sig_armed = false;
    drainSignalPipe();
    reapExited();
    if (anyUnreaped()) armSigchld();
    return .disarm;
}

fn anyUnreaped() bool {
    for (0..MAX_CHILDREN) |i| {
        if (states[i] == ST_RUNNING and !slots[i].flags.reaped) return true;
    }
    return false;
}

fn reapExited() void {
    for (0..MAX_CHILDREN) |i| {
        if (states[i] != ST_RUNNING) continue;
        var status: c_int = 0;
        const r = std.c.waitpid(slots[i].pid, &status, std.c.W.NOHANG);
        if (r == slots[i].pid) {
            const info = decodeStatus(@bitCast(status));
            slots[i].flags.reaped = true;
            slots[i].code = info.code;
            slots[i].sig = info.sig;
        } else if (r == -1) {
            // ECHILD: already reaped elsewhere. Unknown term.
            slots[i].flags.reaped = true;
        } else continue; // 0: still running
        if (childComplete(i)) states[i] = ST_DONE;
    }
}

const TermInfo = struct { code: ?u8 = null, sig: ?SIG = null };

fn decodeStatus(status: u32) TermInfo {
    if (std.c.W.IFEXITED(status)) return .{ .code = std.c.W.EXITSTATUS(status) };
    if (std.c.W.IFSIGNALED(status)) return .{ .sig = std.c.W.TERMSIG(status) };
    return .{};
}

fn childComplete(i: usize) bool {
    const f = slots[i].flags;
    if (!f.reaped) return false;
    if (f.out_open and !f.eof_out) return false;
    if (f.err_open and !f.eof_err) return false;
    return true;
}

// ── slot pool ───────────────────────────────────────────────────────

fn acquireSlot() ?usize {
    for (0..MAX_CHILDREN) |i| {
        if (states[i] != ST_FREE) continue;
        states[i] = ST_CLAIMED;
        gens[i] +%= 1; // invalidates stale JS handles
        const s = &slots[i];
        s.pid = 0;
        s.code = null;
        s.sig = null;
        s.flags = .{};
        s.out_fd = -1;
        s.err_fd = -1;
        s.max_buffer = DEFAULT_MAX_BUFFER;
        s.js_obj = c.JS_UNDEFINED;
        s.wait_promise = c.JS_UNDEFINED;
        s.resolve = c.JS_UNDEFINED;
        s.reject = c.JS_UNDEFINED;
        s.out_acc.clearRetainingCapacity();
        s.err_acc.clearRetainingCapacity();
        return i;
    }
    return null;
}

fn closeFd(fd: *std.posix.fd_t) void {
    if (fd.* >= 0) {
        _ = std.c.close(fd.*);
        fd.* = -1;
    }
}

fn releaseSlot(ctx: ?*c.Context, i: usize) void {
    const s = &slots[i];
    c.freeValue(ctx, s.js_obj);
    c.freeValue(ctx, s.wait_promise);
    c.freeValue(ctx, s.resolve);
    c.freeValue(ctx, s.reject);
    s.js_obj = c.JS_UNDEFINED;
    s.wait_promise = c.JS_UNDEFINED;
    s.resolve = c.JS_UNDEFINED;
    s.reject = c.JS_UNDEFINED;
    closeFd(&s.out_fd);
    closeFd(&s.err_fd);
    if (s.out_acc.capacity > RESULT_RETAIN_MAX) {
        s.out_acc.deinit(gpa);
        s.out_acc = .empty;
    } else s.out_acc.clearRetainingCapacity();
    if (s.err_acc.capacity > RESULT_RETAIN_MAX) {
        s.err_acc.deinit(gpa);
        s.err_acc = .empty;
    } else s.err_acc.clearRetainingCapacity();
    gens[i] +%= 1;
    states[i] = ST_FREE;
    if (live > 0) live -= 1;
}

// ── evented pipe reads ──────────────────────────────────────────────

fn armRead(i: usize, is_out: bool) void {
    const l = g_loop orelse return;
    const s = &slots[i];
    const buf: []u8 = if (is_out) s.out_buf[0..] else s.err_buf[0..];
    const comp = if (is_out) &s.read_out else &s.read_err;
    const stream = if (is_out) s.out_stream else s.err_stream;
    stream.read(l, comp, .{ .slice = buf }, anyopaque, @ptrFromInt(i + 1), readCb);
}

fn readCb(
    ud: ?*anyopaque,
    l: *xev.Loop,
    comp: *xev.Completion,
    stream: xev.Stream,
    buf: xev.ReadBuffer,
    r: xev.ReadError!usize,
) xev.CallbackAction {
    _ = stream;
    _ = buf;
    const i = @intFromPtr(ud orelse return .disarm) - 1;
    if (i >= MAX_CHILDREN or states[i] != ST_RUNNING) return .disarm;
    const is_out = comp == &slots[i].read_out;
    const n = r catch {
        markEof(i, is_out);
        return .disarm;
    };
    if (n == 0) {
        markEof(i, is_out);
        return .disarm;
    }
    if (!slots[i].flags.truncated) {
        const chunk: []const u8 = if (is_out) slots[i].out_buf[0..n] else slots[i].err_buf[0..n];
        appendChunk(i, is_out, chunk);
    }
    // Keep draining after truncation: EOF must still be observed or the slot
    // would never complete. Data is discarded, memory stays at CHUNK.
    if (states[i] != ST_RUNNING) return .disarm;
    _ = l;
    armRead(i, is_out);
    return .disarm;
}

fn appendChunk(i: usize, is_out: bool, chunk: []const u8) void {
    const s = &slots[i];
    const acc = if (is_out) &s.out_acc else &s.err_acc;
    const room = s.max_buffer -| acc.items.len;
    if (chunk.len <= room) {
        const before = acc.capacity;
        acc.appendSlice(gpa, chunk) catch {};
        if (acc.capacity != before) {
            _ = stat_out_heap.fetchAdd(@intCast(acc.capacity - before), .monotonic);
        }
        return;
    }
    if (room > 0) acc.appendSlice(gpa, chunk[0..room]) catch {};
    s.flags.truncated = true;
    _ = stat_truncated.fetchAdd(1, .monotonic);
    // Don't let the child block forever on a full pipe nobody reads.
    std.posix.kill(s.pid, .TERM) catch {};
}

fn markEof(i: usize, is_out: bool) void {
    const s = &slots[i];
    if (is_out) {
        s.flags.eof_out = true;
        s.flags.out_open = false;
        closeFd(&s.out_fd);
    } else {
        s.flags.eof_err = true;
        s.flags.err_open = false;
        closeFd(&s.err_fd);
    }
    if (states[i] == ST_RUNNING and childComplete(i)) states[i] = ST_DONE;
}

// ── setup / loop hooks ──────────────────────────────────────────────

pub fn setup(ctx: *c.Context) void {
    for (&slots) |*s| s.* = .{};
    for (&states) |*st| st.* = ST_FREE;
    live = 0;
    installSigchld();

    const rt = c.getRuntime(ctx);
    _ = c.newClassID(rt, &child_class_id);
    var def = c.ClassDef{ .class_name = "Child", .finalizer = null };
    _ = c.newClass(rt, child_class_id, &def);

    const proto = c.newObject(ctx);
    const kill_fn = c.newCFunction(ctx, jsKill, "kill", 1);
    _ = c.definePropertyValueStr(ctx, proto, "kill", kill_fn, c.PROP_C_W_E);
    const wait_fn = c.newCFunction(ctx, jsWait, "wait", 0);
    _ = c.definePropertyValueStr(ctx, proto, "wait", wait_fn, c.PROP_C_W_E);
    c.setClassProto(ctx, child_class_id, proto);

    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);
    const cp = c.newObject(ctx);
    const spawn_fn = c.newCFunction(ctx, jsSpawn, "spawn", 3);
    _ = c.definePropertyValueStr(ctx, cp, "spawn", spawn_fn, c.PROP_C_W_E);
    const exec_fn = c.newCFunction(ctx, jsExec, "exec", 2);
    _ = c.definePropertyValueStr(ctx, cp, "exec", exec_fn, c.PROP_C_W_E);
    const exec_sync_fn = c.newCFunction(ctx, jsExecSync, "execSync", 2);
    _ = c.definePropertyValueStr(ctx, cp, "execSync", exec_sync_fn, c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, global, "child_process", cp, c.PROP_C_W_E);
}

pub fn setLoop(l: *xev.Loop) void {
    g_loop = l;
    if (live > 0) armSigchld();
}

pub fn liveCount() usize {
    return live;
}

pub fn drainCompleted(ctx: *c.Context) void {
    for (0..MAX_CHILDREN) |i| {
        if (states[i] == ST_DONE) settle(ctx, i);
    }
}

// ── settlement (JS thread) ──────────────────────────────────────────

fn settle(ctx: *c.Context, i: usize) void {
    const s = &slots[i];
    const exec_mode = s.flags.exec_mode;
    const truncated = s.flags.truncated;
    const code = s.code;
    const sig = s.sig;

    // spawn: publish captured results on the Child object.
    if (!exec_mode and c.isUndefined(s.js_obj) == 0 and c.isException(s.js_obj) == 0) {
        if (s.flags.capture) {
            const out_val = if (s.out_acc.items.len == 0)
                c.newUint8ArrayCopy(ctx, "", 0)
            else
                c.newUint8ArrayCopy(ctx, s.out_acc.items.ptr, s.out_acc.items.len);
            _ = c.definePropertyValueStr(ctx, s.js_obj, "stdout", out_val, c.PROP_C_W_E);
            const err_val = if (s.err_acc.items.len == 0)
                c.newUint8ArrayCopy(ctx, "", 0)
            else
                c.newUint8ArrayCopy(ctx, s.err_acc.items.ptr, s.err_acc.items.len);
            _ = c.definePropertyValueStr(ctx, s.js_obj, "stderr", err_val, c.PROP_C_W_E);
        }
        _ = c.definePropertyValueStr(ctx, s.js_obj, "exitCode", if (code) |v| c.newInt64(ctx, v) else c.JS_NULL, c.PROP_C_W_E);
        _ = c.definePropertyValueStr(ctx, s.js_obj, "signalCode", if (sig) |v| sigToValue(ctx, v) else c.JS_NULL, c.PROP_C_W_E);
        _ = c.definePropertyValueStr(ctx, s.js_obj, "truncated", if (truncated) c.JS_TRUE else c.JS_FALSE, c.PROP_C_W_E);
    }

    // Build the promise result before the slot is recycled.
    var result = c.JS_UNDEFINED;
    if (exec_mode) {
        result = c.newObject(ctx);
        if (c.isException(result) == 0) {
            _ = c.definePropertyValueStr(ctx, result, "stdout", bytesToJs(ctx, s.out_acc.items), c.PROP_C_W_E);
            _ = c.definePropertyValueStr(ctx, result, "stderr", bytesToJs(ctx, s.err_acc.items), c.PROP_C_W_E);
            putExit(ctx, result, code, sig);
        }
    } else if (c.isUndefined(s.resolve) == 0 and c.isException(s.resolve) == 0) {
        result = c.newObject(ctx);
        if (c.isException(result) == 0) putExit(ctx, result, code, sig);
    }

    // Detach promise functions so reentrant JS can't touch a recycled slot.
    const resolve_fn = s.resolve;
    const reject_fn = s.reject;
    s.resolve = c.JS_UNDEFINED;
    s.reject = c.JS_UNDEFINED;

    releaseSlot(ctx, i);

    if (exec_mode and truncated) {
        rejectWith(ctx, reject_fn, "maxBuffer exceeded");
    } else if (c.isUndefined(resolve_fn) == 0 and c.isException(resolve_fn) == 0) {
        if (c.isUndefined(result) == 0 and c.isException(result) == 0) {
            var args = [1]c.Value{result};
            const ret = c.call(ctx, resolve_fn, c.JS_UNDEFINED, 1, &args);
            c.freeValue(ctx, ret);
        }
    }
    if (c.isUndefined(result) == 0 and c.isException(result) == 0) c.freeValue(ctx, result);
    c.freeValue(ctx, resolve_fn);
    c.freeValue(ctx, reject_fn);
}

fn putExit(ctx: ?*c.Context, obj: c.Value, code: ?u8, sig: ?SIG) void {
    _ = c.definePropertyValueStr(ctx, obj, "code", if (code) |v| c.newInt64(ctx, v) else c.JS_NULL, c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "signal", if (sig) |v| sigToValue(ctx, v) else c.JS_NULL, c.PROP_C_W_E);
}

fn bytesToJs(ctx: ?*c.Context, bytes: []const u8) c.Value {
    if (bytes.len == 0) return c.newStringLen(ctx, "", 0);
    return c.newStringLen(ctx, bytes.ptr, bytes.len);
}

fn sigToValue(ctx: ?*c.Context, sig: SIG) c.Value {
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "SIG{s}", .{@tagName(sig)}) catch "SIG";
    return c.newStringLen(ctx, s.ptr, s.len);
}

fn rejectWith(ctx: ?*c.Context, reject_fn: c.Value, msg: []const u8) void {
    if (c.isUndefined(reject_fn) != 0 or c.isException(reject_fn) != 0) return;
    const err = c.newError(ctx);
    if (c.isException(err) != 0) return;
    const m = c.newStringLen(ctx, msg.ptr, msg.len);
    _ = c.setPropertyStr(ctx, err, "message", m);
    var args = [1]c.Value{err};
    const ret = c.call(ctx, reject_fn, c.JS_UNDEFINED, 1, &args);
    c.freeValue(ctx, ret);
    c.freeValue(ctx, err);
}

fn throwError(ctx: ?*c.Context, comptime fmt: []const u8, args: anytype) c.Value {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    const err = c.newError(ctx);
    if (c.isException(err) != 0) return c.JS_EXCEPTION;
    const m = c.newStringLen(ctx, msg.ptr, msg.len);
    _ = c.setPropertyStr(ctx, err, "message", m);
    _ = c.throw(ctx, err);
    return c.JS_EXCEPTION;
}

// ── plan building (spawn-time staging arena) ────────────────────────

const Plan = struct {
    argv: []const []const u8,
    cwd: std.process.Child.Cwd = .inherit,
    env: ?*std.process.Environ.Map = null,
    pipe: bool = true,
    max_buffer: usize = DEFAULT_MAX_BUFFER,
};

const ExecCtx = struct {
    promise: c.Value,
    resolve: c.Value,
    reject: c.Value,
};

var spawn_arena: std.heap.ArenaAllocator = undefined;
var spawn_arena_ready = false;

fn arenaAlloc() std.mem.Allocator {
    if (!spawn_arena_ready) {
        spawn_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        spawn_arena_ready = true;
    } else {
        _ = spawn_arena.reset(.retain_capacity);
    }
    return spawn_arena.allocator();
}

fn jsStringCopy(ctx: ?*c.Context, val: c.Value, a: std.mem.Allocator) ?[]const u8 {
    var len: usize = 0;
    const p = c.toCStringLen(ctx, &len, val) orelse return null;
    defer c.freeCString(ctx, p);
    return a.dupe(u8, p[0..len]) catch null;
}

fn buildArgv(ctx: ?*c.Context, a: std.mem.Allocator, command: c.Value, args_val: c.Value) ?[]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    const exe = jsStringCopy(ctx, command, a) orelse return null;
    list.append(a, exe) catch return null;
    if (c.isArray(ctx, args_val) != 0) {
        const len_val = c.getPropertyStr(ctx, args_val, "length");
        defer c.freeValue(ctx, len_val);
        var count: u32 = 0;
        if (c.toUint32(ctx, &count, len_val) != 0) return null;
        var k: u32 = 0;
        while (k < count) : (k += 1) {
            const item = c.getPropertyUint32(ctx, args_val, k);
            defer c.freeValue(ctx, item);
            if (c.isString(item) == 0) return null;
            const s = jsStringCopy(ctx, item, a) orelse return null;
            list.append(a, s) catch return null;
        }
    }
    return list.items;
}

fn buildEnv(ctx: ?*c.Context, a: std.mem.Allocator, obj: c.Value) ?*std.process.Environ.Map {
    const map = a.create(std.process.Environ.Map) catch return null;
    map.* = std.process.Environ.Map.init(a);
    var tab: [*c]c.PropertyEnum = undefined;
    var tlen: u32 = 0;
    if (c.getOwnPropertyNames(ctx, &tab, &tlen, obj, c.GPN_STRING_MASK) != 0) return null;
    defer c.freePropertyEnum(ctx, tab, tlen);
    var k: u32 = 0;
    while (k < tlen) : (k += 1) {
        const atom = tab[k].atom;
        var klen: usize = 0;
        const kptr = c.atomToCStringLen(ctx, &klen, atom) orelse continue;
        defer c.freeCString(ctx, kptr);
        const v = c.getProperty(ctx, obj, atom);
        defer c.freeValue(ctx, v);
        if (c.isException(v) != 0) return null;
        const vstr = c.toString(ctx, v);
        defer c.freeValue(ctx, vstr);
        if (c.isException(vstr) != 0) return null;
        var vlen: usize = 0;
        const vptr = c.toCStringLen(ctx, &vlen, vstr) orelse return null;
        defer c.freeCString(ctx, vptr);
        const key = a.dupe(u8, kptr[0..klen]) catch return null;
        const value = a.dupe(u8, vptr[0..vlen]) catch return null;
        map.put(key, value) catch return null;
    }
    return map;
}

fn parseOptionsInto(ctx: ?*c.Context, a: std.mem.Allocator, plan: *Plan, opts: c.Value) bool {
    if (c.isUndefined(opts) != 0 or c.isNull(opts) != 0) return true;
    if (c.isObject(opts) == 0) {
        _ = c.throwTypeError(ctx, "options must be an object");
        return false;
    }
    const cwd_v = c.getPropertyStr(ctx, opts, "cwd");
    defer c.freeValue(ctx, cwd_v);
    if (c.isString(cwd_v) != 0) {
        plan.cwd = .{ .path = jsStringCopy(ctx, cwd_v, a) orelse return false };
    } else if (c.isUndefined(cwd_v) == 0 and c.isNull(cwd_v) == 0) {
        _ = c.throwTypeError(ctx, "cwd must be a string");
        return false;
    }
    const env_v = c.getPropertyStr(ctx, opts, "env");
    defer c.freeValue(ctx, env_v);
    if (c.isNull(env_v) == 0 and c.isObject(env_v) != 0) {
        plan.env = buildEnv(ctx, a, env_v) orelse return false;
    }
    const stdio_v = c.getPropertyStr(ctx, opts, "stdio");
    defer c.freeValue(ctx, stdio_v);
    if (c.isString(stdio_v) != 0) {
        var l: usize = 0;
        const p = c.toCStringLen(ctx, &l, stdio_v) orelse return false;
        defer c.freeCString(ctx, p);
        const m = p[0..l];
        if (std.mem.eql(u8, m, "pipe")) {
            plan.pipe = true;
        } else if (std.mem.eql(u8, m, "inherit")) {
            plan.pipe = false;
        } else {
            _ = c.throwTypeError(ctx, "stdio must be 'pipe' or 'inherit'");
            return false;
        }
    }
    const mb_v = c.getPropertyStr(ctx, opts, "maxBuffer");
    defer c.freeValue(ctx, mb_v);
    if (c.isNumber(mb_v) != 0) {
        var f: f64 = 0;
        if (c.toFloat64(ctx, &f, mb_v) != 0) return false;
        if (f < 0 or std.math.isNan(f)) {
            _ = c.throwRangeError(ctx, "maxBuffer must be >= 0");
            return false;
        }
        plan.max_buffer = if (std.math.isInf(f) or f >= @as(f64, @floatFromInt(std.math.maxInt(usize))))
            std.math.maxInt(usize)
        else
            @intFromFloat(f);
    }
    return true;
}

// ── launch ──────────────────────────────────────────────────────────

fn launch(ctx: ?*c.Context, plan: *const Plan, xc: ?ExecCtx) c.Value {
    if (perm.global().checkRun(plan.argv[0]) == .denied) {
        if (xc) |x| {
            c.freeValue(ctx, x.reject);
            c.freeValue(ctx, x.resolve);
            c.freeValue(ctx, x.promise);
        }
        return deny.throw(ctx, "child_process", .run, plan.argv[0]);
    }

    const i = acquireSlot() orelse {
        if (xc) |x| {
            rejectWith(ctx, x.reject, "too many child processes (max 8)");
            c.freeValue(ctx, x.reject);
            c.freeValue(ctx, x.resolve);
            return x.promise;
        }
        return throwError(ctx, "too many child processes (max {d})", .{MAX_CHILDREN});
    };
    const s = &slots[i];
    s.flags.exec_mode = xc != null;
    s.flags.capture = plan.pipe;
    s.max_buffer = plan.max_buffer;

    const child = std.process.spawn(getIo(), .{
        .argv = plan.argv,
        .cwd = plan.cwd,
        .environ_map = plan.env,
        .stdin = .ignore,
        .stdout = if (plan.pipe) .pipe else .inherit,
        .stderr = if (plan.pipe) .pipe else .inherit,
    }) catch |err| {
        releaseSlot(ctx, i);
        if (xc) |x| {
            rejectWith(ctx, x.reject, @errorName(err));
            c.freeValue(ctx, x.reject);
            c.freeValue(ctx, x.resolve);
            return x.promise;
        }
        return throwError(ctx, "spawn failed: {s}", .{@errorName(err)});
    };

    s.pid = child.id.?;
    if (plan.pipe) {
        s.out_fd = @intCast(child.stdout.?.handle);
        s.err_fd = @intCast(child.stderr.?.handle);
        s.flags.out_open = true;
        s.flags.err_open = true;
        s.out_stream = xev.Stream.initFd(s.out_fd);
        s.err_stream = xev.Stream.initFd(s.err_fd);
    }

    var child_obj = c.JS_UNDEFINED;
    if (xc) |x| {
        s.resolve = x.resolve;
        s.reject = x.reject;
    } else {
        child_obj = makeChildObj(ctx, i);
        if (c.isException(child_obj) != 0) {
            // OOM-path only, before any read is armed. Reap synchronously.
            std.posix.kill(s.pid, .KILL) catch {};
            var st: c_int = 0;
            _ = std.c.waitpid(s.pid, &st, 0);
            releaseSlot(ctx, i);
            return child_obj;
        }
        s.js_obj = child_obj;
    }

    states[i] = ST_RUNNING;
    live += 1;
    _ = stat_spawned.fetchAdd(1, .monotonic);
    armSigchld();
    if (plan.pipe) {
        armRead(i, true);
        armRead(i, false);
    }
    if (xc) |x| return x.promise;
    return c.dupValue(ctx, child_obj);
}

fn makeChildObj(ctx: ?*c.Context, i: usize) c.Value {
    const obj = c.newObjectClass(ctx, @intCast(child_class_id));
    if (c.isException(obj) != 0) return obj;
    c.setOpaque(obj, @ptrFromInt(i + 1));
    _ = c.definePropertyValueStr(ctx, obj, "$gen", c.newInt64(ctx, gens[i]), c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
    _ = c.definePropertyValueStr(ctx, obj, "pid", c.newInt64(ctx, @intCast(slots[i].pid)), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "exitCode", c.JS_NULL, c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "signalCode", c.JS_NULL, c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "truncated", c.JS_FALSE, c.PROP_C_W_E);
    return obj;
}

// ── JS entries ──────────────────────────────────────────────────────

fn jsSpawn(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 1 or c.isString(argv[0]) == 0) {
        _ = c.throwTypeError(ctx, "spawn requires a command string");
        return c.JS_EXCEPTION;
    }
    if (builtin.os.tag == .windows) return throwError(ctx, "child_process is POSIX-only", .{});

    const a = arenaAlloc();
    const args_val = if (argc >= 2) argv[1] else c.JS_UNDEFINED;
    if (c.isUndefined(args_val) == 0 and c.isNull(args_val) == 0 and c.isArray(ctx, args_val) == 0) {
        _ = c.throwTypeError(ctx, "args must be an array of strings");
        return c.JS_EXCEPTION;
    }
    var plan = Plan{ .argv = buildArgv(ctx, a, argv[0], args_val) orelse {
        if (!c.hasException(ctx)) _ = c.throwTypeError(ctx, "args must be strings");
        return c.JS_EXCEPTION;
    } };
    const opts_val = if (argc >= 3) argv[2] else c.JS_UNDEFINED;
    if (!parseOptionsInto(ctx, a, &plan, opts_val)) return c.JS_EXCEPTION;
    return launch(ctx, &plan, null);
}

fn jsExec(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 1 or c.isString(argv[0]) == 0) {
        _ = c.throwTypeError(ctx, "exec requires a command string");
        return c.JS_EXCEPTION;
    }
    if (builtin.os.tag == .windows) return throwError(ctx, "child_process is POSIX-only", .{});

    var cap: [2]c.Value = .{ c.JS_UNDEFINED, c.JS_UNDEFINED };
    const promise = c.newPromiseCapability(ctx, &cap);
    if (c.isException(promise) != 0) return promise;

    const a = arenaAlloc();
    const cmd = jsStringCopy(ctx, argv[0], a) orelse {
        c.freeValue(ctx, cap[0]);
        c.freeValue(ctx, cap[1]);
        c.freeValue(ctx, promise);
        return c.JS_EXCEPTION;
    };
    const argv_list = a.alloc([]const u8, 3) catch {
        c.freeValue(ctx, cap[0]);
        c.freeValue(ctx, cap[1]);
        c.freeValue(ctx, promise);
        return c.JS_EXCEPTION;
    };
    argv_list[0] = "/bin/sh";
    argv_list[1] = "-c";
    argv_list[2] = cmd;
    var plan = Plan{ .argv = argv_list, .pipe = true };
    const opts_val = if (argc >= 2) argv[1] else c.JS_UNDEFINED;
    if (!parseOptionsInto(ctx, a, &plan, opts_val)) {
        c.freeValue(ctx, cap[0]);
        c.freeValue(ctx, cap[1]);
        c.freeValue(ctx, promise);
        return c.JS_EXCEPTION;
    }
    plan.pipe = true;
    return launch(ctx, &plan, .{ .promise = promise, .resolve = cap[0], .reject = cap[1] });
}

fn jsExecSync(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 1 or c.isString(argv[0]) == 0) {
        _ = c.throwTypeError(ctx, "execSync requires a command string");
        return c.JS_EXCEPTION;
    }
    if (builtin.os.tag == .windows) return throwError(ctx, "child_process is POSIX-only", .{});

    const a = arenaAlloc();
    const cmd = jsStringCopy(ctx, argv[0], a) orelse return c.JS_EXCEPTION;
    var list = [3][]const u8{ "/bin/sh", "-c", cmd };
    var plan = Plan{ .argv = list[0..] };
    const opts_val = if (argc >= 2) argv[1] else c.JS_UNDEFINED;
    if (!parseOptionsInto(ctx, a, &plan, opts_val)) return c.JS_EXCEPTION;

    if (perm.global().checkRun(plan.argv[0]) == .denied)
        return deny.throw(ctx, "child_process.execSync", .run, plan.argv[0]);

    const limit: Io.Limit = if (plan.max_buffer == std.math.maxInt(usize)) .unlimited else .limited(plan.max_buffer);
    const res = std.process.run(gpa, getIo(), .{
        .argv = plan.argv,
        .cwd = plan.cwd,
        .environ_map = plan.env,
        .stdout_limit = limit,
        .stderr_limit = limit,
        .reserve_amount = 64 * 1024,
    }) catch |err| switch (err) {
        error.StreamTooLong => return throwError(ctx, "maxBuffer exceeded", .{}),
        else => return throwError(ctx, "execSync failed: {s}", .{@errorName(err)}),
    };
    _ = stat_spawned.fetchAdd(1, .monotonic);
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);

    const obj = c.newObject(ctx);
    if (c.isException(obj) != 0) return obj;
    _ = c.definePropertyValueStr(ctx, obj, "stdout", bytesToJs(ctx, res.stdout), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "stderr", bytesToJs(ctx, res.stderr), c.PROP_C_W_E);
    switch (res.term) {
        .exited => |v| putExit(ctx, obj, v, null),
        .signal => |v| putExit(ctx, obj, null, v),
        else => putExit(ctx, obj, null, null),
    }
    return obj;
}

const ThisKind = union(enum) { stale, slot: usize };

fn validateThis(ctx: ?*c.Context, this_val: c.Value) ?ThisKind {
    const p = c.getOpaque(this_val, child_class_id) orelse return null;
    const i = @intFromPtr(p) - 1;
    if (i >= MAX_CHILDREN) return null;
    const gen_prop = c.getPropertyStr(ctx, this_val, "$gen");
    defer c.freeValue(ctx, gen_prop);
    if (c.isException(gen_prop) != 0) return null;
    var g: i64 = 0;
    if (c.toInt64(ctx, &g, gen_prop) != 0) return null;
    if (states[i] == ST_FREE or g != gens[i]) return .stale;
    return .{ .slot = i };
}

fn parseSignalName(name_in: []const u8) ?SIG {
    var name = name_in;
    if (name.len > 3 and std.ascii.eqlIgnoreCase(name[0..3], "SIG")) name = name[3..];
    if (name.len == 0 or name.len > 12) return null;
    var buf: [12]u8 = undefined;
    for (name, 0..) |ch, k| buf[k] = std.ascii.toUpper(ch);
    return std.meta.stringToEnum(SIG, buf[0..name.len]);
}

fn parseSignal(ctx: ?*c.Context, val: c.Value) ?SIG {
    if (c.isNumber(val) != 0) {
        var num: i64 = 0;
        if (c.toInt64(ctx, &num, val) != 0) return null;
        if (num <= 0 or num > 1024) return null;
        return std.enums.fromInt(SIG, num);
    }
    if (c.isString(val) == 0) return null;
    var len: usize = 0;
    const p = c.toCStringLen(ctx, &len, val) orelse return null;
    defer c.freeCString(ctx, p);
    return parseSignalName(p[0..len]);
}

fn jsKill(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const kind = validateThis(ctx, this_val) orelse {
        _ = c.throwTypeError(ctx, "kill called on a non-Child value");
        return c.JS_EXCEPTION;
    };
    switch (kind) {
        .stale => return c.JS_FALSE,
        .slot => |i| {
            if (states[i] != ST_RUNNING) return c.JS_FALSE;
            var sig: SIG = .TERM;
            if (argc >= 1 and c.isUndefined(argv[0]) == 0) {
                sig = parseSignal(ctx, argv[0]) orelse {
                    _ = c.throwTypeError(ctx, "unknown signal");
                    return c.JS_EXCEPTION;
                };
            }
            std.posix.kill(slots[i].pid, sig) catch return c.JS_FALSE;
            return c.JS_TRUE;
        },
    }
}

fn jsWait(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = argc;
    _ = argv;
    const kind = validateThis(ctx, this_val) orelse {
        _ = c.throwTypeError(ctx, "wait called on a non-Child value");
        return c.JS_EXCEPTION;
    };
    switch (kind) {
        .stale => return resolvedFromProps(ctx, this_val),
        .slot => |i| {
            if (slots[i].flags.exec_mode) {
                _ = c.throwTypeError(ctx, "wait is only for spawn(); exec() already returns a promise");
                return c.JS_EXCEPTION;
            }
            if (c.isUndefined(slots[i].wait_promise) != 0) {
                var cap: [2]c.Value = .{ c.JS_UNDEFINED, c.JS_UNDEFINED };
                const promise = c.newPromiseCapability(ctx, &cap);
                if (c.isException(promise) != 0) return promise;
                c.freeValue(ctx, cap[1]); // wait never rejects
                slots[i].wait_promise = promise;
                slots[i].resolve = cap[0];
            }
            return c.dupValue(ctx, slots[i].wait_promise);
        },
    }
}

fn resolvedFromProps(ctx: ?*c.Context, this_val: c.Value) c.Value {
    var cap: [2]c.Value = .{ c.JS_UNDEFINED, c.JS_UNDEFINED };
    const promise = c.newPromiseCapability(ctx, &cap);
    if (c.isException(promise) != 0) return promise;
    const obj = c.newObject(ctx);
    const code_prop = c.getPropertyStr(ctx, this_val, "exitCode");
    _ = c.definePropertyValueStr(ctx, obj, "code", code_prop, c.PROP_C_W_E);
    const sig_prop = c.getPropertyStr(ctx, this_val, "signalCode");
    _ = c.definePropertyValueStr(ctx, obj, "signal", sig_prop, c.PROP_C_W_E);
    var args = [1]c.Value{obj};
    const ret = c.call(ctx, cap[0], c.JS_UNDEFINED, 1, &args);
    c.freeValue(ctx, ret);
    c.freeValue(ctx, obj);
    c.freeValue(ctx, cap[0]);
    c.freeValue(ctx, cap[1]);
    return promise;
}

// ── unit tests (registered in src/unit_tests.zig) ───────────────────

test "decodeStatus" {
    try std.testing.expectEqual(@as(?u8, 3), decodeStatus(3 << 8).code);
    try std.testing.expectEqual(@as(?SIG, null), decodeStatus(3 << 8).sig);
    const killed = decodeStatus(15);
    try std.testing.expectEqual(@as(?u8, null), killed.code);
    try std.testing.expectEqual(@as(?SIG, .TERM), killed.sig);
}

test "parseSignalName" {
    try std.testing.expectEqual(@as(?SIG, .TERM), parseSignalName("SIGTERM"));
    try std.testing.expectEqual(@as(?SIG, .TERM), parseSignalName("term"));
    try std.testing.expectEqual(@as(?SIG, .KILL), parseSignalName("SIGKILL"));
    try std.testing.expectEqual(@as(?SIG, null), parseSignalName("SIGBOGUS"));
    try std.testing.expectEqual(@as(?SIG, null), parseSignalName(""));
}
