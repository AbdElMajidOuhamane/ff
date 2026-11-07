const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const c = @import("../c.zig").c;
const microtasks = @import("../event/microtasks.zig");
const pwhash = std.crypto.pwhash;
const bcrypt = pwhash.bcrypt;

extern "c" fn arc4random_buf(buf: [*]u8, len: usize) void;

fn fillRandomBytes(buf: []u8) error{EntropyUnavailable}!void {
    switch (builtin.os.tag) {
        .linux => {
            var off: usize = 0;
            while (off < buf.len) {
                const n = std.c.getrandom(buf.ptr + off, buf.len - off, 0);
                if (n < 0) {
                    const errno = std.posix.errno(n);
                    if (errno == .INTR) continue;
                    std.Io.Threaded.global_single_threaded.io().randomSecure(buf[off..]) catch return error.EntropyUnavailable;
                    return;
                }
                off += @intCast(n);
            }
        },
        else => arc4random_buf(buf.ptr, buf.len),
    }
}

pub const MAX_JOBS: usize = 16;
pub const MIN_COST: u6 = 4;
pub const MAX_COST: u6 = 14; // hard CPU bound
pub const DEFAULT_COST: u6 = 12;
pub const MAX_PASSWORD: usize = 72; // bcrypt's effective limit
pub const MAX_HASH_STR: usize = 128; // $2b$ hashes are 60 bytes

pub const Op = enum(u8) { hash, verify };
pub const State = enum(u8) { free = 0, busy = 1, done = 2, claimed = 3 };

pub const ERR_OK: u8 = 0;
pub const ERR_MISMATCH: u8 = 1;
pub const ERR_INTERNAL: u8 = 2;

// 256 KiB worker stack is plenty for bcrypt frames (~4-8 KiB max)
const WORKER_STACK_SIZE: usize = 256 * 1024;

pub var pending: std.atomic.Value(u64) = .{ .raw = 0 };

// Preallocated SoA slots
var states: [MAX_JOBS]std.atomic.Value(u8) = [_]std.atomic.Value(u8){.{ .raw = @intFromEnum(State.free) }} ** MAX_JOBS;
var ops: [MAX_JOBS]Op = undefined;
var costs: [MAX_JOBS]u6 = undefined;
var passwords: [MAX_JOBS][MAX_PASSWORD]u8 = undefined;
var password_lens: [MAX_JOBS]usize = [_]usize{0} ** MAX_JOBS;
var hashes: [MAX_JOBS][MAX_HASH_STR]u8 = undefined;
var hash_lens: [MAX_JOBS]usize = [_]usize{0} ** MAX_JOBS;
var salts: [MAX_JOBS][16]u8 = undefined;
var outs: [MAX_JOBS][MAX_HASH_STR]u8 = undefined;
var out_lens: [MAX_JOBS]usize = [_]usize{0} ** MAX_JOBS;
var errs: [MAX_JOBS]u8 = [_]u8{ERR_OK} ** MAX_JOBS;
var resolve_funcs: [MAX_JOBS]?c.Value = [_]?c.Value{null} ** MAX_JOBS;
var reject_funcs: [MAX_JOBS]?c.Value = [_]?c.Value{null} ** MAX_JOBS;

var free_list: [MAX_JOBS]u16 = undefined;
var free_count: usize = MAX_JOBS;
var pool_lock: std.atomic.Mutex = .unlocked;

const RING_CAP: usize = MAX_JOBS;
var job_ring: [RING_CAP]u16 = undefined;
var ring_head: usize = 0;
var ring_tail: usize = 0;
var ring_lock: std.atomic.Mutex = .unlocked;

var shutdown_requested = false;
var pool_started = false;
var async_initialized = false;

var worker_threads: [4]?std.Thread = [_]?std.Thread{null} ** 4;
var num_workers: usize = 0;
var job_pipe: [2]std.posix.fd_t = .{ -1, -1 };

const AsyncT = xev.Async;
var async_h: AsyncT = undefined;
var async_comp: xev.Completion = .{};
var async_armed = false;
var g_loop: ?*xev.Loop = null;
var g_ctx: ?*c.Context = null;

fn poolLock() void {
    while (!pool_lock.tryLock()) std.atomic.spinLoopHint();
}
fn poolUnlock() void {
    pool_lock.unlock();
}
fn ringLock() void {
    while (!ring_lock.tryLock()) std.atomic.spinLoopHint();
}
fn ringUnlock() void {
    ring_lock.unlock();
}

