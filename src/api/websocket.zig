const c = @import("../c.zig").c;
const http_native = @import("../net/http_native.zig");
const ws = @import("../net/ws_native.zig");
const std =@import("std");

pub var ws_class_id: c.ClassID = 0;

const WsData = struct {
    slot_id: u16,
};

fn wsFinalizer(rt: ?*c.Runtime, val: c.Value) callconv(.c) void {
    _ = rt;
    if (c.getOpaque(val, ws_class_id)) |ptr| {
        const data: *WsData = @ptrCast(@alignCast(ptr));
        std.heap.smp_allocator.destroy(data);
    }
}

pub fn makeSocket(ctx: ?*c.Context, id: u16) ?c.Value {
    const obj = c.newObjectClass(ctx, @intCast(ws_class_id));
    const data = std.heap.smp_allocator.create(WsData) catch return null;
    data.* = .{ .slot_id = id };
    c.setOpaque(obj, data);
    return obj;
}

fn slotIdFromThis(ctx: ?*c.Context, this_val: c.Value) ?usize {
    const data_ptr = c.getOpaque2(ctx, this_val, ws_class_id) orelse return null;
    const data: *WsData = @ptrCast(@alignCast(data_ptr));
    return data.slot_id;
}

fn socketSend(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const id = slotIdFromThis(ctx, this_val) orelse return c.JS_UNDEFINED;
    if (argc < 1) return c.JS_UNDEFINED;
    const arg = argv[0];
    if (c.isString(arg) != 0) {
        http_native.wsSendTextUtf8(id, arg, ctx);
    }
    return c.JS_UNDEFINED;
}

fn backingBytes(ctx: ?*c.Context, arg: c.Value) ?[]const u8 {
    // Raw ArrayBuffer
    var size: usize = 0;
    const p = c.getArrayBuffer(ctx, &size, arg);
    if (p != null and size > 0) return p[0..size];
    // Typed array view (Uint8Array etc.): JS_GetTypedArrayBuffer works
    // directly on views and reports offset/length — no JS property round-trip.
    var byte_offset: usize = 0;
    var byte_length: usize = 0;
    var bytes_per_element: usize = 0;
    const buf_val = c.getTypedArrayBuffer(ctx, arg, &byte_offset, &byte_length, &bytes_per_element);
    if (c.getTag(buf_val) == c.TAG_EXCEPTION) return null;
    const p2 = c.getArrayBuffer(ctx, &size, buf_val) orelse return null;
    if (byte_offset + byte_length > size) return null;
    return p2[byte_offset..][0..byte_length];
}

fn socketSendBinary(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    const id = slotIdFromThis(ctx, this_val) orelse return c.JS_UNDEFINED;
    if (argc < 1) return c.JS_UNDEFINED;
    const bytes = backingBytes(ctx, argv[0]) orelse return c.JS_UNDEFINED;
    http_native.wsSendBinary(id, bytes);
    return c.JS_UNDEFINED;
}

pub fn setup(ctx: ?*c.Context) void {
    var def = c.ClassDef{
        .class_name = "ServerWebSocket",
        .finalizer = wsFinalizer,
    };
    _ = c.newClassID(c.getRuntime(ctx), &ws_class_id);
    _ = c.newClass(c.getRuntime(ctx), ws_class_id, &def);

    const proto = c.newObject(ctx);
    const methods = [_]struct { name: [*:0]const u8, func: *const c.CFunction, len: c_int }{
        .{ .name = "send", .func = &socketSend, .len = 1 },
        .{ .name = "sendBinary", .func = &socketSendBinary, .len = 1 },
    };
    for (methods) |m| {
        const fn_val = c.newCFunction(ctx, m.func, m.name, m.len);
        _ = c.definePropertyValueStr(ctx, proto, m.name, fn_val, c.PROP_WRITABLE | c.PROP_CONFIGURABLE);
    }
    c.setClassProto(ctx, ws_class_id, proto);
}
