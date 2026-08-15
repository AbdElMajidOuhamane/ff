const c = @import("../c.zig").c;
const http_native = @import("../net/http_native.zig");
const ws = @import("../net/ws_native.zig");

var sock_ids: [http_native.MAX_CONN]u16 = undefined;
var str_send: c.Global = .{ .data_ptr = 0 };
var str_id: c.Global = .{ .data_ptr = 0 };

pub fn setupStrings(isolate: ?*c.Isolate) void {
    var hs: c.HandleScope = undefined;
    c.v8__HandleScope__CONSTRUCT(&hs, isolate);
    defer c.v8__HandleScope__DESTRUCT(&hs);
    c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, "send", 0, -1)), &str_send);
    c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, "id", 0, -1)), &str_id);
}

// Caller must be inside an active HandleScope + entered context.
pub fn makeSocket(isolate: ?*c.Isolate, context: ?*const c.Context, id: u16) ?*const c.Object {
    const iso = isolate orelse return null;
    const ctx = context orelse return null;
    sock_ids[id] = id;

    const obj = c.v8__Object__New(iso) orelse return null;
    var out: c.MaybeBool = undefined;
    _ = c.v8__Object__Set(
        obj,
        ctx,
        @ptrCast(c.v8__Global__Get(&str_id, iso)),
        @ptrCast(c.v8__Integer__NewFromUnsigned(iso, id)),
        &out,
    );
    const ext = c.v8__External__New(iso, @ptrCast(&sock_ids[id]));
    const send = c.v8__Function__New__DEFAULT2(ctx, socketSend, @ptrCast(ext)) orelse return null;
    _ = c.v8__Object__Set(
        obj,
        ctx,
        @ptrCast(c.v8__Global__Get(&str_send, iso)),
        @ptrCast(send),
        &out,
    );
    return obj;
}

fn socketSend(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate) orelse return;
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));

    const data = c.v8__FunctionCallbackInfo__Data(info) orelse return;
    const sp: *u16 = @ptrCast(@alignCast(c.v8__External__Value(@ptrCast(data))));
    const id: usize = sp.*;

    if (c.v8__FunctionCallbackInfo__Length(info) < 1) return;
    const arg = c.v8__FunctionCallbackInfo__INDEX(info, 0) orelse return;
    const str: ?*const c.Value = if (c.v8__Value__IsString(arg))
        arg
    else
        c.v8__Value__ToDetailString(arg, context) orelse return;

    // Encode straight into the slot's write buffer: no temp array, no
    // separate copy, single pass. Length comes from Utf8Length() so the
    // frame header always matches the bytes actually written.
    http_native.wsSendTextUtf8(id, str, isolate);
}
