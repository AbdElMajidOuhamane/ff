const std = @import("std");
const c = @import("../c.zig").c;
const loop_mod = @import("../event/loop.zig");
const microtasks = @import("../event/microtasks.zig");

pub const MAX_CRON = 32;

pub const CronSchedule = union(enum) {
    interval_ms: u64,
    fields: struct {
        min: u64,
        hour: u32,
        dom: u32,
        mon: u16,
        dow: u8,
        dom_restricted: bool,
        dow_restricted: bool,
    },
};

pub const CronJob = struct {
    name: []const u8,
    schedule: []const u8,
    handler: c.Value,
    sched: CronSchedule,
    timer_slot: ?usize = null,
};

pub var cron_jobs: [MAX_CRON]CronJob = undefined;
pub var cron_count: usize = 0;

fn parseSingleField(field: []const u8, min_val: u8, max_val: u8) ?u64 {
    if (field.len == 0) return null;
    var mask: u64 = 0;
    var parts = std.mem.splitScalar(u8, field, ',');
    while (parts.next()) |part| {
        if (part.len == 0) return null;
        var base = part;
        var step: u8 = 1;
        if (std.mem.indexOfScalar(u8, part, '/')) |slash| {
            base = part[0..slash];
            step = std.fmt.parseInt(u8, part[slash + 1 ..], 10) catch return null;
            if (step == 0) return null;
        }

        var start: u8 = undefined;
        var end: u8 = undefined;
        if (std.mem.eql(u8, base, "*")) {
            start = min_val;
            end = max_val;
        } else if (std.mem.indexOfScalar(u8, base, '-')) |dash| {
            start = std.fmt.parseInt(u8, base[0..dash], 10) catch return null;
            end = std.fmt.parseInt(u8, base[dash + 1 ..], 10) catch return null;
            if (start < min_val or end > max_val or start > end) return null;
        } else {
            const v = std.fmt.parseInt(u8, base, 10) catch return null;
            if (v < min_val or v > max_val) return null;
            start = v;
            end = v;
        }

        var v = start;
        while (v <= end) {
            mask |= (@as(u64, 1) << @truncate(v));
            if (v > max_val -| step) break;
            v += step;
        }
    }
    return mask;
}

fn parseSchedule(schedule: []const u8) ?CronSchedule {
    const trimmed = std.mem.trim(u8, schedule, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "@every ")) {
        const rest = std.mem.trim(u8, trimmed["@every ".len..], " \t");
        if (std.mem.endsWith(u8, rest, "ms")) {
            const num = rest[0 .. rest.len - 2];
            const ms = std.fmt.parseInt(u64, num, 10) catch return null;
            return .{ .interval_ms = ms };
        } else if (std.mem.endsWith(u8, rest, "s")) {
            const num = rest[0 .. rest.len - 1];
            const s = std.fmt.parseInt(u64, num, 10) catch return null;
            return .{ .interval_ms = s * 1000 };
        } else if (std.mem.endsWith(u8, rest, "m")) {
            const num = rest[0 .. rest.len - 1];
            const m = std.fmt.parseInt(u64, num, 10) catch return null;
            return .{ .interval_ms = m * 60 * 1000 };
        } else {
            return null;
        }
    }

    var fields: [5][]const u8 = undefined;
    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, trimmed, ' ');
    while (iter.next()) |f| {
        if (f.len == 0) continue;
        if (count >= 5) return null;
        fields[count] = f;
        count += 1;
    }
    if (count != 5) return null;

    const min_m = parseSingleField(fields[0], 0, 59) orelse return null;
    const hour_m = parseSingleField(fields[1], 0, 23) orelse return null;
    const dom_m = parseSingleField(fields[2], 1, 31) orelse return null;
    const mon_m = parseSingleField(fields[3], 1, 12) orelse return null;
    const dow_m = parseSingleField(fields[4], 0, 7) orelse return null;

    return .{
        .fields = .{
            .min = min_m,
            .hour = @truncate(hour_m),
            .dom = @truncate(dom_m),
            .mon = @truncate(mon_m),
            .dow = @truncate(dow_m),
            .dom_restricted = !std.mem.eql(u8, fields[2], "*"),
            .dow_restricted = !std.mem.eql(u8, fields[4], "*"),
        },
    };
}

fn computeNextFireDelay(sched_fields: anytype, now_ts: i64) ?u64 {
    const cur_min_sec = @divFloor(now_ts, 60) * 60;
    var check_sec: i64 = cur_min_sec + 60;
    const max_sec: i64 = cur_min_sec + (366 * 86400);

    while (check_sec < max_sec) {
        const epoch_sec = std.time.epoch.EpochSeconds{ .secs = @intCast(check_sec) };
        const epoch_day = epoch_sec.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_sec = epoch_sec.getDaySeconds();
        const minute = day_sec.getMinutesIntoHour();
        const hour = day_sec.getHoursIntoDay();
        const dom = month_day.day_index + 1;
        const mon = month_day.month.numeric();
        const dow = @as(u3, @intCast(@mod(epoch_day.day + 4, 7)));

        if (((@as(u16, 1) << @truncate(mon)) & sched_fields.mon) == 0) {
            check_sec += 86400;
            continue;
        }

        const dom_match = ((@as(u32, 1) << @truncate(dom)) & sched_fields.dom) != 0;
        const dow_match = (((@as(u8, 1) << @truncate(dow)) & sched_fields.dow) != 0) or
            (dow == 0 and (((@as(u8, 1) << 7) & sched_fields.dow) != 0));

        // Vixie cron: match if either matches when both DOM & DOW are restricted
        const day_matches = if (sched_fields.dom_restricted and sched_fields.dow_restricted)
            (dom_match or dow_match)
        else if (sched_fields.dom_restricted)
            dom_match
        else if (sched_fields.dow_restricted)
            dow_match
        else
            true;

        if (!day_matches) {
            check_sec += 86400;
            continue;
        }

        if (((@as(u32, 1) << @truncate(hour)) & sched_fields.hour) == 0) {
            check_sec += 3600;
            continue;
        }

        if (((@as(u64, 1) << @truncate(minute)) & sched_fields.min) != 0) {
            const diff = check_sec - now_ts;
            return if (diff > 0) @as(u64, @intCast(diff)) * 1000 else 1000;
        }

        check_sec += 60;
    }

    return null;
}

