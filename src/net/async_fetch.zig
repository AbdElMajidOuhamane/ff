
const std = @import("std");
const xev = @import("xev");
const c = @import("../c.zig").c;
const tls = @import("./tls.zig");
const response_mod = @import("../types/response.zig");
const headers_mod = @import("../types/headers.zig");
const builtin = @import("builtin");
const microtasks = @import("../event/microtasks.zig");

var job_counter: counting.CountingAllocator = .{ .base = std.heap.smp_allocator };
const gpa = if (builtin.mode == .Debug)
    job_counter.allocator()
else
    std.heap.smp_allocator;

const counting = @import("../util/counting_allocator.zig");
const http = std.http;

pub const MAX_FETCH = 16;

const JOB_FREE: u8 = 0;
const JOB_BUSY: u8 = 1;
const JOB_DONE: u8 = 2;
const JOB_CLAIMED: u8 = 3;


// Event-loop drain touches only `states` + `pending` + ring indices (hot).
// Payload columns are cold per-job data, never scanned in drains.
// C1 (+ FIX-4): the ResponseData wrapper comes from a freelist and request
// URL/body submit is zero-alloc (static staging, spills only, measured via
// stat_*); the per-fetch heap traffic that remains is the body copy into
// ResponseData.pool + size-triggered spills below.
// Scalar doneMask (not @Vector) is intentional: 16 slots fit one u64 mask
// via inline unrolled scan; ws_client uses @Vector for 64 slots. // ◀ FIX-4 (comment only)

// Hot path touches only `states` + `pending` + ring indices.
// Payload columns below are cold per-job data, never scanned in drains.
var states: [MAX_FETCH]std.atomic.Value(u8) = [_]std.atomic.Value(u8){.{ .raw = JOB_FREE }} ** MAX_FETCH;
var resolve_funcs: [MAX_FETCH]?c.Value = [_]?c.Value{null} ** MAX_FETCH;
var reject_funcs: [MAX_FETCH]?c.Value = [_]?c.Value{null} ** MAX_FETCH;
var results: [MAX_FETCH]?*response_mod.ResponseData = [_]?*response_mod.ResponseData{null} ** MAX_FETCH;
var errs: [MAX_FETCH]?[]const u8 = [_]?[]const u8{null} ** MAX_FETCH;
// Optional so freeOwned is idempotent (null after free → safe re-entry).
var url_bufs: [MAX_FETCH]?[:0]const u8 = [_]?[:0]const u8{null} ** MAX_FETCH;
var uris: [MAX_FETCH]std.Uri = undefined;
var methods: [MAX_FETCH]http.Method = undefined;
var headers: [MAX_FETCH]?*headers_mod.HeadersData = [_]?*headers_mod.HeadersData{null} ** MAX_FETCH;
var bodies: [MAX_FETCH]?[:0]const u8 = [_]?[:0]const u8{null} ** MAX_FETCH;
var redirect_url_bufs: [MAX_FETCH][2048]u8 = undefined;
// C1 FIX: per-slot static URL staging — replaces the per-fetch gpa.dupeZ
// in fetch.zig. Heap spill only for >2048 URLs (flagged in url_owned).
var url_stage_bufs: [MAX_FETCH][2048:0]u8 = undefined;
var url_owned: [MAX_FETCH]bool = [_]bool{false} ** MAX_FETCH;
// FIX-4: request bodies are staged exactly like URLs (borrowed at submit,
// NUL-terminated into body_stage_bufs; heap spill only for >64K, flagged
// in body_owned). Sharing body_stage_bufs with the RESPONSE path is safe:
// runJob writes the request body to the socket before any response bytes
// land in the buffer, and redirect hops re-send before accumulating — the
// staged request is never live when response staging starts. // ◀ FIX-4
var body_owned: [MAX_FETCH]bool = [_]bool{false} ** MAX_FETCH; // ◀ FIX-4
// DOD-FIX TigerBeetle §3: reusable per-slot buffers — no per-fetch alloc
// for the common case. Heap is spill only (measured via stat_* below).
var body_stage_bufs: [MAX_FETCH][64 * 1024]u8 = undefined;
var flate_window_bufs: [MAX_FETCH][32 * 1024]u8 = undefined;
// Measurement for batch/spill tuning (see Verification section of skill).
pub var stat_hdr_spill: std.atomic.Value(u64) = .{ .raw = 0 };
pub var stat_body_heap: std.atomic.Value(u64) = .{ .raw = 0 };
pub var stat_decompress_heap: std.atomic.Value(u64) = .{ .raw = 0 };

