const std = @import("std");
const xev = @import("xev");
const c = @import("../c.zig").c;
const builtin = @import("builtin");
const perm = @import("../security/permissions.zig");
const deny = @import("../security/deny.zig");
const microtasks = @import("../event/microtasks.zig");
// C3: stat counters live in the net modules (verified: nothing in their
// import closures references api/process, so no cycle).
const async_fetch = @import("../net/async_fetch.zig");
const http_native = @import("../net/http_native.zig");
const pg_client = @import("../net/pg_client.zig");
const child_process = @import("child_process.zig");

const Io = std.Io;

const gpa = std.heap.smp_allocator;

// ── Signal handling (SoA, static caps, async-signal-safe wakeup) ────
const NUM_SIGNALS = 5;
const MAX_SIG_LISTENERS = 8;

const sig_names = [NUM_SIGNALS][]const u8{
    "SIGINT",
    "SIGTERM",
    "SIGHUP",
    "SIGUSR1",
    "SIGUSR2",
};

const sig_codes = [NUM_SIGNALS]std.posix.SIG{
    .INT,
    .TERM,
    .HUP,
    .USR1,
    .USR2,
};

var sig_listeners: [NUM_SIGNALS][MAX_SIG_LISTENERS]c.Value =
    [_][MAX_SIG_LISTENERS]c.Value{[_]c.Value{c.JS_UNDEFINED} ** MAX_SIG_LISTENERS} ** NUM_SIGNALS;
var sig_once: [NUM_SIGNALS][MAX_SIG_LISTENERS]bool =
    [_][MAX_SIG_LISTENERS]bool{[_]bool{false} ** MAX_SIG_LISTENERS} ** NUM_SIGNALS;
var sig_count: [NUM_SIGNALS]u8 = [_]u8{0} ** NUM_SIGNALS;
var sig_installed: [NUM_SIGNALS]bool = [_]bool{false} ** NUM_SIGNALS;

var pending_signals: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var sig_async: xev.Async = undefined;
var sig_async_inited: bool = false;
var sig_async_armed: bool = false;
var sig_async_comp: xev.Completion = .{};
var g_loop: ?*xev.Loop = null;

fn signalIndexFromName(name: []const u8) ?usize {
    for (sig_names, 0..) |sn, i| {
        if (std.mem.eql(u8, name, sn)) return i;
    }
    return null;
}

fn posixSignalHandler(sig: std.posix.SIG) callconv(.c) void {
    for (sig_codes, 0..) |sc, i| {
        if (sig == sc) {
            _ = pending_signals.fetchOr(@as(u32, 1) << @intCast(i), .release);
            break;
        }
    }
    if (sig_async_inited) {
        sig_async.notify() catch {};
    }
}

fn sigAsyncCb(
    _: ?*void,
    l: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch {
        sig_async_armed = false;
        return .disarm;
    };
    sig_async.wait(l, &sig_async_comp, void, null, sigAsyncCb);
    sig_async_armed = true;
    return .disarm;
}

fn ensureSignalWatcher() void {
    const l = g_loop orelse return;
    if (!sig_async_inited) {
        sig_async = xev.Async.init() catch return;
        sig_async_inited = true;
    }
    if (!sig_async_armed) {
        sig_async_armed = true;
        sig_async.wait(l, &sig_async_comp, void, null, sigAsyncCb);
    }
}

fn installSignalIdx(idx: usize) void {
    ensureSignalWatcher();
    if (sig_installed[idx]) return;
    sig_installed[idx] = true;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = posixSignalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(sig_codes[idx], &act, null);
}

pub fn setLoop(l: *xev.Loop) void {
    g_loop = l;
}

/// Armed automatically by `http.serve` so SIGINT/SIGTERM trigger graceful drain
/// even when the script did not explicitly call `process.on('SIGTERM', ...)`.
pub fn enableServerSignalTrap() void {
    installSignalIdx(0); // SIGINT
    installSignalIdx(1); // SIGTERM
}

/// Included in loop.zig's `unrefArmed()` so the signal watcher does not hold
/// the event loop open once all servers, timers, and I/O have finished.
pub inline fn unrefSignalCount() usize {
    if (sig_async_armed and pending_signals.load(.acquire) == 0) return 1;
    return 0;
}

