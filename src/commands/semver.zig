const std = @import("std");

// Minimal SemVer for registry ranges. Supports: exact, "=", "^", "~",
// ">=", "<=", ">", "<", "*", partials ("1", "1.2", "1.x"), and
// space-separated AND sets (">=1.0.0 <2.0.0").
// "||", hyphen ranges, npm: aliases -> error.UnsupportedRange (fail loud).
// Prerelease candidates are skipped unless the range itself names one.
// NOTE: Version.pre borrows the input slice (packument keys / range text,
// both alive for the whole resolve run). Never store past run end.

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    pre: []const u8 = "",
};

pub fn parseVersion(s: []const u8) !Version {
    var t = std.mem.trim(u8, s, " \t");
    if (t.len > 0 and (t[0] == 'v' or t[0] == '=')) t = t[1..];
    if (std.mem.indexOfScalar(u8, t, '+')) |i| t = t[0..i];
    var v = Version{ .major = 0, .minor = 0, .patch = 0 };
    var parts = std.mem.splitScalar(u8, t, '.');
    var idx: usize = 0;
    while (parts.next()) |p| {
        if (idx >= 3) return error.BadVersion;
        var num = p;
        if (idx == 2) {
            if (std.mem.indexOfScalar(u8, p, '-')) |d| {
                v.pre = p[d + 1 ..];
                num = p[0..d];
            }
        } else if (std.mem.indexOfScalar(u8, p, '-') != null) {
            return error.BadVersion;
        }
        const n = std.fmt.parseInt(u32, num, 10) catch return error.BadVersion;
        switch (idx) {
            0 => v.major = n,
            1 => v.minor = n,
            2 => v.patch = n,
            else => unreachable,
        }
        idx += 1;
    }
    if (idx != 3) return error.BadVersion;
    return v;
}

pub fn compare(a: Version, b: Version) std.math.Order {
    if (a.major != b.major) return std.math.order(a.major, b.major);
    if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
    if (a.patch != b.patch) return std.math.order(a.patch, b.patch);
    if (a.pre.len == 0 and b.pre.len == 0) return .eq;
    if (a.pre.len == 0) return .gt;
    if (b.pre.len == 0) return .lt;
    return std.mem.order(u8, a.pre, b.pre);
}

fn isWild(s: []const u8) bool {
    return s.len == 0 or std.mem.eql(u8, s, "x") or std.mem.eql(u8, s, "X") or std.mem.eql(u8, s, "*");
}

const Partial = struct {
    base: Version,
    has_upper: bool,
    upper: Version,
};

fn unbounded() Partial {
    return .{
        .base = .{ .major = 0, .minor = 0, .patch = 0 },
        .has_upper = false,
        .upper = .{ .major = 0, .minor = 0, .patch = 0 },
    };
}

fn parsePartial(s: []const u8) !Partial {
    var t = std.mem.trim(u8, s, " \t");
    if (t.len > 0 and t[0] == 'v') t = t[1..];
    if (t.len == 0 or std.mem.eql(u8, t, "*") or std.mem.eql(u8, t, "x") or std.mem.eql(u8, t, "X")) return unbounded();
    const dash = std.mem.indexOfScalar(u8, t, '-');
    const core = if (dash) |d| t[0..d] else t;
    var comps: [3][]const u8 = .{ "", "", "" };
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, core, '.');
    while (it.next()) |p| {
        if (n >= 3) return error.BadRange;
        comps[n] = p;
        n += 1;
    }
    if (isWild(comps[0])) return unbounded();
    const major = std.fmt.parseInt(u32, comps[0], 10) catch return error.BadRange;
    if (n < 2 or isWild(comps[1])) {
        return .{
            .base = .{ .major = major, .minor = 0, .patch = 0 },
            .has_upper = true,
            .upper = .{ .major = major + 1, .minor = 0, .patch = 0 },
        };
    }
    const minor = std.fmt.parseInt(u32, comps[1], 10) catch return error.BadRange;
    if (n < 3 or isWild(comps[2])) {
        return .{
            .base = .{ .major = major, .minor = minor, .patch = 0 },
            .has_upper = true,
            .upper = .{ .major = major, .minor = minor + 1, .patch = 0 },
        };
    }
    return .{ .base = try parseVersion(t), .has_upper = false, .upper = .{ .major = 0, .minor = 0, .patch = 0 } };
}

