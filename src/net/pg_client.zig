//! PostgreSQL wire client — full zig-data-oriented-design compliance + Phase 3:
//! TB §1 Zero Zig-gpa per I/O op after init:
//!   Job freelist + arena.reset(.retain_with_limit = 32KB); frames → wqueue (no temps);
//!   wait queue = intrusive Job list (no Waiter alloc); decodeBytea/arrays/JSON → job arena.
//! TB §2 Batch: Parse/Bind/Describe/Execute/Sync → ONE write; processBuffer drains MANY msgs.
//! TB §3 Buffer reuse + RSS caps: wqueue ≤ 64KB (shrink after write), rbuf ≤ 64KB,
//!   job arena retain ≤ 32KB, freelist ≤ config.max (excess Jobs destroyed).
//! TB §5 Measure: Debug CountingAllocator + atomics (submit/reuse/grow/shrink/wait/arena_fail).
//! Phase 3 decode: JSON/JSONB (114/3802) via parseJSON over a NUL-terminated
//!   job-arena copy (JS_ParseJSON requires buf[len]=='\0'; rbuf never guarantees it);
//!   int8 outside ±2^53 → BigInt;
//!   arrays (bool/int2/int4/int8/text/varchar/float/json/bytea/numeric-as-text,
//!   incl. nested) parsed into JS arrays, temps on job arena.
//! Phase 3 tx: BEGIN pins conn (in_tx bit); tx queries route straight to it;
//!   COMMIT/ROLLBACK unpin + release; detachTx on every death path; destroyTx
//!   for GC'd Tx (in-flight jobs root the Tx object, so only idle conns seen).
//! §Hot/cold: Job.err.* cold (only ErrorResponse); query fields hot.
//! §Layout: ConnFlags packed u8 (incl. in_tx); state/auth/op enum(u8); FieldDesc dense [];
//!   AoS Conn/Job justified: N ≤ max(10), whole-object access per op — no MultiArrayList/SoA.
//! §SIMD: N/A (text wire protocol, no numeric hot loop).
//! Cold (exempt): SCRAM/DNS/Config/pool create; QuickJS heap for promises/rows/errors.

const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const c = @import("../c.zig").c;
const counting = @import("../util/counting_allocator.zig");

var pg_counter: counting.CountingAllocator = .{ .base = std.heap.smp_allocator };
const gpa = if (builtin.mode == .Debug)
    pg_counter.allocator()
else
    std.heap.smp_allocator;

extern "c" fn arc4random_buf(buf: [*]u8, len: usize) void;

/// RSS Option A: per-job arena high-water retained after release.
const ARENA_RETAIN_LIMIT: usize = 32 * 1024;
/// Per-connection write batch buffer cap (freed if exceeded after a write).
const WQUEUE_CAP_MAX: usize = 64 * 1024;
/// Per-connection read buffer cap (no growth past this; full → failConn).
const RBUF_CAP_MAX: usize = 64 * 1024;

pub var pending: std.atomic.Value(u32) = .{ .raw = 0 };
pub var stat_submit: std.atomic.Value(u32) = .{ .raw = 0 };
pub var stat_job_reuse: std.atomic.Value(u32) = .{ .raw = 0 };
pub var stat_job_fresh: std.atomic.Value(u32) = .{ .raw = 0 };
pub var stat_wqueue_grow: std.atomic.Value(u32) = .{ .raw = 0 };
pub var stat_wqueue_shrink: std.atomic.Value(u32) = .{ .raw = 0 };
pub var stat_wait_enqueue: std.atomic.Value(u32) = .{ .raw = 0 };
pub var stat_arena_reset_fail: std.atomic.Value(u32) = .{ .raw = 0 };
pub var stat_freelist_destroy: std.atomic.Value(u32) = .{ .raw = 0 };

var g_loop: ?*xev.Loop = null;
var g_ctx: ?*c.Context = null;

/// Set by sql.zig at setup: builds the Tx JS object for a settled BEGIN.
pub var tx_factory: ?*const fn (?*c.Context, *Tx) c.Value = null;

pub fn setLoop(l: *xev.Loop) void {
    g_loop = l;
}

pub fn setCtx(ctx: *c.Context) void {
    g_ctx = ctx;
}

pub fn dumpStats() void {
    std.debug.print(
        "[pg] submit={d} reuse={d} fresh={d} wq_grow={d} wq_shrink={d} wait={d} arena_fail={d} free_kill={d} allocs={d} frees={d} +{d}B -{d}B\n",
        .{
            stat_submit.load(.monotonic),
            stat_job_reuse.load(.monotonic),
            stat_job_fresh.load(.monotonic),
            stat_wqueue_grow.load(.monotonic),
            stat_wqueue_shrink.load(.monotonic),
            stat_wait_enqueue.load(.monotonic),
            stat_arena_reset_fail.load(.monotonic),
            stat_freelist_destroy.load(.monotonic),
            pg_counter.alloc_count,
            pg_counter.free_count,
            pg_counter.bytes_allocated,
            pg_counter.bytes_freed,
        },
    );
}

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 5432,
    user: []const u8 = "postgres",
    password: []const u8 = "",
    database: []const u8 = "postgres",
    max: usize = 10,
};

pub const FieldDesc = struct {
    name: [:0]u8,
    oid: u32,
};

comptime {
    std.debug.assert(@sizeOf(FieldDesc) == 24);
}

pub const TxOp = enum(u8) { none, begin, commit, rollback };

/// Transaction handle. Owned by the Tx JS object (freed in its finalizer).
/// Every in-flight tx/commit job holds a dup'd ref to the Tx JS object, so the
/// finalizer only ever runs with an idle (or already detached) connection.
pub const Tx = struct {
    pool: *Pool,
    conn: ?*Conn,
    active: bool = true,
};

pub fn txAlive(tx: *Tx) bool {
    return tx.active and tx.conn != null;
}

pub fn txPool(tx: *Tx) *Pool {
    return tx.pool;
}

/// Finalizer path: Tx JS object collected. In-flight jobs root the object, so
/// the pinned conn is idle here; destroy it (server aborts the open txn).
pub fn destroyTx(tx: *Tx) void {
    if (tx.conn) |conn| {
        tx.conn = null;
        tx.active = false;
        if (conn.tx == tx) conn.tx = null;
        conn.flags.in_tx = false;
        if (conn.job == null and !conn.flags.read_armed and !conn.flags.write_armed and conn.state != .dead) {
            const pool = conn.pool;
            removeConn(pool, conn);
            conn.deinit();
        } else {
            // Practically unreachable (see above); fail safe, never strand.
            failConn(conn, "transaction abandoned");
        }
    }
    gpa.destroy(tx);
}