pub fn drainSignals(ctx: *c.Context) void {
    const bits = pending_signals.swap(0, .acq_rel);
    if (bits == 0) return;

    for (0..NUM_SIGNALS) |idx| {
        if ((bits & (@as(u32, 1) << @intCast(idx))) == 0) continue;

        const cnt = sig_count[idx];
        if (cnt == 0) {
            // Default signal-driven graceful shutdown for SIGINT / SIGTERM.
            if (idx == 0 or idx == 1) {
                if (http_native.isRunning()) {
                    http_native.closeServer();
                } else {
                    std.process.exit(if (idx == 0) 130 else 143);
                }
            }
            continue;
        }

        // Snapshot listeners in case a listener mutates the array via off/once.
        var fns: [MAX_SIG_LISTENERS]c.Value = undefined;
        var n_call: usize = 0;
        var write_i: usize = 0;
        for (0..cnt) |i| {
            const fn_val = sig_listeners[idx][i];
            fns[n_call] = c.dupValue(ctx, fn_val);
            n_call += 1;
            if (sig_once[idx][i]) {
                c.freeValue(ctx, fn_val);
            } else {
                sig_listeners[idx][write_i] = fn_val;
                sig_once[idx][write_i] = false;
                write_i += 1;
            }
        }
        sig_count[idx] = @intCast(write_i);

        var sig_str = zigStringToVal(ctx, sig_names[idx]);
        defer c.freeValue(ctx, sig_str);

        for (fns[0..n_call]) |fn_val| {
            const ret = c.call(ctx, fn_val, c.JS_UNDEFINED, 1, @ptrCast(&sig_str));
            c.freeValue(ctx, fn_val);
            if (c.isException(ret) != 0) {
                microtasks.reportUncaught(ctx, "signal handler error");
            } else {
                c.freeValue(ctx, ret);
            }
        }
        microtasks.pumpMicrotasks(ctx);
    }
}

pub fn deinit(ctx: *c.Context) void {
    for (0..NUM_SIGNALS) |idx| {
        for (0..sig_count[idx]) |i| {
            c.freeValue(ctx, sig_listeners[idx][i]);
            sig_listeners[idx][i] = c.JS_UNDEFINED;
            sig_once[idx][i] = false;
        }
        sig_count[idx] = 0;
    }
    _ = pending_signals.store(0, .release);
    sig_async_armed = false;
    g_loop = null;
}

fn addSignalListener(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value, once: bool) c.Value {
    if (argc < 2 or c.isString(argv[0]) == 0 or c.isFunction(ctx, argv[1]) == 0) {
        _ = c.throwTypeError(ctx, "process.on requires (signalName, callback)");
        return c.JS_EXCEPTION;
    }
    var len: usize = 0;
    const cstr = c.toCStringLen(ctx, &len, argv[0]) orelse return c.JS_EXCEPTION;
    defer c.freeCString(ctx, cstr);
    const idx = signalIndexFromName(cstr[0..len]) orelse {
        _ = c.throwRangeError(ctx, "Unsupported signal (supported: SIGINT, SIGTERM, SIGHUP, SIGUSR1, SIGUSR2)");
        return c.JS_EXCEPTION;
    };
    const cnt = sig_count[idx];
    if (cnt >= MAX_SIG_LISTENERS) {
        _ = c.throwRangeError(ctx, "Max signal listeners (8) exceeded");
        return c.JS_EXCEPTION;
    }
    installSignalIdx(idx);
    sig_listeners[idx][cnt] = c.dupValue(ctx, argv[1]);
    sig_once[idx][cnt] = once;
    sig_count[idx] = cnt + 1;
    return c.dupValue(ctx, this_val);
}

fn processOnCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    return addSignalListener(ctx, this_val, argc, argv, false);
}

fn processOnceCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    return addSignalListener(ctx, this_val, argc, argv, true);
}

fn processOffCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    if (argc < 2 or c.isString(argv[0]) == 0) return c.dupValue(ctx, this_val);
    var len: usize = 0;
    const cstr = c.toCStringLen(ctx, &len, argv[0]) orelse return c.dupValue(ctx, this_val);
    defer c.freeCString(ctx, cstr);
    const idx = signalIndexFromName(cstr[0..len]) orelse return c.dupValue(ctx, this_val);
    const target = argv[1];
    const cnt = sig_count[idx];
    for (0..cnt) |i| {
        if (sig_listeners[idx][i].u.ptr == target.u.ptr and sig_listeners[idx][i].tag == target.tag) {
            c.freeValue(ctx, sig_listeners[idx][i]);
            var j: usize = i;
            while (j + 1 < cnt) : (j += 1) {
                sig_listeners[idx][j] = sig_listeners[idx][j + 1];
                sig_once[idx][j] = sig_once[idx][j + 1];
            }
            sig_count[idx] = cnt - 1;
            break;
        }
    }
    return c.dupValue(ctx, this_val);
}

