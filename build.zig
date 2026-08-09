const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("fairyfly", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    const httpz = b.dependency("httpz", .{
    .target = target,
    .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "ff",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
            .imports = &.{
                .{ .name = "fairyfly", .module = mod },
                .{ .name = "xev", .module = b.dependency("libxev", .{}).module("xev") },
                .{ .name = "httpz", .module = httpz.module("httpz") },
            },
        }),
    });

    // Include path for @cImport in engine.zig
    exe.root_module.addIncludePath(.{ .cwd_relative = "vendor/v8/include" });

    // Add C stubs for V8 inspector and memory allocator
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/engine/stubs.c"),
        .flags = &.{},
    });

    // Link V8 C bindings library
    exe.root_module.addLibraryPath(.{ .cwd_relative = "vendor/v8/lib" });
    exe.root_module.linkSystemLibrary("c_v8", .{
        .preferred_link_mode = .static,
    });

    // System libraries needed by V8
    exe.root_module.link_libc = true;
    exe.root_module.linkSystemLibrary("pthread", .{});
    exe.root_module.linkSystemLibrary("m", .{});
    exe.root_module.linkSystemLibrary("dl", .{});

    // macOS frameworks needed by V8
    exe.root_module.linkFramework("CoreFoundation", .{});
    exe.root_module.linkFramework("CoreServices", .{});
    exe.root_module.linkFramework("Security", .{});
    exe.root_module.linkFramework("IOKit", .{});
    exe.root_module.linkFramework("Foundation", .{});

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