fn caretUpper(v: Version) Version {
    if (v.major > 0) return .{ .major = v.major + 1, .minor = 0, .patch = 0 };
    if (v.minor > 0) return .{ .major = 0, .minor = v.minor + 1, .patch = 0 };
    return .{ .major = 0, .minor = 0, .patch = v.patch + 1 };
}

fn tildeUpper(v: Version) Version {
    return .{ .major = v.major, .minor = v.minor + 1, .patch = 0 };
}

fn isPartialToken(t: []const u8) bool {
    if (t.len == 0) return false;
    if (t[0] == '>' or t[0] == '<' or t[0] == '=' or t[0] == '^' or t[0] == '~') return false;
    var dots: usize = 0;
    for (t) |ch| {
        if (ch == '.') dots += 1;
        if (ch == 'x' or ch == 'X' or ch == '*') return true;
    }
    return dots < 2;
}

pub fn satisfies(v: Version, range: []const u8) !bool {
    const r = std.mem.trim(u8, range, " \t");
    if (r.len == 0 or std.mem.eql(u8, r, "*") or std.mem.eql(u8, r, "latest")) {
        return v.pre.len == 0;
    }
    if (std.mem.indexOf(u8, r, "||") != null) return error.UnsupportedRange;
    if (std.mem.indexOf(u8, r, " - ") != null) return error.UnsupportedRange;
    const names_pre = std.mem.indexOfScalar(u8, r, '-') != null;
    var it = std.mem.splitScalar(u8, r, ' ');
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t");
        if (t.len == 0) continue;
        if (t[0] == '^') {
            const p = try parsePartial(t[1..]);
            if (compare(v, p.base) == .lt) return false;
            if (compare(v, caretUpper(p.base)) != .lt) return false;
        } else if (t[0] == '~') {
            const p = try parsePartial(t[1..]);
            if (compare(v, p.base) == .lt) return false;
            if (compare(v, tildeUpper(p.base)) != .lt) return false;
        } else if (isPartialToken(t)) {
            const p = try parsePartial(t);
            if (compare(v, p.base) == .lt) return false;
            if (p.has_upper and compare(v, p.upper) != .lt) return false;
        } else {
            var op: enum { eq, gt, gte, lt, lte } = .eq;
            var body = t;
            if (std.mem.startsWith(u8, t, ">=")) {
                op = .gte;
                body = t[2..];
            } else if (std.mem.startsWith(u8, t, "<=")) {
                op = .lte;
                body = t[2..];
            } else if (std.mem.startsWith(u8, t, ">")) {
                op = .gt;
                body = t[1..];
            } else if (std.mem.startsWith(u8, t, "<")) {
                op = .lt;
                body = t[1..];
            } else if (body[0] == '=') {
                body = body[1..];
            }
            const c = try parseVersion(body);
            const ord = compare(v, c);
            // FIX: Order is only .eq/.lt/.gt — no .gte/.lte members.
            const ok = switch (op) {
                .eq => ord == .eq,
                .gt => ord == .gt,
                .gte => ord != .lt,
                .lt => ord == .lt,
                .lte => ord != .gt,
            };
            if (!ok) return false;
        }
    }
    if (v.pre.len > 0 and !names_pre) return false;
    return true;
}

pub fn maxSatisfying(versions: []const []const u8, range: []const u8) !?[]const u8 {
    var best: ?[]const u8 = null;
    var best_v: Version = .{ .major = 0, .minor = 0, .patch = 0 };
    var have_best = false;
    for (versions) |sv| {
        const v = parseVersion(sv) catch continue;
        const ok = satisfies(v, range) catch |err| {
            if (err == error.UnsupportedRange) return err;
            continue;
        };
        if (!ok) continue;
        if (!have_best or compare(v, best_v) == .gt) {
            best = sv;
            best_v = v;
            have_best = true;
        }
    }
    return best;
}
