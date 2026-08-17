const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig").c;

// Canonical single source of truth for the version surface:
// process.version / process.versions, ff --version, init scaffold.
pub const version = "0.0.1";

// Drawn straight from vendor/v8/include/v8-version.h at compile time.
pub const v8: []const u8 = if (c.V8_IS_CANDIDATE_VERSION == 1)
    std.fmt.comptimePrint("{d}.{d}.{d}-candidate", .{
        @as(usize, @intCast(c.V8_MAJOR_VERSION)),
        @as(usize, @intCast(c.V8_MINOR_VERSION)),
        @as(usize, @intCast(c.V8_BUILD_NUMBER)),
    })
else
    std.fmt.comptimePrint("{d}.{d}.{d}", .{
        @as(usize, @intCast(c.V8_MAJOR_VERSION)),
        @as(usize, @intCast(c.V8_MINOR_VERSION)),
        @as(usize, @intCast(c.V8_BUILD_NUMBER)),
    });

pub const zig_version: []const u8 = builtin.zig_version_string;

pub const platform: []const u8 = switch (builtin.os.tag) {
    .macos => "darwin",
    .linux => "linux",
    .windows => "win32",
    .freebsd => "freebsd",
    else => "unknown",
};

pub const arch: []const u8 = switch (builtin.cpu.arch) {
    .aarch64 => "arm64",
    .x86_64 => "x64",
    .x86 => "ia32",
    .riscv64 => "riscv64",
    else => "unknown",
};