fn processKillCallback(ctx: ?*c.Context, _: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    if (argc < 1) {
        _ = c.throwTypeError(ctx, "process.kill requires a pid");
        return c.JS_EXCEPTION;
    }
    var pid_i64: i64 = 0;
    if (c.toInt64(ctx, &pid_i64, argv[0]) != 0 or pid_i64 <= 0) {
        _ = c.throwRangeError(ctx, "process.kill: invalid pid");
        return c.JS_EXCEPTION;
    }
    const target_pid: std.posix.pid_t = @intCast(pid_i64);
    if (target_pid != std.c.getpid()) {
        if (perm.global().checkRun("kill") == .denied) {
            return deny.throw(ctx, "process.kill", .run, "kill");
        }
    }
    var sig: std.posix.SIG = .TERM;
    if (argc >= 2 and c.isUndefined(argv[1]) == 0) {
        if (c.isString(argv[1]) != 0) {
            var slen: usize = 0;
            const scstr = c.toCStringLen(ctx, &slen, argv[1]) orelse return c.JS_EXCEPTION;
            defer c.freeCString(ctx, scstr);
            const idx = signalIndexFromName(scstr[0..slen]) orelse {
                _ = c.throwRangeError(ctx, "process.kill: unknown signal");
                return c.JS_EXCEPTION;
            };
            sig = sig_codes[idx];
        } else {
            var sig_num: i32 = 15;
            _ = c.toInt32(ctx, &sig_num, argv[1]);
            sig = @enumFromInt(sig_num);
        }
    }
    std.posix.kill(target_pid, sig) catch {
        _ = c.throwTypeError(ctx, "process.kill failed");
        return c.JS_EXCEPTION;
    };
    return c.JS_TRUE;
}

fn getIo() Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn throwErr(ctx: ?*c.Context, msg: []const u8) void {
    const msg_val = c.newStringLen(ctx, msg.ptr, msg.len);
    _ = c.throw(ctx, msg_val);
}

fn zigStringToVal(ctx: ?*c.Context, str: []const u8) c.Value {
    return c.newStringLen(ctx, str.ptr, @intCast(str.len));
}

fn extractString(ctx: ?*c.Context, argc: c_int, argv: [*c]const c.Value, index: c_int) ?[:0]const u8 {
    if (argc <= index) return null;
    const val = argv[@intCast(index)];
    if (c.isString(val) == 0) return null;
    var str_len: usize = 0;
    const str_ptr = c.toCStringLen(ctx, &str_len, val) orelse return null;
    defer c.freeCString(ctx, str_ptr);

    if (std.mem.indexOfScalar(u8, str_ptr[0..str_len], 0) != null) {
        throwErr(ctx, "path contains a NUL byte");
        return null;
    }
    if (str_len >= std.fs.max_path_bytes) {
        throwErr(ctx, "path too long");
        return null;
    }

    return gpa.dupeZ(u8, str_ptr[0..str_len]) catch null;
}

fn exitCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    var code: u8 = 0;
    if (argc > 0) {
        var pres: i64 = 0;
        _ = c.toInt64(ctx, &pres, argv[0]);
        const clamped: i64 = @max(0, @min(pres, 255));
        code = @intCast(clamped);
    }
    std.process.exit(code);
}

fn cwdCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    _ = argc;
    _ = argv;
    const io = getIo();
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const len = std.process.currentPath(io, &buf) catch {
        throwErr(ctx, "getcwd failed");
        return c.JS_UNDEFINED;
    };
    return zigStringToVal(ctx, buf[0..len]);
}

fn chdirCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    const path = extractString(ctx, argc, argv, 0) orelse {
        if (c.hasException(ctx)) return c.JS_EXCEPTION;
        throwErr(ctx, "chdir requires a path argument");
        return c.JS_UNDEFINED;
    };
    defer gpa.free(path);

    if (perm.global().checkPath(.read, path) == .denied)
        return deny.throw(ctx, "process.chdir", .read, path);

    const io = getIo();
    std.process.setCurrentPath(io, path) catch {
        throwErr(ctx, "chdir failed");
        return c.JS_UNDEFINED;
    };
    perm.refreshCwd();
    return c.JS_UNDEFINED;
}