pub const Job = struct {
    pool: *Pool,
    arena: std.heap.ArenaAllocator,
    resolve: c.Value = c.JS_UNDEFINED,
    reject: c.Value = c.JS_UNDEFINED,
    sql: []const u8 = "",
    params: []const ?[]const u8 = &.{},
    param_oids: []const u32 = &.{},
    fields: []FieldDesc = &.{},
    rows_val: c.Value = c.JS_UNDEFINED,
    has_error: bool = false,
    row_count: usize = 0,
    in_startup: bool = false,
    wait_next: ?*Job = null,
    tx: ?*Tx = null,
    tx_obj: c.Value = c.JS_UNDEFINED,
    tx_op: TxOp = .none,
    /// Cold: filled only on ErrorResponse; arena-backed; cleared on release.
    err: struct {
        severity: []const u8 = "",
        code: []const u8 = "",
        message: []const u8 = "",
        detail: []const u8 = "",
    } = .{},

    pub fn allocator(self: *Job) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn dupe(self: *Job, s: []const u8) ![]u8 {
        return self.arena.allocator().dupe(u8, s);
    }

    pub fn dupeZ(self: *Job, s: []const u8) ![:0]u8 {
        return self.arena.allocator().dupeZ(u8, s);
    }

    pub fn alloc(self: *Job, comptime T: type, n: usize) ![]T {
        return self.arena.allocator().alloc(T, n);
    }

    /// Free JS refs, reset arena (retain ≤ 32KB), return to freelist (≤ pool.max).
    pub fn release(self: *Job) void {
        if (g_ctx) |ctx| {
            if (c.isUndefined(self.resolve) == 0) c.freeValue(ctx, self.resolve);
            if (c.isUndefined(self.reject) == 0) c.freeValue(ctx, self.reject);
            if (c.isUndefined(self.rows_val) == 0) c.freeValue(ctx, self.rows_val);
            if (c.isUndefined(self.tx_obj) == 0) c.freeValue(ctx, self.tx_obj);
        }
        self.resolve = c.JS_UNDEFINED;
        self.reject = c.JS_UNDEFINED;
        self.rows_val = c.JS_UNDEFINED;
        self.tx_obj = c.JS_UNDEFINED;
        if (!self.arena.reset(.{ .retain_with_limit = ARENA_RETAIN_LIMIT })) {
            _ = stat_arena_reset_fail.fetchAdd(1, .monotonic);
        }
        self.sql = "";
        self.params = &.{};
        self.param_oids = &.{};
        self.fields = &.{};
        self.has_error = false;
        self.err = .{};
        self.row_count = 0;
        self.in_startup = false;
        self.wait_next = null;
        self.tx = null;
        self.tx_op = .none;
        // Freelist hard cap: destroy excess Jobs so idle RSS stays ≤ max * job_budget.
        if (self.pool.job_freelist.items.len >= self.pool.config.max) {
            _ = stat_freelist_destroy.fetchAdd(1, .monotonic);
            self.arena.deinit();
            gpa.destroy(self);
            return;
        }
        self.pool.job_freelist.append(gpa, self) catch {
            _ = stat_freelist_destroy.fetchAdd(1, .monotonic);
            self.arena.deinit();
            gpa.destroy(self);
        };
    }

    pub fn destroy(self: *Job) void {
        if (g_ctx) |ctx| {
            if (c.isUndefined(self.resolve) == 0) c.freeValue(ctx, self.resolve);
            if (c.isUndefined(self.reject) == 0) c.freeValue(ctx, self.reject);
            if (c.isUndefined(self.rows_val) == 0) c.freeValue(ctx, self.rows_val);
            if (c.isUndefined(self.tx_obj) == 0) c.freeValue(ctx, self.tx_obj);
        }
        self.arena.deinit();
        gpa.destroy(self);
    }
};

const ConnState = enum(u8) {
    connecting,
    auth,
    ready,
    busy,
    closing,
    dead,
};

const AuthPhase = enum(u8) {
    none,
    wait_r,
    need_cleartext,
    need_md5,
    need_scram,
    scram_wait_server_first,
    scram_wait_server_final,
    done,
};

/// Hot I/O flags packed — matches http_native ConnFlags pattern.
const ConnFlags = packed struct(u8) {
    read_armed: bool = false,
    write_armed: bool = false,
    close_after_write: bool = false,
    fd_open: bool = true,
    in_tx: bool = false,
    _pad: u3 = 0,
};

comptime {
    std.debug.assert(@sizeOf(ConnFlags) == 1);
    std.debug.assert(@sizeOf(ConnState) == 1);
    std.debug.assert(@sizeOf(AuthPhase) == 1);
}

const Scram = struct {
    client_first_bare: []u8,
    server_first: []u8 = &.{},
    combined_nonce: []u8 = &.{},
    salt: []u8 = &.{},
    iterations: u32 = 4096,
    stored_key: [32]u8 = undefined,
    auth_message: []u8 = &.{},
    server_sig: [32]u8 = undefined,

    pub fn deinit(self: *Scram) void {
        gpa.free(self.client_first_bare);
        if (self.server_first.len > 0) gpa.free(self.server_first);
        if (self.combined_nonce.len > 0) gpa.free(self.combined_nonce);
        if (self.salt.len > 0) gpa.free(self.salt);
        if (self.auth_message.len > 0) gpa.free(self.auth_message);
    }
};

const Conn = struct {
    pool: *Pool,
    tcp: xev.TCP,
    state: ConnState = .connecting,
    auth_phase: AuthPhase = .none,
    scram: ?*Scram = null,
    md5_salt: [4]u8 = undefined,
    job: ?*Job = null,
    tx: ?*Tx = null,
    rbuf: std.ArrayList(u8) = .empty,
    wqueue: std.ArrayList(u8) = .empty,
    woff: usize = 0,
    flags: ConnFlags = .{},
    connect_comp: xev.Completion = .{},
    read_comp: xev.Completion = .{},
    write_comp: xev.Completion = .{},
    close_comp: xev.Completion = .{},

    fn deinit(self: *Conn) void {
        detachTx(self);
        if (self.scram) |s| {
            s.deinit();
            gpa.destroy(s);
        }
        self.rbuf.deinit(gpa);
        self.wqueue.deinit(gpa);
        if (self.flags.fd_open) {
            _ = std.c.close(self.tcp.fd);
            self.flags.fd_open = false;
        }
        gpa.destroy(self);
    }
};

