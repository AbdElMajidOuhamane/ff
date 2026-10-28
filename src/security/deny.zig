const std = @import("std");
const c = @import("../c.zig").c;
const perm = @import("permissions.zig");

pub fn flag(kind: perm.Kind) []const u8 {
    return switch (kind) {
        .read => "--allow-read",
        .write => "--allow-write",
        .net => "--allow-net",
        .env => "--allow-env",
        .run => "--allow-run",
        .ffi => "--allow-ffi",
    };
}

/// Build a PermissionDenied Error. Caller owns the value.
pub fn make(ctx: ?*c.Context, api: []const u8, kind: perm.Kind, detail: []const u8) c.Value {
    var msg_buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &msg_buf,
        "{s} requires {s} for '{s}'",
        .{ api, flag(kind), detail },
    ) catch "permission denied";

    const err = c.newError(ctx);
    if (c.isException(err) != 0) return err;

    const name = c.newStringLen(ctx, "PermissionDenied", 16);
    _ = c.definePropertyValueStr(ctx, err, "name", name, c.PROP_C_W_E);
    const code = c.newStringLen(ctx, "PERMISSION_DENIED", 17);
    _ = c.definePropertyValueStr(ctx, err, "code", code, c.PROP_C_W_E);
    const m = c.newStringLen(ctx, msg.ptr, msg.len);
    _ = c.definePropertyValueStr(ctx, err, "message", m, c.PROP_C_W_E);
    return err;
}

/// Throw synchronously. Use at every API boundary.
pub fn throw(ctx: ?*c.Context, api: []const u8, kind: perm.Kind, detail: []const u8) c.Value {
    const err = make(ctx, api, kind, detail);
    if (c.isException(err) != 0) return err;
    return c.throw(ctx, err);
}
