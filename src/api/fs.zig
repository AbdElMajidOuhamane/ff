const std = @import("std");
const c = @import("../c.zig").c;
const xev = @import("xev");
const microtasks = @import("../event/microtasks.zig");

const Io = std.Io;
const Dir = Io.Dir;

const gpa = std.heap.smp_allocator;

const MAX_PATH = 4096;
const MAX_READ = 10 * 1024 * 1024;

fn getIo() Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn jsPathArg(ctx: ?*c.Context, argc: c_int, argv: [*c]const c.Value, index: c_int, buf: []u8) ?[]const u8 {
    if (argc <= index) return null;
    const val = argv[@intCast(index)];
    if (c.isString(val) == 0) return null;
    var str_len: usize = 0;
    const str_ptr = c.toCStringLen(ctx, &str_len, val) orelse return null;
    defer c.freeCString(ctx, str_ptr);
    const len = @min(str_len, buf.len);
    @memcpy(buf[0..len], str_ptr[0..len]);
    return buf[0..len];
}

fn throwErr(ctx: ?*c.Context, msg: []const u8) void {
    const msg_val = c.newStringLen(ctx, msg.ptr, msg.len);
    _ = c.throw(ctx, msg_val);
}

fn jsBoolArg(ctx: ?*c.Context, argc: c_int, argv: [*c]const c.Value, index: c_int) bool {
    if (argc <= index) return false;
    return c.toBool(ctx, argv[@intCast(index)]) != 0;
}

fn readFileCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = jsPathArg(ctx, argc, argv, 0, &path_buf) orelse return c.JS_UNDEFINED;

    const io = getIo();
    const content = Dir.cwd().readFileAlloc(
        io,
        path,
        gpa,
        .limited(MAX_READ),
    ) catch |err| {
        throwErr(ctx, @errorName(err));
        return c.JS_UNDEFINED;
    };
    defer gpa.free(content);

    // COMPAT: default string (restores server), opt-in binary for images.
    // fs.readFile(path) / fs.readFile(path, "utf8") -> string (old behavior)
    // fs.readFile(path, "buffer" | "binary") -> ArrayBuffer (PNG fix)
    if (argc >= 2 and c.isString(argv[1]) != 0) {
        var mode_len: usize = 0;
        const mode_ptr = c.toCStringLen(ctx, &mode_len, argv[1]) orelse return c.JS_UNDEFINED;
        defer c.freeCString(ctx, mode_ptr);
        const mode = mode_ptr[0..mode_len];
        if (std.mem.eql(u8, mode, "buffer") or std.mem.eql(u8, mode, "binary")) {
            if (content.len == 0) return c.newArrayBufferCopy(ctx, "", 0);
            return c.newArrayBufferCopy(ctx, content.ptr, content.len);
        }
    }
    if (content.len == 0) return c.newStringLen(ctx, "", 0);
    return c.newStringLen(ctx, content.ptr, content.len);
}

fn writeFileCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = jsPathArg(ctx, argc, argv, 0, &path_buf) orelse return c.JS_UNDEFINED;

    if (argc < 2) return c.JS_UNDEFINED;
    const data_val = argv[1];
    var str_len: usize = 0;
    const str_ptr = c.toCStringLen(ctx, &str_len, data_val) orelse return c.JS_UNDEFINED;
    defer c.freeCString(ctx, str_ptr);
    const data_final = @min(str_len, MAX_READ);

    const io = getIo();
    Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = str_ptr[0..data_final],
    }) catch |err| {
        throwErr(ctx, @errorName(err));
    };
    return c.JS_UNDEFINED;
}

fn existsCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = jsPathArg(ctx, argc, argv, 0, &path_buf) orelse return c.JS_FALSE;

    const io = getIo();
    const found = if (Dir.cwd().access(io, path, .{})) true else |_| false;
    return if (found) c.JS_TRUE else c.JS_FALSE;
}

