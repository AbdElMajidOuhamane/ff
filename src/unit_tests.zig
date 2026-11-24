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
test {
    _ = @import("modules/resolver.zig");
}

test {
    _ = @import("crypto/bcrypt_pool.zig");
}

test {
    _ = @import("util/limits.zig");
}

test {
    _ = @import("engine/interrupt.zig");
}

test {
    _ = @import("security/sandbox.zig");
}

test {
    _ = @import("api/console.zig");
}

test {
    _ = @import("event/microtasks.zig");
}

test {
    _ = @import("api/fs.zig");
}

test {
    _ = @import("api/cron.zig");
}

test {
    _ = @import("util/env_file.zig");
}

test {
    _ = @import("types/blob.zig");
}

test {
    _ = @import("types/formdata.zig");
}

test {
    _ = @import("types/pool_slice.zig");
}

test {
    _ = @import("api/url.zig");
}

test {
    _ = @import("api/sql.zig");
}

test {
    _ = @import("util/counting_allocator.zig");
}

test {
    _ = @import("worker/thread_marker.zig");
}
