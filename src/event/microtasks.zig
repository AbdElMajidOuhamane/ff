const c = @import("../c.zig").c; 

pub fn pumpMicrotasks(isolate: ?*const c.Isolate) void {
    c.v8__Isolate__PerformMicrotaskCheckpoint(@constCast(isolate));
}