fn mkdirCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = jsPathArg(ctx, argc, argv, 0, &path_buf) orelse return c.JS_UNDEFINED;

    const recursive = jsBoolArg(ctx, argc, argv, 1);
    const io = getIo();

    if (recursive) {
        Dir.cwd().createDirPath(io, path) catch |err| {
            throwErr(ctx, @errorName(err));
        };
    } else {
        Dir.cwd().createDir(io, path, .default_dir) catch |err| {
            throwErr(ctx, @errorName(err));
        };
    }
    return c.JS_UNDEFINED;
}

fn rmCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = jsPathArg(ctx, argc, argv, 0, &path_buf) orelse return c.JS_UNDEFINED;

    const recursive = jsBoolArg(ctx, argc, argv, 1);
    const io = getIo();

    if (recursive) {
        Dir.cwd().deleteTree(io, path) catch |err| {
            throwErr(ctx, @errorName(err));
        };
    } else {
        Dir.cwd().deleteFile(io, path) catch {
            Dir.cwd().deleteDir(io, path) catch |err| {
                throwErr(ctx, @errorName(err));
            };
        };
    }
    return c.JS_UNDEFINED;
}

fn readdirCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;

    var path_buf: [MAX_PATH]u8 = undefined;
    const path = jsPathArg(ctx, argc, argv, 0, &path_buf) orelse return c.JS_UNDEFINED;

    const io = getIo();
    var dir = Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        throwErr(ctx, @errorName(err));
        return c.JS_UNDEFINED;
    };
    defer dir.close(io);

    var names = std.ArrayList([:0]const u8).empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        const name = gpa.dupeZ(u8, entry.name) catch continue;
        names.append(gpa, name) catch continue;
    }

    const arr = c.newArray(ctx);
    for (names.items, 0..) |name, i| {
        const js_name = c.newStringLen(ctx, name.ptr, name.len);
        _ = c.setPropertyUint32(ctx, arr, @intCast(i), js_name);
    }
    return arr;
}

// ── Async FS (C2): Promise-based non-blocking variants ─────────────
//
// Sync names above block the loop thread (documented, kept for scripts).
// The *Async variants below run on a fixed 16-slot job pool on a shared
// xev thread pool (mirror: ffi.zig CallJob + async_fetch states), so a
// slow disk never stalls connections. Completion drains on the JS thread
// via drainCompleted (wired into event/loop.zig like ffi_api).
//
// Steady state per op: zero gpa after high-water warmup — the read result
// and readdir name buffers are per-job ArrayLists with clearRetaining-
// Capacity; only the write payload >64KB spills to heap (freed at settle).

const MAX_FS_JOBS: usize = 16;
const ST_FREE: u8 = 0;
const ST_CLAIMED: u8 = 1;
const ST_DONE: u8 = 2;
// Retained result high-water per job: bigger buffers are freed at settle
// so one 10MB read doesn't pin 10MB×16 forever.
const RESULT_RETAIN_MAX: usize = 256 * 1024;
// Static write staging per job (16×64KB); heap spill above it.
const WRITE_STAGE: usize = 64 * 1024;

const FsOp = enum(u8) { read_file, write_file, exists, mkdir, rm, readdir };

const FsJob = struct {
    task: xev.ThreadPool.Task = .{ .callback = jobRun },
    op: FsOp = .read_file,
    path: [MAX_PATH]u8 = undefined,
    path_len: usize = 0,
    mode: u8 = 0, // read_file: 0 = utf8 string, 1 = buffer
    recursive: bool = false, // mkdir/rm
    found: bool = false, // exists result
    // write input: static staging, heap spill above WRITE_STAGE
    data_static: [WRITE_STAGE]u8 = undefined,
    data: []const u8 = &.{},
    data_heap: ?[]u8 = null,
    // results: reused across jobs (cleared at acquire, retained at settle)
    result: std.ArrayList(u8) = .empty,
    name_count: usize = 0, // readdir: NUL-separated names packed in result
    ok: bool = false,
    err_name: ?[:0]const u8 = null, // static @errorName string
    resolve: c.Value = c.JS_UNDEFINED,
    reject: c.Value = c.JS_UNDEFINED,
    used: bool = false,
};
// Option B: `undefined` + runtime init in setup() keeps this array in
// __bss (zerofill, no file footprint). A comptime `.{}`-initialized array
// is emitted into file-backed __DATA because of the nonzero defaults
// (task.callback pointer, JS_UNDEFINED) — macOS then faults in the full
// 16×(64KB+) staging region at load (+~1.1MB peak RSS, confirmed with
// mem-bench and `size -m` section deltas).
var jobs: [MAX_FS_JOBS]FsJob = undefined;

