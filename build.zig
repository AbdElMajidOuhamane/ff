const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
