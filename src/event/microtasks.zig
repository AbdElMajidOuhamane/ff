const std = @import("std");
const c = @import("../c.zig").c;

// Set whenever a top-level eval, a module's promise, a queued job, or a
// timer callback throws. Consumed by main / start  to choose the
// process exit code — previously every script error exited 0.
pub var had_error: bool = false;

// Pull the pending exception off `ctx`, print it, and mark the run failed.
pub fn reportUncaught(ctx: *c.Context, where: []const u8) void {
    had_error = true;
    const exc = c.getException(ctx);
    defer c.freeValue(ctx, exc);
    if (c.toCString(ctx, exc)) |m| {
        defer c.freeCString(ctx, m);
        std.debug.print("{s}: {s}\n", .{ where, m });
    } else {
        std.debug.print("{s}: <unprintable error>\n", .{where});
    }
}

// Hot microtask drain: zero-alloc batch pump. The loop calls this after
// every I/O batch, so completions stay contiguous and predictable.
//
// JS_ExecutePendingJob returns >0 when a job ran, 0 when the queue is
// empty, and <0 when the job *threw* — the exception is left in *pctx.
// The old `while (executePendingJob(...) != 0) {}` swallowed both the
// message and the exit status on the <0 path.
pub fn pumpMicrotasks(ctx: *c.Context) void {
    const rt = c.getRuntime(ctx);
    var pctx: ?*c.Context = undefined;
    while (true) {
        const rc = c.executePendingJob(rt, &pctx);
        if (rc == 0) break;
        if (rc < 0) reportUncaught(pctx orelse ctx, "Uncaught (in promise)");
    }
}
