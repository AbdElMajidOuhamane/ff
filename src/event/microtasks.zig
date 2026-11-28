const std = @import("std");
const c = @import("../c.zig").c;
const interrupt = @import("../engine/interrupt.zig");

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

pub const MAX_REJECTIONS: usize = 64;

// Zero-alloc SoA table tracking promises rejected without a `.catch()` handler.
// Flushed at the end of pumpMicrotasks / event loop exit so same-tick `.catch()`
// attachments cancel reporting cleanly.
var rej_ptrs: [MAX_REJECTIONS]?*anyopaque = [_]?*anyopaque{null} ** MAX_REJECTIONS;
var rej_reasons: [MAX_REJECTIONS]c.Value = [_]c.Value{c.JS_UNDEFINED} ** MAX_REJECTIONS;
var rej_count: usize = 0;

pub fn findSlot(ptrs: []const ?*anyopaque, count: usize, target: ?*anyopaque) ?usize {
    const t = target orelse return null;
    for (ptrs[0..count], 0..) |p, i| {
        if (p == t) return i;
    }
    return null;
}

fn printRejection(ctx: *c.Context, reason: c.Value) void {
    if (c.toCString(ctx, reason)) |m| {
        defer c.freeCString(ctx, m);
        std.debug.print("Uncaught (in promise): {s}\n", .{m});
    } else {
        std.debug.print("Uncaught (in promise): <unprintable error>\n", .{});
    }
    const stack_val = c.getPropertyStr(ctx, reason, "stack");
    defer c.freeValue(ctx, stack_val);
    if (c.isException(stack_val) == 0 and c.isUndefined(stack_val) == 0) {
        if (c.toCString(ctx, stack_val)) |sm| {
            defer c.freeCString(ctx, sm);
            std.debug.print("{s}\n", .{sm});
        }
    }
}

pub fn hostPromiseRejectionTracker(
    ctx: ?*c.Context,
    promise: c.JSValueConst,
    reason: c.JSValueConst,
    is_handled: bool,
    opaque_: ?*anyopaque,
) callconv(.c) void {
    _ = opaque_;
    const jc = ctx orelse return;
    const ptr = promise.u.ptr;

    if (is_handled) {
        if (findSlot(&rej_ptrs, rej_count, ptr)) |idx| {
            c.freeValue(jc, rej_reasons[idx]);
            const last = rej_count - 1;
            if (idx != last) {
                rej_ptrs[idx] = rej_ptrs[last];
                rej_reasons[idx] = rej_reasons[last];
            }
            rej_ptrs[last] = null;
            rej_reasons[last] = c.JS_UNDEFINED;
            rej_count = last;
        }
        return;
    }

    if (findSlot(&rej_ptrs, rej_count, ptr) != null) return;
    if (rej_count < MAX_REJECTIONS) {
        rej_ptrs[rej_count] = ptr;
        rej_reasons[rej_count] = c.dupValue(jc, reason);
        rej_count += 1;
    } else {
        had_error = true;
        printRejection(jc, reason);
    }
}

pub fn discardRejection(ctx: ?*c.Context, promise: c.JSValueConst) void {
    const jc = ctx orelse return;
    if (findSlot(&rej_ptrs, rej_count, promise.u.ptr)) |idx| {
        c.freeValue(jc, rej_reasons[idx]);
        const last = rej_count - 1;
        if (idx != last) {
            rej_ptrs[idx] = rej_ptrs[last];
            rej_reasons[idx] = rej_reasons[last];
        }
        rej_ptrs[last] = null;
        rej_reasons[last] = c.JS_UNDEFINED;
        rej_count = last;
    }
}

pub fn flushUnhandledRejections(ctx: *c.Context) void {
    if (rej_count == 0) return;
    had_error = true;
    const n = rej_count;
    for (0..n) |i| {
        printRejection(ctx, rej_reasons[i]);
        c.freeValue(ctx, rej_reasons[i]);
        rej_ptrs[i] = null;
        rej_reasons[i] = c.JS_UNDEFINED;
    }
    rej_count = 0;
}

pub fn clearUnhandledRejections(ctx: *c.Context) void {
    const n = rej_count;
    for (0..n) |i| {
        c.freeValue(ctx, rej_reasons[i]);
        rej_ptrs[i] = null;
        rej_reasons[i] = c.JS_UNDEFINED;
    }
    rej_count = 0;
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
    if (c.isJobPending(rt)) {
        const idx = interrupt.getRuntimeIdx(rt) orelse 0;
        interrupt.enterJsAuto(idx);
        defer interrupt.leaveJsAuto(idx);

        var pctx: ?*c.Context = undefined;
        while (true) {
            const rc = c.executePendingJob(rt, &pctx);
            if (rc == 0) break;
            if (rc < 0) reportUncaught(pctx orelse ctx, "Uncaught (in promise)");
        }
    }
    flushUnhandledRejections(ctx);
}

test "findSlot locates matching non-null promise pointer" {
    var a: u8 = 1;
    var b: u8 = 2;
    var c_var: u8 = 3;
    const ptrs = [_]?*anyopaque{ &a, &b, null, null };

    try std.testing.expectEqual(@as(?usize, 0), findSlot(&ptrs, 2, &a));
    try std.testing.expectEqual(@as(?usize, 1), findSlot(&ptrs, 2, &b));
    try std.testing.expectEqual(@as(?usize, null), findSlot(&ptrs, 2, &c_var));
    try std.testing.expectEqual(@as(?usize, null), findSlot(&ptrs, 2, null));
    try std.testing.expectEqual(@as(?usize, null), findSlot(&ptrs, 0, &a));
}
