// `zig build test` collects `test` blocks ONLY from files reached via
// `test { _ = @import(...); }` from this root. Plain const-imports (as in
// src/main.zig) do NOT propagate test discovery — that silently ran zero
// tests. Every file with colocated `test` blocks gets a line here.

test {
    _ = @import("commands/semver.zig");
}

test {
    _ = @import("commands/imprint.zig");
}

test {
    _ = @import("net/http_native.zig");
}

test {
    _ = @import("net/http2_server.zig");
}

test {
    _ = @import("net/nghttp2_c.zig");
}

test {
    _ = @import("net/udp_native.zig");
}

test {
    _ = @import("net/ws_native.zig");
}

test {
    _ = @import("net/proxy.zig");
}

test {
    _ = @import("types/headers.zig");
}

test {
    _ = @import("types/response.zig");
}

test {
    _ = @import("types/request.zig");
}
test {
    _ = @import("api/child_process.zig");
}

test {
    _ = @import("util/cli.zig");
}

test {
    _ = @import("security/permissions.zig");
}
