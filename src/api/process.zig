const std = @import("std");
const c = @import("../c.zig").c;
const builtin = @import("builtin");

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
    return c.newStringLen(ctx, str.ptr, str.len);
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
fn memoryUsageCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    _ = argc;
    _ = argv;
    var mu: c.MemoryUsage = undefined;
    c.computeMemoryUsage(c.getRuntime(ctx), &mu);
    const obj = c.newObject(ctx);
    _ = c.setPropertyStr(ctx, obj, "rss", c.newInt32(ctx, 0));
    _ = c.setPropertyStr(ctx, obj, "heapTotal", c.newInt64(ctx, mu.malloc_size));
    _ = c.setPropertyStr(ctx, obj, "heapUsed", c.newInt64(ctx, mu.memory_used_size));
    _ = c.setPropertyStr(ctx, obj, "external", c.newInt32(ctx, 0));
    return obj;
}
fn nCpusCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    _ = argc;
    _ = argv;
    const n = std.Thread.getCpuCount() catch 1;
    return c.newInt64(ctx, @intCast(n));
}

fn hostnameCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    _ = argc;
    _ = argv;
    var buf: [256]u8 = undefined;
    if (std.c.gethostname(&buf, buf.len) == 0) {
        const span = std.mem.span(@as([*:0]const u8, @ptrCast(&buf)));
        return zigStringToVal(ctx, span);
    }
    return c.JS_UNDEFINED;
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
    };
    return c.JS_UNDEFINED;
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
        const mem_usage_fn = c.newCFunction(ctx, memoryUsageCallback, "memoryUsage", 0);
    _ = c.definePropertyValueStr(ctx, process_obj, "memoryUsage", mem_usage_fn, c.PROP_C_W_E);
        const n_cpus_fn = c.newCFunction(ctx, nCpusCallback, "_nCpus", 0);
    _ = c.definePropertyValueStr(ctx, process_obj, "_nCpus", n_cpus_fn, c.PROP_C_W_E);

    const hostname_fn = c.newCFunction(ctx, hostnameCallback, "_hostname", 0);
    _ = c.definePropertyValueStr(ctx, process_obj, "_hostname", hostname_fn, c.PROP_C_W_E);

    _ = c.definePropertyValueStr(ctx, global, "process", process_obj, c.PROP_C_W_E);
}
