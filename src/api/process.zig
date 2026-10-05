const std = @import("std");
const c = @import("../c.zig").c;
const builtin = @import("builtin");
// C3: stat counters live in the net modules (verified: nothing in their
// import closures references api/process, so no cycle).
const async_fetch = @import("../net/async_fetch.zig");
const http_native = @import("../net/http_native.zig");
const pg_client = @import("../net/pg_client.zig");

const Io = std.Io;

const gpa = std.heap.smp_allocator;

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
    var buf: [4096]u8 = undefined;
    const len = @min(str_len, buf.len);
    @memcpy(buf[0..len], str_ptr[0..len]);
    return gpa.dupeZ(u8, buf[0..len]) catch null;
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
        throwErr(ctx, "chdir requires a path argument");
        return c.JS_UNDEFINED;
    };
    defer gpa.free(path);

    const io = getIo();
    std.process.setCurrentPath(io, path) catch {
        throwErr(ctx, "chdir failed");
        return c.JS_UNDEFINED;
    };
    return c.JS_UNDEFINED;
}

// C3 FIX: expose the TB §5 spill/reuse counters to JS (works in Release
// too — the Debug stderr dumps don't). Key names match what
// bench/fetch_spill.js expects: fetch.bodyHeap, fetch.hdrSpill,
// fetch.decompressHeap, http.bodySpill, http.bodySpillReuse, pg.*.
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