fn poolInit() void {
    for (0..MAX_JOBS) |i| free_list[i] = @intCast(MAX_JOBS - 1 - i);
    free_count = MAX_JOBS;
}

fn acquireSlot() ?usize {
    if (free_count == 0) return null;
    free_count -= 1;
    const s: usize = free_list[free_count];
    states[s].store(@intFromEnum(State.busy), .release);
    return s;
}

fn releaseSlot(s: usize) void {
    poolLock();
    defer poolUnlock();
    states[s].store(@intFromEnum(State.free), .release);
    out_lens[s] = 0;
    password_lens[s] = 0;
    hash_lens[s] = 0;
    errs[s] = ERR_OK;
    std.crypto.secureZero(u8, passwords[s][0..]);
    std.crypto.secureZero(u8, hashes[s][0..]);
    std.crypto.secureZero(u8, salts[s][0..]);
    std.crypto.secureZero(u8, outs[s][0..]);
    std.debug.assert(free_count < MAX_JOBS);
    if (free_count >= MAX_JOBS) return;
    free_list[free_count] = @intCast(s);
    free_count += 1;
}

fn freeResolvers(ctx: ?*c.Context, s: usize) void {
    const c_ctx = ctx orelse g_ctx;
    if (c_ctx) |cx| {
        if (resolve_funcs[s]) |v| {
            c.freeValue(cx, v);
            resolve_funcs[s] = null;
        }
        if (reject_funcs[s]) |v| {
            c.freeValue(cx, v);
            reject_funcs[s] = null;
        }
    } else {
        resolve_funcs[s] = null;
        reject_funcs[s] = null;
    }
}

pub fn setLoop(l: *xev.Loop) void {
    g_loop = l;
}

pub fn arm(loop: *xev.Loop) void {
    g_loop = loop;
    if (async_armed) return;
    async_armed = true;
    async_h.wait(loop, &async_comp, void, null, asyncCb);
}

pub fn ensureArmed() void {
    if (async_armed) return;
    if (g_loop) |l| arm(l);
}

fn asyncCb(ud: ?*void, l: *xev.Loop, comp: *xev.Completion, r: AsyncT.WaitError!void) xev.CallbackAction {
    _ = ud;
    _ = l;
    _ = comp;
    _ = r catch return .disarm;
    if (g_ctx) |ctx| {
        drainCompleted(ctx);
        microtasks.pumpMicrotasks(ctx);
    }
    if (pending.load(.acquire) > 0) {
        async_armed = true;
        return .rearm;
    } else {
        async_armed = false;
        return .disarm;
    }
}

fn ensureStarted(ctx: ?*c.Context) !void {
    if (pool_started) return;
    poolLock();
    defer poolUnlock();
    if (pool_started) return;

    g_ctx = ctx;
    poolInit();
    async_h = AsyncT.init() catch return error.OutOfMemory;
    async_initialized = true;
    async_armed = false;
    ring_head = 0;
    ring_tail = 0;
    shutdown_requested = false;

    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) {
        async_h.deinit();
        async_initialized = false;
        return error.OutOfMemory;
    }
    job_pipe = fds;

    const cpu_count = std.Thread.getCpuCount() catch 2;
    const target_workers = @min(4, @max(2, cpu_count -| 1));
    var spawned: usize = 0;

    for (0..target_workers) |i| {
        worker_threads[i] = std.Thread.spawn(
            .{ .stack_size = WORKER_STACK_SIZE },
            workerLoop,
            .{},
        ) catch {
            worker_threads[i] = null;
            break;
        };
        spawned += 1;
    }
    num_workers = spawned;
    if (num_workers == 0) {
        _ = std.c.close(job_pipe[0]);
        _ = std.c.close(job_pipe[1]);
        job_pipe = .{ -1, -1 };
        async_h.deinit();
        async_initialized = false;
        return error.OutOfMemory;
    }
    pool_started = true;
}

fn wakeAllWorkers() void {
    if (job_pipe[1] < 0) return;
    var b: [4]u8 = [_]u8{1} ** 4;
    _ = std.c.write(job_pipe[1], &b, num_workers);
}