pub const Pool = struct {
    config: Config,
    conns: std.ArrayList(*Conn) = .empty,
    idle: std.ArrayList(*Conn) = .empty,
    job_freelist: std.ArrayList(*Job) = .empty,
    wait_head: ?*Job = null,
    wait_tail: ?*Job = null,
    closed: bool = false,

    pub fn create(config: Config) !*Pool {
        const owned = try dupeConfig(config);
        const p = try gpa.create(Pool);
        p.* = .{ .config = owned };
        if (builtin.mode == .Debug) {
            std.debug.print(
                "[pg layout] Job={d}B Conn={d}B FieldDesc={d}B Config={d}B arena_cap={d} wq_cap={d} rbuf_cap={d}\n",
                .{
                    @sizeOf(Job),
                    @sizeOf(Conn),
                    @sizeOf(FieldDesc),
                    @sizeOf(Config),
                    ARENA_RETAIN_LIMIT,
                    WQUEUE_CAP_MAX,
                    RBUF_CAP_MAX,
                },
            );
        }
        return p;
    }

    pub fn destroy(self: *Pool) void {
        self.closeNow();
        while (self.job_freelist.pop()) |j| {
            j.destroy();
        }
        freeConfig(self.config);
        gpa.destroy(self);
    }

    /// Preallocated op state (TB §1): freelist hit = 0 gpa.
    pub fn acquireJob(self: *Pool) ?*Job {
        if (self.job_freelist.pop()) |j| {
            _ = stat_job_reuse.fetchAdd(1, .monotonic);
            return j;
        }
        const j = gpa.create(Job) catch return null;
        _ = stat_job_fresh.fetchAdd(1, .monotonic);
        j.* = .{
            .pool = self,
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
        return j;
    }

    pub fn query(self: *Pool, job: *Job) void {
        _ = pending.fetchAdd(1, .acq_rel);
        _ = stat_submit.fetchAdd(1, .monotonic);
        if (self.closed) {
            settleReject(job, "pool is closed");
            return;
        }
        // Transaction-pinned routing: straight to the tx conn, never the pool.
        if (job.tx) |tx| {
            if (!tx.active or tx.conn == null) {
                settleReject(job, "transaction closed");
                return;
            }
            const conn = tx.conn.?;
            if (conn.job != null or conn.state != .ready) {
                settleReject(job, "transaction busy");
                return;
            }
            job.wait_next = null;
            conn.job = job;
            conn.state = .busy;
            sendQuery(conn) catch {
                failConn(conn, "failed to send query");
            };
            return;
        }
        if (self.idle.items.len > 0) {
            const idx = self.idle.items.len - 1;
            const conn = self.idle.items[idx];
            self.idle.items.len = idx;
            job.in_startup = false;
            job.wait_next = null;
            conn.job = job;
            conn.state = .busy;
            sendQuery(conn) catch {
                failConn(conn, "failed to send query");
            };
            return;
        }
        if (self.conns.items.len < self.config.max) {
            self.startConn(job) catch {
                settleReject(job, "failed to start connection");
            };
            return;
        }
        // Pool saturated: intrusive wait queue — 0 gpa (no Waiter).
        job.wait_next = null;
        if (self.wait_tail) |tail| {
            tail.wait_next = job;
            self.wait_tail = job;
        } else {
            self.wait_head = job;
            self.wait_tail = job;
        }
        _ = stat_wait_enqueue.fetchAdd(1, .monotonic);
    }

    fn startConn(self: *Pool, job: *Job) !void {
        const loop = g_loop orelse return error.NoLoop;
        const addr = try resolveHost(self.config.host, self.config.port);
        const tcp = try xev.TCP.init(addr);
        const conn = try gpa.create(Conn);
        conn.* = .{ .pool = self, .tcp = tcp };
        job.in_startup = true;
        job.wait_next = null;
        conn.job = job;
        try self.conns.append(gpa, conn);
        tcp.connect(loop, &conn.connect_comp, addr, Conn, conn, connectCb);
    }

    fn release(self: *Pool, conn: *Conn) void {
        if (self.closed or conn.state == .dead) {
            removeConn(self, conn);
            conn.deinit();
            return;
        }
        // Safety net: pinned tx conns never return to the idle list.
        if (conn.flags.in_tx) {
            conn.job = null;
            conn.state = .ready;
            return;
        }
        if (self.wait_head) |next| {
            self.wait_head = next.wait_next;
            if (self.wait_head == null) self.wait_tail = null;
            next.wait_next = null;
            next.in_startup = false;
            conn.job = next;
            conn.state = .busy;
            sendQuery(conn) catch {
                failConn(conn, "failed to send query");
            };
            return;
        }
        conn.job = null;
        conn.state = .ready;
        self.idle.append(gpa, conn) catch {
            removeConn(self, conn);
            conn.deinit();
        };
    }

    pub fn closeNow(self: *Pool) void {
        self.closed = true;
        while (self.wait_head) |job| {
            self.wait_head = job.wait_next;
            if (self.wait_head == null) self.wait_tail = null;
            job.wait_next = null;
            settleReject(job, "pool is closed");
        }
        while (self.idle.items.len > 0) {
            const conn = self.idle.pop().?;
            terminateAndDestroy(conn);
        }
        while (self.conns.items.len > 0) {
            const conn = self.conns.pop().?;
            if (conn.job) |job| {
                settleReject(job, "pool is closed");
                conn.job = null;
            }
            terminateAndDestroy(conn);
        }
    }
};

fn dupeConfig(cfg: Config) !Config {
    var out = cfg;
    out.host = try gpa.dupe(u8, cfg.host);
    out.user = try gpa.dupe(u8, cfg.user);
    out.password = try gpa.dupe(u8, cfg.password);
    out.database = try gpa.dupe(u8, cfg.database);
    return out;
}

fn freeConfig(cfg: Config) void {
    gpa.free(cfg.host);
    gpa.free(cfg.user);
    gpa.free(cfg.password);
    gpa.free(cfg.database);
}

fn removeConn(pool: *Pool, conn: *Conn) void {
    for (pool.idle.items, 0..) |c0, i| {
        if (c0 == conn) {
            _ = pool.idle.orderedRemove(i);
            break;
        }
    }
    for (pool.conns.items, 0..) |c0, i| {
        if (c0 == conn) {
            _ = pool.conns.orderedRemove(i);
            break;
        }
    }
}

/// Idempotent: safe to call from every teardown path.
fn detachTx(conn: *Conn) void {
    if (conn.tx) |t| {
        t.conn = null;
        t.active = false;
        conn.tx = null;
    }
    conn.flags.in_tx = false;
}

fn destroyConn(conn: *Conn) void {
    detachTx(conn);
    if (conn.scram) |s| {
        s.deinit();
        gpa.destroy(s);
        conn.scram = null;
    }
    conn.rbuf.deinit(gpa);
    conn.wqueue.deinit(gpa);
    gpa.destroy(conn);
}

fn terminateAndDestroy(conn: *Conn) void {
    detachTx(conn);
    if (conn.flags.fd_open) {
        const term = "X\x00\x00\x00\x04";
        _ = std.c.write(conn.tcp.fd, term.ptr, term.len);
        _ = std.c.close(conn.tcp.fd);
        conn.flags.fd_open = false;
    }
    if (conn.job) |job| {
        settleReject(job, "connection closed");
        conn.job = null;
    }
    conn.state = .dead;
    removeConn(conn.pool, conn);
    if (!conn.flags.read_armed and !conn.flags.write_armed) {
        destroyConn(conn);
    }
}

pub fn settleResolve(job: *Job, rows: c.Value) void {
    const ctx = g_ctx orelse {
        _ = pending.fetchSub(1, .acq_rel);
        job.release();
        return;
    };
    var args = [_]c.Value{rows};
    const ret = c.call(ctx, job.resolve, c.JS_UNDEFINED, 1, &args);
    c.freeValue(ctx, ret);
    c.freeValue(ctx, rows);
    _ = pending.fetchSub(1, .acq_rel);
    job.release();
}

fn settleReject(job: *Job, msg: []const u8) void {
    const ctx = g_ctx orelse {
        _ = pending.fetchSub(1, .acq_rel);
        job.release();
        return;
    };
    const err = makeError(ctx, "ERROR", "08006", msg, null);
    if (c.isException(err) != 0) {
        const exc = c.getException(ctx);
        c.freeValue(ctx, exc);
        _ = pending.fetchSub(1, .acq_rel);
        job.release();
        return;
    }
    var args = [_]c.Value{err};
    const ret = c.call(ctx, job.reject, c.JS_UNDEFINED, 1, &args);
    c.freeValue(ctx, ret);
    c.freeValue(ctx, err);
    _ = pending.fetchSub(1, .acq_rel);
    job.release();
}

pub fn makeError(
    ctx: ?*c.Context,
    severity: []const u8,
    code: []const u8,
    message: []const u8,
    detail: ?[]const u8,
) c.Value {
    const err = c.newError(ctx);
    if (c.isException(err) != 0) return err;
    const msg_v = c.newStringLen(ctx, message.ptr, message.len);
    _ = c.setPropertyStr(ctx, err, "message", msg_v);
    const sev_v = c.newStringLen(ctx, severity.ptr, severity.len);
    _ = c.setPropertyStr(ctx, err, "severity", sev_v);
    const code_v = c.newStringLen(ctx, code.ptr, code.len);
    _ = c.setPropertyStr(ctx, err, "code", code_v);
    if (detail) |d| {
        const d_v = c.newStringLen(ctx, d.ptr, d.len);
        _ = c.setPropertyStr(ctx, err, "detail", d_v);
    }
    return err;
}

fn failConn(conn: *Conn, msg: []const u8) void {
    detachTx(conn);
    const job = conn.job;
    conn.job = null;
    conn.state = .dead;
    if (job) |j| {
        settleReject(j, msg);
    }
    const pool = conn.pool;
    removeConn(pool, conn);
    if (conn.flags.fd_open) {
        _ = std.c.close(conn.tcp.fd);
        conn.flags.fd_open = false;
    }
    if (!conn.flags.read_armed and !conn.flags.write_armed) {
        destroyConn(conn);
    }
}

fn connectCb(
    ud: ?*Conn,
    l: *xev.Loop,
    comp: *xev.Completion,
    tcp: xev.TCP,
    r: xev.ConnectError!void,
) xev.CallbackAction {
    _ = comp;
    const conn = ud orelse return .disarm;
    r catch {
        failConn(conn, "connection failed");
        return .disarm;
    };
    _ = tcp;
    conn.state = .auth;
    conn.auth_phase = .wait_r;
    queueStartup(conn) catch {
        failConn(conn, "failed to queue startup");
        return .disarm;
    };
    armWrite(conn, l);
    return .disarm;
}

fn armWrite(conn: *Conn, l: *xev.Loop) void {
    if (conn.flags.write_armed or conn.state == .dead) return;
    if (conn.woff >= conn.wqueue.items.len) return;
    conn.flags.write_armed = true;
    const slice = conn.wqueue.items[conn.woff..];
    conn.tcp.write(l, &conn.write_comp, .{ .slice = slice }, Conn, conn, writeCb);
}

fn armRead(conn: *Conn, l: *xev.Loop) void {
    if (conn.flags.read_armed or conn.state == .dead) return;
    const start = conn.rbuf.items.len;
    if (conn.rbuf.capacity - start < 8192) {
        const new_cap = @min(start + 8192, RBUF_CAP_MAX);
        if (new_cap > conn.rbuf.capacity) {
            conn.rbuf.ensureTotalCapacity(gpa, new_cap) catch {
                failConn(conn, "out of memory");
                return;
            };
        }
    }
    const space = conn.rbuf.items.ptr[start..conn.rbuf.capacity];
    if (space.len == 0) {
        failConn(conn, "read buffer full");
        return;
    }
    conn.flags.read_armed = true;
    conn.tcp.read(l, &conn.read_comp, .{ .slice = space }, Conn, conn, readCb);
}

fn writeCb(
    ud: ?*Conn,
    l: *xev.Loop,
    comp: *xev.Completion,
    tcp: xev.TCP,
    buf: xev.WriteBuffer,
    r: xev.WriteError!usize,
) xev.CallbackAction {
    _ = comp;
    _ = tcp;
    _ = buf;
    const conn = ud orelse return .disarm;
    conn.flags.write_armed = false;
    if (conn.state == .dead) {
        destroyConn(conn);
        return .disarm;
    }
    const n = r catch {
        failConn(conn, "write failed");
        return .disarm;
    };
    conn.woff += n;
    if (conn.flags.close_after_write) {
        if (conn.flags.fd_open) {
            _ = std.c.close(conn.tcp.fd);
            conn.flags.fd_open = false;
        }
        const pool = conn.pool;
        removeConn(pool, conn);
        detachTx(conn);
        if (conn.scram) |s| {
            s.deinit();
            gpa.destroy(s);
            conn.scram = null;
        }
        conn.rbuf.deinit(gpa);
        conn.wqueue.deinit(gpa);
        gpa.destroy(conn);
        return .disarm;
    }
    if (conn.woff >= conn.wqueue.items.len) {
        conn.wqueue.clearRetainingCapacity();
        // RSS cap: release high-water write buffer if above budget.
        if (conn.wqueue.capacity > WQUEUE_CAP_MAX) {
            conn.wqueue.shrinkAndFree(gpa, 0);
            _ = stat_wqueue_shrink.fetchAdd(1, .monotonic);
        }
        conn.woff = 0;
        if (conn.state == .auth or conn.state == .busy) armRead(conn, l);
    } else {
        armWrite(conn, l);
    }
    return .disarm;
}

fn readCb(
    ud: ?*Conn,
    l: *xev.Loop,
    comp: *xev.Completion,
    tcp: xev.TCP,
    buf: xev.ReadBuffer,
    r: xev.ReadError!usize,
) xev.CallbackAction {
    _ = comp;
    _ = tcp;
    _ = buf;
    const conn = ud orelse return .disarm;
    conn.flags.read_armed = false;
    if (conn.state == .dead) {
        destroyConn(conn);
        return .disarm;
    }
    const n = r catch {
        failConn(conn, "read failed");
        return .disarm;
    };
    if (n == 0) {
        failConn(conn, "connection closed by server");
        return .disarm;
    }
    conn.rbuf.items.len += n;
    processBuffer(conn, l);
    return .disarm;
}

fn processBuffer(conn: *Conn, l: *xev.Loop) void {
    while (conn.state != .dead) {
        if (conn.rbuf.items.len < 5) break;
        const typ = conn.rbuf.items[0];
        const len = std.mem.readInt(u32, conn.rbuf.items[1..5], .big);
        if (len < 4) {
            failConn(conn, "invalid message length");
            return;
        }
        const total: usize = 1 + @as(usize, len);
        if (conn.rbuf.items.len < total) break;
        const payload = conn.rbuf.items[5..total];
        handleMessage(conn, l, typ, payload) catch {
            failConn(conn, "protocol error");
            return;
        };
        const rem = conn.rbuf.items.len - total;
        std.mem.copyForwards(u8, conn.rbuf.items[0..rem], conn.rbuf.items[total..]);
        conn.rbuf.items.len = rem;
        if (conn.state == .dead) return;
    }
    if (conn.state == .auth or conn.state == .busy) {
        if (!conn.flags.read_armed and conn.woff >= conn.wqueue.items.len) armRead(conn, l);
    }
}

fn handleMessage(conn: *Conn, l: *xev.Loop, typ: u8, payload: []const u8) !void {
    switch (typ) {
        'R' => try handleAuth(conn, l, payload),
        'S', 'K', 'N', '1', '2', 'n', 's', 'A', 'v' => {},
        'T' => try handleRowDesc(conn, payload),
        'D' => try handleDataRow(conn, payload),
        'C' => {},
        'E' => try handleErrorResponse(conn, payload),
        'Z' => handleReady(conn, l),
        else => {},
    }
}

fn handleAuth(conn: *Conn, l: *xev.Loop, payload: []const u8) !void {
    if (payload.len < 4) return error.BadAuth;
    const code = std.mem.readInt(u32, payload[0..4], .big);
    switch (code) {
        0 => {
            conn.auth_phase = .done;
        },
        3 => {
            conn.auth_phase = .need_cleartext;
            try queuePassword(conn, null);
            armWrite(conn, l);
        },
        5 => {
            if (payload.len < 8) return error.BadAuth;
            @memcpy(conn.md5_salt[0..4], payload[4..8]);
            conn.auth_phase = .need_md5;
            try queuePassword(conn, null);
            armWrite(conn, l);
        },
        10, 11, 12 => {
            if (code == 10) {
                try beginScram(conn, payload[4..]);
                armWrite(conn, l);
            } else if (code == 11) {
                try handleScramServerFirst(conn, l, payload[4..]);
            } else if (code == 12) {
                try handleScramServerFinal(conn, payload[4..]);
            }
        },
        else => return error.UnsupportedAuth,
    }
}

fn handleRowDesc(conn: *Conn, payload: []const u8) !void {
    const job = conn.job orelse return;
    if (payload.len < 2) return error.BadRowDesc;
    const n = std.mem.readInt(u16, payload[0..2], .big);
    if (n > 0) {
        job.fields = try job.alloc(FieldDesc, n);
    } else {
        job.fields = &.{};
    }
    var off: usize = 2;
    var i: u16 = 0;
    while (i < n) : (i += 1) {
        const name_start = off;
        while (off < payload.len and payload[off] != 0) off += 1;
        if (off >= payload.len) return error.BadRowDesc;
        const name = payload[name_start..off];
        off += 1;
        if (off + 18 > payload.len) return error.BadRowDesc;
        const oid = std.mem.readInt(u32, payload[off + 6 ..][0..4], .big);
        off += 18;
        job.fields[i] = .{ .name = try job.dupeZ(name), .oid = oid };
    }
    const ctx = g_ctx orelse return;
    if (c.isUndefined(job.rows_val) != 0) {
        job.rows_val = c.newArray(ctx);
    }
}

fn handleDataRow(conn: *Conn, payload: []const u8) !void {
    const job = conn.job orelse return;
    const ctx = g_ctx orelse return;
    if (payload.len < 2) return error.BadDataRow;
    const ncols = std.mem.readInt(u16, payload[0..2], .big);
    var off: usize = 2;
    const obj = c.newObject(ctx);
    var i: u16 = 0;
    while (i < ncols) : (i += 1) {
        if (off + 4 > payload.len) return error.BadDataRow;
        const flen = std.mem.readInt(i32, payload[off..][0..4], .big);
        off += 4;
        var text: ?[]const u8 = null;
        if (flen >= 0) {
            const fl: usize = @intCast(flen);
            if (off + fl > payload.len) return error.BadDataRow;
            text = payload[off .. off + fl];
            off += fl;
        }
        const idx: usize = i;
        if (idx >= job.fields.len) continue;
        const field = job.fields[idx];
        const val = textToJs(ctx, text, field.oid, job.allocator());
        _ = c.setPropertyStr(ctx, obj, field.name.ptr, val);
    }
    if (c.isUndefined(job.rows_val) != 0) job.rows_val = c.newArray(ctx);
    // Dense index write — setPropertyUint32 consumes obj.
    _ = c.setPropertyUint32(ctx, job.rows_val, @intCast(job.row_count), obj);
    job.row_count += 1;
}

fn handleErrorResponse(conn: *Conn, payload: []const u8) !void {
    const job = conn.job orelse return;
    const alloc = job.allocator();
    var severity: ?[]const u8 = null;
    var code: ?[]const u8 = null;
    var message: ?[]const u8 = null;
    var detail: ?[]const u8 = null;
    var off: usize = 0;
    while (off < payload.len and payload[off] != 0) {
        const ftype = payload[off];
        off += 1;
        const start = off;
        while (off < payload.len and payload[off] != 0) off += 1;
        const val = payload[start..off];
        if (off < payload.len) off += 1;
        switch (ftype) {
            'S' => severity = val,
            'V' => {},
            'C' => code = val,
            'M' => message = val,
            'D' => detail = val,
            else => {},
        }
    }
    job.has_error = true;
    if (severity) |s| job.err.severity = try alloc.dupe(u8, s);
    if (code) |s| job.err.code = try alloc.dupe(u8, s);
    if (message) |s| job.err.message = try alloc.dupe(u8, s);
    if (detail) |s| job.err.detail = try alloc.dupe(u8, s);
}

fn handleReady(conn: *Conn, l: *xev.Loop) void {
    switch (conn.state) {
        .auth => {
            conn.state = .ready;
            conn.auth_phase = .done;
            if (conn.job) |job| {
                if (job.in_startup) {
                    job.in_startup = false;
                    conn.state = .busy;
                    sendQuery(conn) catch {
                        failConn(conn, "failed to send query");
                        return;
                    };
                    return;
                }
            }
            const pool = conn.pool;
            if (pool.idle.append(gpa, conn)) |_| {
                if (conn.job == null) return;
            } else |_| {}
            if (conn.job) |job| {
                conn.job = null;
                settleResolve(job, c.newArray(g_ctx));
                return;
            }
        },
        .busy => {
            const job = conn.job;
            conn.job = null;
            if (job) |j| {
                switch (j.tx_op) {
                    .begin => settleBegin(j, conn),
                    .commit, .rollback => settleEnd(j, conn),
                    .none => {
                        settleJobDone(j);
                        if (conn.flags.in_tx) {
                            // Pinned tx conn: park, never the idle list.
                            conn.state = .ready;
                        } else {
                            conn.pool.release(conn);
                        }
                    },
                }
            } else if (conn.flags.in_tx) {
                conn.state = .ready;
            } else {
                conn.pool.release(conn);
            }
        },
        else => {},
    }
    _ = l;
}

/// BEGIN settled: pin the conn to a new Tx and resolve with the Tx JS object.
fn settleBegin(job: *Job, conn: *Conn) void {
    const pool = conn.pool;
    if (job.has_error) {
        settleJobDone(job);
        pool.release(conn);
        return;
    }
    const ctx = g_ctx orelse {
        _ = pending.fetchSub(1, .acq_rel);
        job.release();
        pool.release(conn);
        return;
    };
    const tx = gpa.create(Tx) catch {
        job.has_error = true;
        job.err = .{ .severity = "ERROR", .code = "53200", .message = "out of memory" };
        settleJobDone(job);
        pool.release(conn);
        return;
    };
    tx.* = .{ .pool = pool, .conn = conn };
    conn.tx = tx;
    conn.flags.in_tx = true;
    const mk = tx_factory orelse {
        conn.tx = null;
        conn.flags.in_tx = false;
        tx.conn = null;
        tx.active = false;
        gpa.destroy(tx);
        job.has_error = true;
        job.err = .{ .severity = "ERROR", .code = "XX000", .message = "tx factory missing" };
        settleJobDone(job);
        pool.release(conn);
        return;
    };
    const obj = mk(ctx, tx);
    if (c.isException(obj) != 0) {
        const exc = c.getException(ctx);
        c.freeValue(ctx, exc);
        conn.tx = null;
        conn.flags.in_tx = false;
        tx.conn = null;
        tx.active = false;
        gpa.destroy(tx);
        job.has_error = true;
        job.err = .{ .severity = "ERROR", .code = "XX000", .message = "failed to create transaction" };
        settleJobDone(job);
        pool.release(conn);
        return;
    }
    var args = [_]c.Value{obj};
    const ret = c.call(ctx, job.resolve, c.JS_UNDEFINED, 1, &args);
    c.freeValue(ctx, ret);
    c.freeValue(ctx, obj);
    _ = pending.fetchSub(1, .acq_rel);
    if (builtin.mode == .Debug) dumpStats();
    job.release();
    conn.state = .ready;
}

/// COMMIT/ROLLBACK settled: detach first (later JS calls may GC the Tx),
/// then resolve, then return the conn to the pool.
fn settleEnd(job: *Job, conn: *Conn) void {
    const pool = conn.pool;
    const tx = conn.tx;
    if (tx) |t| {
        t.conn = null;
        t.active = false;
    }
    conn.tx = null;
    conn.flags.in_tx = false;
    settleJobDone(job);
    pool.release(conn);
}

fn settleJobDone(job: *Job) void {
    const ctx = g_ctx orelse {
        _ = pending.fetchSub(1, .acq_rel);
        job.release();
        return;
    };
    if (job.has_error) {
        const err = makeError(
            ctx,
            job.err.severity,
            job.err.code,
            job.err.message,
            if (job.err.detail.len > 0) job.err.detail else null,
        );
        if (c.isUndefined(job.rows_val) == 0) {
            c.freeValue(ctx, job.rows_val);
            job.rows_val = c.JS_UNDEFINED;
        }
        if (c.isException(err) != 0) {
            const exc = c.getException(ctx);
            c.freeValue(ctx, exc);
            _ = pending.fetchSub(1, .acq_rel);
            if (builtin.mode == .Debug) dumpStats();
            job.release();
            return;
        }
        var args = [_]c.Value{err};
        const ret = c.call(ctx, job.reject, c.JS_UNDEFINED, 1, &args);
        c.freeValue(ctx, ret);
        c.freeValue(ctx, err);
        _ = pending.fetchSub(1, .acq_rel);
        if (builtin.mode == .Debug) dumpStats();
        job.release();
        return;
    }
    var rows = job.rows_val;
    job.rows_val = c.JS_UNDEFINED;
    if (c.isUndefined(rows) != 0) rows = c.newArray(ctx);
    var args = [_]c.Value{rows};
    const ret = c.call(ctx, job.resolve, c.JS_UNDEFINED, 1, &args);
    c.freeValue(ctx, ret);
    c.freeValue(ctx, rows);
    _ = pending.fetchSub(1, .acq_rel);
    if (builtin.mode == .Debug) dumpStats();
    job.release();
}

fn queueStartup(conn: *Conn) !void {
    const cfg = &conn.pool.config;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "user\x00");
    try buf.appendSlice(gpa, cfg.user);
    try buf.append(gpa, 0);
    try buf.appendSlice(gpa, "database\x00");
    try buf.appendSlice(gpa, cfg.database);
    try buf.append(gpa, 0);
    try buf.append(gpa, 0);
    const body_len: u32 = @intCast(buf.items.len + 8);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, body_len);
    var len_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_be, body_len, .big);
    try out.appendSlice(gpa, &len_be);
    var proto: [4]u8 = undefined;
    std.mem.writeInt(u32, &proto, 196608, .big);
    try out.appendSlice(gpa, &proto);
    try out.appendSlice(gpa, buf.items);
    try conn.wqueue.appendSlice(gpa, out.items);
}

