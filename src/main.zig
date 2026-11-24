const std = @import("std");
const builtin = @import("builtin");
const cli = @import("util/cli.zig");
const engine = @import("engine/engine.zig");
const qjs = @import("engine/quickjs_shim.zig");
const tls = @import("net/tls.zig");
const ffcfg = @import("ffcfg");
const permissions = @import("security/permissions.zig");
const sandbox = @import("security/sandbox.zig");
const child_process_api = @import("api/child_process.zig");
const process_api = @import("api/process.zig");
const stdio = @import("api/stdio.zig");
const limits = @import("util/limits.zig");
const interrupt = @import("engine/interrupt.zig");
const loop_mod = @import("event/loop.zig");
const microtasks = @import("event/microtasks.zig");
const init_cmd = @import("commands/init.zig");
const imprint_cmd = @import("commands/imprint.zig");
const sever_cmd = @import("commands/sever.zig");
const start_cmd = @import("commands/start.zig");

const test_cmd = @import("commands/test.zig");
const repl_cmd = @import("commands/repl.zig");
const upgrade_cmd = @import("commands/upgrade.zig");
const compile_cmd = @import("commands/compile.zig");
const fmt_cmd = @import("commands/fmt.zig");
const watch_cmd = @import("commands/watch.zig");
const Command = enum {
    init,
    imprint,
    sever,
    start,
    test_cmd,
    repl,
    upgrade,
    compile,
    fmt,
    watch,
    help,
    e_flag,
    file,
    version,
    none,
};
fn parseCommand(arg: []const u8) Command {
    if (std.mem.eql(u8, arg, "init")) return .init;
    if (std.mem.eql(u8, arg, "imprint")) return .imprint;
    if (std.mem.eql(u8, arg, "sever")) return .sever;
    if (std.mem.eql(u8, arg, "start")) return .start;
    if (std.mem.eql(u8, arg, "test")) return .test_cmd;
    if (std.mem.eql(u8, arg, "repl")) return .repl;
    if (std.mem.eql(u8, arg, "upgrade")) return .upgrade;
    if (std.mem.eql(u8, arg, "compile")) return .compile;
    if (std.mem.eql(u8, arg, "fmt")) return .fmt;
    if (std.mem.eql(u8, arg, "-e")) return .e_flag;
    if (std.mem.eql(u8, arg, "--version")) return .version;
    if (std.mem.eql(u8, arg, "--watch")) return .watch;
    if (std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return .help;
    return .file;
}
fn shutdownRuntime(runtime: *engine.Runtime) void {
    engine.deinitNetwork();
    runtime.event_loop.deinit();
    runtime.deinit();
}
fn parseCaFlag(init: std.process.Init) void {
    var it = init.minimal.args.iterate();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--ca")) {
            tls.ca_file = it.next() orelse {
                cli.failWithHint("--ca requires a path", .{}, "usage: ff <file> --ca <path>", .{});
            };
            return;
        }
    }
}
fn parsePermissions(init: std.process.Init) void {
    permissions.initFromArgs(init.minimal.args) catch |err| {
        cli.failWithHint(
            "invalid permission flag: {s}",
            .{@errorName(err)},
            "usage: --allow-<read|write|net|env|run|ffi>[=scope,...]",
            .{},
        );
    };
}
fn parseLimits(init: std.process.Init) void {
    limits.initFromArgs(init.minimal.args) catch |err| {
        switch (err) {
            error.InvalidHeapSize => cli.failWithHint("invalid --max-heap value", .{}, "heap limit must be between 8MB and 4GB (e.g. --max-heap=64MB)", .{}),
            error.InvalidStackSize => cli.failWithHint("invalid --max-stack value", .{}, "stack limit must be at least 128KB (e.g. --max-stack=1MB)", .{}),
            error.InvalidWorkerHeapSize => cli.failWithHint("invalid --worker-heap value", .{}, "worker heap limit must be between 1MB and main heap size", .{}),
            error.InvalidCpuBudget => cli.failWithHint("invalid --cpu-budget value", .{}, "cpu budget must be between 0 and 3600000 ms", .{}),
            error.InvalidWallTimeout => cli.failWithHint("invalid --wall-timeout value", .{}, "wall timeout must be between 0 and 3600000 ms", .{}),
            error.InvalidMaxLogBytes => cli.failWithHint("invalid --max-log-bytes value", .{}, "log cap must be 0..100MB (e.g. --max-log-bytes=64KB)", .{}),
            error.MissingEnvFilePath => cli.failWithHint("--env-file requires a path", .{}, "usage: ff --env-file <path>", .{}),
            error.MissingStackSizeValue => cli.failWithHint("--max-stack requires a value", .{}, "usage: ff --max-stack <size> (e.g. --max-stack=1MB)", .{}),
            error.InvalidByteSize => cli.failWithHint("invalid byte size format", .{}, "use suffixes KB, MB, or GB (e.g. 64MB)", .{}),
            error.NativeStackTooSmall => {
                const lim = limits.get();
                cli.failWithHint(
                    "native stack is too small",
                    .{},
                    "detected native stack is {d} KB; fairyfly requires at least 256 KB",
                    .{lim.native_stack_bytes / 1024},
                );
            },
            error.StackSizeExceedsNative => {
                const lim = limits.get();
                cli.failWithHint(
                    "--max-stack exceeds safe limit for native stack",
                    .{},
                    "detected native stack is {d} MB; safe limit is at most {d} MB (native/2)",
                    .{
                        lim.native_stack_bytes / (1024 * 1024),
                        lim.stack_max_bytes / (1024 * 1024),
                    },
                );
            },
        }
    };
}

