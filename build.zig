const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bearssl = b.option(bool, "bearssl", "Enable BearSSL TLS (https/wss)") orelse true;

    // ── Build-options module (ffcfg) ──
    const ffcfg_opts = b.addOptions();
    ffcfg_opts.addOption(bool, "bearssl", bearssl);
    const ff_version = b.option([]const u8, "version", "Runtime version string") orelse "0.1.0-canary";
    ffcfg_opts.addOption([]const u8, "version", ff_version);
    const ffcfg_mod = ffcfg_opts.createModule();

    // ── QuickJS C translation (auto-generates types + inline functions) ──
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("vendor/quickjs/quickjs.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(b.path("vendor/quickjs"));
    const c_mod = translate.createModule();

    // ── BearSSL: translated declarations module + compiled static library ──
    var bssl_mod: ?*std.Build.Module = null;
    var bssl_lib: ?*std.Build.Step.Compile = null;
    if (bearssl) {
        const btranslate = b.addTranslateC(.{
            .root_source_file = b.path("vendor/bearssl/zig_bridge.h"),
            .target = target,
            .optimize = optimize,
        });
        btranslate.addIncludePath(b.path("vendor/bearssl/inc"));
        bssl_mod = btranslate.createModule();

        const io = b.graph.io;
        var files: std.ArrayList([]const u8) = .empty;
        var src_dir = std.Io.Dir.cwd().openDir(io, "vendor/bearssl/src", .{ .iterate = true }) catch {
            std.debug.print("error: vendor/bearssl missing - it is fetched by the Dockerfile (or run the vendor fetch locally)\n", .{});
            return;
        };
        defer src_dir.close(io);
        var walker = src_dir.walk(b.allocator) catch unreachable;
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".c")) continue;
            const rel = b.allocator.dupe(u8, entry.path) catch unreachable;
            files.append(b.allocator, rel) catch unreachable;
        }
        std.mem.sort([]const u8, files.items, {}, struct {
            fn lt(_: void, a: []const u8, bb: []const u8) bool {
                return std.mem.order(u8, a, bb) == .lt;
            }
        }.lt);

        const lib = b.addLibrary(.{
            .name = "bearssl",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        lib.root_module.addIncludePath(b.path("vendor/bearssl/inc"));
        lib.root_module.addIncludePath(b.path("vendor/bearssl/src"));
        lib.root_module.addCSourceFiles(.{ .root = b.path("vendor/bearssl/src"), .files = files.items });
        bssl_lib = lib;
    }

    // ── nghttp2: HTTP/2 framing + HPACK (always compiled in) ──
    // Bindings are hand-written in src/net/nghttp2_c.zig (explicit extern
    // declarations). The C sources below provide the link-time symbols.
    const nghttp2_c_mod = b.createModule(.{
        .root_source_file = b.path("src/net/nghttp2_c.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const nghttp2_lib = blk: {
        const io = b.graph.io;
        var nghttp2_files: std.ArrayList([]const u8) = .empty;
        var nghttp2_src = std.Io.Dir.cwd().openDir(io, "vendor/nghttp2/lib", .{ .iterate = true }) catch {
            std.debug.print("error: vendor/nghttp2 missing — vendor nghttp2 v1.70.0 lib/*.c + includes/\n", .{});
            return;
        };
        defer nghttp2_src.close(io);
        var walker = nghttp2_src.walk(b.allocator) catch unreachable;
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".c")) continue;
            const rel = b.allocator.dupe(u8, entry.path) catch unreachable;
            nghttp2_files.append(b.allocator, rel) catch unreachable;
        }
        std.mem.sort([]const u8, nghttp2_files.items, {}, struct {
            fn lt(_: void, a: []const u8, bb: []const u8) bool {
                return std.mem.order(u8, a, bb) == .lt;
            }
        }.lt);

        const lib = b.addLibrary(.{
            .linkage = .static,
            .name = "nghttp2",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        lib.root_module.addIncludePath(b.path("vendor/nghttp2/lib"));
        lib.root_module.addIncludePath(b.path("vendor/nghttp2/includes"));
        lib.root_module.addCSourceFiles(.{
            .root = b.path("vendor/nghttp2/lib"),
            .files = nghttp2_files.items,
            .flags = &.{
                "-std=c99",
                // No autotools/cmake here, so no generated config.h: tell
                // nghttp2_net.h directly that the POSIX byte-order headers
                // exist. Without these, htons/htonl/ntohs/ntohl are
                // undeclared (hard error on musl; macOS libc declares them
                // transitively, which is why native builds passed).
                "-DHAVE_ARPA_INET_H",
                "-DHAVE_NETINET_IN_H",
            },
        });
        lib.installHeadersDirectory(b.path("vendor/nghttp2/includes"), "", .{});
        break :blk lib;
    };

    // ── SQLite: translated declarations module + compiled static library ──
    const sqltranslate = b.addTranslateC(.{
        .root_source_file = b.path("vendor/sqlite/zig_bridge.h"),
        .target = target,
        .optimize = optimize,
    });
    sqltranslate.addIncludePath(b.path("vendor/sqlite"));
    const sql_mod = sqltranslate.createModule();

    const mod_sqlite = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod_sqlite.addIncludePath(b.path("vendor/sqlite"));
    mod_sqlite.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{
            "-std=c99",
            "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
            "-DSQLITE_USE_ALLOCA=1",
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_TEMP_STORE=3",
            "-DSQLITE_ENABLE_API_ARMOR=1",
            "-DSQLITE_ENABLE_UNLOCK_NOTIFY",
            "-DSQLITE_DEFAULT_FILE_PERMISSIONS=0600",
            "-DSQLITE_OMIT_DECLTYPE=1",
            "-DSQLITE_OMIT_DEPRECATED=1",
            "-DSQLITE_OMIT_LOAD_EXTENSION=1",
            "-DSQLITE_OMIT_PROGRESS_CALLBACK=1",
            "-DSQLITE_OMIT_SHARED_CACHE",
            "-DSQLITE_OMIT_TRACE=1",
            "-DSQLITE_OMIT_UTF16=1",
        },
    });

    const sqlite_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "sqlite3",
        .root_module = mod_sqlite,
    });
    sqlite_lib.installHeadersDirectory(b.path("vendor/sqlite"), "", .{});

    // ── Executable ──
    const exe = b.addExecutable(.{
        .name = "ff",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
            .imports = &.{
                .{ .name = "xev", .module = b.addModule("xev-shim", .{
                    .root_source_file = b.path("src/xev.zig"),
                    .imports = &.{.{ .name = "xev-inner",
                        .module = b.dependency("libxev", .{}).module("xev"),
                    } },
                }) },
                .{ .name = "quickjs_c", .module = c_mod },
                .{ .name = "sqlite_c", .module = sql_mod },
                .{ .name = "nghttp2_c", .module = nghttp2_c_mod },
            },
        }),
    });

    // TLS wiring: build options + declarations module + static library.
    exe.root_module.addImport("ffcfg", ffcfg_mod);
    if (bearssl) {
        exe.root_module.addImport("bearssl_c", bssl_mod.?);
        exe.root_module.linkLibrary(bssl_lib.?);
    }

    // Link SQLite static library
    exe.root_module.linkLibrary(sqlite_lib);

    // Link nghttp2 static library (resolves the extern fn symbols
    // declared in src/net/nghttp2_c.zig)
    exe.root_module.linkLibrary(nghttp2_lib);

    // ── Compile QuickJS C sources ──
    const qjs_flags: []const []const u8 = &.{
        "-D_GNU_SOURCE",
    };

    exe.root_module.addCSourceFile(.{ .file = b.path("vendor/quickjs/quickjs.c"), .flags = qjs_flags });
    exe.root_module.addCSourceFile(.{ .file = b.path("vendor/quickjs/libregexp.c"), .flags = qjs_flags });
    exe.root_module.addCSourceFile(.{ .file = b.path("vendor/quickjs/libunicode.c"), .flags = qjs_flags });
    exe.root_module.addCSourceFile(.{ .file = b.path("vendor/quickjs/dtoa.c"), .flags = qjs_flags });

    exe.root_module.addIncludePath(b.path("vendor/quickjs"));

    exe.root_module.link_libc = true;
    exe.root_module.linkSystemLibrary("m", .{});

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