// C3 FIX: expose the TB §5 spill/reuse counters to JS (works in Release
// too — the Debug stderr dumps don't). Key names match what
// bench/fetch_spill.js expects: fetch.bodyHeap, fetch.hdrSpill,
// fetch.decompressHeap, http.bodySpill, http.bodySpillReuse,
// http.reqSpill, http.reqSpillReuse, pg.*.
// JS_NewInt64 takes i64: the u64 counters need @intCast (same-width
// signed/unsigned does not coerce); pg's u32 counters widen implicitly.
fn statsCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    _ = argc;
    _ = argv;
    const root = c.newObject(ctx);

    const fetch_obj = c.newObject(ctx);
    _ = c.definePropertyValueStr(ctx, fetch_obj, "bodyHeap", c.newInt64(ctx, @intCast(async_fetch.stat_body_heap.load(.monotonic))), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, fetch_obj, "hdrSpill", c.newInt64(ctx, @intCast(async_fetch.stat_hdr_spill.load(.monotonic))), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, fetch_obj, "decompressHeap", c.newInt64(ctx, @intCast(async_fetch.stat_decompress_heap.load(.monotonic))), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, root, "fetch", fetch_obj, c.PROP_C_W_E);

    const http_obj = c.newObject(ctx);
    _ = c.definePropertyValueStr(ctx, http_obj, "bodySpill", c.newInt64(ctx, @intCast(http_native.stat_body_spill.load(.monotonic))), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, http_obj, "bodySpillReuse", c.newInt64(ctx, @intCast(http_native.stat_body_spill_reuse.load(.monotonic))), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, http_obj, "reqSpill", c.newInt64(ctx, @intCast(http_native.stat_req_spill.load(.monotonic))), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, http_obj, "reqSpillReuse", c.newInt64(ctx, @intCast(http_native.stat_req_spill_reuse.load(.monotonic))), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, root, "http", http_obj, c.PROP_C_W_E);

    const pg_obj = c.newObject(ctx);
    _ = c.definePropertyValueStr(ctx, pg_obj, "submit", c.newInt64(ctx, pg_client.stat_submit.load(.monotonic)), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, pg_obj, "jobReuse", c.newInt64(ctx, pg_client.stat_job_reuse.load(.monotonic)), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, pg_obj, "jobFresh", c.newInt64(ctx, pg_client.stat_job_fresh.load(.monotonic)), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, pg_obj, "wqueueGrow", c.newInt64(ctx, pg_client.stat_wqueue_grow.load(.monotonic)), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, pg_obj, "wqueueShrink", c.newInt64(ctx, pg_client.stat_wqueue_shrink.load(.monotonic)), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, pg_obj, "waitEnqueue", c.newInt64(ctx, pg_client.stat_wait_enqueue.load(.monotonic)), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, pg_obj, "arenaResetFail", c.newInt64(ctx, pg_client.stat_arena_reset_fail.load(.monotonic)), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, pg_obj, "freelistDestroy", c.newInt64(ctx, pg_client.stat_freelist_destroy.load(.monotonic)), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, root, "pg", pg_obj, c.PROP_C_W_E);
    const child_obj = c.newObject(ctx);
    _ = c.definePropertyValueStr(ctx, child_obj, "spawned", c.newInt64(ctx, @intCast(child_process.stat_spawned.load(.monotonic))), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, child_obj, "truncated", c.newInt64(ctx, @intCast(child_process.stat_truncated.load(.monotonic))), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, child_obj, "outHeap", c.newInt64(ctx, @intCast(child_process.stat_out_heap.load(.monotonic))), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, root, "child", child_obj, c.PROP_C_W_E);
    return root;
}

// C3 FIX: docs/guides/process.md claimed "nothing for RSS" —
// bench/streams/streams_bench.js already calls process.memoryUsage().rss.
// getrusage(0): who=0 is RUSAGE_SELF/SELF on every POSIX target.
fn memoryUsageCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    _ = argc;
    _ = argv;
    const ru = std.posix.getrusage(0);
    const raw: i64 = @max(ru.maxrss, 0);
    // Linux reports KiB, Darwin reports bytes — normalize to bytes.
    const rss: u64 = switch (builtin.os.tag) {
        .linux => @as(u64, @intCast(raw)) * 1024,
        else => @intCast(raw),
    };
    const obj = c.newObject(ctx);
    _ = c.definePropertyValueStr(ctx, obj, "rss", c.newInt64(ctx, @intCast(rss)), c.PROP_C_W_E);
    return obj;
}

