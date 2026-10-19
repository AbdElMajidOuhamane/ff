const std = @import("std");

// Shared presentation for ff's own CLI messages.
//
// Scope: Zig-side diagnostics only. JS runtime exceptions keep their own
// "Error: ..." rendering (engine.zig reportAndFail, repl.zig) — do not route
// those through here.
//
// Everything goes to stderr via std.debug.print, matching the existing
// convention across the command modules.

pub const red = "\x1b[31m";
pub const green = "\x1b[32m";
pub const yellow = "\x1b[33m";
pub const dim = "\x1b[2m";
pub const bold = "\x1b[1m";
pub const reset = "\x1b[0m";

// -1 = not probed yet, 0 = plain, 1 = color.
var color_state: i8 = -1;

/// Color only when stderr is a terminal and NO_COLOR is unset
/// (https://no-color.org — presence of the variable disables color).
pub fn useColor() bool {
    if (color_state < 0) {
        color_state = if (std.c.isatty(2) != 0 and std.c.getenv("NO_COLOR") == null) 1 else 0;
    }
    return color_state == 1;
}

/// Friendly text for the common file-open failures.
pub fn fileErrText(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "no such file",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.IsDir => "is a directory",
        error.NotDir => "not a directory",
        error.NameTooLong => "name too long",
        error.SymLinkLoop => "too many symbolic links",
        error.StreamTooLong, error.FileTooBig => "file too large",
        else => @errorName(err),
    };
}

pub fn errorMsg(comptime fmt: []const u8, args: anytype) void {
    if (useColor()) {
        std.debug.print(red ++ "error" ++ reset ++ ": " ++ fmt ++ "\n", args);
    } else {
        std.debug.print("error: " ++ fmt ++ "\n", args);
    }
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    if (useColor()) {
        std.debug.print(yellow ++ "warning" ++ reset ++ ": " ++ fmt ++ "\n", args);
    } else {
        std.debug.print("warning: " ++ fmt ++ "\n", args);
    }
}

pub fn hint(comptime fmt: []const u8, args: anytype) void {
    if (useColor()) {
        std.debug.print(dim ++ "hint: " ++ fmt ++ reset ++ "\n", args);
    } else {
        std.debug.print("hint: " ++ fmt ++ "\n", args);
    }
}

/// Print `error: <message>` and exit 1.
pub fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    errorMsg(fmt, args);
    std.process.exit(1);
}

/// Print `error: <message>` + a dim `hint:` line, then exit 1.
pub fn failWithHint(
    comptime msg_fmt: []const u8,
    msg_args: anytype,
    comptime hint_fmt: []const u8,
    hint_args: anytype,
) noreturn {
    errorMsg(msg_fmt, msg_args);
    hint(hint_fmt, hint_args);
    std.process.exit(1);
}

/// Usage error: `error: <message>`, a one-line `Usage:` reminder, exit 1.
pub fn usageFail(comptime usage: []const u8, comptime fmt: []const u8, args: anytype) noreturn {
    errorMsg(fmt, args);
    std.debug.print("Usage: {s}\n", .{usage});
    std.process.exit(1);
}

pub fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  ff init [-y|--yes] [<dir>]  Initialize a new project
        \\  ff imprint [pkg[@ver] ...]  Add exact dep(s) to ff.json + ff.lock
        \\  ff sever [pkg ...] [--force]  Remove dep(s)
        \\  ff start [--cert cert.pem --key key.pem]   Run the project
        \\  ff test [filter]     Run test/*.test.js
        \\  ff repl              Interactive REPL
        \\  ff upgrade [--check] Self-update from GitHub Releases
        \\  ff compile <f.js> [-o out.ffbc]  Compile to bytecode
        \\  ff fmt [--write|--check] <files...>  Format via prettier
        \\  ff --watch <file|start>  Restart on file changes
        \\  ff -e <code>         Run inline JavaScript
        \\  ff <file.js>         Run a JavaScript file
        \\  --allow-ffi           Allow ffi.dlopen (native libraries)
        \\  ff --version         Print runtime version
        \\  -h, --help           Show this help
        \\
    , .{});
}

test "fileErrText maps common open failures" {
    try std.testing.expectEqualStrings("no such file", fileErrText(error.FileNotFound));
    try std.testing.expectEqualStrings("permission denied", fileErrText(error.AccessDenied));
    try std.testing.expectEqualStrings("is a directory", fileErrText(error.IsDir));
}