pub fn deinit() void {
    if (pool_started) {
        ringLock();
        shutdown_requested = true;
        ringUnlock();
        wakeAllWorkers();
        for (&worker_threads) |*t| {
            if (t.*) |*tt| {
                tt.join();
                t.* = null;
            }
        }
        pool_started = false;
    }
    if (job_pipe[0] >= 0) _ = std.c.close(job_pipe[0]);
    if (job_pipe[1] >= 0) _ = std.c.close(job_pipe[1]);
    job_pipe = .{ -1, -1 };
    if (async_initialized) {
        async_h.deinit();
        async_initialized = false;
        async_armed = false;
    }
    for (0..MAX_JOBS) |s| {
        if (states[s].load(.acquire) != @intFromEnum(State.free)) {
            freeResolvers(null, s);
            std.crypto.secureZero(u8, passwords[s][0..]);
            std.crypto.secureZero(u8, hashes[s][0..]);
            std.crypto.secureZero(u8, salts[s][0..]);
            std.crypto.secureZero(u8, outs[s][0..]);
            states[s].store(@intFromEnum(State.free), .release);
        }
    }
}

fn workerLoop() void {
    while (true) {
        var wake: [1]u8 = undefined;
        const n = std.c.read(job_pipe[0], &wake, 1);
        if (n <= 0) return;
        var got: ?u16 = null;
        ringLock();
        if (ring_head != ring_tail) {
            got = job_ring[ring_head % RING_CAP];
            ring_head +%= 1;
        }
        const stop = shutdown_requested and ring_head == ring_tail;
        ringUnlock();
        if (got) |slot_id| runJob(slot_id);
        if (stop) return;
    }
}

fn runJob(slot: usize) void {
    defer {
        std.crypto.secureZero(u8, passwords[slot][0..]);
        std.crypto.secureZero(u8, hashes[slot][0..]);
        std.crypto.secureZero(u8, salts[slot][0..]);
        states[slot].store(@intFromEnum(State.done), .release);
        _ = pending.fetchSub(1, .acq_rel);
        async_h.notify() catch {};
    }

    if (ops[slot] == .hash) {
        const pw = passwords[slot][0..password_lens[slot]];
        const cost = costs[slot];
        const salt = salts[slot];
        const out_slice = bcrypt.strHashWithSalt(
            pw,
            .{
                .params = .{ .rounds_log = cost, .silently_truncate_password = false },
                .encoding = .crypt, // $2b$-style crypt format
            },
            outs[slot][0..],
            salt,
        ) catch {
            errs[slot] = ERR_INTERNAL;
            return;
        };
        out_lens[slot] = out_slice.len;
        errs[slot] = ERR_OK;
    } else {
        if (errs[slot] == ERR_MISMATCH) {
            return;
        }
        const pw = passwords[slot][0..password_lens[slot]];
        var h_buf: [MAX_HASH_STR]u8 = undefined;
        const orig_h = hashes[slot][0..hash_lens[slot]];
        var h = orig_h;
        // Interop normalization: $2a$ and $2y$ (e.g. from htpasswd) map to $2b$
        if (orig_h.len == 60 and orig_h[0] == '$' and orig_h[1] == '2' and (orig_h[2] == 'a' or orig_h[2] == 'y') and orig_h[3] == '$') {
            @memcpy(h_buf[0..orig_h.len], orig_h);
            h_buf[2] = 'b';
            h = h_buf[0..orig_h.len];
        }

        bcrypt.strVerify(
            h,
            pw,
            .{ .silently_truncate_password = false },
        ) catch |e| switch (e) {
            error.PasswordVerificationFailed, error.InvalidEncoding => {
                errs[slot] = ERR_MISMATCH;
                return;
            },
            else => {
                errs[slot] = ERR_INTERNAL;
                return;
            },
        };
        errs[slot] = ERR_OK;
    }
}

pub const SubmitError = error{ QueueFull, PasswordTooLong, HashTooLong, OutOfMemory, EntropyUnavailable };

