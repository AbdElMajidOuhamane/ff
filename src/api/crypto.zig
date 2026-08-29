const std = @import("std");
const c = @import("../c.zig").c;

const gpa = std.heap.smp_allocator;

extern "c" fn arc4random_buf(buf: [*]u8, len: usize) void;

fn getRandomBytes(buf: []u8) void {
    switch (@import("builtin").os.tag) {
        .linux => {
            var off: usize = 0;
            while (off < buf.len) {
                const n = std.c.getrandom(buf.ptr + off, buf.len - off, 0);
                if (n < 0) {
                    if (std.posix.errno(n) == .INTR) continue;
                    std.Io.Threaded.global_single_threaded.io().random(buf[off..]);
                    return;
                }
                off += @intCast(n);
            }
        },
        else => arc4random_buf(buf.ptr, buf.len),
    }
}

fn getRandomValuesCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 1) {
        _ = c.throwTypeError(ctx, "getRandomValues requires a TypedArray argument");
        return c.JS_UNDEFINED;
    }
    return argv[0];
}

fn randomUUIDCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    _ = argc;
    _ = argv;
    var uuid_bytes: [16]u8 = undefined;
    getRandomBytes(&uuid_bytes);

    uuid_bytes[6] = (uuid_bytes[6] & 0x0f) | 0x40;
    uuid_bytes[8] = (uuid_bytes[8] & 0x3f) | 0x80;

    var uuid: [36]u8 = undefined;
    const hex = "0123456789abcdef";
    var i: usize = 0;
    var j: usize = 0;
    while (i < 16) : (i += 1) {
        uuid[j] = hex[uuid_bytes[i] >> 4];
        uuid[j + 1] = hex[uuid_bytes[i] & 0x0f];
        j += 2;
        if (i == 3 or i == 5 or i == 7 or i == 9) {
            uuid[j] = '-';
            j += 1;
        }
    }

    return c.newStringLen(ctx, &uuid, 36);
}

fn subtleDigestCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 2) {
        c.throwTypeError(ctx, "subtle.digest requires algorithm and data");
        return c.JS_UNDEFINED;
    }
    _ = argv;
    // TODO: Phase 3 — full QuickJS implementation
    return c.JS_UNDEFINED;
}

pub fn setup(ctx: *c.Context) void {
    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);
    const crypto_obj = c.newObject(ctx);

    const getRandomValues_fn = c.newCFunction(ctx, getRandomValuesCallback, "getRandomValues", 1);
    _ = c.definePropertyValueStr(ctx, crypto_obj, "getRandomValues", getRandomValues_fn, c.PROP_C_W_E);

    const randomUUID_fn = c.newCFunction(ctx, randomUUIDCallback, "randomUUID", 0);
    _ = c.definePropertyValueStr(ctx, crypto_obj, "randomUUID", randomUUID_fn, c.PROP_C_W_E);

    const subtle_obj = c.newObject(ctx);
    _ = c.definePropertyValueStr(ctx, crypto_obj, "subtle", subtle_obj, c.PROP_C_W_E);

    _ = c.definePropertyValueStr(ctx, global, "crypto", crypto_obj, c.PROP_C_W_E);
}