// C2 FIX: hot scan keys outside the ~70KB job record (same split as A3:
// drainCompleted scans this 16-byte column, not the payloads).
var job_state: [MAX_FS_JOBS]std.atomic.Value(u8) =
    [_]std.atomic.Value(u8){.{ .raw = ST_FREE }} ** MAX_FS_JOBS;

fn jobIndex(job: *FsJob) usize {
    return (@intFromPtr(job) - @intFromPtr(&jobs)) / @sizeOf(FsJob);
}

var fs_pool: xev.ThreadPool = undefined;
var fs_pool_up = false;

fn poolRef() *xev.ThreadPool {
    if (!fs_pool_up) {
        fs_pool = xev.ThreadPool.init(.{ .max_threads = 4 });
        fs_pool_up = true;
    }
    return &fs_pool;
}

const AsyncT = xev.Async;
var async_h: AsyncT = undefined;
var async_comp: xev.Completion = .{};
var async_armed = false;
var async_ready = false;
var g_loop: ?*xev.Loop = null;
var g_ctx: ?*c.Context = null;

pub var pending: std.atomic.Value(u64) = .{ .raw = 0 };

pub fn setLoop(l: *xev.Loop) void {
    g_loop = l;
    if (!async_ready) {
        async_h = AsyncT.init() catch return;
        async_ready = true;
    }
}

fn notifyAsync() void {
    if (async_ready) async_h.notify() catch {};
}

pub fn ensureArmed() void {
    if (async_armed) return;
    const l = g_loop orelse return;
    async_armed = true;
    async_h.wait(l, &async_comp, void, null, asyncCb);
}

fn asyncCb(ud: ?*void, l: *xev.Loop, comp: *xev.Completion, r: AsyncT.WaitError!void) xev.CallbackAction {
    _ = ud;
    _ = comp;
    _ = r catch return .disarm;
    if (g_ctx) |ctx| {
        drainCompleted(ctx);
        microtasks.pumpMicrotasks(ctx);
    }
    if (pending.load(.acquire) > 0) {
        async_armed = true;
        async_h.wait(l, &async_comp, void, null, asyncCb);
    } else async_armed = false;
    return .disarm;
}

fn acquireJob() ?*FsJob {
    for (0..MAX_FS_JOBS) |i| {
        if (job_state[i].cmpxchgStrong(ST_FREE, ST_CLAIMED, .acq_rel, .acquire) != null) continue;
        const j = &jobs[i];
        j.task = .{ .callback = jobRun };
        j.data = &.{};
        j.data_heap = null;
        j.result.clearRetainingCapacity();
        j.name_count = 0;
        j.found = false;
        j.ok = false;
        j.err_name = null;
        j.resolve = c.JS_UNDEFINED;
        j.reject = c.JS_UNDEFINED;
        j.used = true;
        return j;
    }
    return null;
}

fn jobFail(job: *FsJob, err: anyerror) void {
    job.err_name = @errorName(err);
    job.ok = false;
}