pub fn submitHash(
    ctx: *c.Context,
    password: []const u8,
    cost: u6,
    resolve: c.Value,
    reject: c.Value,
) SubmitError!void {
    if (password.len > MAX_PASSWORD) return error.PasswordTooLong;
    ensureStarted(ctx) catch return error.OutOfMemory;

    var salt: [16]u8 = undefined;
    fillRandomBytes(&salt) catch return error.EntropyUnavailable;

    poolLock();
    const s = acquireSlot() orelse {
        poolUnlock();
        return error.QueueFull;
    };

    ops[s] = .hash;
    costs[s] = cost;
    @memcpy(passwords[s][0..password.len], password);
    password_lens[s] = password.len;
    @memcpy(&salts[s], &salt);
    errs[s] = ERR_OK;
    out_lens[s] = 0;

    resolve_funcs[s] = c.dupValue(ctx, resolve);
    reject_funcs[s] = c.dupValue(ctx, reject);
    poolUnlock();

    _ = pending.fetchAdd(1, .acq_rel);

    ringLock();
    if (shutdown_requested) {
        ringUnlock();
        _ = pending.fetchSub(1, .acq_rel);
        freeResolvers(ctx, s);
        releaseSlot(s);
        return error.QueueFull;
    }
    job_ring[ring_tail % RING_CAP] = @intCast(s);
    ring_tail +%= 1;
    ringUnlock();

    _ = std.c.write(job_pipe[1], &[_]u8{1}, 1);
    ensureArmed();
}

pub fn submitVerify(
    ctx: *c.Context,
    password: []const u8,
    hash: []const u8,
    resolve: c.Value,
    reject: c.Value,
) SubmitError!void {
    if (hash.len > MAX_HASH_STR) return error.HashTooLong;
    ensureStarted(ctx) catch return error.OutOfMemory;

    poolLock();
    const s = acquireSlot() orelse {
        poolUnlock();
        return error.QueueFull;
    };

    ops[s] = .verify;
    if (password.len <= MAX_PASSWORD) {
        @memcpy(passwords[s][0..password.len], password);
        password_lens[s] = password.len;
        errs[s] = ERR_OK;
    } else {
        // Passwords > 72 bytes cannot match bcrypt with silently_truncate_password=false
        password_lens[s] = 0;
        errs[s] = ERR_MISMATCH;
    }
    @memcpy(hashes[s][0..hash.len], hash);
    hash_lens[s] = hash.len;
    out_lens[s] = 0;

    resolve_funcs[s] = c.dupValue(ctx, resolve);
    reject_funcs[s] = c.dupValue(ctx, reject);
    poolUnlock();

    _ = pending.fetchAdd(1, .acq_rel);

    ringLock();
    if (shutdown_requested) {
        ringUnlock();
        _ = pending.fetchSub(1, .acq_rel);
        freeResolvers(ctx, s);
        releaseSlot(s);
        return error.QueueFull;
    }
    job_ring[ring_tail % RING_CAP] = @intCast(s);
    ring_tail +%= 1;
    ringUnlock();

    _ = std.c.write(job_pipe[1], &[_]u8{1}, 1);
    ensureArmed();
}

fn doneMask() u64 {
    var mask: u64 = 0;
    inline for (0..MAX_JOBS) |i| {
        if (states[i].load(.acquire) == @intFromEnum(State.done)) {
            mask |= @as(u64, 1) << @intCast(i);
        }
    }
    return mask;
}

fn claimSlot(s: usize) bool {
    return states[s].cmpxchgStrong(
        @intFromEnum(State.done),
        @intFromEnum(State.claimed),
        .acq_rel,
        .acquire,
    ) == null;
}

pub fn drainCompleted(ctx: ?*c.Context) void {
    var mask = doneMask();
    while (mask != 0) {
        const s: usize = @ctz(mask);
        mask &= mask - 1;
        if (claimSlot(s)) completeJob(ctx, s);
    }
}

