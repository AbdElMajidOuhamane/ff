const std = @import("std");
const types = @import("types.zig");
const Import = types.Import;
const ImportType = types.ImportType;
const Export = types.Export;
const ExportType = types.ExportType;
const Allocator = std.mem.Allocator;

pub fn findImportEnd(src: []const u8) usize {
    var depth: i32 = 0;
    for (src, 0..) |ch, i| {
        if (ch == '{') {
            depth += 1;
        } else if (ch == '}') {
            depth -= 1;
        } else if (depth == 0 and (ch == ';' or ch == '\n')) {
            return i;
        }
    }
    return src.len;
}

pub fn findExportEnd(src: []const u8) usize {
    const trimmed = std.mem.trimStart(u8, src, " \t\n");
    const offset = src.len - trimmed.len;
    if (trimmed.len == 0) return 0;
    if (std.mem.startsWith(u8, trimmed, "function ") or std.mem.startsWith(u8, trimmed, "class ")) {
        var depth: i32 = 0;
        var found_open = false;
        for (trimmed, 0..) |ch, i| {
            if (ch == '{') {
                depth += 1;
                found_open = true;
            } else if (ch == '}') {
                depth -= 1;
                if (found_open and depth == 0) return offset + i + 1;
            }
        }
        return src.len;
    }
    if (std.mem.startsWith(u8, trimmed, "default ")) {
        const rest = trimmed[8..];
        if (std.mem.startsWith(u8, rest, "function ") or std.mem.startsWith(u8, rest, "class ")) {
            var depth: i32 = 0;
            var found_open = false;
            for (rest, 0..) |ch, i| {
                if (ch == '{') {
                    depth += 1;
                    found_open = true;
                } else if (ch == '}') {
                    depth -= 1;
                    if (found_open and depth == 0) return offset + 8 + i + 1;
                }
            }
            return src.len;
        }
    }
    const semi = std.mem.indexOf(u8, src, ";");
    return if (semi) |s| s else src.len;
}

pub fn extractIdentifier(stmt: []const u8) []const u8 {
    const keywords = [_][]const u8{ "function ", "const ", "let ", "var ", "class " };
    for (keywords) |kw| {
        if (std.mem.startsWith(u8, stmt, kw)) {
            const rest = std.mem.trim(u8, stmt[kw.len..], " \t\n");
            const end_pos = for (rest, 0..) |ch, i| {
                if (ch == ' ' or ch == '=' or ch == '(' or ch == '{' or ch == ';' or ch == ',') break i;
            } else rest.len;
            return rest[0..end_pos];
        }
    }
    const trimmed = std.mem.trim(u8, stmt, " \t\n");
    const end_pos = for (trimmed, 0..) |ch, i| {
        if (ch == ' ' or ch == '=' or ch == '(' or ch == '{' or ch == ';' or ch == ',') break i;
    } else trimmed.len;
    return trimmed[0..end_pos];
}

pub fn parseImportStatement(allocator: Allocator, stmt: []const u8, imports: *std.ArrayList(Import)) !void {
    const from_pos = std.mem.indexOf(u8, stmt, " from ");
    if (from_pos == null) return;
    const bindings_part = std.mem.trim(u8, stmt[0..from_pos.?], " \t\n");
    const specifier_part = std.mem.trim(u8, stmt[from_pos.? + 6 ..], " \t\n\"'");
    if (bindings_part.len == 0) return;
    if (std.mem.startsWith(u8, bindings_part, "* as ")) {
        const local_name = std.mem.trim(u8, bindings_part[5..], " \t\n");
        try imports.append(allocator, .{
            .specifier = try allocator.dupe(u8, specifier_part),
            .local_name = try allocator.dupe(u8, local_name),
            .export_name = try allocator.dupe(u8, local_name),
            .import_type = .namespace,
        });
    } else if (bindings_part[0] == '{') {
        const inner = std.mem.trim(u8, bindings_part[1..], " \t\n}");
        var iter = std.mem.splitScalar(u8, inner, ',');
        while (iter.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t\n");
            if (trimmed.len == 0) continue;
            const as_pos = std.mem.indexOf(u8, trimmed, " as ");
            const name = if (as_pos) |p|
                std.mem.trim(u8, trimmed[0..p], " \t\n")
            else
                trimmed;
            const local = if (as_pos) |p|
                std.mem.trim(u8, trimmed[p + 4 ..], " \t\n")
            else
                name;
            try imports.append(allocator, .{
                .specifier = try allocator.dupe(u8, specifier_part),
                .local_name = try allocator.dupe(u8, local),
                .export_name = try allocator.dupe(u8, name),
                .import_type = .named,
            });
        }
    } else {
        try imports.append(allocator, .{
            .specifier = try allocator.dupe(u8, specifier_part),
            .local_name = try allocator.dupe(u8, bindings_part),
            .export_name = try allocator.dupe(u8, "default"),
            .import_type = .default,
        });
    }
}