/// Worker thread: blocking FS calls only. No JS, no QuickJS.
/// Result bytes land in the reusable per-job `result` buffer (grows only
/// to high-water); `data` was staged at submit (static or heap spill).
fn runOp(job: *FsJob) void {
    const io = getIo();
    const path = job.path[0..job.path_len];
    switch (job.op) {
        .read_file => {
            const f = Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch |err| {
                jobFail(job, err);
                return;
            };
            defer f.close(io);
            var staging: [8192]u8 = undefined;
            var r = f.reader(io, &staging);
            var total: usize = 0;
            while (true) {
                job.result.ensureUnusedCapacity(gpa, 8192) catch |err| {
                    jobFail(job, err);
                    return;
                };
                const spare_all = job.result.allocatedSlice();
                const spare = spare_all[job.result.items.len..][0..8192];
                const n = r.interface.readSliceShort(spare) catch |err| {
                    jobFail(job, err);
                    return;
                };
                if (n == 0) break;
                job.result.items.len += n;
                total += n;
                if (total > MAX_READ) {
                    jobFail(job, error.FileTooLarge);
                    return;
                }
            }
            job.ok = true;
        },
        .write_file => {
            Dir.cwd().writeFile(io, .{
                .sub_path = path,
                .data = job.data[0..@min(job.data.len, MAX_READ)],
            }) catch |err| {
                jobFail(job, err);
                return;
            };
            job.ok = true;
        },
        .exists => {
            job.found = if (Dir.cwd().access(io, path, .{})) true else |_| false;
            job.ok = true;
        },
        .mkdir => {
            if (job.recursive) {
                Dir.cwd().createDirPath(io, path) catch |err| {
                    jobFail(job, err);
                    return;
                };
            } else {
                Dir.cwd().createDir(io, path, .default_dir) catch |err| {
                    jobFail(job, err);
                    return;
                };
            }
            job.ok = true;
        },
        .rm => {
            if (job.recursive) {
                Dir.cwd().deleteTree(io, path) catch |err| {
                    jobFail(job, err);
                    return;
                };
            } else {
                Dir.cwd().deleteFile(io, path) catch {
                    Dir.cwd().deleteDir(io, path) catch |err| {
                        jobFail(job, err);
                        return;
                    };
                };
            }
            job.ok = true;
        },
        .readdir => {
            var dir = Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
                jobFail(job, err);
                return;
            };
            defer dir.close(io);
            var iter = dir.iterate();
            var count: usize = 0;
            while (iter.next(io) catch null) |entry| {
                job.result.ensureUnusedCapacity(gpa, entry.name.len + 1) catch |err| {
                    jobFail(job, err);
                    return;
                };
                job.result.appendSlice(gpa, entry.name) catch |err| {
                    jobFail(job, err);
                    return;
                };
                job.result.append(gpa, 0) catch |err| {
                    jobFail(job, err);
                    return;
                };
                count += 1;
            }
            job.name_count = count;
            job.ok = true;
        },
    }
}

fn jobRun(task: *xev.ThreadPool.Task) void {
    const job: *FsJob = @alignCast(@fieldParentPtr("task", task));
    runOp(job);
    job_state[jobIndex(job)].store(ST_DONE, .release);
    notifyAsync();
}

fn rejectWith(job: *FsJob, ctx: ?*c.Context, name: []const u8) void {
    const err = c.newError(ctx);
    if (c.isException(err) != 0) return;
    const mv = c.newStringLen(ctx, name.ptr, name.len);
    _ = c.setPropertyStr(ctx, err, "message", mv);
    var args = [_]c.Value{err};
    const ret = c.call(ctx, job.reject, c.JS_UNDEFINED, 1, &args);
    c.freeValue(ctx, ret);
    c.freeValue(ctx, err);
}

fn resolveWith(job: *FsJob, ctx: ?*c.Context, val: c.Value) void {
    var args = [_]c.Value{val};
    const ret = c.call(ctx, job.resolve, c.JS_UNDEFINED, 1, &args);
    c.freeValue(ctx, ret);
    c.freeValue(ctx, val);
}

