const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bearssl = b.option(bool, "bearssl", "Enable BearSSL TLS (https/wss)") orelse true;

    // ── Build-options module (ffcfg) ──
    const ffcfg_opts = b.addOptions();
    ffcfg_opts.addOption(bool, "bearssl", bearssl);
    const ffcfg_mod = ffcfg_opts.createModule();

    // ── QuickJS C translation (auto-generates types + inline functions) ──
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("vendor/quickjs/quickjs.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(b.path("vendor/quickjs"));
    const c_mod = translate.createModule();

    // ── Fairyfly library module ──
    const mod = b.addModule("fairyfly", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{.{
            .name = "quickjs_c",
            .module = c_mod,
        }},
    });

    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });

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

        // Collect every BearSSL .c file under vendor/bearssl/src (deterministic order).
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
        // In Zig 0.16 include paths and C sources live on Module, not Compile.
        lib.root_module.addIncludePath(b.path("vendor/bearssl/inc"));
        lib.root_module.addIncludePath(b.path("vendor/bearssl/src"));
        lib.root_module.addCSourceFiles(.{ .root = b.path("vendor/bearssl/src"), .files = files.items });
        bssl_lib = lib;
    }

    // ── Executable ──
    const exe = b.addExecutable(.{
        .name = "ff",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
            .imports = &.{
                .{ .name = "fairyfly", .module = mod },
                .{ .name = "xev", .module = b.addModule("xev-shim", .{
                    .root_source_file = b.path("src/xev.zig"),
                    .imports = &.{.{ .name = "xev-inner",
                        .module = b.dependency("libxev", .{}).module("xev"),
                    } },
                }) },
                .{ .name = "httpz", .module = httpz.module("httpz") },
                .{ .name = "quickjs_c", .module = c_mod },
            },
        }),
    });

    // TLS wiring: build options + declarations module + static library.
    exe.root_module.addImport("ffcfg", ffcfg_mod);
    if (bearssl) {
        exe.root_module.addImport("bearssl_c", bssl_mod.?);
        exe.root_module.linkLibrary(bssl_lib.?);
    }

    // ── Compile QuickJS C sources ──
    const qjs_flags: []const []const u8 = &.{
        "-DCONFIG_VERSION=\"2024_01_13\"",
        "-DCONFIG_BIGNUM",
        "-DCONFIG_CHECK_OPTIONS",
        "-D_GNU_SOURCE",
    };

    exe.root_module.addCSourceFile(.{ .file = b.path("vendor/quickjs/quickjs.c"), .flags = qjs_flags });
    exe.root_module.addCSourceFile(.{ .file = b.path("vendor/quickjs/cutils.c"), .flags = qjs_flags });
    exe.root_module.addCSourceFile(.{ .file = b.path("vendor/quickjs/libregexp.c"), .flags = qjs_flags });
    exe.root_module.addCSourceFile(.{ .file = b.path("vendor/quickjs/libunicode.c"), .flags = qjs_flags });
    exe.root_module.addCSourceFile(.{ .file = b.path("vendor/quickjs/dtoa.c"), .flags = qjs_flags });
    exe.root_module.addCSourceFile(.{ .file = b.path("vendor/quickjs/quickjs-libc.c"), .flags = qjs_flags });

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

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