comptime {
    std.debug.assert(@sizeOf(@TypeOf(states)) == MAX_FETCH * @sizeOf(std.atomic.Value(u8)));
    std.debug.assert(@alignOf(@TypeOf(states)) >= 1);
}

var free_list: [MAX_FETCH]u16 = undefined;
var free_count: usize = MAX_FETCH;
var pool_lock: std.atomic.Mutex = .unlocked;

const RING_CAP = MAX_FETCH;
var job_ring: [RING_CAP]u16 = undefined;
var ring_head: usize = 0;
var ring_tail: usize = 0;
var ring_lock: std.atomic.Mutex = .unlocked;
var shutdown_requested = false;
var pool_started = false;
var worker_threads: [MAX_FETCH]?std.Thread = [_]?std.Thread{null} ** MAX_FETCH;
var job_pipe: [2]std.posix.fd_t = .{ -1, -1 };

const AsyncT = xev.Async;
var async_h: AsyncT = undefined;
var async_comp: xev.Completion = .{};
var async_armed = false;
var g_ctx: ?*c.Context = null;
var g_loop: ?*xev.Loop = null;

pub var pending: std.atomic.Value(u64) = .{ .raw = 0 };

fn poolLock() void {
    while (!pool_lock.tryLock()) std.atomic.spinLoopHint();
}
fn poolUnlock() void { pool_lock.unlock(); }
fn ringLock() void { while (!ring_lock.tryLock()) std.atomic.spinLoopHint(); }
fn ringUnlock() void { ring_lock.unlock(); }