/// JS thread: build JS values from worker results (copies — the reusable
/// buffers stay ours), free caps, return the slot. Runs inside drainCompleted.
fn settleJob(ctx: ?*c.Context, job: *FsJob) void {
    defer {
        c.freeValue(ctx, job.resolve);
        c.freeValue(ctx, job.reject);
        job.resolve = c.JS_UNDEFINED;
        job.reject = c.JS_UNDEFINED;
        if (job.data_heap) |d| {
            gpa.free(d);
            job.data_heap = null;
        }
        job.data = &.{};
        // Cap retained high-water so one huge file doesn't pin memory.
        if (job.result.capacity > RESULT_RETAIN_MAX) {
            job.result.deinit(gpa);
            job.result = .empty;
        }
        _ = pending.fetchSub(1, .release);
    }
    if (!job.ok) {
        rejectWith(job, ctx, job.err_name orelse "fs error");
        return;
    }
    switch (job.op) {
        .read_file => {
            const bytes = job.result.items;
            // COMPAT: mirror the sync mode flag (utf8 string vs buffer).
            const v = if (job.mode == 1)
                (if (bytes.len == 0) c.newArrayBufferCopy(ctx, "", 0) else c.newArrayBufferCopy(ctx, bytes.ptr, bytes.len))
            else
                (if (bytes.len == 0) c.newStringLen(ctx, "", 0) else c.newStringLen(ctx, bytes.ptr, bytes.len));
            resolveWith(job, ctx, v);
        },
        .write_file, .mkdir, .rm => {
            var no_args = [_]c.Value{};
            const ret = c.call(ctx, job.resolve, c.JS_UNDEFINED, 0, &no_args);
            c.freeValue(ctx, ret);
        },
        .exists => {
            resolveWith(job, ctx, if (job.found) c.JS_TRUE else c.JS_FALSE);
        },
        .readdir => {
            const arr = c.newArray(ctx);
            var off: usize = 0;
            var idx: u32 = 0;
            var k: usize = 0;
            while (k < job.name_count) : (k += 1) {
                const start = off;
                while (off < job.result.items.len and job.result.items[off] != 0) off += 1;
                const name = job.result.items[start..off];
                off += 1; // skip NUL
                const js_name = c.newStringLen(ctx, name.ptr, name.len);
                _ = c.setPropertyUint32(ctx, arr, idx, js_name);
                idx += 1;
            }
            var args = [_]c.Value{arr};
            const ret = c.call(ctx, job.resolve, c.JS_UNDEFINED, 1, &args);
            c.freeValue(ctx, ret);
            c.freeValue(ctx, arr);
        },
    }
}

pub fn drainCompleted(ctx: ?*c.Context) void {
    // C2 FIX: scan the 16-byte state column, not the ~70KB job records.
    for (0..MAX_FS_JOBS) |i| {
        if (job_state[i].load(.acquire) != ST_DONE) continue;
        settleJob(ctx, &jobs[i]);
        jobs[i].used = false;
        job_state[i].store(ST_FREE, .release);
    }
}

fn submitJob(
    ctx: ?*c.Context,
    op: FsOp,
    path: []const u8,
    mode: u8,
    recursive: bool,
    data: []const u8,
) c.Value {
    var cap: [2]c.Value = undefined;
    const promise = c.newPromiseCapability(ctx, &cap);
    if (c.isException(promise) != 0) return promise;
    const job = acquireJob() orelse {
        c.freeValue(ctx, cap[0]);
        c.freeValue(ctx, cap[1]);
        c.freeValue(ctx, promise);
        return c.throwOutOfMemory(ctx);
    };
    @memcpy(job.path[0..path.len], path);
    job.path_len = path.len;
    job.op = op;
    job.mode = mode;
    job.recursive = recursive;
    if (data.len > 0) {
        // Write payload: static staging, heap spill above WRITE_STAGE.
        // The JS string may be GC'd after return — the copy is required.
        if (data.len <= job.data_static.len) {
            @memcpy(job.data_static[0..data.len], data);
            job.data = job.data_static[0..data.len];
        } else {
            const heap = gpa.alloc(u8, data.len) catch {
                job.used = false;
                job_state[jobIndex(job)].store(ST_FREE, .release);
                c.freeValue(ctx, cap[0]);
                c.freeValue(ctx, cap[1]);
                c.freeValue(ctx, promise);
                return c.throwOutOfMemory(ctx);
            };
            @memcpy(heap, data);
            job.data_heap = heap;
            job.data = heap;
        }
    }
    job.resolve = c.dupValue(ctx, cap[0]);
    job.reject = c.dupValue(ctx, cap[1]);
    c.freeValue(ctx, cap[0]);
    c.freeValue(ctx, cap[1]);
    _ = pending.fetchAdd(1, .acq_rel);
    ensureArmed();
    poolRef().schedule(.from(&job.task));
    return promise;
}