fn queuePassword(conn: *Conn, scram_data: ?[]const u8) !void {
    const cfg = &conn.pool.config;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    switch (conn.auth_phase) {
        .need_cleartext => {
            try body.appendSlice(gpa, cfg.password);
            try body.append(gpa, 0);
        },
        .need_md5 => {
            var inner: [16]u8 = undefined;
            var md5 = std.crypto.hash.Md5.init(.{});
            md5.update(cfg.password);
            md5.update(cfg.user);
            md5.final(&inner);
            var inner_hex: [32]u8 = undefined;
            hexEncode(&inner_hex, &inner);
            var md5b = std.crypto.hash.Md5.init(.{});
            md5b.update(&inner_hex);
            md5b.update(&conn.md5_salt);
            var outer: [16]u8 = undefined;
            md5b.final(&outer);
            var outer_hex: [32]u8 = undefined;
            hexEncode(&outer_hex, &outer);
            try body.appendSlice(gpa, "md5");
            try body.appendSlice(gpa, &outer_hex);
            try body.append(gpa, 0);
        },
        .need_scram => {
            const data = scram_data orelse return error.BadScram;
            try body.appendSlice(gpa, data);
        },
        .scram_wait_server_first => {},
        else => return error.BadAuth,
    }
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);
    const body_len: u32 = @intCast(body.items.len + 4);
    var len_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_be, body_len, .big);
    try msg.append(gpa, 'p');
    try msg.appendSlice(gpa, &len_be);
    try msg.appendSlice(gpa, body.items);
    try conn.wqueue.appendSlice(gpa, msg.items);
}

