const std = @import("std");
const c = @import("../c.zig").c;

const ns_per_us: u64 = 1_000;
const us_per_s: u64 = 1_000_000;
const ms_per_s: f64 = 1_000.0;

// data plane: one monotonic read, integer-domain accumulation, single f64 scale.
// no allocations, no dynamic memory, no self — a pure primitive transform.
fn monotonic_ms_now() f64 {
    var ts: c.timespec = undefined;
    const rc = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    std.debug.assert(rc == 0);
    std.debug.assert(ts.tv_sec >= 0 and ts.tv_nsec >= 0);

    const total_us: u64 = @as(u64, @intCast(ts.tv_sec)) * us_per_s +
        @as(u64, @intCast(ts.tv_nsec)) / ns_per_us;
    return @as(f64, @floatFromInt(total_us)) / ms_per_s;
}

// control plane: V8 interop shell only — argument marshalling + return value.
fn now_callback(info: ?*const c.FunctionCallbackInfo) callconv(.c) void {
    const isolate = c.v8__FunctionCallbackInfo__GetIsolate(info);
    var retval: c.ReturnValue = undefined;
    c.v8__FunctionCallbackInfo__GetReturnValue(info, &retval);
    c.v8__ReturnValue__Set(retval, c.v8__Number__New(isolate, monotonic_ms_now()));
}

pub fn setup(isolate: ?*c.Isolate, context: ?*c.Context) void {
    var hs: c.HandleScope = undefined;
    c.v8__HandleScope__CONSTRUCT(&hs, isolate);
    defer c.v8__HandleScope__DESTRUCT(&hs);

    const global = c.v8__Context__Global(context);
    const perf_obj = c.v8__Object__New(isolate);
    var out: c.MaybeBool = undefined;

    const now_fn = c.v8__Function__New__DEFAULT(context, now_callback);
    _ = c.v8__Object__Set(perf_obj, context, c.v8__String__NewFromUtf8(isolate, "now", 0, -1), now_fn, &out);
    _ = c.v8__Object__Set(global, context, c.v8__String__NewFromUtf8(isolate, "performance", 0, -1), perf_obj, &out);
}