fn isRuntimeFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--env-file") or
        std.mem.startsWith(u8, arg, "--env-file=") or
        std.mem.eql(u8, arg, "--max-heap") or
        std.mem.startsWith(u8, arg, "--max-heap=") or
        std.mem.eql(u8, arg, "--max-stack") or
        std.mem.startsWith(u8, arg, "--max-stack=") or
        std.mem.eql(u8, arg, "--worker-heap") or
        std.mem.startsWith(u8, arg, "--worker-heap=") or
        std.mem.eql(u8, arg, "--cpu-budget") or
        std.mem.startsWith(u8, arg, "--cpu-budget=") or
        std.mem.eql(u8, arg, "--wall-timeout") or
        std.mem.startsWith(u8, arg, "--wall-timeout=") or
        std.mem.eql(u8, arg, "--max-log-bytes") or
        std.mem.startsWith(u8, arg, "--max-log-bytes=") or
        std.mem.eql(u8, arg, "--simple-sandbox");
}

fn skipRuntimeFlag(arg: []const u8, it: *std.process.Args.Iterator) void {
    if (std.mem.eql(u8, arg, "--env-file") or
        std.mem.eql(u8, arg, "--max-heap") or
        std.mem.eql(u8, arg, "--max-stack") or
        std.mem.eql(u8, arg, "--worker-heap") or
        std.mem.eql(u8, arg, "--cpu-budget") or
        std.mem.eql(u8, arg, "--wall-timeout") or
        std.mem.eql(u8, arg, "--max-log-bytes"))
    {
        _ = it.next();
    }
}

// POSIX forces SIGINT/SIGQUIT to ignore for background jobs, so `kill -INT`
// on a backgrounded ff was a no-op. Restore the default action when a
// signal was ignored; caught handlers are left alone (exec already reset
// them to default for us).
fn resetIgnoredInterrupt() void {
    for ([_]std.posix.SIG{ .INT, .TERM }) |sig| {
        var old: std.posix.Sigaction = undefined;
        std.posix.sigaction(sig, null, &old);
        if (old.handler.handler == std.posix.SIG.IGN) {
            const act: std.posix.Sigaction = .{
                .handler = .{ .handler = std.posix.SIG.DFL },
                .mask = std.posix.sigemptyset(),
                .flags = 0,
            };
            std.posix.sigaction(sig, &act, null);
        }
    }
}

// Under `ff --watch` the supervisor exports FF_WATCH_PARENT before spawn;
// if the supervisor dies (even SIGKILL), exit within 500ms instead of
// living on as an orphan.
fn maybeStartParentWatchdog() void {
    const env = std.c.getenv("FF_WATCH_PARENT") orelse return;
    const parent = std.fmt.parseInt(std.posix.pid_t, std.mem.span(env), 10) catch return;
    const t = std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, parentWatchdog, .{parent}) catch return;
    t.detach();
}

fn parentWatchdog(parent: std.posix.pid_t) void {
    const ts = std.c.timespec{ .sec = 0, .nsec = 500_000_000 };
    while (true) {
        _ = std.c.nanosleep(&ts, null);
        if (std.posix.getppid() != parent) std.c._exit(0);
    }
}

// Runs the event loop to quiescence, then exits 1 if anything threw —
// a top-level throw, a rejected module promise, a failed job, or a
// timer/microtask error. Previously every one of these exited 0.
fn runAndExit(runtime: *engine.Runtime) void {
    runtime.event_loop.runWithMicrotasks(runtime.ctx);
    if (microtasks.had_error) std.process.exit(1);
}

