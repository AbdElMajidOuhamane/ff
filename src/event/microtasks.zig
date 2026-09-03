const c = @import("../c.zig").c;

// Hot microtask drain: zero-alloc batch pump. The loop calls this after
// every I/O batch, so completions stay contiguous and predictable.
pub fn pumpMicrotasks(ctx: *c.Context) void {
    const rt = c.getRuntime(ctx);
    var pctx: ?*c.Context = undefined;
    while (c.executePendingJob(rt, &pctx) != 0) {}
}
