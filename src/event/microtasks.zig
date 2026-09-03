const c = @import("../c.zig").c;

pub fn pumpMicrotasks(ctx: *c.Context) void {
    const rt = c.getRuntime(ctx);
    var pctx: ?*c.Context = undefined;
    while (c.executePendingJob(rt, &pctx) != 0) {}
}