fn beginScram(conn: *Conn, mechanisms: []const u8) !void {
    if (std.mem.indexOf(u8, mechanisms, "SCRAM-SHA-256") == null) return error.NoScram;
    const cfg = &conn.pool.config;
    var nonce_raw: [18]u8 = undefined;
    fillRandom(&nonce_raw);
    var nonce_b64_buf: [24]u8 = undefined;
    const nonce_b64 = std.base64.standard.Encoder.encode(&nonce_b64_buf, &nonce_raw);
    var bare: std.ArrayList(u8) = .empty;
    defer bare.deinit(gpa);
    try bare.appendSlice(gpa, "n=");
    try bare.appendSlice(gpa, cfg.user);
    try bare.appendSlice(gpa, ",r=");
    try bare.appendSlice(gpa, nonce_b64);
    const scram = try gpa.create(Scram);
    scram.* = .{ .client_first_bare = try bare.toOwnedSlice(gpa) };
    conn.scram = scram;
    var first: std.ArrayList(u8) = .empty;
    defer first.deinit(gpa);
    try first.appendSlice(gpa, "n,,");
    try first.appendSlice(gpa, scram.client_first_bare);
    const first_owned = try first.toOwnedSlice(gpa);
    defer gpa.free(first_owned);
    const mech = "SCRAM-SHA-256";
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);
    const body_len: u32 = @intCast(mech.len + 1 + 4 + first_owned.len + 4);
    var len_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_be, body_len, .big);
    var flen_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &flen_be, @intCast(first_owned.len), .big);
    try msg.append(gpa, 'p');
    try msg.appendSlice(gpa, &len_be);
    try msg.appendSlice(gpa, mech);
    try msg.append(gpa, 0);
    try msg.appendSlice(gpa, &flen_be);
    try msg.appendSlice(gpa, first_owned);
    try conn.wqueue.appendSlice(gpa, msg.items);
    conn.auth_phase = .scram_wait_server_first;
}