fn poolInit() void {
    for (0..MAX_FETCH) |i| free_list[i] = @intCast(MAX_FETCH - 1 - i);
    free_count = MAX_FETCH;
}
fn acquireSlot() ?usize {
    if (free_count == 0) return null;
    free_count -= 1;
    const s: usize = free_list[free_count];
    states[s].store(JOB_BUSY, .release);
    return s;
}
fn releaseSlot(s: usize) void {
    states[s].store(JOB_FREE, .release);
    url_bufs[s] = null;
    url_owned[s] = false;
    uris[s] = undefined;
    methods[s] = undefined;
    headers[s] = null;
    bodies[s] = null;
    body_owned[s] = false; // ◀ FIX-4
    freeResolvers(s);
    results[s] = null;
    errs[s] = null;
    free_list[free_count] = @intCast(s);
    free_count += 1;
}
fn freeResolvers(s: usize) void {
    if (g_ctx) |ctx| {
        if (resolve_funcs[s]) |v| { c.freeValue(ctx, v); resolve_funcs[s] = null; }
        if (reject_funcs[s]) |v| { c.freeValue(ctx, v); reject_funcs[s] = null; }
    } else {
        resolve_funcs[s]=null;
        reject_funcs[s]=null;
    }
}
fn makeJobPipe() !void {
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeCreateFailed;
    job_pipe = fds;
}
fn wakeAllWorkers() void {
    if (job_pipe[1] < 0) return;
    var b: [MAX_FETCH]u8 = [_]u8{1} ** MAX_FETCH;
    _ = std.c.write(job_pipe[1], &b, b.len);
}
pub fn init(ctx: ?*c.Context) void {
    g_ctx = ctx;
    poolInit();
    async_h = AsyncT.init() catch unreachable;
    async_armed = false;
    ring_head = 0;
    ring_tail = 0;
    shutdown_requested = false;
    makeJobPipe() catch { async_h.deinit(); return; };
    for (&worker_threads) |*t| {
        t.* = std.Thread.spawn(.{ .stack_size = 1024*1024 }, workerLoop, .{}) catch { t.*=null; break; };
    }
    pool_started = true;
}
pub fn deinit() void {
    if (pool_started) {
        ringLock(); shutdown_requested=true; ringUnlock();
        wakeAllWorkers();
        for (&worker_threads) |*t| { if (t.*) |*tt| { tt.join(); t.*=null; } }
        pool_started=false;
    }
    if (job_pipe[0]>=0) _=std.c.close(job_pipe[0]);
    if (job_pipe[1]>=0) _=std.c.close(job_pipe[1]);
    job_pipe=.{-1,-1};
    async_h.deinit();
    for (0..MAX_FETCH) |s| {
        // BUG-5 FIX: a slot retired while JOB_DONE/JOB_CLAIMED still holds a
        // heap ResponseData that no JS object ever wrapped — release it, else
        // the wrapper + its body buffer leak at shutdown.
        if (states[s].load(.acquire)!=JOB_FREE) { freeResolvers(s); freeOwned(s); freeResult(s); }
    }
}
fn freeOwned(s: usize) void {
    // C1 FIX: url_bufs[s] is usually a view into url_stage_bufs[s] (no free);
    // only the >2048 heap spill is owned (url_owned flag).
    // FIX-4: bodies work the same — usually a view into body_stage_bufs[s]
    // (staged synchronously at submit); only the >64K heap spill is owned
    // (body_owned flag). (Supersedes the BUG-7 "unconditional by design"
    // note for URLs and bodies.) // ◀ FIX-4
    if (url_owned[s]) {
        if (url_bufs[s]) |u| gpa.free(u);
        url_owned[s] = false;
    }
    url_bufs[s] = null;
    if (headers[s]) |h| h.release();
    headers[s] = null;
    if (body_owned[s]) { // ◀ FIX-4
        if (bodies[s]) |b| gpa.free(b); // ◀ FIX-4
        body_owned[s] = false; // ◀ FIX-4
    } // ◀ FIX-4
    bodies[s] = null;
}
fn freeResult(s: usize) void {
    // C1 FIX: return the shell to the ResponseData freelist (was deinit +
    // destroy per fetch). Mirrors responseFinalizer semantics.
    if (results[s]) |data| {
        response_mod.releaseData(data);
        results[s] = null;
    }
}
fn workerLoop() void {
    while (true) {
        var wake: [1]u8=undefined;
        const n = std.c.read(job_pipe[0], &wake, 1);
        if (n<=0) return;
        var got: ?u16=null;
        ringLock();
        if (ring_head != ring_tail) { got=job_ring[ring_head % RING_CAP]; ring_head+%=1; }
        const stop = shutdown_requested and ring_head==ring_tail;
        ringUnlock();
        if (got) |slot_id| runJob(slot_id);
        if (stop) return;
    }
}
pub fn submit(
    ctx: ?*c.Context,
    resolve_func: c.Value,
    reject_func: c.Value,
    url: []const u8,
    uri: std.Uri,
    method: http.Method,
    headers_ptr: *headers_mod.HeadersData,
    body: ?[]const u8, // ◀ FIX-4: BORROWED (was caller-owned heap [:0])
) !void {
    poolLock(); defer poolUnlock();
    const s = acquireSlot() orelse {
        if (builtin.mode==.Debug) std.debug.print("[submit] rejected: pool full\n", .{});
        // C1 FIX (+ FIX-4): url and body are BORROWED now (staged below) —
        // nothing to free. // ◀ FIX-4
        headers_ptr.release();
        return error.NoConnectionAvailable;
    };
    // C1 FIX: stage the borrowed URL into the per-slot static buffer.
    // Heap spill only for >2048 URLs. Replaces fetch.zig's gpa.dupeZ.
    if (url.len < url_stage_bufs[s].len) {
        @memcpy(url_stage_bufs[s][0..url.len], url);
        url_stage_bufs[s][url.len] = 0;
        url_bufs[s] = url_stage_bufs[s][0..url.len :0];
        url_owned[s] = false;
    } else {
        url_bufs[s] = gpa.dupeZ(u8, url) catch {
            headers_ptr.release();
            releaseSlot(s);
            return error.NoConnectionAvailable;
        };
        url_owned[s] = true;
    }
    // FIX-4: stage the borrowed body the same way. NUL-terminate so
    // bodies[s] keeps its [:0] type; strict < leaves room for the sentinel.
    // Replaces fetch.zig's per-fetch gpa.dupeZ. Heap spill only for >64K
    // bodies (measured via stat_body_heap, freed in freeOwned). // ◀ FIX-4
    if (body) |bb| { // ◀ FIX-4
        if (bb.len < body_stage_bufs[s].len) { // ◀ FIX-4
            @memcpy(body_stage_bufs[s][0..bb.len], bb); // ◀ FIX-4
            body_stage_bufs[s][bb.len] = 0; // ◀ FIX-4
            bodies[s] = body_stage_bufs[s][0..bb.len :0]; // ◀ FIX-4
            body_owned[s] = false; // ◀ FIX-4
        } else { // ◀ FIX-4
            _ = stat_body_heap.fetchAdd(1, .release); // ◀ FIX-4
            bodies[s] = gpa.dupeZ(u8, bb) catch { // ◀ FIX-4
                headers_ptr.release(); // ◀ FIX-4
                freeOwned(s); // frees a staged URL spill; headers[s] still null // ◀ FIX-4
                releaseSlot(s); // ◀ FIX-4
                return error.NoConnectionAvailable; // ◀ FIX-4
            }; // ◀ FIX-4
            body_owned[s] = true; // ◀ FIX-4
        } // ◀ FIX-4
    } else { // ◀ FIX-4
        bodies[s] = null; // ◀ FIX-4
        body_owned[s] = false; // ◀ FIX-4
    } // ◀ FIX-4
    uris[s]=uri; methods[s]=method; headers[s]=headers_ptr;
    results[s]=null; errs[s]=null;
    resolve_funcs[s]=c.dupValue(ctx, resolve_func);
    reject_funcs[s]=c.dupValue(ctx, reject_func);
    _ = pending.fetchAdd(1, .acq_rel);
    ringLock();
    if (shutdown_requested) {
        ringUnlock();
        _ = pending.fetchSub(1, .acq_rel);
        freeResolvers(s); freeOwned(s); releaseSlot(s);
        return error.NoConnectionAvailable;
    }
    job_ring[ring_tail % RING_CAP]=@intCast(s);
    ring_tail+%=1;
    ringUnlock();
    _ = std.c.write(job_pipe[1], &[_]u8{1}, 1);
    ensureArmed();
}
fn resolveRedirectInto(out: []u8, current_url: []const u8, loc: []const u8) ?[]const u8 {
    const scheme_sep = std.mem.indexOf(u8, current_url, "://") orelse return null;
    const auth_start = scheme_sep+3;
    const auth_end = std.mem.indexOfScalarPos(u8, current_url, auth_start, '/') orelse current_url.len;
    if (std.mem.startsWith(u8, loc, "http://") or std.mem.startsWith(u8, loc, "https://")) {
        if (loc.len>out.len) return null;
        @memcpy(out[0..loc.len], loc); return out[0..loc.len];
    }
    if (std.mem.startsWith(u8, loc, "//")) {
        const n = scheme_sep+1;
        if (n+loc.len>out.len) return null;
        @memcpy(out[n..][0..loc.len], loc); return out[0..n+loc.len];
    }
    if (loc.len>0 and loc[0]=='/') {
        if (auth_end+loc.len>out.len) return null;
        @memcpy(out[0..auth_end], current_url[0..auth_end]);
        @memcpy(out[auth_end..][0..loc.len], loc);
        return out[0..auth_end+loc.len];
    }
    const path = current_url[auth_end..];
    const q = std.mem.indexOfScalar(u8, path, '?') orelse path.len;
    const dir_end = std.mem.lastIndexOfScalar(u8, path[0..q], '/') orelse 0;
    if (auth_end+dir_end+1+loc.len>out.len) return null;
    var n: usize=0;
    @memcpy(out[0..auth_end], current_url[0..auth_end]); n=auth_start;
    @memcpy(out[n..][0..dir_end+1], path[0..dir_end+1]); n+=dir_end+1;
    @memcpy(out[n..][0..loc.len], loc);
    return out[0..n];
}
fn runJob(slot_id: u16) void {
    const s: usize=slot_id;
    if (builtin.mode==.Debug) job_counter.reset();
    const n_headers = headers[s].?.len();
    // Fast path: stack buffer, zero heap alloc for typical header counts.
    // Spill (>64) is measured — tune 64 via stat_hdr_spill + bench.
    var http_hdrs_buf: [64]http.Header=undefined;
    var http_hdrs: []http.Header=&[_]http.Header{};
    var hdr_view: std.ArrayList(http.Header)=.empty;
    var use_heap = false;
    defer if (use_heap) hdr_view.deinit(gpa);
    if (n_headers <= http_hdrs_buf.len) {
        for (0..n_headers) |i| { const p=headers[s].?.getPair(i); http_hdrs_buf[i]=.{.name=p.name,.value=p.value}; }
        http_hdrs=http_hdrs_buf[0..n_headers];
    } else {
        _ = stat_hdr_spill.fetchAdd(1, .release);
        use_heap = true;
        hdr_view.ensureTotalCapacity(gpa, n_headers) catch { failSlot(s,"Out of memory"); return; };
        for (0..n_headers) |i| { const p=headers[s].?.getPair(i); hdr_view.append(gpa,.{.name=p.name,.value=p.value}) catch {failSlot(s,"Out of memory"); return;}; }
        http_hdrs=hdr_view.items;
    }
    var current_method = methods[s];
    var current_url: []const u8 = url_bufs[s] orelse "";
    var current_body: ?[:0]const u8 = bodies[s];
    var redirect_count: u32=0;
    var redirected=false;
    var loc_buf: [4096]u8=undefined;
    var owned_body: ?[]u8=null;
    // owned_body points either at body_stage_bufs[s] staging (no free) or a
    // heap spill (must free). Track with a flag so lifetime is explicit.
    var owned_heap = false;
    defer {
        if (owned_heap) {
            if (owned_body) |b| gpa.free(b);
            }
        }
    hop: while (true) {
        const current_uri = std.Uri.parse(current_url) catch { failSlot(s,"Invalid URL"); return; };
        var req = tls.client().request(current_method, current_uri, .{.extra_headers=http_hdrs}) catch |err| {
            std.debug.print("[fetch] request failed: {s} url={s}\n", .{ @errorName(err), current_url });
            failSlot(s, "Network error");
            return;
        };
        req.redirect_behavior=.unhandled;
        defer req.deinit();
        var slot: ?usize=null;
        if (req.connection) |cn| slot=tls.attach(cn);
        defer if (slot) |sl| tls.detach(sl);
        if (current_body) |payload| {
            req.transfer_encoding=.{.content_length=payload.len};
            var body_writer = req.sendBodyUnflushed(&.{}) catch { failSlot(s,"Failed to send request body"); return; };
            body_writer.writer.writeAll(payload) catch { failSlot(s,"Failed to write request body"); return; };
            body_writer.end() catch {};
            req.connection.?.flush() catch {};
        } else {
            req.sendBodiless() catch { failSlot(s,"Failed to send request"); return; };
        }
        var redirect_buf: [8000]u8=undefined;
        var response = req.receiveHead(&redirect_buf) catch { failSlot(s,"Failed to receive response"); return; };
        const status_code = @intFromEnum(response.head.status);
        var location: ?[]const u8=null;
        if (status_code/100==3) {
            var header_it=response.head.iterateHeaders();
            while (header_it.next()) |h| { if (std.ascii.eqlIgnoreCase(h.name,"location")) {location=h.value; break;}}
        }
        if (status_code/100==3 and location!=null) {
            if (redirect_count>=5) { failSlot(s,"Too many redirects"); return; }
            redirect_count+=1; redirected=true;
            const loc=location.?;
            if (loc.len==0 or loc.len>loc_buf.len) { failSlot(s,"Invalid redirect location"); return; }
            const new_url=resolveRedirectInto(&loc_buf, current_url, loc) orelse { failSlot(s,"Invalid redirect location"); return; };
            if (new_url.len > redirect_url_bufs[s].len) { failSlot(s,"Invalid redirect location"); return; }
            @memcpy(redirect_url_bufs[s][0..new_url.len], new_url);
            current_url=redirect_url_bufs[s][0..new_url.len];
            const code=status_code;
            if (code==303 or ((code==301 or code==302) and current_method==.POST)) { current_method=.GET; current_body=null; }
            else if (code!=307 and code!=308) { current_body=null; }
            continue :hop;
        }
        const status_class=status_code/100;
        const has_body = switch(status_class){1=>false,2=>response.head.status!=.no_content and response.head.status!=.not_modified,3=>false,else=>true,};
        if (!has_body) { req.connection.?.closing=true; }
        // C1 FIX: pooled ResponseData shell (was one gpa.create per fetch).
        const resp_data = response_mod.acquire() orelse { failSlot(s,"Out of memory"); return; };
        // F1: take ownership of the slot's parsed headers directly — no
        // create+release of a throwaway HeadersData per fetch.
        resp_data.* = response_mod.ResponseData.initWithHeaders(headers[s].?);
        headers[s]=null;
        // BUG-2 FIX: the adopted container still holds the REQUEST headers
        // from fetch.zig's in_flight pool. Reset it in place BEFORE the
        // response headers are appended below, otherwise res.headers still
        // exposes the request's x-api-key and every other request header.
        // clearRetainingCapacity preserves the reserved byte pools, so the
        // append stays zero-alloc — the F1 "one HeadersData + one growth per
        // fetch" invariant is untouched (DOD / TigerBeetle §1).
        // Safe: http_hdrs was consumed by sendBodiless/sendBody at :304/:309,
        // and std.http.Client.Request.deinit (client.zig:890) only touches
        // the connection then does `r.* = undefined` — never extra_headers.
        resp_data.headers.clear();
        resp_data.status=status_code;
        // C1 FIX: single pool growth for status_text + url (was: one growth
        // per storeString). Body reserves separately below (size known later).
        const phrase = response.head.status.phrase() orelse "OK";
        resp_data.pool.ensureTotalCapacity(gpa, phrase.len + current_url.len + 64) catch {};
        resp_data.setStatusText(phrase);
        resp_data.redirected=redirected;
        resp_data.setUrl(current_url);
        // Batch reserve: single growth for response headers.
        {
            var hn: usize = 0;
            var header_it=response.head.iterateHeaders();
            while (header_it.next()) |_| hn += 1;
            if (hn > 0) resp_data.headers.reserveEntries(hn);
            var header_it2=response.head.iterateHeaders();
            while (header_it2.next()) |h| { resp_data.headers.appendEntry(h.name,h.value); }
        }
        if (has_body) {
            var transfer_buf: [8192]u8=undefined;
            const content_encoding=response.head.content_encoding;
            const compressed=content_encoding!=.identity;
            var decompress_buf: ?[]u8=null;
            var decompress_heap = false;
            defer {
                   if (decompress_heap) {
                    if (decompress_buf) |d| gpa.free(d);
                    }
                }
            var decompress: std.http.Decompress=undefined;
            const reader = if (!compressed) response.reader(&transfer_buf) else dec:{
                const window_len: usize = switch(content_encoding){.gzip,.deflate=>std.compress.flate.max_window_len,.zstd=>std.compress.zstd.default_window_len,else=>0,};
                if (window_len==0) { std.debug.print("[fetch] unsupported content-encoding: {s}\n", .{@tagName(content_encoding)}); break :dec response.reader(&transfer_buf); }
                // Reuse per-slot flate window (32K); heap spill only for zstd/large.
                if (window_len <= flate_window_bufs[s].len) {
                    decompress_buf=flate_window_bufs[s][0..window_len];
                    break :dec response.readerDecompressing(&transfer_buf, &decompress, decompress_buf.?);
                }
                _ = stat_decompress_heap.fetchAdd(1, .release);
                const d=gpa.alloc(u8,window_len) catch break :dec response.reader(&transfer_buf);
                decompress_buf=d; decompress_heap=true;
                break :dec response.readerDecompressing(&transfer_buf, &decompress, d);
            };
            var body_incomplete=false;
            const wire_cl = if (content_encoding==.identity) response.head.content_length else null;
            if (wire_cl) |cl| {
                if (cl>0) {
                    const len: usize=@intCast(cl);
                    // Reuse 64K stage buffer; heap spill measured via stat_body_heap.
                    if (len <= body_stage_bufs[s].len) {
                        const b = body_stage_bufs[s][0..len];
                        const n=reader.readSliceShort(b) catch |err| read_b:{ std.debug.print("[fetch] body read error: {s}\n", .{@errorName(err)}); break :read_b 0; };
                        if (n==0){ body_incomplete=true; }
                        else if (n==len){ owned_body=b; owned_heap=false; }
                        else {
                            const hb=gpa.alloc(u8,n) catch null;
                            if (hb) |h| { @memcpy(h, b[0..n]); owned_body=h; owned_heap=true; }
                            else body_incomplete=true;
                            _ = stat_body_heap.fetchAdd(1, .release);
                        }
                    } else {
                        _ = stat_body_heap.fetchAdd(1, .release);
                        const buf=gpa.alloc(u8,len) catch |err| alloc_b:{ std.debug.print("[fetch] body alloc error: {s}\n", .{@errorName(err)}); break :alloc_b null; };
                        if (buf) |b| {
                            const n=reader.readSliceShort(b) catch |err| read_b:{ std.debug.print("[fetch] body read error: {s}\n", .{@errorName(err)}); break :read_b 0; };
                            if (n==0){ gpa.free(b); body_incomplete=true; }
                            else if (n==len){ owned_body=b; owned_heap=true; }
                            else{
                                const shrunk=gpa.realloc(b,n) catch null;
                                if (shrunk) |sh| { owned_body=sh; owned_heap=true; }
                                else { gpa.free(b); body_incomplete=true; }
                            }
                        }
                    }
                }
            } else {
                // Unknown length: fill stage buffer first, spill to heap only if needed.
                var chunk: [16*1024]u8=undefined;
                var total: usize=0;
                var heap_acc: std.ArrayList(u8)=.empty;
                var heap_used = false;
                defer if (heap_used) heap_acc.deinit(gpa);
                while (true) {
                    const n=reader.readSliceShort(chunk[0..]) catch |err| acc_b:{ std.debug.print("[fetch] body read error: {s} after {d} bytes\n", .{@errorName(err), total}); break :acc_b 0; };
                    if (n==0) break;
                    if (!heap_used and total + n <= body_stage_bufs[s].len) {
                        @memcpy(body_stage_bufs[s][total..][0..n], chunk[0..n]);
                        total+=n;
                    } else {
                        if (!heap_used) {
                            _ = stat_body_heap.fetchAdd(1, .release);
                            heap_acc.ensureTotalCapacity(gpa,64*1024) catch {};
                            heap_acc.appendSlice(gpa, body_stage_bufs[s][0..total]) catch |err|{ std.debug.print("[fetch] body accumulate error: {s}\n", .{@errorName(err)}); break; };
                            heap_used=true;
                        }
                        heap_acc.appendSlice(gpa,chunk[0..n]) catch |err|{ std.debug.print("[fetch] body accumulate error: {s}\n", .{@errorName(err)}); break; };
                        total+=n;
                    }
                }
                if (total>0){
                    if (heap_used){ owned_body=heap_acc.toOwnedSlice(gpa) catch |err| fin_b:{ std.debug.print("[fetch] body finalize error: {s}\n", .{@errorName(err)}); break :fin_b null; }; owned_heap = owned_body != null; heap_used=false; }
                    else { owned_body=body_stage_bufs[s][0..total]; owned_heap=false; }
                }
            }
            if (compressed){
                var plain_reader=response.reader(&transfer_buf);
                var drain: [2048]u8=undefined;
                while (true){ const n=plain_reader.readSliceShort(drain[0..]) catch break; if (n==0) break; }
            }
            if (body_incomplete){ req.connection.?.closing=true; }
        }
        if (owned_body) |b| {
            if (owned_heap) { resp_data.setBodyOwned(b); owned_body=null; owned_heap=false; }
            else {
                // C1 FIX: single growth for the body bytes (was: appendSlice
                // growth). Skipped for the owned_heap path above — that one
                // transfers the buffer without touching the pool.
                resp_data.pool.ensureTotalCapacity(gpa, resp_data.pool.items.len + b.len) catch {};
                resp_data.setBody(b);
            }
        }
        else if (response.head.content_length!=null and has_body) { resp_data.setBody(""); }
        if (builtin.mode==.Debug){
            std.debug.print("[allocs] job {d}: allocs={d} frees={d} +{d}B -{d}B shells={d}\n", .{slot_id,job_counter.alloc_count,job_counter.free_count,job_counter.bytes_allocated,job_counter.bytes_freed,job_counter.alloc_count -| job_counter.free_count,});
            // C1 FIX: pooled ResponseData shells are reused, not freed —
            // per-job balance holds modulo ≤1 shell transfer (was: exact).
            std.debug.assert(job_counter.alloc_count >= job_counter.free_count);
            std.debug.assert(job_counter.alloc_count - job_counter.free_count <= 1);
        }
        okSlot(s, resp_data);
        break :hop;
    }
}
fn failSlot(s: usize, comptime msg: []const u8) void {
    if (builtin.mode==.Debug) std.debug.print("[fail] slot {d}: {s}\n", .{s,msg});
    errs[s]=msg; finishSlot(s);
}
fn okSlot(s: usize, data: *response_mod.ResponseData) void { results[s]=data; finishSlot(s); }
fn finishSlot(s: usize) void {
    states[s].store(JOB_DONE,.release);
    _ = pending.fetchSub(1, .release);
    async_h.notify() catch {};
}
pub fn arm(loop: *xev.Loop) void {
    if (async_armed) return;
    async_armed=true; g_loop=loop;
    async_h.wait(loop, &async_comp, void, null, asyncCb);
}
pub fn ensureArmed() void { if (async_armed) return; if (g_loop) |l| arm(l); }
pub fn setLoop(l: *xev.Loop) void { g_loop=l; }
fn asyncCb(ud: ?*void, l: *xev.Loop, comp: *xev.Completion, r: AsyncT.WaitError!void) xev.CallbackAction {
    _=ud; _=comp; _=r catch return .disarm;
    if (g_ctx) |ctx| { drainCompleted(ctx); microtasks.pumpMicrotasks(ctx); }
    if (pending.load(.acquire)>0){ async_armed=true; async_h.wait(l, &async_comp, void, null, asyncCb); } else { async_armed=false; }
    return .disarm;
}
fn doneMask() u64 {
    // A5 FIX: acquire-load the atomics (was: non-atomic `.raw` read — a data
    // race against the worker thread's `.release` store). Claim still goes
    // through claimSlot's cmpxchgStrong below.
    var mask: u64=0;
    inline for (0..MAX_FETCH) |i| { if (states[i].load(.acquire)==JOB_DONE) mask|=@as(u64,1)<<@intCast(i); }
    return mask;
}
fn claimSlot(s: usize) bool { return states[s].cmpxchgStrong(JOB_DONE, JOB_CLAIMED, .acq_rel, .acquire)==null; }
pub fn drainCompleted(ctx: ?*c.Context) void {
    var mask=doneMask();
    while (mask!=0){ const s:usize=@ctz(mask); mask &= mask-1; if (claimSlot(s)) completeJob(ctx,s); }
}
fn completeJob(ctx: ?*c.Context, s: usize) void {
    // BUG-5 FIX: freeResult on the resolver-missing paths — results[s] held
    // a heap ResponseData that releaseSlot would otherwise just null out.
    const resolve=resolve_funcs[s] orelse { freeResolvers(s); freeOwned(s); freeResult(s); releaseSlot(s); return; };
    const reject=reject_funcs[s] orelse { freeResolvers(s); freeOwned(s); freeResult(s); releaseSlot(s); return; };
    if (results[s]) |data| {
        const obj=response_mod.buildResponseJSObject(ctx, data);
        // BUG-5 FIX: JS_Call borrows argv, it does not consume it — one
        // Response (and its HeadersData + body) leaked per successful fetch.
        defer c.freeValue(ctx, obj);
        var args=[_]c.Value{obj};
        _ = c.call(ctx, resolve, c.JS_UNDEFINED, 1, &args);
    } else {
        const msg=errs[s] orelse "fetch failed";
        const ev=c.newStringLen(ctx, msg.ptr, @intCast(msg.len));
        // BUG-5 FIX: same borrow semantics — one Error string leaked per
        // failed fetch.
        defer c.freeValue(ctx, ev);
        var args=[_]c.Value{ev};
        _ = c.call(ctx, reject, c.JS_UNDEFINED, 1, &args);
    }
    freeResolvers(s);
    // FIX: release submit-owned url/body/Headers on the normal path too
    // (ownership was documented as freeOwned but only deinit/shutdown called it).
    freeOwned(s);
    results[s]=null;
errs[s]=null;
    releaseSlot(s);
}