fn run(init: std.process.Init) !void {
    child_process_api.setIo(init.io);
    process_api.setIo(init.io);

    if (builtin.os.tag != .windows) {
        resetIgnoredInterrupt();
        maybeStartParentWatchdog();
    }
    parsePermissions(init);
    parseLimits(init);
    var args_iter = init.minimal.args.iterate();
    const exe = args_iter.next() orelse {
        cli.printUsage();
        return;
    };

    // Check if running as a standalone binary with embedded bytecode
    var self_exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.process.executablePath(init.io, &self_exe_buf)) |n| {
        const self_path = self_exe_buf[0..n];
        if (std.Io.Dir.cwd().openFile(init.io, self_path, .{ .mode = .read_only })) |file| {
            defer file.close(init.io);
            if (file.stat(init.io)) |st| {
                const trailer_magic = "FFSTANDA";
                const trailer_len = trailer_magic.len + 8 + 8; // 24 bytes
                if (st.size >= trailer_len) {
                    var trailer_buf: [24]u8 = undefined;
                    const read_bytes = file.readPositionalAll(init.io, &trailer_buf, st.size - trailer_len) catch 0;
                    if (read_bytes == trailer_len and std.mem.eql(u8, trailer_buf[0..trailer_magic.len], trailer_magic)) {
                        const bc_size = std.mem.readInt(u64, trailer_buf[trailer_magic.len..][0..8], .little);
                        const expected_hash = std.mem.readInt(u64, trailer_buf[trailer_magic.len + 8 ..][0..8], .little);
                        if (bc_size > 0 and bc_size <= st.size - trailer_len) {
                            const self_bin_len = st.size - trailer_len - bc_size;
                            const host_bin = std.heap.page_allocator.alloc(u8, self_bin_len) catch null;
                            if (host_bin) |hb| {
                                defer std.heap.page_allocator.free(hb);
                                const h_read = file.readPositionalAll(init.io, hb, 0) catch 0;
                                if (h_read == self_bin_len) {
                                    const actual_hash = std.hash.Wyhash.hash(0, hb);
                                    if (actual_hash != expected_hash) {
                                        cli.fail("standalone bytecode was compiled with a different build of fairyfly", .{});
                                    }
                                }
                            }
                            const bc_slice = std.heap.page_allocator.alloc(u8, bc_size) catch null;
                            if (bc_slice) |bc| {
                                defer std.heap.page_allocator.free(bc);
                                const bc_read = file.readPositionalAll(init.io, bc, st.size - trailer_len - bc_size) catch 0;
                                if (bc_read == bc_size) {
                                    const runtime = try engine.Runtime.init(init.minimal.args);
                                    defer shutdownRuntime(runtime);
                                    sandbox.applyIfRequested();
                                    if (!runtime.evalBytecode(bc)) microtasks.had_error = true;
                                    runAndExit(runtime);
                                    return;
                                }
                            }
                        }
                    }
                }
            } else |_| {}
        } else |_| {}
    } else |_| {}

    var first_arg: [:0]const u8 = undefined;
    while (true) {
        first_arg = args_iter.next() orelse {
            cli.printUsage();
            return;
        };
        if (isRuntimeFlag(first_arg)) {
            skipRuntimeFlag(first_arg, &args_iter);
        } else if (permissions.isPermissionFlag(first_arg)) {
            // already processed in parsePermissions
        } else if (std.mem.eql(u8, first_arg, "--ca")) {
            _ = args_iter.next();
        } else {
            break;
        }
    }
    const cmd = parseCommand(first_arg);
    switch (cmd) {
        .init => {
            var gpa_state = std.heap.DebugAllocator(.{}).init;
            defer _ = gpa_state.deinit();
            const gpa = gpa_state.allocator();
            var rest = std.ArrayList([]const u8).empty;
            defer rest.deinit(gpa);
            while (args_iter.next()) |a| try rest.append(gpa, a);
            try init_cmd.run(init.io, rest.items);
        },
        .imprint => {
            var gpa_state = std.heap.DebugAllocator(.{}).init;
            defer _ = gpa_state.deinit();
            const gpa = gpa_state.allocator();
            var rest = std.ArrayList([]const u8).empty;
            defer rest.deinit(gpa);
            while (args_iter.next()) |a| try rest.append(gpa, a);
            try imprint_cmd.run(init.io, rest.items);
        },
        .sever => {
            var gpa_state = std.heap.DebugAllocator(.{}).init;
            defer _ = gpa_state.deinit();
            const gpa = gpa_state.allocator();
            var rest = std.ArrayList([]const u8).empty;
            defer rest.deinit(gpa);
            while (args_iter.next()) |a| try rest.append(gpa, a);
            try sever_cmd.run(init.io, rest.items);
        },
        .start => try start_cmd.run(init.io, init),
        .test_cmd => try test_cmd.run(init.io, init),
        .repl => try repl_cmd.run(init.io, init),
        .upgrade => try upgrade_cmd.run(init.io, init),
        .compile => try compile_cmd.run(init.io, init),
        .fmt => try fmt_cmd.run(init.io, init),
        .watch => {
            var target: ?[]const u8 = null;
            var forward = std.ArrayList([]const u8).empty;
            defer forward.deinit(std.heap.page_allocator);
            while (args_iter.next()) |a| {
                if (std.mem.eql(u8, a, "--ca")) {
                    const v = args_iter.next() orelse {
                        cli.failWithHint("--ca requires a path", .{}, "usage: ff --watch <file|start> --ca <path>", .{});
                    };
                    try forward.append(std.heap.page_allocator, a);
                    try forward.append(std.heap.page_allocator, v);
                } else if (permissions.isPermissionFlag(a)) {
                    try forward.append(std.heap.page_allocator, a);
                } else if (target == null) {
                    target = a;
                } else {
                    try forward.append(std.heap.page_allocator, a);
                }
            }
            const t = target orelse {
                cli.failWithHint("--watch requires a file or 'start'", .{}, "usage: ff --watch <file|start>", .{});
            };
            if (std.mem.eql(u8, t, "start")) {
                try watch_cmd.run(init.io, exe, .start, t, forward.items);
            } else {
                try watch_cmd.run(init.io, exe, .file, t, forward.items);
            }
        },
        .version => {
            std.debug.print("ff {s} ({s}-{s})\n", .{
                ffcfg.version,
                @tagName(builtin.os.tag),
                @tagName(builtin.cpu.arch),
            });
        },
        .help => cli.printUsage(),
        .e_flag => {
            const code = args_iter.next() orelse {
                cli.failWithHint("-e requires an argument", .{}, "usage: ff -e '<code>'", .{});
            };
            parseCaFlag(init);
            const runtime = try engine.Runtime.init(init.minimal.args);
            defer shutdownRuntime(runtime);
            sandbox.applyIfRequested();
            interrupt.enterJs(0, interrupt.monotonicNowMs());
            if (!runtime.eval(code, "<eval>")) microtasks.had_error = true;
            interrupt.leaveJs(0);
            runAndExit(runtime);
        },
        .file => {
            if (first_arg.len > 0 and first_arg[0] == '-') {
                if (std.mem.eql(u8, first_arg, "--ca")) {
                    cli.failWithHint("--ca must follow a script", .{}, "usage: ff <file> --ca <path>", .{});
                }
                cli.failWithHint("unknown option '{s}'", .{first_arg}, "run 'ff --help'", .{});
            }
            parseCaFlag(init);
            const runtime = try engine.Runtime.init(init.minimal.args);
            defer shutdownRuntime(runtime);
            sandbox.applyIfRequested();
            const allocator = std.heap.page_allocator;
            const buf = std.Io.Dir.cwd().readFileAllocOptions(
                init.io,
                first_arg,
                allocator,
                .unlimited,
                .of(u8),
                0,
            ) catch |err| {
                cli.failWithHint("cannot open '{s}': {s}", .{ first_arg, cli.fileErrText(err) }, "check the path and try again", .{});
            };
            defer allocator.free(buf);
            const size = buf.len;

            if (std.mem.endsWith(u8, first_arg, ".ffbc")) {
                if (!runtime.evalBytecode(buf[0..size])) microtasks.had_error = true;
                runAndExit(runtime);
            } else {
                const source: [:0]const u8 = buf;
                interrupt.enterJs(0, interrupt.monotonicNowMs());
                if (!runtime.evalModule(source, first_arg)) microtasks.had_error = true;
                interrupt.leaveJs(0);
                runAndExit(runtime);
            }
        },
        .none => cli.printUsage(),
    }
}

// Entry point: any error that escapes a command (a bug, not a handled user
// error) is reported once here instead of leaking as a raw `error: Name`.
pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        cli.errorMsg("unexpected error: {s}", .{@errorName(err)});
        cli.hint("this is a bug — please report it with the command you ran", .{});
        std.process.exit(1);
    };
}