pub fn setup(ctx: *c.Context, args: std.process.Args) void {
    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);
    const process_obj = c.newObject(ctx);

    const exit_fn = c.newCFunction(ctx, exitCallback, "exit", 1);
    _ = c.definePropertyValueStr(ctx, process_obj, "exit", exit_fn, c.PROP_C_W_E);

    const cwd_fn = c.newCFunction(ctx, cwdCallback, "cwd", 0);
    _ = c.definePropertyValueStr(ctx, process_obj, "cwd", cwd_fn, c.PROP_C_W_E);

    const chdir_fn = c.newCFunction(ctx, chdirCallback, "chdir", 1);
    _ = c.definePropertyValueStr(ctx, process_obj, "chdir", chdir_fn, c.PROP_C_W_E);

    // C3: allocation/spill introspection for bench/fetch_spill.js.
    const stats_fn = c.newCFunction(ctx, statsCallback, "stats", 0);
    _ = c.definePropertyValueStr(ctx, process_obj, "stats", stats_fn, c.PROP_C_W_E);

    const memory_usage_fn = c.newCFunction(ctx, memoryUsageCallback, "memoryUsage", 0);
    _ = c.definePropertyValueStr(ctx, process_obj, "memoryUsage", memory_usage_fn, c.PROP_C_W_E);

    const on_fn = c.newCFunction(ctx, processOnCallback, "on", 2);
    _ = c.definePropertyValueStr(ctx, process_obj, "on", on_fn, c.PROP_C_W_E);
    const once_fn = c.newCFunction(ctx, processOnceCallback, "once", 2);
    _ = c.definePropertyValueStr(ctx, process_obj, "once", once_fn, c.PROP_C_W_E);
    const off_fn = c.newCFunction(ctx, processOffCallback, "off", 2);
    _ = c.definePropertyValueStr(ctx, process_obj, "off", off_fn, c.PROP_C_W_E);
    const rm_fn = c.newCFunction(ctx, processOffCallback, "removeListener", 2);
    _ = c.definePropertyValueStr(ctx, process_obj, "removeListener", rm_fn, c.PROP_C_W_E);
    const kill_fn = c.newCFunction(ctx, processKillCallback, "kill", 2);
    _ = c.definePropertyValueStr(ctx, process_obj, "kill", kill_fn, c.PROP_C_W_E);

    const pid_val = c.newInt64(ctx, @intCast(@as(i64, std.c.getpid())));
    _ = c.definePropertyValueStr(ctx, process_obj, "pid", pid_val, c.PROP_C_W_E);

    const platform_str = comptime switch (builtin.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        .windows => "win32",
        .freebsd => "freebsd",
        else => "unknown",
    };
    _ = c.definePropertyValueStr(ctx, process_obj, "platform", zigStringToVal(ctx, platform_str), c.PROP_C_W_E);

    const arch_str = comptime switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x64",
        .x86 => "ia32",
        .riscv64 => "riscv64",
        else => "unknown",
    };
    _ = c.definePropertyValueStr(ctx, process_obj, "arch", zigStringToVal(ctx, arch_str), c.PROP_C_W_E);

    const env_obj = c.newObject(ctx);
    const c_environ = std.c.environ;
    var i: usize = 0;
    while (c_environ[i]) |entry| : (i += 1) {
        const entry_str = std.mem.span(entry);
        if (std.mem.indexOfScalar(u8, entry_str, '=')) |eq_pos| {
            if (!perm.global().checkEnv(entry_str[0..eq_pos])) continue;
            const key_atom = c.newAtomLen(ctx, entry_str.ptr, eq_pos);
            if (key_atom == 0) continue;
            const val = entry_str[eq_pos + 1 ..];
            _ = c.definePropertyValue(ctx, env_obj, key_atom, zigStringToVal(ctx, val), c.PROP_C_W_E);
            c.freeAtom(ctx, key_atom);
        }
    }
    _ = c.definePropertyValueStr(ctx, process_obj, "env", env_obj, c.PROP_C_W_E);

    const argv_arr = c.newArray(ctx);
    var arg_idx: u32 = 0;
    var args_iter = args.iterate();
    while (args_iter.next()) |arg| {
        _ = c.setPropertyUint32(ctx, argv_arr, arg_idx, zigStringToVal(ctx, arg));
        arg_idx += 1;
    }
    _ = c.definePropertyValueStr(ctx, process_obj, "argv", argv_arr, c.PROP_C_W_E);

    _ = c.definePropertyValueStr(ctx, global, "process", process_obj, c.PROP_C_W_E);
}