fn readFileAsyncCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = jsPathArg(ctx, argc, argv, 0, &path_buf) orelse {
        _ = c.throwTypeError(ctx, "fs.readFileAsync requires a path");
        return c.JS_EXCEPTION;
    };
    var mode: u8 = 0;
    if (argc >= 2 and c.isString(argv[1]) != 0) {
        var mode_len: usize = 0;
        const mode_ptr = c.toCStringLen(ctx, &mode_len, argv[1]) orelse return c.JS_EXCEPTION;
        defer c.freeCString(ctx, mode_ptr);
        const m = mode_ptr[0..mode_len];
        if (std.mem.eql(u8, m, "buffer") or std.mem.eql(u8, m, "binary")) mode = 1;
    }
    return submitJob(ctx, .read_file, path, mode, false, &.{});
}

fn writeFileAsyncCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = jsPathArg(ctx, argc, argv, 0, &path_buf) orelse {
        _ = c.throwTypeError(ctx, "fs.writeFileAsync requires a path");
        return c.JS_EXCEPTION;
    };
    if (argc < 2) {
        _ = c.throwTypeError(ctx, "fs.writeFileAsync requires data");
        return c.JS_EXCEPTION;
    }
    var str_len: usize = 0;
    const str_ptr = c.toCStringLen(ctx, &str_len, argv[1]) orelse return c.JS_EXCEPTION;
    defer c.freeCString(ctx, str_ptr);
    return submitJob(ctx, .write_file, path, 0, false, str_ptr[0..@min(str_len, MAX_READ)]);
}

fn existsAsyncCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = jsPathArg(ctx, argc, argv, 0, &path_buf) orelse {
        _ = c.throwTypeError(ctx, "fs.existsAsync requires a path");
        return c.JS_EXCEPTION;
    };
    return submitJob(ctx, .exists, path, 0, false, &.{});
}

fn mkdirAsyncCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = jsPathArg(ctx, argc, argv, 0, &path_buf) orelse {
        _ = c.throwTypeError(ctx, "fs.mkdirAsync requires a path");
        return c.JS_EXCEPTION;
    };
    return submitJob(ctx, .mkdir, path, 0, jsBoolArg(ctx, argc, argv, 1), &.{});
}

fn rmAsyncCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = jsPathArg(ctx, argc, argv, 0, &path_buf) orelse {
        _ = c.throwTypeError(ctx, "fs.rmAsync requires a path");
        return c.JS_EXCEPTION;
    };
    return submitJob(ctx, .rm, path, 0, jsBoolArg(ctx, argc, argv, 1), &.{});
}

fn readdirAsyncCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = jsPathArg(ctx, argc, argv, 0, &path_buf) orelse {
        _ = c.throwTypeError(ctx, "fs.readdirAsync requires a path");
        return c.JS_EXCEPTION;
    };
    return submitJob(ctx, .readdir, path, 0, false, &.{});
}