pub fn parseImports(allocator: Allocator, source: []const u8, imports: *std.ArrayList(Import)) !void {
    var remaining = source;
    while (remaining.len > 0) {
        const import_pos = std.mem.indexOf(u8, remaining, "import ");
        if (import_pos == null) break;
        remaining = remaining[import_pos.? + 7 ..];
        if (remaining.len > 0 and remaining[0] == '(') continue;
        const end_stmt = findImportEnd(remaining);
        const stmt = remaining[0..end_stmt];
        remaining = remaining[end_stmt..];
        if (stmt.len == 0) continue;
        if (std.mem.startsWith(u8, stmt, "type ")) continue;
        try parseImportStatement(allocator, stmt, imports);
    }
}

pub fn parseExportStatement(allocator: Allocator, stmt: []const u8, exports: *std.ArrayList(Export)) !void {
    if (std.mem.startsWith(u8, stmt, "default ")) {
        try exports.append(allocator, .{
            .export_type = .default,
            .name = "default",
            .local_name = try allocator.dupe(u8, stmt[8..]),
            .source = null,
        });
    } else if (std.mem.startsWith(u8, stmt, "* from ")) {
        const specifier = std.mem.trim(u8, stmt[7..], " \t\n\"'");
        try exports.append(allocator, .{
            .export_type = .reexport,
            .name = "*",
            .local_name = "",
            .source = try allocator.dupe(u8, specifier),
        });
    } else if (stmt[0] == '{') {
        const inner = std.mem.trim(u8, stmt[1..], " \t\n}");
        var iter = std.mem.splitScalar(u8, inner, ',');
        while (iter.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t\n");
            if (trimmed.len == 0) continue;
            const as_pos = std.mem.indexOf(u8, trimmed, " as ");
            const name = if (as_pos) |p|
                std.mem.trim(u8, trimmed[0..p], " \t\n")
            else
                trimmed;
            const local_name = if (as_pos) |p|
                std.mem.trim(u8, trimmed[p + 4 ..], " \t\n")
            else
                trimmed;
            try exports.append(allocator, .{
                .export_type = .named,
                .name = try allocator.dupe(u8, name),
                .local_name = try allocator.dupe(u8, local_name),
                .source = null,
            });
        }
    } else {
        const name = extractIdentifier(stmt);
        if (name.len > 0) {
            try exports.append(allocator, .{
                .export_type = .named,
                .name = try allocator.dupe(u8, name),
                .local_name = try allocator.dupe(u8, name),
                .source = null,
            });
        }
    }
}

pub fn parseExports(allocator: Allocator, source: []const u8, exports: *std.ArrayList(Export)) !void {
    var remaining = source;
    while (remaining.len > 0) {
        const export_pos = std.mem.indexOf(u8, remaining, "export ");
        if (export_pos == null) break;
        remaining = remaining[export_pos.? + 7 ..];
        if (remaining.len == 0) continue;
        const end = findExportEnd(remaining);
        const stmt = remaining[0..end];
        remaining = remaining[end..];
        if (stmt.len == 0) continue;
        try parseExportStatement(allocator, stmt, exports);
    }
}
