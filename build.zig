const std = @import("std");

// Everything a runtime module needs: named imports, C libraries, QuickJS
// sources, system libs. Built once, shared by the exe, fuzzers and tests
// so the three roots can never drift apart.
const RuntimeLibs = struct {
    xev_shim: *std.Build.Module,
    c_mod: *std.Build.Module,
    sql_mod: *std.Build.Module,
    ffcfg_mod: *std.Build.Module,
    bssl_mod: ?*std.Build.Module,
    bssl_lib: ?*std.Build.Step.Compile,
    sqlite_lib: *std.Build.Step.Compile,
    nghttp2_lib: *std.Build.Step.Compile,
    qjs_flags: []const []const u8,
    bearssl: bool,
    ffi: bool,
};

fn runtimeModule(
    b: *std.Build,
    root_src: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    libs: RuntimeLibs,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path(root_src),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .imports = &.{
            .{ .name = "xev", .module = libs.xev_shim },
            .{ .name = "quickjs_c", .module = libs.c_mod },
            .{ .name = "sqlite_c", .module = libs.sql_mod },
        },
    });
    // Vendored C is not UBSan-clean: quickjs-ng v0.16.2's arena allocator
    // trips the C UB trap (ud2 → SIGILL) in x86_64 ReleaseSafe during
    // JS_NewRuntime, and the vendored static-lib modules would otherwise
    // leave __ubsan_handle_* references needing the UBSan runtime at link.
    // Keep Zig safety checks; disable C UB detection for every C module.
    mod.sanitize_c = .off;
    // TLS wiring: build options + declarations module + static library.
    mod.addImport("ffcfg", libs.ffcfg_mod);
    if (libs.bearssl) {
        mod.addImport("bearssl_c", libs.bssl_mod.?);
        mod.linkLibrary(libs.bssl_lib.?);
    }
    // Link SQLite static library
    mod.linkLibrary(libs.sqlite_lib);
    // Link nghttp2 static library (resolves the extern fn symbols
    // declared in src/net/nghttp2_c.zig)
    mod.linkLibrary(libs.nghttp2_lib);
    // ── Compile QuickJS C sources ──
    mod.addCSourceFile(.{ .file = b.path("vendor/quickjs/quickjs.c"), .flags = libs.qjs_flags });
    mod.addCSourceFile(.{ .file = b.path("vendor/quickjs/libregexp.c"), .flags = libs.qjs_flags });
    mod.addCSourceFile(.{ .file = b.path("vendor/quickjs/libunicode.c"), .flags = libs.qjs_flags });
    mod.addCSourceFile(.{ .file = b.path("vendor/quickjs/dtoa.c"), .flags = libs.qjs_flags });
    mod.addIncludePath(b.path("vendor/quickjs"));
    mod.linkSystemLibrary("m", .{});
    // Link system libffi only when FFI is enabled; otherwise compile
    // symbol stubs so the extern declarations in src/api/ffi.zig resolve.
    if (libs.ffi) {
        mod.linkSystemLibrary("ffi", .{});
    } else {
        mod.addCSourceFile(.{ .file = b.path("src/ffi_stubs.c"), .flags = &.{} });
    }
    return mod;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bearssl = b.option(bool, "bearssl", "Enable BearSSL TLS (https/wss)") orelse true;
    const ffi = b.option(bool, "ffi", "Enable FFI (dlopen native libraries)") orelse true; // NEW
    const io_uring = b.option(bool, "io_uring", "Use io_uring backend on Linux (default: true; -Dio_uring=false selects epoll)") orelse true;
    const strip = b.option(bool, "strip", "Strip debug info from the executable (default: ReleaseFast/ReleaseSmall)") orelse
        (optimize == .ReleaseFast or optimize == .ReleaseSmall);

    // ── Build-options module (ffcfg) ──
    const ffcfg_opts = b.addOptions();
    ffcfg_opts.addOption(bool, "bearssl", bearssl);
    ffcfg_opts.addOption(bool, "ffi", ffi); // NEW
    ffcfg_opts.addOption(bool, "io_uring", io_uring);
    const ff_version = b.option([]const u8, "version", "Runtime version string") orelse "0.2.0-beta";
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
        // Match the root module: no C UBSan for vendored C (see runtimeModule).
        lib.root_module.sanitize_c = .off;
        bssl_lib = lib;
    }

    // ── nghttp2: HTTP/2 framing + HPACK (always compiled in) ──
    // Bindings are hand-written in src/net/nghttp2_c.zig (explicit extern
    // declarations). The C sources below provide the link-time symbols.
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
        // Match the root module: no C UBSan for vendored C (see runtimeModule).
        lib.root_module.sanitize_c = .off;
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
    // Match the root module: no C UBSan for vendored C (see runtimeModule).
    mod_sqlite.sanitize_c = .off;

    const sqlite_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "sqlite3",
        .root_module = mod_sqlite,
    });
    sqlite_lib.installHeadersDirectory(b.path("vendor/sqlite"), "", .{});

    // Shared by exe, tests and fuzzers (one module instance, no duplicates).
    const xev_shim = b.addModule("xev-shim", .{
        .root_source_file = b.path("src/xev.zig"),
        .imports = &.{
            .{
                .name = "xev-inner",
                .module = b.dependency("libxev", .{}).module("xev"),
            },
            .{ .name = "ffcfg", .module = ffcfg_mod },
        },
    });

    // ── Compile QuickJS C sources ──
    const qjs_flags: []const []const u8 = &.{
        "-D_GNU_SOURCE",
    };

    const libs: RuntimeLibs = .{
        .xev_shim = xev_shim,
        .c_mod = c_mod,
        .sql_mod = sql_mod,
        .ffcfg_mod = ffcfg_mod,
        .bssl_mod = bssl_mod,
        .bssl_lib = bssl_lib,
        .sqlite_lib = sqlite_lib,
        .nghttp2_lib = nghttp2_lib,
        .qjs_flags = qjs_flags,
        .bearssl = bearssl,
        .ffi = ffi,
    };

    // ── Executable ──
    const exe = b.addExecutable(.{
        .name = "ff",
        .root_module = runtimeModule(b, "src/main.zig", target, optimize, libs),
    });
    exe.root_module.strip = strip;

    b.installArtifact(exe);

    // ── Fuzzers: deterministic, seed-driven parser fuzzers (src/fuzz_tests.zig).
    // Run: zig build fuzz -- <target|smoke> [seed] [--events-max=N]
    // Always fuzz in ReleaseSafe so OOB/overflow checks fire:
    //   zig build fuzz -Doptimize=ReleaseSafe -- smoke
    const fuzz_exe = b.addExecutable(.{
        .name = "fuzz",
        .root_module = runtimeModule(b, "src/fuzz_tests.zig", target, optimize, libs),
    });
    fuzz_exe.stack_size = 4 * 1024 * 1024;
    fuzz_exe.root_module.omit_frame_pointer = false;
    fuzz_exe.root_module.strip = false;

    const install_fuzz = b.addInstallArtifact(fuzz_exe, .{});
    const fuzz_build_step = b.step("fuzz:build", "Build fuzzers (no run)");
    fuzz_build_step.dependOn(&install_fuzz.step);

    const fuzz_run = b.addRunArtifact(fuzz_exe);
    if (b.args) |args| fuzz_run.addArgs(args);
    const fuzz_step = b.step("fuzz", "Run fuzzers (see src/fuzz_tests.zig)");
    fuzz_step.dependOn(&fuzz_run.step);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{ .root_module = runtimeModule(b, "src/unit_tests.zig", target, optimize, libs) });
    exe_tests.root_module.strip = false;
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    // ── Test binary for kcov: DWARF machine-code coverage needs no
    // compiler instrumentation, so this is a plain build of the same
    // tests. Run: zig build test:build -Doptimize=ReleaseSafe, then
    // kcov --include-path=./src kcov-output ./zig-out/bin/ff-test
    const install_tests = b.addInstallArtifact(exe_tests, .{ .dest_sub_path = "ff-test" });
    const test_build_step = b.step("test:build", "Build the test binary (no run, for kcov)");
    test_build_step.dependOn(&install_tests.step);
}
