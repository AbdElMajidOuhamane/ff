const c = @import("../c.zig").c;

pub fn pumpMicrotasks(ctx: *c.Context) void {
    const rt = c.getRuntime(ctx);
    while (c.executePendingJob(rt, null) != 0) {}
}