fn handleScramServerFirst(conn: *Conn, l: *xev.Loop, data: []const u8) !void {
    const scram = conn.scram orelse return error.NoScram;
    if (scram.server_first.len > 0) gpa.free(scram.server_first);
    scram.server_first = try gpa.dupe(u8, data);
    var it = std.mem.splitScalar(u8, data, ',');
    var nonce: ?[]const u8 = null;
    var salt_b64: ?[]const u8 = null;
    var iter_s: ?[]const u8 = null;
    while (it.next()) |part| {
        if (std.mem.startsWith(u8, part, "r=")) nonce = part[2..];
        if (std.mem.startsWith(u8, part, "s=")) salt_b64 = part[2..];
        if (std.mem.startsWith(u8, part, "i=")) iter_s = part[2..];
    }
    const n = nonce orelse return error.BadScram;
    const sb = salt_b64 orelse return error.BadScram;
    const is = iter_s orelse return error.BadScram;
    if (scram.combined_nonce.len > 0) gpa.free(scram.combined_nonce);
    scram.combined_nonce = try gpa.dupe(u8, n);
    var salt_dec: [64]u8 = undefined;
    const salt_len = std.base64.standard.Decoder.calcSizeForSlice(sb) catch return error.BadScram;
    if (salt_len > salt_dec.len) return error.BadScram;
    std.base64.standard.Decoder.decode(salt_dec[0..salt_len], sb) catch return error.BadScram;
    if (scram.salt.len > 0) gpa.free(scram.salt);
    scram.salt = try gpa.dupe(u8, salt_dec[0..salt_len]);
    scram.iterations = std.fmt.parseInt(u32, is, 10) catch return error.BadScram;

    const cfg = &conn.pool.config;
    var salted: [32]u8 = undefined;
    try std.crypto.pwhash.pbkdf2(&salted, cfg.password, scram.salt, scram.iterations, std.crypto.auth.hmac.sha2.HmacSha256);
    var client_key: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&client_key, "Client Key", &salted);
    std.crypto.hash.sha2.Sha256.hash(&client_key, &scram.stored_key, .{});

    var without_proof: std.ArrayList(u8) = .empty;
    defer without_proof.deinit(gpa);
    try without_proof.appendSlice(gpa, "c=biws,r=");
    try without_proof.appendSlice(gpa, scram.combined_nonce);

    var auth_msg: std.ArrayList(u8) = .empty;
    defer auth_msg.deinit(gpa);
    try auth_msg.appendSlice(gpa, scram.client_first_bare);
    try auth_msg.append(gpa, ',');
    try auth_msg.appendSlice(gpa, scram.server_first);
    try auth_msg.append(gpa, ',');
    try auth_msg.appendSlice(gpa, without_proof.items);
    if (scram.auth_message.len > 0) gpa.free(scram.auth_message);
    scram.auth_message = try auth_msg.toOwnedSlice(gpa);

    var client_sig: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&client_sig, scram.auth_message, &scram.stored_key);
    var proof: [32]u8 = undefined;
    for (&proof, 0..) |*b, i| b.* = client_key[i] ^ client_sig[i];
    var server_key: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&server_key, "Server Key", &salted);
    std.crypto.auth.hmac.sha2.HmacSha256.create(&scram.server_sig, scram.auth_message, &server_key);

    var final_msg: std.ArrayList(u8) = .empty;
    defer final_msg.deinit(gpa);
    try final_msg.appendSlice(gpa, without_proof.items);
    try final_msg.appendSlice(gpa, ",p=");
    var proof_b64_buf: [44]u8 = undefined;
    const proof_b64 = std.base64.standard.Encoder.encode(&proof_b64_buf, &proof);
    try final_msg.appendSlice(gpa, proof_b64);
    const final_owned = try final_msg.toOwnedSlice(gpa);
    defer gpa.free(final_owned);

    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);
    const body_len: u32 = @intCast(final_owned.len + 4);
    var len_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_be, body_len, .big);
    try msg.append(gpa, 'p');
    try msg.appendSlice(gpa, &len_be);
    try msg.appendSlice(gpa, final_owned);
    try conn.wqueue.appendSlice(gpa, msg.items);
    conn.auth_phase = .scram_wait_server_final;
    armWrite(conn, l);
}

