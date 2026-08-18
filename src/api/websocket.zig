const c = @import("../c.zig").c;
const http_native = @import("../net/http_native.zig");


var sock_ids: [http_native.MAX_CONN]u16 = undefined;
var str_send: c.Global = .{ .data_ptr = 0 };
var str_send_binary: c.Global = .{ .data_ptr = 0 };
var str_close: c.Global = .{ .data_ptr = 0 };
var str_id: c.Global = .{ .data_ptr = 0 };

pub fn setupStrings(isolate: ?*c.Isolate) void {
    var hs: c.HandleScope = undefined;
    c.v8__HandleScope__CONSTRUCT(&hs, isolate);
    defer c.v8__HandleScope__DESTRUCT(&hs);
    c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, "send", 0, -1)), &str_send);
    c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, "sendBinary", 0, -1)), &str_send_binary);
    c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, "close", 0, -1)), &str_close);
    c.v8__Global__New(isolate, @ptrCast(c.v8__String__NewFromUtf8(isolate, "id", 0, -1)), &str_id);
}

// slot index from the bound-function External (shared by send/sendBinary/close).
fn slotFrom(info: ?*const c.FunctionCallbackInfo) ?usize {
    const data = c.v8__FunctionCallbackInfo__Data(info) orelse return null;
    const sp: *u16 = @ptrCast(@alignCast(c.v8__External__Value(@ptrCast(data))));
    return sp.*;
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
    const send_binary = c.v8__Function__New__DEFAULT2(ctx, socketSendBinary, @ptrCast(ext)) orelse return null;
    const close = c.v8__Function__New__DEFAULT2(ctx, socketClose, @ptrCast(ext)) orelse return null;
    _ = c.v8__Object__Set(obj, ctx, @ptrCast(c.v8__Global__Get(&str_send, iso)), @ptrCast(send), &out);
    _ = c.v8__Object__Set(obj, ctx, @ptrCast(c.v8__Global__Get(&str_send_binary, iso)), @ptrCast(send_binary), &out);
    _ = c.v8__Object__Set(obj, ctx, @ptrCast(c.v8__Global__Get(&str_close, iso)), @ptrCast(close), &out);
    return obj;
}

fn socketSend(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate) orelse return;
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));

    const id = slotFrom(info) orelse return;
    if (c.v8__FunctionCallbackInfo__Length(info) < 1) return;
    const arg = c.v8__FunctionCallbackInfo__INDEX(info, 0) orelse return;
    const str: ?*const c.Value = if (c.v8__Value__IsString(arg))
        arg
    else
        c.v8__Value__ToDetailString(arg, context) orelse return;

    http_native.wsSendTextUtf8(id, str, isolate);
}

fn socketSendBinary(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    _ = c.v8__Isolate__GetCurrentContext(isolate) orelse return;
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));

    const id = slotFrom(info) orelse return;
    if (c.v8__FunctionCallbackInfo__Length(info) < 1) return;
    const arg = c.v8__FunctionCallbackInfo__INDEX(info, 0) orelse return;

    if (c.v8__Value__IsArrayBuffer(arg)) {
        const ab: *const c.ArrayBuffer = @ptrCast(arg);
        var store = c.v8__ArrayBuffer__GetBackingStore(ab);
        const backing = c.std__shared_ptr__v8__BackingStore__get(&store) orelse return;
        const data = @as([*]u8, @ptrCast(c.v8__BackingStore__Data(backing) orelse return));
        const len = c.v8__BackingStore__ByteLength(backing);
        http_native.wsSendBinary(id, data[0..len], isolate);
        return;
    }
    if (c.v8__Value__IsArrayBufferView(arg)) {
        const view: *const c.Value = @ptrCast(arg);
        const ab = c.v8__ArrayBufferView__Buffer(@ptrCast(@constCast(view))) orelse return;
        var store = c.v8__ArrayBuffer__GetBackingStore(ab);
        const backing = c.std__shared_ptr__v8__BackingStore__get(&store) orelse return;
        const data = @as([*]u8, @ptrCast(c.v8__BackingStore__Data(backing) orelse return));
        const offset = c.v8__ArrayBufferView__ByteOffset(view);
        const len = c.v8__ArrayBufferView__ByteLength(view);
        http_native.wsSendBinary(id, data[offset .. offset + len], isolate);
        return;
    }
    if (c.v8__Value__IsString(arg)) {
        http_native.wsSendBinaryUtf8(id, arg, isolate);
    }
}

fn socketClose(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    const context = c.v8__Isolate__GetCurrentContext(isolate) orelse return;
    var ret: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &ret);
    c.v8__ReturnValue__Set(ret, @ptrCast(c.v8__Undefined(isolate)));

    const id = slotFrom(info) orelse return;

    var code: u16 = 1000;
    if (c.v8__FunctionCallbackInfo__Length(info) >= 1) {
        if (c.v8__FunctionCallbackInfo__INDEX(info, 0)) |code_val| {
            var maybe: c.MaybeI32 = undefined;
            c.v8__Value__Int32Value(code_val, context, &maybe);
            if (maybe.has_value and maybe.value >= 0) {
                code = @intCast(@min(@as(i64, @intCast(maybe.value)), 65535));
            }
        }
    }

    if (c.v8__FunctionCallbackInfo__Length(info) < 2) {
        http_native.wsSendCloseReason(id, code, "");
        return;
    }
    const reason_arg = c.v8__FunctionCallbackInfo__INDEX(info, 1) orelse {
        http_native.wsSendCloseReason(id, code, "");
        return;
    };
    const str: ?*const c.Value = if (c.v8__Value__IsString(reason_arg))
        reason_arg
    else
        c.v8__Value__ToDetailString(reason_arg, context);

    if (str) |s| {
        const ulen_raw = c.v8__String__Utf8Length(s, isolate);
        if (ulen_raw <= 0) {
            http_native.wsSendCloseReason(id, code, "");
            return;
        }
        const ulen: usize = @intCast(ulen_raw);
        var buf: [http_native.CLOSE_REASON_MAX]u8 = undefined;
        const capacity = @min(ulen, buf.len);
        const wrote = c.v8__String__WriteUtf8(s, isolate, &buf, @intCast(capacity), 0);
        if (wrote <= 0) {
            http_native.wsSendCloseReason(id, code, "");
            return;
        }
        http_native.wsSendCloseReason(id, code, buf[0..@intCast(wrote)]);
    } else {
        http_native.wsSendCloseReason(id, code, "");
    }
}
