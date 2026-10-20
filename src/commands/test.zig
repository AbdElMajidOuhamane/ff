const std = @import("std");
const cli = @import("../util/cli.zig");
const engine = @import("../engine/engine.zig");
const microtasks = @import("../event/microtasks.zig"); // NEW

// ff test [filter] — run test/*.test.js through the runtime.
// Same convention as test/run.sh: eval returns true = pass.
// Optional filter: `ff test url` runs only url.test.js.
pub fn run(io: std.Io, init: std.process.Init) !void {
    const dir = std.Io.Dir.cwd();
    const allocator = std.heap.page_allocator;

    var filter: ?[]const u8 = null;
    var it = init.minimal.args.iterate();
    _ = it.next(); // ff
    _ = it.next(); // test
    while (it.next()) |a| {
        // --allow-ffi and other flags are consumed by main.zig, not filters.
        if (std.mem.startsWith(u8, a, "--")) continue;
        filter = a;
        break;
    }

    var test_dir = dir.openDir(io, "test", .{ .iterate = true }) catch {
        cli.failWithHint("no test/ directory found", .{}, "create test/*.test.js files to run", .{});
    };
    defer test_dir.close(io);

    const runtime = try engine.Runtime.init(init.minimal.args);
    defer {
        engine.deinitNetwork();
        runtime.event_loop.deinit();
        runtime.deinit();
    }

    var pass: u32 = 0;
    var fail: u32 = 0;
    var diter = test_dir.iterate();
    while (diter.next(io) catch null) |entry| {
        const name = entry.name;
        if (!std.mem.endsWith(u8, name, ".test.js")) continue;
        if (filter) |f| {
            if (std.mem.indexOf(u8, name, f) == null) continue;
        }
        const sub = try std.fmt.allocPrint(allocator, "test/{s}", .{name});
        defer allocator.free(sub);

        const content = dir.readFileAlloc(io, sub, allocator, .limited(10 * 1024 * 1024)) catch {
            printResult(false, sub);
            fail += 1;
            continue;
        };
        defer allocator.free(content);
        const source: [:0]const u8 = allocator.dupeZ(u8, content) catch continue;
        defer allocator.free(source);

        var path_buf = allocator.alloc(u8, sub.len + 1) catch continue;
        defer allocator.free(path_buf);
        @memcpy(path_buf[0..sub.len], sub);
        path_buf[sub.len] = 0;
        const path_z: [:0]const u8 = path_buf[0..sub.len :0];

        microtasks.had_error = false; // NEW: reset before each file
        const ok = runtime.evalModule(source, path_z);
        runtime.event_loop.runWithMicrotasks(runtime.ctx);
        const clean = ok and !microtasks.had_error; // NEW: catch async failures
        if (clean) {
            printResult(true, sub);
            pass += 1;
        } else {
            printResult(false, sub);
            fail += 1;
        }
    }

    if (pass + fail == 0) {
        if (filter) |f| cli.fail("no tests match '{s}'", .{f});
    }
    printSummary(pass, fail);
    if (fail > 0) std.process.exit(1);
}

// "OK"/"FAIL" + path. test/run.sh greps for the literal FAIL substring, and
// ANSI around the word does not hide it; piped output is uncolored anyway.
fn printResult(ok: bool, sub: []const u8) void {
    const word = if (ok) "OK" else "FAIL";
    const pad = if (ok) "   " else " ";
    if (cli.useColor()) {
        if (ok) {
            std.debug.print(cli.green ++ cli.glyph_ok ++ " OK" ++ cli.reset ++ "   {s}\n", .{sub});
        } else {
            std.debug.print(cli.red ++ cli.glyph_fail ++ " FAIL" ++ cli.reset ++ " {s}\n", .{sub});
        }
    } else {
        std.debug.print("{s}{s}{s}\n", .{ word, pad, sub });
    }
}

fn printSummary(pass: u32, fail: u32) void {
    if (cli.useColor()) {
        if (fail == 0) {
            std.debug.print("\n" ++ cli.green ++ cli.glyph_ok ++ " {d} passed" ++ cli.reset ++ ", {d} failed\n", .{ pass, fail });
        } else {
            std.debug.print("\n" ++ cli.green ++ "{d} passed" ++ cli.reset ++ ", " ++ cli.red ++ "{d} failed" ++ cli.reset ++ "\n", .{ pass, fail });
        }
    } else {
        std.debug.print("\n{d} passed, {d} failed\n", .{ pass, fail });
    }
}