fn handleScramServerFinal(conn: *Conn, data: []const u8) !void {
    if (std.mem.startsWith(u8, data, "e=")) return error.ScamError;
    if (!std.mem.startsWith(u8, data, "v=")) return error.BadScram;
    const sig_b64 = data[2..];
    var sig: [32]u8 = undefined;
    const sig_len = std.base64.standard.Decoder.calcSizeForSlice(sig_b64) catch return error.BadScram;
    if (sig_len != 32) return error.BadScram;
    std.base64.standard.Decoder.decode(sig[0..sig_len], sig_b64) catch return error.BadScram;
    const scram = conn.scram orelse return error.NoScram;
    if (!std.crypto.timing_safe.eql([32]u8, sig, scram.server_sig)) return error.ServerSigMismatch;
    conn.auth_phase = .done;
}

/// All extended-protocol frames → ONE wqueue region (TB §2 batch + TB §3 reuse).
fn sendQuery(conn: *Conn) !void {
    const job = conn.job orelse return error.NoJob;
    var need: usize = job.sql.len + 128 + job.param_oids.len * 4;
    for (job.params) |p| {
        if (p) |v| need += v.len + 8;
    }
    const cap_before = conn.wqueue.capacity;
    try conn.wqueue.ensureUnusedCapacity(gpa, need);
    if (conn.wqueue.capacity > cap_before) {
        _ = stat_wqueue_grow.fetchAdd(1, .monotonic);
    }
    try appendParse(&conn.wqueue, job.sql, job.param_oids);
    try appendBind(&conn.wqueue, job.params);
    try appendDescribe(&conn.wqueue);
    try appendExecute(&conn.wqueue);
    try appendSync(&conn.wqueue);
    const loop = g_loop orelse return error.NoLoop;
    armWrite(conn, loop);
}

fn appendCStr(buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.appendSlice(gpa, s);
    try buf.append(gpa, 0);
}

fn appendI32(buf: *std.ArrayList(u8), v: i32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(i32, &b, v, .big);
    try buf.appendSlice(gpa, &b);
}

fn appendI16(buf: *std.ArrayList(u8), v: i16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(i16, &b, v, .big);
    try buf.appendSlice(gpa, &b);
}

fn patchLen(buf: *std.ArrayList(u8), len_at: usize, body_at: usize) void {
    const body_len: u32 = @intCast(buf.items.len - body_at + 4);
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, body_len, .big);
    @memcpy(buf.items[len_at .. len_at + 4], &b);
}

fn appendParse(buf: *std.ArrayList(u8), query: []const u8, oids: []const u32) !void {
    try buf.append(gpa, 'P');
    const len_at = buf.items.len;
    try buf.appendSlice(gpa, &.{ 0, 0, 0, 0 });
    const body_at = buf.items.len;
    try appendCStr(buf, "");
    try appendCStr(buf, query);
    try appendI16(buf, @intCast(oids.len));
    for (oids) |oid| try appendI32(buf, @bitCast(oid));
    patchLen(buf, len_at, body_at);
}

fn appendBind(buf: *std.ArrayList(u8), params: []const ?[]const u8) !void {
    try buf.append(gpa, 'B');
    const len_at = buf.items.len;
    try buf.appendSlice(gpa, &.{ 0, 0, 0, 0 });
    const body_at = buf.items.len;
    try appendCStr(buf, "");
    try appendCStr(buf, "");
    try appendI16(buf, 0);
    try appendI16(buf, @intCast(params.len));
    for (params) |p| {
        if (p) |bytes| {
            try appendI32(buf, @intCast(bytes.len));
            try buf.appendSlice(gpa, bytes);
        } else {
            try appendI32(buf, -1);
        }
    }
    try appendI16(buf, 0);
    patchLen(buf, len_at, body_at);
}

fn appendDescribe(buf: *std.ArrayList(u8)) !void {
    try buf.append(gpa, 'D');
    try appendI32(buf, 6);
    try buf.append(gpa, 'P');
    try buf.append(gpa, 0);
}

fn appendExecute(buf: *std.ArrayList(u8)) !void {
    try buf.append(gpa, 'E');
    const len_at = buf.items.len;
    try buf.appendSlice(gpa, &.{ 0, 0, 0, 0 });
    const body_at = buf.items.len;
    try appendCStr(buf, "");
    try appendI32(buf, 0);
    patchLen(buf, len_at, body_at);
}

fn appendSync(buf: *std.ArrayList(u8)) !void {
    try buf.append(gpa, 'S');
    try appendI32(buf, 4);
}

fn hexEncode(out: []u8, data: []const u8) void {
    const digits = "0123456789abcdef";
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        out[i * 2] = digits[data[i] >> 4];
        out[i * 2 + 1] = digits[data[i] & 0xf];
    }
}

fn fillRandom(buf: []u8) void {
    switch (@import("builtin").os.tag) {
        .linux => {
            var off: usize = 0;
            while (off < buf.len) {
                const n = std.c.getrandom(buf.ptr + off, buf.len - off, 0);
                if (n < 0) {
                    if (std.posix.errno(n) == .INTR) continue;
                    std.Io.Threaded.global_single_threaded.io().random(buf[off..]);
                    return;
                }
                off += @intCast(n);
            }
        },
        else => {
            arc4random_buf(buf.ptr, buf.len);
        },
    }
}

fn resolveHost(host: []const u8, port: u16) !std.Io.net.IpAddress {
    if (std.Io.net.IpAddress.parse(host, port)) |ip| return ip else |_| {}
    var hints: std.c.addrinfo = std.mem.zeroes(std.c.addrinfo);
    hints.family = std.posix.AF.UNSPEC;
    hints.socktype = std.posix.SOCK.STREAM;
    hints.protocol = std.posix.IPPROTO.TCP;
    var port_buf: [8]u8 = undefined;
    const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{port});
    const port_z = try gpa.dupeZ(u8, port_str);
    defer gpa.free(port_z);
    const host_z = try gpa.dupeZ(u8, host);
    defer gpa.free(host_z);
    var res: ?*std.c.addrinfo = null;
    const eai = std.c.getaddrinfo(host_z.ptr, port_z.ptr, &hints, &res);
    if (@intFromEnum(eai) != 0) return error.DnsFailure;
    defer if (res) |r| std.c.freeaddrinfo(r);
    const info = res orelse return error.DnsFailure;
    const sa = info.addr orelse return error.DnsFailure;
    if (info.family == std.posix.AF.INET) {
        const sin: *const std.c.sockaddr.in = @ptrCast(@alignCast(sa));
        const bytes: [4]u8 = @bitCast(@byteSwap(sin.addr));
        return .{ .ip4 = .{ .bytes = bytes, .port = std.mem.bigToNative(u16, sin.port) } };
    }
    if (info.family == std.posix.AF.INET6) {
        const sin6: *const std.c.sockaddr.in6 = @ptrCast(@alignCast(sa));
        return .{ .ip6 = .{ .bytes = sin6.addr, .port = std.mem.bigToNative(u16, sin6.port) } };
    }
    return error.UnsupportedFamily;
}

