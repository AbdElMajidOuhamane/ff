const std = @import("std");
const cli = @import("../util/cli.zig");
const engine = @import("../engine/engine.zig");
const microtasks = @import("../event/microtasks.zig");
const tls_server = @import("../net/tls_server.zig");
const http_native = @import("../net/http_native.zig");
const tls = @import("../net/tls.zig");

fn envSlice(name: [:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name.ptr) orelse return null;
    return std.mem.span(v);
}

pub fn run(io: std.Io, init: std.process.Init) !void {
    const dir = std.Io.Dir.cwd();
    const allocator = std.heap.page_allocator;

    // ── TLS: ff start --cert cert.pem --key key.pem (env FF_CERT/FF_KEY fallback) ──
    var cert_path: ?[]const u8 = null;
    var key_path: ?[]const u8 = null;
    var it = init.minimal.args.iterate();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--cert")) {
            cert_path = it.next() orelse {
                cli.failWithHint("--cert requires a path", .{}, "usage: ff start [--cert cert.pem --key key.pem]", .{});
            };
        } else if (std.mem.eql(u8, a, "--key")) {
            key_path = it.next() orelse {
                cli.failWithHint("--key requires a path", .{}, "usage: ff start [--cert cert.pem --key key.pem]", .{});
            };
        }
    }
    if (cert_path == null) cert_path = envSlice("FF_CERT");
    if (key_path == null) key_path = envSlice("FF_KEY");

    if (cert_path != null and key_path != null) {
        if (!tls_server.available) {
            cli.failWithHint("this build has no TLS support", .{}, "rebuild without -Dbearssl=false", .{});
        }
        const cert_pem = dir.readFileAlloc(io, cert_path.?, allocator, .limited(512 * 1024)) catch |err| {
            cli.failWithHint("cannot read cert file '{s}': {s}", .{ cert_path.?, cli.fileErrText(err) }, "check the path and permissions", .{});
        };
        defer allocator.free(cert_pem);
        const key_pem = dir.readFileAlloc(io, key_path.?, allocator, .limited(256 * 1024)) catch |err| {
            cli.failWithHint("cannot read key file '{s}': {s}", .{ key_path.?, cli.fileErrText(err) }, "check the path and permissions", .{});
        };
        defer allocator.free(key_pem);
        tls_server.initServer(cert_pem, key_pem) catch |e| {
            cli.fail("TLS init failed: {s}", .{@errorName(e)});
        };
        http_native.enableTls();
        // Trust this cert in the runtime's own fetch/wss client (self-signed
        // dev setup). tls.init() — which consumes ca_file — runs inside
        // engine.Runtime.init below. cert_path points into argv/env memory
        // and stays valid for the process lifetime.
        tls.ca_file = cert_path;
        std.debug.print("[https] TLS enabled (cert={s} key={s}) — https/wss on the same port\n", .{ cert_path.?, key_path.? });
    } else if (cert_path != null or key_path != null) {
        cli.fail("--cert and --key must be provided together", .{});
    }

    const ff_content = dir.readFileAlloc(io, "ff.json", allocator, .limited(1024 * 1024)) catch {
        cli.failWithHint("no ff.json in this directory", .{}, "run 'ff init' to create one", .{});
    };
    defer allocator.free(ff_content);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, ff_content, .{}) catch {
        cli.fail("ff.json is not valid JSON", .{});
    };
    defer parsed.deinit();
    if (parsed.value != .object) cli.fail("ff.json must be a JSON object", .{});
    const main_val = parsed.value.object.get("main") orelse {
        cli.failWithHint("ff.json is missing the 'main' field", .{}, "add a \"main\" field pointing at your entry file", .{});
    };
    if (main_val != .string) cli.fail("ff.json 'main' must be a string", .{});
    const main_name = main_val.string;
    var main_name_buf = allocator.alloc(u8, main_name.len + 1) catch cli.fail("out of memory", .{});
    defer allocator.free(main_name_buf);
    @memcpy(main_name_buf[0..main_name.len], main_name);
    main_name_buf[main_name.len] = 0;
    const main_name_z: [:0]const u8 = main_name_buf[0..main_name.len :0];
    const js_content = dir.readFileAlloc(io, main_name, allocator, .limited(10 * 1024 * 1024)) catch |err| {
        cli.failWithHint("cannot open '{s}': {s}", .{ main_name, cli.fileErrText(err) }, "check the \"main\" field in ff.json", .{});
    };
    defer allocator.free(js_content);
    const source: [:0]const u8 = allocator.dupeZ(u8, js_content) catch cli.fail("out of memory", .{});
    defer allocator.free(source);
    const runtime = try engine.Runtime.init(init.minimal.args);
    // DOD-FIX 9: boot_arena is the sole owner of `runtime` and
    // runtime.event_loop. Runtime.deinit() frees the arena.
    defer {
        engine.deinitNetwork();
        runtime.event_loop.deinit();
        runtime.deinit();
    }
    cli.step("starting {s}", .{main_name});
    if (!runtime.evalModule(source, main_name_z)) microtasks.had_error = true;
    runtime.event_loop.runWithMicrotasks(runtime.ctx);
    if (microtasks.had_error) std.process.exit(1);
}