fn completeJob(ctx: ?*c.Context, s: usize) void {
    const resolve = resolve_funcs[s];
    const reject = reject_funcs[s];
    defer {
        freeResolvers(ctx, s);
        releaseSlot(s);
    }

    if (resolve == null or reject == null) return;
    const c_ctx = ctx orelse g_ctx orelse return;

    const op = ops[s];
    const err = errs[s];

    if (err == ERR_INTERNAL) {
        const err_val = c.newError(c_ctx);
        if (c.isException(err_val) == 0) {
            const msg = "crypto.bcrypt: internal error";
            const mv = c.newStringLen(c_ctx, msg.ptr, msg.len);
            _ = c.setPropertyStr(c_ctx, err_val, "message", mv);
            var args = [_]c.Value{err_val};
            const ret = c.call(c_ctx, reject.?, c.JS_UNDEFINED, 1, &args);
            c.freeValue(c_ctx, ret);
            c.freeValue(c_ctx, err_val);
        }
        return;
    }

    switch (op) {
        .hash => {
            const out_str = outs[s][0..out_lens[s]];
            const val = c.newStringLen(c_ctx, out_str.ptr, out_str.len);
            var args = [_]c.Value{val};
            const ret = c.call(c_ctx, resolve.?, c.JS_UNDEFINED, 1, &args);
            c.freeValue(c_ctx, ret);
            c.freeValue(c_ctx, val);
        },
        .verify => {
            const val = if (err == ERR_OK) c.JS_TRUE else c.JS_FALSE;
            var args = [_]c.Value{val};
            const ret = c.call(c_ctx, resolve.?, c.JS_UNDEFINED, 1, &args);
            c.freeValue(c_ctx, ret);
        },
    }
}

// ── Unit Tests ───────────────────────────────────────────────────────────────

test "bcrypt known test vector with fixed salt" {
    const password = "password";
    const salt: [16]u8 = "0123456789abcdef".*;
    var out: [MAX_HASH_STR]u8 = undefined;
    const h = try bcrypt.strHashWithSalt(
        password,
        .{
            .params = .{ .rounds_log = 5, .silently_truncate_password = false },
            .encoding = .crypt,
        },
        &out,
        salt,
    );
    try std.testing.expectEqualStrings("$2b$05$KBCwKxOzLha2MUDgW0PjXe/f7LpTW2UTNeJsFFK5sp4T0lXZccuGq", h);
    try bcrypt.strVerify(h, password, .{ .silently_truncate_password = false });
    try std.testing.expectError(
        error.PasswordVerificationFailed,
        bcrypt.strVerify(h, "wrong_password", .{ .silently_truncate_password = false }),
    );
}

test "bcrypt cost bounds: rounds_log 4 and 14" {
    const password = "test";
    const salt: [16]u8 = "0123456789abcdef".*;
    var out: [MAX_HASH_STR]u8 = undefined;

    // Cost 4 (min)
    const h4 = try bcrypt.strHashWithSalt(
        password,
        .{ .params = .{ .rounds_log = MIN_COST, .silently_truncate_password = false }, .encoding = .crypt },
        &out,
        salt,
    );
    try std.testing.expect(std.mem.startsWith(u8, h4, "$2b$04$"));
    try bcrypt.strVerify(h4, password, .{ .silently_truncate_password = false });

    // Cost bounds constants
    try std.testing.expectEqual(@as(u6, 4), MIN_COST);
    try std.testing.expectEqual(@as(u6, 14), MAX_COST);
    try std.testing.expectEqual(@as(u6, 12), DEFAULT_COST);
}

test "bcrypt verify malformed hash returns error/mismatch" {
    const verify_opts: bcrypt.VerifyOptions = .{ .silently_truncate_password = false };
    // Not enough segments
    try std.testing.expectError(error.InvalidEncoding, bcrypt.strVerify("not_a_bcrypt_hash", "pw", verify_opts));
    // Invalid prefix
    try std.testing.expectError(error.InvalidEncoding, bcrypt.strVerify("$1$05$0123456789abcdef0123456789abcdef0123456789abcdef012345", "pw", verify_opts));
}

test "bcrypt slot queue full and secureZero" {
    poolInit();
    try std.testing.expectEqual(MAX_JOBS, free_count);

    var acquired: [MAX_JOBS]usize = undefined;
    for (0..MAX_JOBS) |i| {
        acquired[i] = acquireSlot().?;
    }
    // Pool is now completely full
    try std.testing.expect(acquireSlot() == null);

    // Release all slots and verify clean zeroing
    for (0..MAX_JOBS) |i| {
        const s = acquired[i];
        passwords[s][0] = 'X';
        salts[s][0] = 'Y';
        outs[s][0] = 'Z';
        releaseSlot(s);
        try std.testing.expectEqual(@as(u8, 0), passwords[s][0]);
        try std.testing.expectEqual(@as(u8, 0), salts[s][0]);
        try std.testing.expectEqual(@as(u8, 0), outs[s][0]);
    }
    try std.testing.expectEqual(MAX_JOBS, free_count);
}