pub fn textToJs(ctx: ?*c.Context, text: ?[]const u8, oid: u32, alloc: std.mem.Allocator) c.Value {
    if (text == null) return c.JS_NULL;
    const t = text.?;
    switch (oid) {
        16 => {
            if (t.len == 1 and (t[0] == 't' or t[0] == 'T')) return c.JS_TRUE;
            if (t.len == 1 and (t[0] == 'f' or t[0] == 'F')) return c.JS_FALSE;
            if (std.ascii.eqlIgnoreCase(t, "true")) return c.JS_TRUE;
            if (std.ascii.eqlIgnoreCase(t, "false")) return c.JS_FALSE;
            return c.JS_FALSE;
        },
        20, 21, 23 => {
            const n = std.fmt.parseInt(i64, t, 10) catch {
                return c.newStringLen(ctx, t.ptr, t.len);
            };
            const lim = @as(i64, 1) << 53;
            if (n >= -lim and n <= lim) return c.newInt64(ctx, n);
            if (oid == 20) return c.newBigInt64(ctx, n);
            return c.newStringLen(ctx, t.ptr, t.len);
        },
        700, 701 => {
            const f = std.fmt.parseFloat(f64, t) catch {
                return c.newStringLen(ctx, t.ptr, t.len);
            };
            return c.newFloat64(ctx, f);
        },
        17 => return decodeBytea(ctx, alloc, t),
        114, 3802 => {
            // JS_ParseJSON requires buf[len] == '\0' ("buf must be zero terminated"
            // in quickjs.c). t points into conn.rbuf where the byte after the value
            // is the next column's length prefix or the next message type ('C') —
            // never a guaranteed NUL. Non-last columns only parsed by luck (a 0x00
            // length-prefix byte). Copy to a NUL-terminated job-arena buffer;
            // OOM → raw string. Also avoids a one-past-end read when the value
            // sits at the exact end of the buffered bytes.
            const buf = alloc.alloc(u8, t.len + 1) catch {
                return c.newStringLen(ctx, t.ptr, t.len);
            };
            @memcpy(buf[0..t.len], t);
            buf[t.len] = 0;
            const v = c.parseJSON(ctx, buf.ptr, t.len, "");
            if (c.isException(v) != 0) {
                const exc = c.getException(ctx);
                c.freeValue(ctx, exc);
                return c.newStringLen(ctx, t.ptr, t.len);
            }
            return v;
        },
        else => {
            if (arrayElemOid(oid)) |elem| return parsePgArray(ctx, alloc, t, elem);
            return c.newStringLen(ctx, t.ptr, t.len);
        },
    }
}

/// Array OID → element OID. Unknown (incl. non-arrays) → null.
fn arrayElemOid(oid: u32) ?u32 {
    return switch (oid) {
        1000 => 16, // _bool
        1001 => 17, // _bytea
        1005 => 21, // _int2
        1007 => 23, // _int4
        1009 => 25, // _text
        1014 => 25, // _bpchar
        1015 => 25, // _varchar
        1016 => 20, // _int8
        1021 => 700, // _float4
        1022 => 701, // _float8
        1028 => 20, // _oid (fits i64)
        1231 => 25, // _numeric → string (no precision loss)
        199 => 114, // _json
        3807 => 3802, // _jsonb
        else => null,
    };
}

fn parsePgArray(ctx: ?*c.Context, alloc: std.mem.Allocator, text: []const u8, elem_oid: u32) c.Value {
    var pos: usize = 0;
    return parseArrayInner(ctx, alloc, text, &pos, elem_oid, 0);
}

/// Recursive PG array-literal parser. Malformed input → whole text as string
/// (never an exception value, never partial garbage).
fn parseArrayInner(
    ctx: ?*c.Context,
    alloc: std.mem.Allocator,
    s: []const u8,
    pos: *usize,
    elem_oid: u32,
    depth: u8,
) c.Value {
    if (depth > 8 or pos.* >= s.len or s[pos.*] != '{') {
        return c.newStringLen(ctx, s.ptr, s.len);
    }
    pos.* += 1;
    const arr = c.newArray(ctx);
    if (c.isException(arr) != 0) return arr;
    var idx: u32 = 0;
    while (true) {
        while (pos.* < s.len and s[pos.*] == ' ') pos.* += 1;
        if (pos.* >= s.len) {
            c.freeValue(ctx, arr);
            return c.newStringLen(ctx, s.ptr, s.len);
        }
        if (s[pos.*] == '}') {
            pos.* += 1;
            break;
        }
        var elem: c.Value = undefined;
        if (s[pos.*] == '{') {
            elem = parseArrayInner(ctx, alloc, s, pos, elem_oid, depth + 1);
        } else if (s[pos.*] == '"') {
            pos.* += 1;
            var buf: std.ArrayList(u8) = .empty;
            var closed = false;
            while (pos.* < s.len) {
                const ch = s[pos.*];
                if (ch == '\\' and pos.* + 1 < s.len) {
                    buf.append(alloc, s[pos.* + 1]) catch {
                        c.freeValue(ctx, arr);
                        return c.newStringLen(ctx, s.ptr, s.len);
                    };
                    pos.* += 2;
                    continue;
                }
                if (ch == '"') {
                    pos.* += 1;
                    closed = true;
                    break;
                }
                buf.append(alloc, ch) catch {
                    c.freeValue(ctx, arr);
                    return c.newStringLen(ctx, s.ptr, s.len);
                };
                pos.* += 1;
            }
            if (!closed) {
                c.freeValue(ctx, arr);
                return c.newStringLen(ctx, s.ptr, s.len);
            }
            elem = textToJs(ctx, buf.items, elem_oid, alloc);
        } else {
            const start = pos.*;
            while (pos.* < s.len and s[pos.*] != ',' and s[pos.*] != '}') pos.* += 1;
            var tok = s[start..pos.*];
            while (tok.len > 0 and tok[tok.len - 1] == ' ') tok = tok[0 .. tok.len - 1];
            if (std.ascii.eqlIgnoreCase(tok, "NULL")) {
                elem = c.JS_NULL;
            } else {
                elem = textToJs(ctx, tok, elem_oid, alloc);
            }
        }
        // setPropertyUint32 consumes elem.
        _ = c.setPropertyUint32(ctx, arr, idx, elem);
        idx += 1;
        while (pos.* < s.len and s[pos.*] == ' ') pos.* += 1;
        if (pos.* < s.len and s[pos.*] == ',') {
            pos.* += 1;
            continue;
        }
    }
    return arr;
}

fn decodeBytea(ctx: ?*c.Context, alloc: std.mem.Allocator, text: []const u8) c.Value {
    var hex = text;
    if (std.mem.startsWith(u8, hex, "\\x")) hex = hex[2..];
    if (hex.len % 2 != 0) return c.newStringLen(ctx, text.ptr, text.len);
    const nbytes = hex.len / 2;
    // Job arena (hot) — no gpa; freed with arena on Job.release.
    const out = alloc.alloc(u8, nbytes) catch return c.throwOutOfMemory(ctx);
    var i: usize = 0;
    while (i < nbytes) : (i += 1) {
        const hi = std.fmt.charToDigit(hex[i * 2], 16) catch {
            return c.newStringLen(ctx, text.ptr, text.len);
        };
        const lo = std.fmt.charToDigit(hex[i * 2 + 1], 16) catch {
            return c.newStringLen(ctx, text.ptr, text.len);
        };
        out[i] = (hi << 4) | lo;
    }
    const ab = c.newArrayBufferCopy(ctx, out.ptr, out.len);
    if (c.getTag(ab) == c.TAG_EXCEPTION) return ab;
    var free_ab = true;
    defer if (free_ab) c.freeValue(ctx, ab);
    var argv = [_]c.Value{
        ab,
        c.newInt32(ctx, 0),
        c.newInt32(ctx, @intCast(out.len)),
    };
    const view = c.newTypedArray(ctx, 3, &argv, c.JS_TYPED_ARRAY_UINT8);
    free_ab = false;
    c.freeValue(ctx, ab);
    return view;
}
