const std = @import("std");
const engine = @import("../engine/engine.zig");
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
                std.debug.print("[https] --cert requires a path\n", .{});
                return;
            };
        } else if (std.mem.eql(u8, a, "--key")) {
            key_path = it.next() orelse {
                std.debug.print("[https] --key requires a path\n", .{});
                return;
            };
        }
    }
    if (cert_path == null) cert_path = envSlice("FF_CERT");
    if (key_path == null) key_path = envSlice("FF_KEY");

    if (cert_path != null and key_path != null) {
        if (!tls_server.available) {
            std.debug.print("[https] built without TLS (rebuild without -Dbearssl=false)\n", .{});
            return;
        }
        const cert_pem = dir.readFileAlloc(io, cert_path.?, allocator, .limited(512 * 1024)) catch {
            std.debug.print("[https] could not read cert file '{s}'\n", .{cert_path.?});
            return;
        };
        defer allocator.free(cert_pem);
        const key_pem = dir.readFileAlloc(io, key_path.?, allocator, .limited(256 * 1024)) catch {
            std.debug.print("[https] could not read key file '{s}'\n", .{key_path.?});
            return;
        };
        defer allocator.free(key_pem);
        tls_server.initServer(cert_pem, key_pem) catch |e| {
            std.debug.print("[https] TLS init failed: {s}\n", .{@errorName(e)});
            return;
        };
        http_native.enableTls();
        // Trust this cert in the runtime's own fetch/wss client (self-signed
        // dev setup). tls.init() — which consumes ca_file — runs inside
        // engine.Runtime.init below. cert_path points into argv/env memory
        // and stays valid for the process lifetime.
        tls.ca_file = cert_path;
        std.debug.print("[https] TLS enabled (cert={s} key={s}) — https/wss on the same port\n", .{ cert_path.?, key_path.? });
    } else if (cert_path != null or key_path != null) {
        std.debug.print("[https] --cert and --key must be provided together\n", .{});
        return;
    }

    const ff_content = dir.readFileAlloc(io, "ff.json", allocator, .limited(1024 * 1024)) catch {
        std.debug.print("No ff.json found. Run 'ff init' first.\n", .{});
        return;
    };
    defer allocator.free(ff_content);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, ff_content, .{}) catch {
        std.debug.print("ff.json is not valid JSON.\n", .{});
        return;
    };
    defer parsed.deinit();
    const main_val = parsed.value.object.get("main") orelse {
        std.debug.print("ff.json is missing the 'main' field.\n", .{});
        return;
    };
    const main_name = main_val.string;
    var main_name_buf = allocator.alloc(u8, main_name.len + 1) catch return;
    defer allocator.free(main_name_buf);
    @memcpy(main_name_buf[0..main_name.len], main_name);
    main_name_buf[main_name.len] = 0;
    const main_name_z: [:0]const u8 = main_name_buf[0..main_name.len :0];
    const js_content = dir.readFileAlloc(io, main_name, allocator, .limited(10 * 1024 * 1024)) catch {
        std.debug.print("Could not open '{s}'.\n", .{main_name});
        return;
    };
    defer allocator.free(js_content);
    const source: [:0]const u8 = allocator.dupeZ(u8, js_content) catch return;
    defer allocator.free(source);
    const runtime = try engine.Runtime.init(init.minimal.args);
    // DOD-FIX 9: boot_arena is the sole owner of `runtime` and
    // runtime.event_loop. Runtime.deinit() frees the arena.
    defer {
        engine.deinitNetwork();
        runtime.event_loop.deinit();
        runtime.deinit();
    }
    _ = runtime.evalModule(source, main_name_z);
    runtime.event_loop.runWithMicrotasks(runtime.ctx);
}
