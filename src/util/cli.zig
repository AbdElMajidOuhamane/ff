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

// Status glyphs. Kept as UTF-8 in every mode; only color is TTY-gated.
pub const glyph_ok = "✓";
pub const glyph_step = "→";
pub const glyph_fail = "✗";
pub const glyph_bullet = "•";

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

/// Success confirmation: green check when colored.
pub fn ok(comptime fmt: []const u8, args: anytype) void {
    if (useColor()) {
        std.debug.print(green ++ glyph_ok ++ reset ++ " " ++ fmt ++ "\n", args);
    } else {
        std.debug.print(glyph_ok ++ " " ++ fmt ++ "\n", args);
    }
}

/// Neutral action/progress line: dim arrow when colored.
pub fn step(comptime fmt: []const u8, args: anytype) void {
    if (useColor()) {
        std.debug.print(dim ++ glyph_step ++ reset ++ " " ++ fmt ++ "\n", args);
    } else {
        std.debug.print(glyph_step ++ " " ++ fmt ++ "\n", args);
    }
}

/// Secondary detail under a step: dim bullet when colored.
pub fn bullet(comptime fmt: []const u8, args: anytype) void {
    if (useColor()) {
        std.debug.print("  " ++ dim ++ glyph_bullet ++ reset ++ " " ++ fmt ++ "\n", args);
    } else {
        std.debug.print("  " ++ glyph_bullet ++ " " ++ fmt ++ "\n", args);
    }
}

/// Section title: bold when colored.
pub fn heading(comptime text: []const u8) void {
    if (useColor()) {
        std.debug.print(bold ++ text ++ reset ++ "\n", .{});
    } else {
        std.debug.print(text ++ "\n", .{});
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
    heading("Usage:");
    std.debug.print("  ff <file.js> [--ca <path>] [--allow-ffi]\n", .{});
    std.debug.print("  ff -e <code> [--ca <path>] [--allow-ffi]\n", .{});
    std.debug.print("  ff --watch <file|start> [--ca <path>]\n", .{});
    std.debug.print("  ff <command> [options]\n", .{});
    std.debug.print("\n", .{});
    heading("Commands:");
    helpItem("init [-y] [<dir>]", "Initialize a new project");
    helpItem("start", "Run the project (main from ff.json)");
    helpItem("test [filter]", "Run test/*.test.js");
    helpItem("repl", "Interactive REPL");
    helpItem("imprint [pkg...]", "Add exact dep(s) to ff.json + ff.lock");
    helpItem("sever [pkg...]", "Remove dep(s)");
    helpItem("compile <file.js>", "Compile to bytecode (-o out.ffbc)");
    helpItem("fmt <files...>", "Format via prettier (--write|--check)");
    helpItem("upgrade [--check]", "Self-update from GitHub Releases");
    helpItem("help", "Show this help");
    std.debug.print("\n", .{});
    heading("Options:");
    helpItem("--ca <path>", "Trust an extra CA bundle (ff <file> / ff -e)");
    helpItem("--cert, --key", "PEM cert/key for TLS (ff start)");
    helpItem("--allow-ffi", "Allow ffi.dlopen (native libraries)");
    helpItem("--version", "Print runtime version");
    helpItem("-h, --help", "Show this help");
}

const help_column = 22;

// One aligned row in the usage summary (bold command when colored).
pub fn helpItem(comptime cmd: []const u8, comptime desc: []const u8) void {
    const pad: []const u8 = if (cmd.len < help_column) "                      "[0 .. help_column - cmd.len] else " ";
    if (useColor()) {
        std.debug.print("  " ++ bold ++ "{s}" ++ reset ++ "{s}{s}\n", .{ cmd, pad, desc });
    } else {
        std.debug.print("  {s}{s}{s}\n", .{ cmd, pad, desc });
    }
}

test "fileErrText maps common open failures" {
    try std.testing.expectEqualStrings("no such file", fileErrText(error.FileNotFound));
    try std.testing.expectEqualStrings("permission denied", fileErrText(error.AccessDenied));
    try std.testing.expectEqualStrings("is a directory", fileErrText(error.IsDir));
}