pub fn setup(ctx: *c.Context) void {
    // Option B: initialize the job pool at runtime so `jobs` stays in
    // __bss. Field-store loop only — data_static (16×64KB) is deliberately
    // never written here, so those pages stay demand-paged until a write
    // job claims its slot. (A comptime `[_]FsJob{.{}} ** N` initializer
    // would place the whole array in file-backed __DATA: +~1.1MB RSS.)
    for (&jobs) |*j| {
        j.task = .{ .callback = jobRun };
        j.op = .read_file;
        j.path_len = 0;
        j.mode = 0;
        j.recursive = false;
        j.found = false;
        j.data = &.{};
        j.data_heap = null;
        j.result = .empty;
        j.name_count = 0;
        j.ok = false;
        j.err_name = null;
        j.resolve = c.JS_UNDEFINED;
        j.reject = c.JS_UNDEFINED;
        j.used = false;
    }

    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);
    const fs_obj = c.newObject(ctx);

    const readFile_fn = c.newCFunction(ctx, readFileCallback, "readFile", 2);
    _ = c.definePropertyValueStr(ctx, fs_obj, "readFile", readFile_fn, c.PROP_C_W_E);

    const writeFile_fn = c.newCFunction(ctx, writeFileCallback, "writeFile", 2);
    _ = c.definePropertyValueStr(ctx, fs_obj, "writeFile", writeFile_fn, c.PROP_C_W_E);

    const exists_fn = c.newCFunction(ctx, existsCallback, "exists", 1);
    _ = c.definePropertyValueStr(ctx, fs_obj, "exists", exists_fn, c.PROP_C_W_E);

    const mkdir_fn = c.newCFunction(ctx, mkdirCallback, "mkdir", 2);
    _ = c.definePropertyValueStr(ctx, fs_obj, "mkdir", mkdir_fn, c.PROP_C_W_E);

    const rm_fn = c.newCFunction(ctx, rmCallback, "rm", 2);
    _ = c.definePropertyValueStr(ctx, fs_obj, "rm", rm_fn, c.PROP_C_W_E);

    const readdir_fn = c.newCFunction(ctx, readdirCallback, "readdir", 1);
    _ = c.definePropertyValueStr(ctx, fs_obj, "readdir", readdir_fn, c.PROP_C_W_E);

    // C2: non-blocking Promise variants (fixed job pool, thread-pool workers).
    const readFileAsync_fn = c.newCFunction(ctx, readFileAsyncCallback, "readFileAsync", 2);
    _ = c.definePropertyValueStr(ctx, fs_obj, "readFileAsync", readFileAsync_fn, c.PROP_C_W_E);

    const writeFileAsync_fn = c.newCFunction(ctx, writeFileAsyncCallback, "writeFileAsync", 2);
    _ = c.definePropertyValueStr(ctx, fs_obj, "writeFileAsync", writeFileAsync_fn, c.PROP_C_W_E);

    const existsAsync_fn = c.newCFunction(ctx, existsAsyncCallback, "existsAsync", 1);
    _ = c.definePropertyValueStr(ctx, fs_obj, "existsAsync", existsAsync_fn, c.PROP_C_W_E);

    const mkdirAsync_fn = c.newCFunction(ctx, mkdirAsyncCallback, "mkdirAsync", 2);
    _ = c.definePropertyValueStr(ctx, fs_obj, "mkdirAsync", mkdirAsync_fn, c.PROP_C_W_E);

    const rmAsync_fn = c.newCFunction(ctx, rmAsyncCallback, "rmAsync", 2);
    _ = c.definePropertyValueStr(ctx, fs_obj, "rmAsync", rmAsync_fn, c.PROP_C_W_E);

    const readdirAsync_fn = c.newCFunction(ctx, readdirAsyncCallback, "readdirAsync", 1);
    _ = c.definePropertyValueStr(ctx, fs_obj, "readdirAsync", readdirAsync_fn, c.PROP_C_W_E);

    _ = c.definePropertyValueStr(ctx, global, "fs", fs_obj, c.PROP_C_W_E);
}