fn getTimestampSec() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @intCast(ts.sec);
}

fn cronTrampoline(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 1) return c.JS_UNDEFINED;
    var job_idx: i32 = 0;
    if (c.toInt32(ctx, &job_idx, argv[0]) != 0 or job_idx < 0 or job_idx >= cron_count) {
        return c.JS_UNDEFINED;
    }
    const idx: usize = @intCast(job_idx);
    const job = &cron_jobs[idx];

    // Invoke user callback and report any uncaught exception
    const res = c.call(ctx, job.handler, c.JS_UNDEFINED, 0, null);
    if (c.isException(res) != 0) {
        microtasks.reportUncaught(ctx.?, "Uncaught (in cron)");
    }
    c.freeValue(ctx, res);

    // Reschedule next fire
    switch (job.sched) {
        .fields => |f| {
            const next_delay = computeNextFireDelay(f, getTimestampSec()) orelse {
                std.debug.print("cron '{s}': no future fire time found\n", .{job.name});
                return c.JS_UNDEFINED;
            };
            const tm = loop_mod.timer_mgr orelse {
                std.debug.print("cron '{s}': timer manager not available\n", .{job.name});
                return c.JS_UNDEFINED;
            };
            const trampoline_fn = c.newCFunction(ctx, cronTrampoline, "cronTrampoline", 1);
            defer c.freeValue(ctx, trampoline_fn);
            var tramp_argv = [_]c.Value{c.newInt32(ctx, job_idx)};
            job.timer_slot = tm.setTimeout(ctx.?, trampoline_fn, next_delay, &tramp_argv) catch |err| {
                std.debug.print("cron '{s}': failed to re-arm timer: {s}\n", .{ job.name, @errorName(err) });
                return c.JS_UNDEFINED;
            };
        },
        else => {},
    }
    return c.JS_UNDEFINED;
}

fn cronRegisterCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 3 or c.isString(argv[0]) == 0 or c.isString(argv[1]) == 0 or c.isFunction(ctx, argv[2]) == 0) {
        return c.throwTypeError(ctx, "ff.cron requires (name, schedule, callback)");
    }
    if (cron_count >= MAX_CRON) {
        return c.throwTypeError(ctx, "Max cron jobs (32) exceeded");
    }

    var n_len: usize = 0;
    const n_cstr = c.toCStringLen(ctx, &n_len, argv[0]) orelse return c.JS_EXCEPTION;
    defer c.freeCString(ctx, n_cstr);

    var s_len: usize = 0;
    const s_cstr = c.toCStringLen(ctx, &s_len, argv[1]) orelse return c.JS_EXCEPTION;
    defer c.freeCString(ctx, s_cstr);

    const sched_str = s_cstr[0..s_len];
    const sched = parseSchedule(sched_str) orelse {
        return c.throwTypeError(ctx, "invalid cron schedule expression");
    };

    const tm = loop_mod.timer_mgr orelse {
        return c.throwTypeError(ctx, "timer manager not initialized");
    };

    const name = std.heap.page_allocator.dupe(u8, n_cstr[0..n_len]) catch return c.throwOutOfMemory(ctx);
    const sched_owned = std.heap.page_allocator.dupe(u8, sched_str) catch return c.throwOutOfMemory(ctx);

    const job_idx = cron_count;
    var timer_slot: ?usize = null;

    switch (sched) {
        .interval_ms => |ms| {
            timer_slot = tm.setInterval(ctx.?, argv[2], ms, &.{}) catch {
                return c.throwTypeError(ctx, "failed to schedule cron timer (timer table full)");
            };
        },
        .fields => |f| {
            const delay_ms = computeNextFireDelay(f, getTimestampSec()) orelse {
                return c.throwTypeError(ctx, "cron schedule will never match in the next 366 days");
            };
            const trampoline_fn = c.newCFunction(ctx, cronTrampoline, "cronTrampoline", 1);
            defer c.freeValue(ctx, trampoline_fn);
            var tramp_argv = [_]c.Value{c.newInt32(ctx, @intCast(job_idx))};
            timer_slot = tm.setTimeout(ctx.?, trampoline_fn, delay_ms, &tramp_argv) catch {
                return c.throwTypeError(ctx, "failed to schedule cron timer (timer table full)");
            };
        },
    }

    cron_jobs[cron_count] = .{
        .name = name,
        .schedule = sched_owned,
        .handler = c.dupValue(ctx, argv[2]),
        .sched = sched,
        .timer_slot = timer_slot,
    };
    cron_count += 1;
    return c.JS_UNDEFINED;
}

pub fn setup(ctx: *c.Context) void {
    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);

    const ff_val = c.getPropertyStr(ctx, global, "ff");
    defer c.freeValue(ctx, ff_val);

    const ff_obj = if (c.isObject(ff_val) != 0)
        c.dupValue(ctx, ff_val)
    else
        c.newObject(ctx);

    const cron_fn = c.newCFunction(ctx, cronRegisterCallback, "cron", 3);
    _ = c.definePropertyValueStr(ctx, ff_obj, "cron", cron_fn, c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, global, "ff", ff_obj, c.PROP_C_W_E);
}
