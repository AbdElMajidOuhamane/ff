const std = @import("std");

// NO_PROXY support. std.http.Client implements HTTP proxying itself
// (http_proxy/https_proxy + CONNECT), but not the NO_PROXY bypass list —
// this module parses the env value and decides which hosts bypass the
// proxy; net/tls.zig routes those to a second, proxy-free client.
//
// Entry grammar (curl-like):
//   *                  bypass every host
//   example.com        host itself and any subdomain
//   .example.com       same (leading dot / "*." accepted, ignored)
//   example.com:8080   only that port
//   [::1]:8080         bracketed IPv6 with port
//   ::1                bare IPv6 (no port; >1 colon = not a port split)
// Matching is case-insensitive. Entries borrow `raw` (the env string), which
// is process-lifetime storage on POSIX.

pub const Entry = struct {
    host: []const u8,
    port: ?u16 = null,
};

pub const NoProxy = struct {
    bypass_all: bool = false,
    entries: []const Entry = &.{},

    pub fn bypasses(self: NoProxy, host: []const u8, port: u16) bool {
        if (self.bypass_all) return true;
        const h = stripBrackets(host);
        for (self.entries) |e| {
            if (e.port) |p| {
                if (p != port) continue;
            }
            if (hostMatches(h, e.host)) return true;
        }
        return false;
    }

    pub fn deinit(self: NoProxy, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
    }
};

fn stripBrackets(host: []const u8) []const u8 {
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']')
        return host[1 .. host.len - 1];
    return host;
}

fn hostMatches(host: []const u8, entry: []const u8) bool {
    const e = stripBrackets(entry);
    if (e.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(host, e)) return true;
    if (host.len > e.len + 1) {
        const tail = host[host.len - e.len ..];
        if (host[host.len - e.len - 1] == '.' and std.ascii.eqlIgnoreCase(tail, e))
            return true;
    }
    return false;
}

fn allDigits(s: []const u8) bool {
    for (s) |ch| {
        if (ch < '0' or ch > '9') return false;
    }
    return s.len > 0;
}

pub fn parse(allocator: std.mem.Allocator, raw: []const u8) !NoProxy {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(allocator);
    var bypass_all = false;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |raw_entry| {
        const entry = std.mem.trim(u8, raw_entry, " \t");
        if (entry.len == 0) continue;
        if (std.mem.eql(u8, entry, "*")) {
            bypass_all = true;
            continue;
        }

        var host_part = entry;
        var port: ?u16 = null;
        if (entry[0] == '[') {
            // [v6] or [v6]:port
            const close = std.mem.indexOfScalar(u8, entry, ']') orelse continue;
            host_part = entry[0 .. close + 1];
            const rest = entry[close + 1 ..];
            if (rest.len > 0) {
                if (rest[0] != ':') continue;
                port = std.fmt.parseInt(u16, rest[1..], 10) catch continue;
            }
        } else if (std.mem.count(u8, entry, ":") == 1) {
            // host:port — a bare IPv6 has more than one colon and is left whole.
            const colon = std.mem.indexOfScalar(u8, entry, ':').?;
            const maybe_port = entry[colon + 1 ..];
            if (allDigits(maybe_port)) {
                port = std.fmt.parseInt(u16, maybe_port, 10) catch continue;
                host_part = entry[0..colon];
            }
        }

        var h = std.mem.trim(u8, host_part, " \t");
        if (std.mem.startsWith(u8, h, "*.")) {
            h = h[2..];
        } else if (h.len > 0 and h[0] == '.') {
            h = h[1..];
        }
        if (h.len == 0) continue;
        try entries.append(allocator, .{ .host = h, .port = port });
    }
    return .{
        .bypass_all = bypass_all,
        .entries = try entries.toOwnedSlice(allocator),
    };
}

// ---- tests (wired via src/unit_tests.zig) ----

test "no_proxy: empty and whitespace entries" {
    const allocator = std.testing.allocator;
    const np = try parse(allocator, "");
    defer np.deinit(allocator);
    try std.testing.expect(!np.bypasses("example.com", 80));

    const np2 = try parse(allocator, " , ,");
    defer np2.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), np2.entries.len);
}

test "no_proxy: star bypasses everything" {
    const allocator = std.testing.allocator;
    const np = try parse(allocator, "*");
    defer np.deinit(allocator);
    try std.testing.expect(np.bypasses("anything.example", 443));
}

test "no_proxy: exact, suffix, and case-insensitive matches" {
    const allocator = std.testing.allocator;
    const np = try parse(allocator, "Example.COM, .internal.test");
    defer np.deinit(allocator);
    try std.testing.expect(np.bypasses("example.com", 80));
    try std.testing.expect(np.bypasses("EXAMPLE.com", 80));
    try std.testing.expect(np.bypasses("api.example.com", 80));
    try std.testing.expect(np.bypasses("db.internal.test", 5432));
    try std.testing.expect(!np.bypasses("notexample.com", 80));
    try std.testing.expect(!np.bypasses("internal.test.evil", 80));
}

test "no_proxy: port-scoped entries" {
    const allocator = std.testing.allocator;
    const np = try parse(allocator, "example.com:8080, *.other.test:443");
    defer np.deinit(allocator);
    try std.testing.expect(np.bypasses("example.com", 8080));
    try std.testing.expect(!np.bypasses("example.com", 80));
    try std.testing.expect(np.bypasses("sub.other.test", 443));
    try std.testing.expect(!np.bypasses("sub.other.test", 80));
}

test "no_proxy: ipv4, ipv6, localhost" {
    const allocator = std.testing.allocator;
    const np = try parse(allocator, "127.0.0.1, localhost, [::1]:8080");
    defer np.deinit(allocator);
    try std.testing.expect(np.bypasses("127.0.0.1", 80));
    try std.testing.expect(np.bypasses("localhost", 3000));
    try std.testing.expect(np.bypasses("[::1]", 8080));
    try std.testing.expect(np.bypasses("::1", 8080));
    try std.testing.expect(!np.bypasses("::1", 80));
    try std.testing.expect(!np.bypasses("127.0.0.2", 80));
}

test "no_proxy: bare ipv6 entry has no port" {
    const allocator = std.testing.allocator;
    const np = try parse(allocator, "::1");
    defer np.deinit(allocator);
    try std.testing.expect(np.bypasses("::1", 443));
}
