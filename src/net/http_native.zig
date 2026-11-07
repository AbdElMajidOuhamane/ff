const std = @import("std");
const simd = std.simd;
const xev = @import("xev");
const cli = @import("../util/cli.zig");
const c = @import("../c.zig").c;
const microtasks = @import("../event/microtasks.zig");
const ws = @import("ws_native.zig");
const api_ws = @import("../api/websocket.zig");
const builtin = @import("builtin");
const tls_mod = @import("tls_server.zig");
const tls_on = tls_mod.available;
const http2_mod = @import("http2_server.zig");
const response_mod = @import("../types/response.zig");
const headers_mod = @import("../types/headers.zig");
const gpa = std.heap.smp_allocator;

// F3: the Debug req_counter (CountingAllocator) that used to wrap this
// file's allocator was deleted: a process-wide counter only proved "allocs
// matched frees", not "zero allocs per request" — vacuous false assurance.
// The meaningful per-job counter lives in net/async_fetch.zig. Exception:
// response bodies above BODY_BUF_SIZE still take a documented gpa spill in
// stageLargeResponse (measured via stat_body_spill / stat_body_spill_reuse;
// spills ≤ BODY_SPILL_RETAIN_MAX are retained on the slot across responses).

pub const MAX_CONN = 512;
const READ_BUF_SIZE = 4096;
// H1 request-body spill (cold path). The static buffer above stays the fast
// path; only requests that do not fit ever touch the allocator.
const REQ_BODY_MAX = 1 * 1024 * 1024; // per-request hard cap
const REQ_SPILL_RETAIN_MAX = 64 * 1024; // retained per idle slot
const REQ_SPILL_GLOBAL_MAX = 64 * 1024 * 1024; // in-flight spill budget
pub const WRITE_BUF_SIZE = 16384;
const ACCEPT_BATCH = 8;

const ConnState = enum(u8) { idle, reading, writing, closing };
const ConnFlags = packed struct(u16) {
    keep_alive: bool = false,
    ws_open: bool = false,
    ws_writing: bool = false,
    ws_close_after_write: bool = false,
    ws_read_armed: bool = false,
    ws_pending_open: bool = false,
    tls: bool = false,
    tls_close_after_write: bool = false,
    handler_parked: bool = false,
    h2_active: bool = false,
    h2_checked: bool = false,
    tls_read_armed: bool = false,
    // Which column the staged large body lives in (body_heap vs body_bufs).
    // Stored, not derived: the old `body_lens > BODY_BUF_SIZE` predicate had
    // to stay in lockstep with two independent columns, and a retained spill
    // outlives its response.
    body_from_heap: bool = false,
    // Which column the staged request body lives in (req_spill vs read_bufs).
    req_body_spill: bool = false,
    _pad: u2 = 0,
};
comptime {
    assert(@sizeOf(ConnFlags) == 2);
    assert(@alignOf(ConnFlags) == 2);
    assert(@sizeOf(Method) == 1);
    assert(@alignOf(Method) == 1);
    assert(@sizeOf(ParsedRequest) <= 64);
    assert(@alignOf(ParsedRequest) <= 8);
    assert(@sizeOf(ConnState) == 1);
}
const assert = std.debug.assert;

pub const Method = enum(u8) { get, post, put, delete, head, options, patch, none };
pub var states: [MAX_CONN]ConnState = [_]ConnState{.idle} ** MAX_CONN;
var cflags: [MAX_CONN]ConnFlags = [_]ConnFlags{.{}} ** MAX_CONN;

pub var write_lens: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
pub var write_offsets: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
var methods: [MAX_CONN]Method = [_]Method{.none} ** MAX_CONN;
var read_comps: [MAX_CONN]xev.Completion = [_]xev.Completion{.{}} ** MAX_CONN;
var read_cancel_comps: [MAX_CONN]xev.Completion = [_]xev.Completion{.{}} ** MAX_CONN;
var read_armed_bits: [MAX_CONN / 64]u64 = [_]u64{0} ** (MAX_CONN / 64);
inline fn isReadArmed(id: usize) bool {
    return (read_armed_bits[id >> 6] >> @intCast(id & 63)) & 1 == 1;
}
inline fn setReadArmed(id: usize, armed: bool) void {
    const w = &read_armed_bits[id >> 6];
    const bit: u64 = @as(u64, 1) << @intCast(id & 63);
    if (armed) w.* |= bit else w.* &= ~bit;
}
pub var write_comps: [MAX_CONN]xev.Completion = [_]xev.Completion{.{}} ** MAX_CONN;
var close_comps: [MAX_CONN]xev.Completion = [_]xev.Completion{.{}} ** MAX_CONN;
var hdr_scan_off: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
var fds: [MAX_CONN]xev.TCP = undefined;
var buf_lens: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
// F4: bytes of read_bufs[0..buf_lens] consumed by the current request
// (headers_end + content_length). Keep-alive re-arms use it to preserve
// pipelined bytes instead of discarding them.
var req_consumed: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
var ws_partial_len: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
// DOD §3: 512B bool column → 64B bitset (8×u64). Set only on fragment start,
// read only on fragment completion — never scanned linearly with buf_lens.
var ws_partial_binary_bits: [MAX_CONN / 64]u64 = [_]u64{0} ** (MAX_CONN / 64);
inline fn wsPartialBinary(id: usize) bool {
    return (ws_partial_binary_bits[id >> 6] >> @intCast(id & 63)) & 1 == 1;
}
inline fn wsSetPartialBinary(id: usize, is_bin: bool) void {
    const w = &ws_partial_binary_bits[id >> 6];
    const bit: u64 = @as(u64, 1) << @intCast(id & 63);
    if (is_bin) w.* |= bit else w.* &= ~bit;
}
// Same §3 trick for fragment state: "a fragmented message is open" is a bit,
// not a sentinel in ws_partial_len. RFC 6455 allows a zero-length first
// fragment, which left the length at 0 and made the legal continuation look
// spurious (close 1002).
var ws_fragment_open_bits: [MAX_CONN / 64]u64 = [_]u64{0} ** (MAX_CONN / 64);
inline fn wsFragmentOpen(id: usize) bool {
    return (ws_fragment_open_bits[id >> 6] >> @intCast(id & 63)) & 1 == 1;
}
inline fn wsSetFragmentOpen(id: usize, open: bool) void {
    const w = &ws_fragment_open_bits[id >> 6];
    const bit: u64 = @as(u64, 1) << @intCast(id & 63);
    if (open) w.* |= bit else w.* &= ~bit;
}
var ws_sockets: [MAX_CONN]?c.Value = [_]?c.Value{null} ** MAX_CONN;
var ws_batch: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
var read_bufs: [MAX_CONN][READ_BUF_SIZE]u8 = undefined;
pub var write_bufs: [MAX_CONN][WRITE_BUF_SIZE]u8 = undefined;

var ws_partial: [MAX_CONN][ws.WS_MSG_SIZE]u8 = undefined;

var body_remaining: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
var body_source_off: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
// body_bufs holds one fully-staged large response body per slot. Static
// allocation: MAX_CONN × BODY_BUF_SIZE. Bodies larger than BODY_BUF_SIZE
// get a 500 (JS body pointers are freed when callHandler returns, so the
// whole body must be staged before the write pipeline starts).
const BODY_BUF_SIZE = 64 * 1024;
const BODY_SPILL_RETAIN_MAX = 256 * 1024; // retained-spill cap: bounds 512-slot worst case
const MAX_BODY_SIZE = 10 * 1024 * 1024; //10 MB gate — matches fs.zig MAX_READ
var body_bufs: [MAX_CONN][BODY_BUF_SIZE]u8 = undefined;
// Retained across responses on the same slot; freed at closeConn/setupSlot
// or at drain end when a spill exceeds BODY_SPILL_RETAIN_MAX.
var body_heap: [MAX_CONN]?[]u8 = [_]?[]u8{null} ** MAX_CONN; // heap spill for >64KB
var body_lens: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
// Spill telemetry for the >64KB response path (mirrors async_fetch stat_*).
pub var stat_body_spill: std.atomic.Value(u64) = .{ .raw = 0 };
pub var stat_body_spill_reuse: std.atomic.Value(u64) = .{ .raw = 0 };
// ── H1 request-body spill (cold path) ─────────────────────────────
// Null until a request's headers+body exceed READ_BUF_SIZE. Layout:
//   [0..req_hdr_end]  private copy of the headers (ParsedRequest slices)
//   [req_hdr_end..]   body
// One dense pointer column plus scalar columns; no per-request object.
var req_spill: [MAX_CONN]?[]u8 = [_]?[]u8{null} ** MAX_CONN;
var req_spill_len: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
var req_spill_want: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
var req_hdr_end: [MAX_CONN]usize = [_]usize{0} ** MAX_CONN;
var req_spill_bytes: std.atomic.Value(usize) = .{ .raw = 0 };
pub var stat_req_spill: std.atomic.Value(u64) = .{ .raw = 0 };
pub var stat_req_spill_reuse: std.atomic.Value(u64) = .{ .raw = 0 };
// ── TLS (https/wss): per-slot BearSSL engine + bidirectional iobuf ──
var tls_ctxs: [MAX_CONN]tls_mod.Ctx = undefined;
var tls_iobufs: [MAX_CONN][tls_mod.IOBUF_LEN]u8 = undefined;
var tls_active: bool = false; // runtime switch (cert/key given), set before accept starts
var free_list: [MAX_CONN]u16 = undefined;
var free_count: usize = 0;
pub var slot_ids: [MAX_CONN]u16 = undefined;

// ── Parked async handlers (one flat column per slot) ── // NEW
// Generation counter guards late promise reactions against slot reuse.
var slot_gen: [MAX_CONN]u16 = [_]u16{0} ** MAX_CONN;
var parked_since_ms: [MAX_CONN]u64 = [_]u64{0} ** MAX_CONN;
var promise_class_id: c.ClassID = 0;
// Cached "then" atom for parkHandler: one JS_NewAtomLen per process instead
// of one intern+release per parked async request. Process-lifetime, like
// promise_class_id — never freed. // ◀ FIX-3
var then_atom: c.Atom = 0; // ◀ FIX-3

const HDR_MAX = 2048;
const HANDLER_TIMEOUT_MS: u64 = 30_000;
const WATCHDOG_INTERVAL_MS: u64 = 1000;
// Bounded drain: server.close() waits this long for in-flight work, then
// hard-closes the remaining slots. Independent of the watchdog so the
// deadline still fires if the watchdog is stopped early.
const SHUTDOWN_DRAIN_MS: u64 = 5000;
// Header/body/idle read deadline (slowloris defence). One u64 column swept by
// the existing watchdogCb — no per-connection timer, no hot-path allocation.
// DOD §7: one pass over a dense column, batch API, zero per-conn objects.
const CONN_TIMEOUT_MS: u64 = 30_000;
var deadline_ms: [MAX_CONN]u64 = [_]u64{0} ** MAX_CONN;
var watchdog_timer: xev.Timer = undefined;
var watchdog_comp: xev.Completion = .{};
var watchdog_cancel_comp: xev.Completion = .{};
var watchdog_started = false;
var shutdown_timer: xev.Timer = undefined;
var shutdown_comp: xev.Completion = .{};
var shutdown_cancel_comp: xev.Completion = .{};
var shutdown_timer_started = false;

pub var server_running = std.atomic.Value(bool).init(false);
pub var bound_port: u16 = 0;
pub var handler_fn: ?c.Value = null;
pub var handler_ctx: ?*c.Context = null;
pub var ws_enabled: bool = false;
pub var ws_on_open: ?c.Value = null;
pub var ws_on_message: ?c.Value = null;
pub var ws_on_close: ?c.Value = null;
var native_echo: bool = false;
var listener_tcp: xev.TCP = undefined;
var accept_comp: xev.Completion = .{};
var accept_cancel_comp: xev.Completion = .{};
var listener_close_comp: xev.Completion = .{};
var accept_armed: bool = false;
var listener_closed: bool = false;
var closing_server: bool = false;
var shutdown_deadline_ms: u64 = 0;
var close_resolve: ?c.Value = null;
var close_cb_fn: ?c.Value = null;
var g_loop: ?*xev.Loop = null;
var initialized: bool = false;

// Gap-7 fix: largest→smallest field order (56B, still ≤64 assert).
// Stack transient only — never stored in a large array.
//
// INVARIANT (security-critical): content_length is bounded by REQ_BODY_MAX at
// parse time. Every downstream `headers_end + content_length` is then
// provably in range (and content_length ≤ REQ_BODY_MAX), which is what bounds
// tryUpgrade and processPlaintext without checked adds on the hot path.
// ws_key is non-empty only for a fully validated RFC 6455 handshake; ws_bad
// marks "key seen, handshake invalid".
pub const ParsedRequest = struct {
    method: []const u8,
    url: []const u8,
    ws_key: []const u8,
    content_length: usize,
    method_tag: Method,
    keep_alive: bool,
    framing_ok: bool,
    ws_bad: bool,
    // Content-Length exceeded REQ_BODY_MAX: framing is invalid, but the
    // processPlaintext caller answers 413 instead of 400.
    too_large: bool,
};

// ---- SIMD/CI helpers (unchanged) ----

// CPU-native u8 vector width for every scan below (16 on SSE2/baseline,
// 32 on AVX2, 64 on AVX-512; 16 where the target has no suggestion).
// Single const so the findTokenCI dispatch threshold can never drift
// from the width the SIMD scans actually use.
const vec_len_u8 = simd.suggestVectorLength(u8) orelse 16;

fn freePop() ?usize {
    if (free_count == 0) return null;
    free_count -= 1;
    return free_list[free_count];
}
fn freePush(id: usize) void {
    // Unchecked cursor into a static column: a double release for one slot
    // would write past free_list into the next global. Latent today (see
    // closeConn's .closing guard) — keep it structural.
    assert(free_count < MAX_CONN);
    if (free_count >= MAX_CONN) return;
    free_list[free_count] = @intCast(id);
    free_count += 1;
}
fn findTokenCIScalar(haystack: []const u8, needle: []const u8) ?usize {
    outer: for (0..haystack.len - needle.len + 1) |i| {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) continue :outer;
        }
        return i;
    }
    return null;
}
fn matchCI(haystack: []const u8, pos: usize, needle: []const u8) bool {
    var j: usize = 0;
    while (j < needle.len) : (j += 1) {
        if (std.ascii.toLower(haystack[pos + j]) != std.ascii.toLower(needle[j])) return false;
    }
    return true;
}
fn ciStartsWith(s: []const u8, comptime prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    inline for (prefix, 0..) |ch, k| {
        if (std.ascii.toLower(s[k]) != ch) return false;
    }
    return true;
}
fn ciListHas(value: []const u8, token: []const u8) bool {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        var s: usize = 0;
        var e: usize = raw.len;
        while (s < e and (raw[s] == ' ' or raw[s] == '\t')) s += 1;
        while (e > s and (raw[e - 1] == ' ' or raw[e - 1] == '\t')) e -= 1;
        const member = raw[s..e];
        if (member.len == token.len and matchCI(member, 0, token)) return true;
    }
    return false;
}
fn findTokenCISimd(haystack: []const u8, needle: []const u8) ?usize {
    const n = needle.len;
    const window_end = haystack.len - n + 1;
    const first = std.ascii.toLower(needle[0]);
    const N = vec_len_u8;
    const V = @Vector(N, u8);
    const M = std.meta.Int(.unsigned, N);
    const spl_first: V = @splat(first);
    const spl_lower: V = @splat(@as(u8, 0x20));
    var i: usize = 0;
    while (i < window_end and window_end - i >= N) : (i += N) {
        const v: V = haystack[i..][0..N].*;
        var bits: M = @bitCast((v | spl_lower) == spl_first);
        while (bits != 0) {
            const j: usize = @ctz(bits);
            if (matchCI(haystack, i + j, needle)) return i + j;
            bits &= bits - 1;
        }
    }
    while (i < window_end) : (i += 1) {
        if (matchCI(haystack, i, needle)) return i;
    }
    return null;
}
fn findTokenCI(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    if (haystack.len - needle.len + 1 >= vec_len_u8) return findTokenCISimd(haystack, needle);
    return findTokenCIScalar(haystack, needle);
}
pub fn findHeaderEnd(h: []const u8, from: usize) ?usize {
    if (h.len < 4 or from + 4 > h.len) return null;
    const N = vec_len_u8;
    const V = @Vector(N, u8);
    const M = std.meta.Int(.unsigned, N);
    const spl_lf: V = @splat('\n');
    var i: usize = @max(from + 3, 3);
    while (i < h.len) {
        const chunk_end = @min(i + N, h.len);
        if (chunk_end - i >= N) {
            const v: V = h[i..][0..N].*;
            var bits: M = @bitCast(v == spl_lf);
            while (bits != 0) {
                const off: usize = @ctz(bits);
                bits &= bits - 1;
                const p = i + off;
                if (p >= 3 and h[p - 3] == '\r' and h[p - 2] == '\n' and h[p - 1] == '\r') return p - 3;
            }
            i += N;
        } else {
            while (i < chunk_end) : (i += 1) {
                if (h[i] == '\n' and h[i - 3] == '\r' and h[i - 2] == '\n' and h[i - 1] == '\r') return i - 3;
            }
        }
    }
    return null;
}
pub fn classifyMethod(s: []const u8) Method {
    if (s.len == 3) {
        if (s[0] == 'G' and s[1] == 'E' and s[2] == 'T') return .get;
        if (s[0] == 'P' and s[1] == 'U' and s[2] == 'T') return .put;
    } else if (s.len == 4) {
        if (s[0] == 'P' and s[1] == 'O' and s[2] == 'S' and s[3] == 'T') return .post;
        if (s[0] == 'H' and s[1] == 'E' and s[2] == 'A' and s[3] == 'D') return .head;
    } else if (s.len == 5) {
        if (s[0] == 'P' and s[1] == 'A' and s[2] == 'T' and s[3] == 'C' and s[4] == 'H') return .patch;
    } else if (s.len == 6) {
        // FIX: "DELETE" is exactly 6 bytes (indices 0..5) — the old code read
        // s[6] here (OOB: panics in safe builds, silent `.none` in ReleaseFast).
        if (s[0] == 'D' and s[1] == 'E' and s[2] == 'L' and s[3] == 'E' and s[4] == 'T' and s[5] == 'E') return .delete;
    } else if (s.len == 7) {
        if (s[0] == 'O' and s[1] == 'P' and s[2] == 'T' and s[3] == 'I' and s[4] == 'O' and s[5] == 'N' and s[6] == 'S') return .options;
    }
    return .none;
}
fn trimOws(s: []const u8) []const u8 {
    var b = s;
    while (b.len > 0 and (b[0] == ' ' or b[0] == '\t')) b = b[1..];
    var e = b.len;
    while (e > 0 and (b[e - 1] == ' ' or b[e - 1] == '\t')) e -= 1;
    return b[0..e];
}
fn isCtlOrSpace(ch: u8) bool {
    return ch <= 0x20 or ch == 0x7f;
}
/// RFC 6455 §4.2.1: 16 random bytes base64-encoded → exactly 24 chars, "==".
fn validWsKey(k: []const u8) bool {
    if (k.len != 24 or k[22] != '=' or k[23] != '=') return false;
    for (k[0..22]) |ch| {
        const ok = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '+' or ch == '/';
        if (!ok) return false;
    }
    return true;
}
/// Strict request parse. Security-relevant rules, all enforced here so the
/// hot path never has to re-check them:
///   * Content-Length: digits only, single occurrence, ≤ REQ_BODY_MAX
///   * Transfer-Encoding: refused (chunked is not implemented — accepting
///     one framing while a proxy accepts another is request smuggling)
///   * obs-fold, whitespace-before-colon, colon-less lines: refused
///   * WebSocket handshake validated by header table, not a buffer scan
pub fn parseRequest(buf: []const u8, headers_end: usize) ParsedRequest {
    var pr = ParsedRequest{
        .method = "",
        .method_tag = .none,
        .url = "",
        .ws_key = "",
        .content_length = 0,
        .keep_alive = true,
        .framing_ok = true,
        .ws_bad = false,
        .too_large = false,
    };
    const region = buf[0..headers_end];
    if (region.len < 10) return pr;
    const sp1 = std.mem.indexOfScalar(u8, region, ' ') orelse return pr;
    if (sp1 + 1 >= region.len) return pr;
    const sp2 = std.mem.indexOfScalarPos(u8, region, sp1 + 1, ' ') orelse return pr;
    pr.method = region[0..sp1];
    pr.method_tag = classifyMethod(pr.method);
    pr.url = region[sp1 + 1 .. sp2];
    for (pr.url) |ch| {
        if (isCtlOrSpace(ch)) pr.framing_ok = false;
    }

    const proto_full = region[sp2 + 1 ..];
    var plen: usize = 0;
    while (plen < proto_full.len and proto_full[plen] != '\r' and proto_full[plen] != '\n') plen += 1;
    const is_11 = std.mem.eql(u8, std.mem.trim(u8, proto_full[0..plen], " \t"), "HTTP/1.1");

    var has_close = false;
    var has_keepalive = false;
    var seen_cl = false;
    var seen_te = false;
    var upgrading = false;
    var conn_upgrade = false;
    var ws_ver_ok = false;
    var ws_key_seen: u32 = 0;
    var ws_key_val: []const u8 = "";

    // Skip the request line (protocol token + CRLF) so the loop below sees
    // ONLY header lines. The old loop started at the protocol token and
    // treated "HTTP/1.1" as a header line.
    var i: usize = sp2 + 1;
    while (i < region.len and region[i] != '\r' and region[i] != '\n') i += 1;
    while (i < region.len and (region[i] == '\r' or region[i] == '\n')) i += 1;

    while (i < region.len) {
        const line_start = i;
        while (i < region.len and region[i] != '\r' and region[i] != '\n') i += 1;
        const hline = region[line_start..i];

        skip_to_next_line: {
            if (hline.len == 0) break :skip_to_next_line;
            // obs-fold continuation is a smuggling primitive.
            if (hline[0] == ' ' or hline[0] == '\t') {
                pr.framing_ok = false;
                break :skip_to_next_line;
            }
            const colon = std.mem.indexOfScalar(u8, hline, ':') orelse {
                pr.framing_ok = false;
                break :skip_to_next_line;
            };
            const raw_name = hline[0..colon];
            // Whitespace before ':' (BWS) is another smuggling primitive.
            const name = std.mem.trimEnd(u8, raw_name, " \t");
            if (name.len == 0 or name.len != raw_name.len) {
                pr.framing_ok = false;
                break :skip_to_next_line;
            }
            for (name) |ch| {
                if (isCtlOrSpace(ch) or ch == ':') pr.framing_ok = false;
            }
            const value = trimOws(hline[colon + 1 ..]);

            if (std.ascii.eqlIgnoreCase(name, "connection")) {
                if (!has_close and ciListHas(value, "close")) has_close = true;
                if (!has_keepalive and ciListHas(value, "keep-alive")) has_keepalive = true;
                if (ciListHas(value, "upgrade")) conn_upgrade = true;
            } else if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                if (seen_cl) {
                    // Duplicate CL: folding is ambiguous across intermediaries,
                    // so refuse rather than pick a winner.
                    pr.framing_ok = false;
                } else {
                    seen_cl = true;
                    var all_digits = value.len > 0;
                    for (value) |ch| {
                        if (ch < '0' or ch > '9') all_digits = false;
                    }
                    if (!all_digits) {
                        pr.framing_ok = false;
                    } else if (std.fmt.parseInt(usize, value, 10)) |n| {
                        // Bodies above the static buffer spill to req_spill;
                        // only REQ_BODY_MAX is a hard framing rejection.
                        if (n > REQ_BODY_MAX) {
                            pr.too_large = true;
                            pr.framing_ok = false;
                        } else {
                            pr.content_length = n;
                        }
                    } else |_| {
                        pr.framing_ok = false;
                    }
                }
            } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
                seen_te = true;
            } else if (std.ascii.eqlIgnoreCase(name, "upgrade")) {
                if (ciListHas(value, "websocket")) upgrading = true;
            } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-key")) {
                ws_key_seen +%= 1;
                ws_key_val = value;
            } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-version")) {
                if (std.mem.eql(u8, value, "13")) ws_ver_ok = true;
            }
        }

        while (i < region.len and (region[i] == '\r' or region[i] == '\n')) i += 1;
    }

    // Transfer codings are not implemented: honouring one system and not the
    // other is exactly how request smuggling starts.
    if (seen_te) pr.framing_ok = false;

    if (ws_key_seen != 0) {
        const ok = ws_key_seen == 1 and
            pr.method_tag == .get and
            is_11 and
            pr.content_length == 0 and
            upgrading and conn_upgrade and ws_ver_ok and
            validWsKey(ws_key_val);
        if (ok) pr.ws_key = ws_key_val else pr.ws_bad = true;
    }

    pr.keep_alive = if (is_11) !has_close else has_keepalive;
    return pr;
}
fn statusReason(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        301 => "Moved Permanently",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Payload Too Large",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        else => "Unknown",
    };
}
fn pushStr(w: []u8, pos: *usize, s: []const u8) void {
    @memcpy(w[pos.*..][0..s.len], s);
    pos.* += s.len;
}
fn appendUInt(w: []u8, pos: *usize, value: usize) void {
    var buf: [20]u8 = undefined;
    var n: usize = 0;
    var v = value;
    if (v == 0) {
        buf[0] = '0';
        n = 1;
    } else {
        while (v > 0) : (v /= 10) {
            buf[n] = @as(u8, @intCast('0' + v % 10));
            n += 1;
        }
        std.mem.reverse(u8, buf[0..n]);
    }
    @memcpy(w[pos.*..][0..n], buf[0..n]);
    pos.* += n;
}
fn wantsBodyBytes(id: usize, status: u16) bool {
    return methods[id] != .head and status != 204 and status != 304;
}
fn formatResponseHeader(w: []u8, status: u16, content_length: ?usize, keep_alive: bool) usize {
    var pos: usize = 0;
    pushStr(w, &pos, "HTTP/1.1 ");
    appendUInt(w, &pos, status);
    pushStr(w, &pos, " ");
    pushStr(w, &pos, statusReason(status));
    pushStr(w, &pos, "\r\n");
    pushStr(w, &pos, "Content-Type: text/plain\r\n");
    if (content_length) |n| {
        pushStr(w, &pos, "Content-Length: ");
        appendUInt(w, &pos, n);
        pushStr(w, &pos, "\r\n");
    }
    if (keep_alive) pushStr(w, &pos, "Connection: keep-alive\r\n");
    pushStr(w, &pos, "\r\n");
    return pos;
}
fn buildResponse(id: usize, status: u16, body: []const u8) void {
    if (cflags[id].h2_active) {
        // H2 has no reason phrases: status-only response, body dropped.
        http2_mod.respondErrorH2(id, status);
        return;
    }
    const suppress = !wantsBodyBytes(id, status);
    const cl: ?usize = if (status == 204 or status == 304) null else body.len;
    const w: *[WRITE_BUF_SIZE]u8 = &write_bufs[id];
    var pos = formatResponseHeader(w[0..], status, cl, cflags[id].keep_alive);
    if (!suppress and body.len > 0 and pos + body.len <= WRITE_BUF_SIZE) {
        @memcpy(w[pos..][0..body.len], body);
        pos += body.len;
    }
    write_lens[id] = pos;
}

/// Terminal protocol error: answer with keep-alive OFF and consume the whole
/// buffered span, so keepAlivePreserve can never re-parse the offending bytes.
/// Without this, a 413 leaves `req_consumed` stale and the slot hangs waiting
/// for a body that can never fit the read buffer.
fn rejectWith(id: usize, l: *xev.Loop, status: u16, body: []const u8) void {
    cflags[id].keep_alive = false;
    req_consumed[id] = buf_lens[id];
    body_lens[id] = 0;
    body_remaining[id] = 0;
    body_source_off[id] = 0;
    cflags[id].body_from_heap = false;
    resetReqSpill(id);
    buildResponse(id, status, body);
    states[id] = .writing;
    armWrite(id, l);
}

// ── H1 request-body spill helpers ─────────────────────────────────
// The global budget bounds 512 slots: retained buffers are capped per slot,
// and in-flight growth is capped process-wide. Both are cold-path only.

fn reqSpillReserve(delta: usize) bool {
    var cur = req_spill_bytes.load(.monotonic);
    while (true) {
        if (cur > REQ_SPILL_GLOBAL_MAX or delta > REQ_SPILL_GLOBAL_MAX - cur) return false;
        if (req_spill_bytes.cmpxchgStrong(cur, cur + delta, .acq_rel, .acquire) == null) return true;
        cur = req_spill_bytes.load(.acquire);
    }
}

fn reqSpillRelease(n: usize) void {
    _ = req_spill_bytes.fetchSub(n, .monotonic);
}

fn ensureReqSpill(id: usize, need: usize) ?[]u8 {
    if (req_spill[id]) |old| {
        if (old.len >= need) {
            _ = stat_req_spill_reuse.fetchAdd(1, .release);
            return old[0..need];
        }
        const delta = need - old.len;
        if (!reqSpillReserve(delta)) return null;
        const grown = gpa.realloc(old, need) catch {
            reqSpillRelease(delta);
            return null;
        };
        req_spill[id] = grown;
        return grown[0..need];
    }
    _ = stat_req_spill.fetchAdd(1, .release);
    if (!reqSpillReserve(need)) return null;
    const buf = gpa.alloc(u8, need) catch {
        reqSpillRelease(need);
        return null;
    };
    req_spill[id] = buf;
    return buf[0..need];
}

fn releaseReqSpillIfOversized(id: usize) void {
    if (req_spill[id]) |old| {
        if (old.len > REQ_SPILL_RETAIN_MAX) {
            reqSpillRelease(old.len);
            gpa.free(old);
            req_spill[id] = null;
        }
    }
}

/// Retire a completed request; keep a small retained capacity for reuse.
fn resetReqSpill(id: usize) void {
    releaseReqSpillIfOversized(id);
    req_spill_len[id] = 0;
    req_spill_want[id] = 0;
    req_hdr_end[id] = 0;
    cflags[id].req_body_spill = false;
}

/// Slot teardown: the slot will be handed to another peer.
fn destroyReqSpill(id: usize) void {
    if (req_spill[id]) |old| {
        reqSpillRelease(old.len);
        gpa.free(old);
        req_spill[id] = null;
    }
    req_spill_len[id] = 0;
    req_spill_want[id] = 0;
    req_hdr_end[id] = 0;
    cflags[id].req_body_spill = false;
}

fn armReadReqSpill(id: usize, l: *xev.Loop) void {
    if (tls_on and cflags[id].tls) {
        // TLS plaintext always lands in read_bufs; tlsPump drains it into
        // the spill in chunks (BearSSL records can be ~32 KB).
        armRead(id, l);
        return;
    }
    const need = req_spill_want[id] - req_spill_len[id];
    states[id] = .reading;
    setReadArmed(id, true);
    fds[id].read(
        l,
        &read_comps[id],
        .{ .slice = req_spill[id].?[req_spill_len[id]..][0..need] },
        u16,
        &slot_ids[id],
        readCb,
    );
}

fn continueReqSpill(id: usize, l: *xev.Loop) void {
    if (req_spill_len[id] < req_spill_want[id]) {
        armReadReqSpill(id, l);
        return;
    }
    finishReqSpill(id, l);
}

fn finishReqSpill(id: usize, l: *xev.Loop) void {
    const hdr_end = req_hdr_end[id];
    const total = req_spill_want[id];
    const buf = req_spill[id].?;
    const pr = parseRequest(buf[0..hdr_end], hdr_end);
    methods[id] = pr.method_tag;

    if (pr.method.len == 0 or !pr.framing_ok or
        pr.content_length != total - hdr_end)
    {
        resetReqSpill(id);
        rejectWith(id, l, 400, "Bad Request");
        return;
    }

    cflags[id].keep_alive = pr.keep_alive and !closing_server;
    // read_bufs, if non-empty here (TLS over-read), is entirely the next
    // request's bytes: consume none of it.
    req_consumed[id] = 0;
    cflags[id].req_body_spill = false;

    const body = buf[hdr_end..total];
    if (native_echo) {
        buildResponse(id, 200, "{\"message\":\"ok\"}");
    } else {
        const hdrs = parseHeaders(buf[0..hdr_end]) catch |err| switch (err) {
            error.HeadersTooLarge => {
                resetReqSpill(id);
                rejectWith(id, l, 431, "Request Header Fields Too Large");
                return;
            },
            error.OutOfMemory => {
                resetReqSpill(id);
                rejectWith(id, l, 503, "Service Unavailable");
                return;
            },
        };
        callHandlerWithHeaders(id, &pr, body, hdrs); // copies body into a JS string
    }
    resetReqSpill(id);

    if (cflags[id].h2_active) {
        http2_mod.flushNow(id, l);
        return;
    }
    if (!cflags[id].handler_parked) {
        states[id] = .writing;
        armWrite(id, l);
    } else {
        states[id] = .reading;
    }
}

// ── TLS (https/wss) helpers ─────────────────────────────────────────
// Plain path: kernel reads/writes hit read_bufs/write_bufs directly.
// TLS path:   kernel <-> BearSSL engine; plaintext flows via read_bufs/write_bufs.

pub fn enableTls() void {
    if (tls_on) tls_active = tls_mod.ready();
}

pub fn disableTls() void {
    tls_active = false;
}

fn armRead(id: usize, l: *xev.Loop) void {
    if (tls_on and cflags[id].tls) {
        if (cflags[id].tls_read_armed) return; // already pending — prevent libxev double-push
        const sp = tls_mod.recvRecSpace(&tls_ctxs[id]);
        if (sp.len == 0) return;
        states[id] = .reading;
        cflags[id].tls_read_armed = true;
        setReadArmed(id, true);
        fds[id].read(l, &read_comps[id], .{ .slice = sp }, u16, &slot_ids[id], readCb);
        return;
    }
    states[id] = .reading;
    setReadArmed(id, true);
    fds[id].read(l, &read_comps[id], .{ .slice = read_bufs[id][buf_lens[id]..] }, u16, &slot_ids[id], readCb);
}

pub fn armWrite(id: usize, l: *xev.Loop) void {
    if (tls_on and cflags[id].tls) {
        var fed: usize = 0;
        while (write_lens[id] > fed) {
            const got = tls_mod.sendAppFeed(&tls_ctxs[id], write_bufs[id][fed..write_lens[id]]);
            if (got == 0) break;
            fed += got;
        }
        if (fed < write_lens[id]) {
            const rem = write_lens[id] - fed;
            @memmove(write_bufs[id][0..rem], write_bufs[id][fed..write_lens[id]]);
            write_lens[id] = rem;
        } else {
            write_lens[id] = 0;
        }
        write_offsets[id] = 0;
        tls_mod.flush(&tls_ctxs[id]);
        const out = tls_mod.sendRecReady(&tls_ctxs[id]);
        if (out.len == 0) return;
        states[id] = .writing;
        fds[id].write(l, &write_comps[id], .{ .slice = out }, u16, &slot_ids[id], writeCb);
        return;
    }
    states[id] = .writing;
    fds[id].write(l, &write_comps[id], .{ .slice = write_bufs[id][write_offsets[id]..write_lens[id]] }, u16, &slot_ids[id], writeCb);
}
/// Drive the BearSSL engine. br_ssl_engine_current_state() returns a
/// COMBINATION of bitmask flags (bearssl_ssl.h: BR_SSL_CLOSED=0x0001,
/// SENDREC=0x0002, RECVREC=0x0004, SENDAPP=0x0008, RECVAPP=0x0010), so
/// dispatch with & (like BearSSL's own run_until in ssl_io.c), never ==.
/// Priority per pass: SENDREC > RECVAPP > SENDAPP > RECVREC.
/// Called from readCb (after recvRecAck) and from writeCb (after ciphertext drained).
fn tlsPump(id: usize, l: *xev.Loop) void {
    var spins: u8 = 0;
    while (spins < 32) : (spins += 1) {
        const st = tls_mod.curState(&tls_ctxs[id]);
        if (st & tls_mod.ST_CLOSED != 0) {
            closeConn(id);
            return;
        }
        if (st & tls_mod.ST_SENDREC != 0) {
            // H2's pumpWrite already owns the single outstanding write.
            // Arming here would double-push write_comps; let writeCb resume.
            if (cflags[id].h2_active and http2_mod.isWriteArmed(id)) return;
            const out = tls_mod.sendRecReady(&tls_ctxs[id]);
            if (out.len > 0) {
                states[id] = .writing;
                if (cflags[id].h2_active) http2_mod.markWriteArmed(id);
                fds[id].write(l, &write_comps[id], .{ .slice = out }, u16, &slot_ids[id], writeCb);
                return;
            }
        }
        if (st & tls_mod.ST_RECVAPP != 0) {
            // One-time ALPN check on first decrypted data: "h2" diverts
            // this slot to nghttp2; anything else stays HTTP/1.1.
            if (!cflags[id].h2_checked) {
                cflags[id].h2_checked = true;
                if (tls_mod.selectedAlpn(&tls_ctxs[id])) |proto| {
                    if (std.mem.eql(u8, proto, "h2")) {
                        cflags[id].h2_active = true;
                        _ = http2_mod.initSession(id);
                    }
                }
            }
            const app = tls_mod.recvAppReady(&tls_ctxs[id]);
            if (app.len > 0) {
                if (cflags[id].req_body_spill) {
                    // BearSSL can hand us ~32 KB at once; the spill buffer is
                    // the destination, so large TLS uploads never touch
                    // read_bufs.
                    const need = req_spill_want[id] - req_spill_len[id];
                    const take = @min(need, app.len);
                    if (take > 0) {
                        @memcpy(req_spill[id].?[req_spill_len[id]..][0..take], app[0..take]);
                        req_spill_len[id] += take;
                        tls_mod.recvAppAck(&tls_ctxs[id], take);
                    }
                    if (req_spill_len[id] == req_spill_want[id]) {
                        finishReqSpill(id, l); // write armed
                        return; // unacked plaintext stays for the next pump
                    }
                    continue;
                }

                // A single TLS record can carry more plaintext than the static
                // request buffer. Fill what fits and parse it first: a large
                // H1 body then enters req_spill instead of closing the socket.
                const space = READ_BUF_SIZE - buf_lens[id];
                const take = @min(space, app.len);
                if (take > 0) {
                    @memcpy(read_bufs[id][buf_lens[id]..][0..take], app[0..take]);
                    buf_lens[id] += take;
                    tls_mod.recvAppAck(&tls_ctxs[id], take);
                }
                if (take == app.len and buf_lens[id] < READ_BUF_SIZE) continue;

                const before = buf_lens[id];
                processPlaintext(id, l);

                if (cflags[id].req_body_spill) continue; // drain remaining plaintext into the spill
                if (cflags[id].h2_active) {
                    if (buf_lens[id] == READ_BUF_SIZE and before == READ_BUF_SIZE) {
                        closeConn(id); // no progress and no room
                        return;
                    }
                    continue;
                }
                if (cflags[id].ws_open and buf_lens[id] >= READ_BUF_SIZE) {
                    closeConn(id); // frame exceeds the static staging buffer
                    return;
                }
                return; // H1 response/write armed; leftovers drain on the next pump
            }
        }
        if (st & tls_mod.ST_SENDAPP != 0) {
            if (write_lens[id] > 0) {
                armWrite(id, l);
                return;
            }
            // Nothing staged: keep the read side armed so the peer's next
            // records (handshake or app data) can arrive.
            if (tls_mod.recvRecSpace(&tls_ctxs[id]).len > 0) {
                if (buf_lens[id] > 0) {
                    processPlaintext(id, l);
                    return;
                }
                if (cflags[id].ws_open) armReadId(id, l) else armRead(id, l);
                return;
            }
        }
        if (st & tls_mod.ST_RECVREC != 0) {
            if (tls_mod.recvRecSpace(&tls_ctxs[id]).len > 0) {
                if (buf_lens[id] > 0) {
                    processPlaintext(id, l);
                    return;
                }
                if (cflags[id].ws_open) armReadId(id, l) else armRead(id, l);
                return;
            }
        }
        return;
    }
}

fn noopCancelCb(
    _: ?*anyopaque,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.Result,
) xev.CallbackAction {
    return .disarm;
}

fn hardClose(id: usize) void {
    states[id] = .closing;
    const loop = g_loop orelse {
        setReadArmed(id, false);
        states[id] = .idle;
        freePush(id);
        return;
    };
    if (isReadArmed(id)) {
        setReadArmed(id, false);
        read_cancel_comps[id] = .{
            .op = .{ .cancel = .{ .c = &read_comps[id] } },
            .userdata = null,
            .callback = noopCancelCb,
        };
        loop.add(&read_cancel_comps[id]);
    }
    fds[id].close(loop, &close_comps[id], u16, &slot_ids[id], closeCb);
}

fn extractInt(ctx: ?*c.Context, val: c.Value, default: u16) u16 {
    if (c.isUndefined(val) != 0 or c.isNull(val) != 0) return default;
    var out: i32 = 0;
    if (c.toInt32(ctx, &out, val) == -1) return default;
    // Bounded cast: a negative or >3-digit status would trap in safe builds
    // and wrap to 65535 in ReleaseFast.
    if (out < 100 or out > 999) return default;
    return @intCast(out);
}

fn nowMs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @intCast(@as(i64, ts.sec) * std.time.ms_per_s + @divTrunc(ts.nsec, std.time.ns_per_ms));
}

fn isManagedHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "content-length") or
        std.ascii.eqlIgnoreCase(name, "transfer-encoding") or
        std.ascii.eqlIgnoreCase(name, "connection");
}

fn printException(ctx: ?*c.Context, exc: c.Value) void {
    if (ctx == null) return;
    const msg = c.toCString(ctx, exc) orelse return;
    defer c.freeCString(ctx, msg);
    std.debug.print("[http] handler error: {s}\n", .{msg});
}

// Retained-spill gate: spills ≤ BODY_SPILL_RETAIN_MAX stay on the slot after
// the drain so the next large response reuses them (free+dupe avoided);
// larger spills are freed at drain end to bound memory.
fn releaseSpillIfOversized(id: usize) void {
    if (body_heap[id]) |old| {
        if (old.len > BODY_SPILL_RETAIN_MAX) {
            gpa.free(old);
            body_heap[id] = null;
        }
    }
}

// UAF FIX (memory rule: a borrow dies with its block, not with its function).
// Copy a JS-owned body into this slot's static staging column WHILE the borrow
// is still alive. Never returns a pointer into `src`.
//   ≤BODY_BUF_SIZE → body_bufs[id] (zero alloc)
//   larger         → the retained heap spill (reused when capacity fits)
// Sets cflags.body_from_heap so the drain never has to re-derive the column.
pub fn stageBodyBytes(id: usize, src: []const u8) ?[]const u8 {
    if (src.len == 0) return &[_]u8{};
    if (src.len <= BODY_BUF_SIZE) {
        @memcpy(body_bufs[id][0..src.len], src);
        cflags[id].body_from_heap = false;
        return body_bufs[id][0..src.len];
    }
    _ = stat_body_spill.fetchAdd(1, .release);
    if (body_heap[id]) |old| {
        if (old.len >= src.len) {
            _ = stat_body_spill_reuse.fetchAdd(1, .release);
            @memcpy(old[0..src.len], src);
            cflags[id].body_from_heap = true;
            return old[0..src.len];
        }
        gpa.free(old);
        body_heap[id] = null;
    }
    const buf = gpa.dupe(u8, src) catch return null;
    body_heap[id] = buf;
    cflags[id].body_from_heap = true;
    return buf;
}

/// Publish an already-staged body to the write drain. No copy: the bytes are
/// already in body_bufs or body_heap; cflags.body_from_heap says which.
pub fn publishStagedBody(id: usize, blen: usize) void {
    body_lens[id] = blen;
    body_remaining[id] = blen;
    body_source_off[id] = 0;
}

// DOD-FIX 3: chunked large-body write helper. The caller has already
// formatted the header block into write_bufs[id] (write_lens[id] = header
// length); writeCb drains WRITE_BUF_SIZE chunks from the staged body afterwards.
// ≤64KB stages into static body_bufs (unchanged fast path);
// >64KB spills to a per-slot heap buffer (measured via stat_body_spill /
// stat_body_spill_reuse; retained while ≤ BODY_SPILL_RETAIN_MAX instead of
// free+dupe per response).
// NOTE: retained for the Response-instance / ArrayBuffer paths only; those
// borrows are owned by the JS `result` and stay alive through this call.
fn stageLargeResponse(id: usize, header_len: usize, body_ptr: [*]const u8, blen: usize) void {
    write_lens[id] = header_len;
    write_offsets[id] = 0;
    if (blen <= BODY_BUF_SIZE) {
        @memcpy(body_bufs[id][0..blen], body_ptr[0..blen]);
        cflags[id].body_from_heap = false;
    } else {
        _ = stat_body_spill.fetchAdd(1, .release);
        // Reuse capacity when the previous spill still fits: avoids a
        // free+dupe cycle on every large response (body_lens tracks the
        // logical length; the drain reads [body_source_off..][0..n]).
        if (body_heap[id]) |old| {
            if (old.len >= blen) {
                _ = stat_body_spill_reuse.fetchAdd(1, .release);
                @memcpy(old[0..blen], body_ptr[0..blen]);
                body_lens[id] = blen;
                body_remaining[id] = blen;
                body_source_off[id] = 0;
                cflags[id].body_from_heap = true;
                return;
            }
            gpa.free(old);
            body_heap[id] = null;
        }
        body_heap[id] = gpa.dupe(u8, body_ptr[0..blen]) catch {
            buildResponse(id, 500, "Internal Server Error");
            return;
        };
        cflags[id].body_from_heap = true;
    }
    body_lens[id] = blen; // total staged body size
    body_remaining[id] = blen; // bytes not yet copied into write_bufs
    body_source_off[id] = 0; // read cursor into staged body
}

/// Format the H1 header block into write_bufs[id] and return its length.
/// `body_len` is what Content-Length advertises (for HEAD it stays the GET
/// length while `suppress` drops the bytes). Body staging columns are reset
/// by the caller before publishing anything.
fn formatHead(
    id: usize,
    status: u16,
    status_text: []const u8,
    hdrs: ?*headers_mod.HeadersData,
    body_len: usize,
    suppress: bool,
) usize {
    const w: *[WRITE_BUF_SIZE]u8 = &write_bufs[id];
    var pos: usize = 0;

    pushStr(w, &pos, "HTTP/1.1 ");
    appendUInt(w, &pos, status);
    pushStr(w, &pos, " ");
    if (status_text.len > 0 and std.mem.indexOfAny(u8, status_text, "\r\n") == null) {
        pushStr(w, &pos, status_text);
    } else {
        pushStr(w, &pos, statusReason(status));
    }
    pushStr(w, &pos, "\r\n");

    // User headers from the Response's HeadersData (already lowercased).
    // Drop CR/LF-bearing pairs (header-injection guard).
    var seen_ct = false;
    if (hdrs) |h| {
        for (0..h.len()) |i| {
            const p = h.getPair(i);
            if (isManagedHeader(p.name)) continue;
            if (std.mem.indexOfAny(u8, p.name, "\r\n") != null or
                std.mem.indexOfAny(u8, p.value, "\r\n") != null) continue;
            if (std.ascii.eqlIgnoreCase(p.name, "content-type")) seen_ct = true;
            if (pos + p.name.len + p.value.len + 4 > HDR_MAX) break;
            pushStr(w, &pos, p.name);
            pushStr(w, &pos, ": ");
            pushStr(w, &pos, p.value);
            pushStr(w, &pos, "\r\n");
        }
    }
    // Back-compat default content type only when JS gave none.
    if (!seen_ct and body_len > 0 and !suppress) {
        pushStr(w, &pos, "Content-Type: text/plain\r\n");
    }
    if (status != 204 and status != 304) {
        pushStr(w, &pos, "Content-Length: ");
        appendUInt(w, &pos, body_len);
        pushStr(w, &pos, "\r\n");
    }
    if (cflags[id].keep_alive) {
        pushStr(w, &pos, "Connection: keep-alive\r\n");
    } else if (closing_server) {
        pushStr(w, &pos, "Connection: close\r\n");
    }
    pushStr(w, &pos, "\r\n");
    return pos;
}

/// Clear the per-response body staging state (and its source discriminant).
fn resetBodyStaging(id: usize) void {
    write_offsets[id] = 0;
    body_lens[id] = 0;
    body_remaining[id] = 0;
    body_source_off[id] = 0;
    cflags[id].body_from_heap = false;
}

// NEW: shared response staging — used by the sync path and the parked
// continuation. Reads Response objects natively (opaque pointer, no JS
// property lookups), plain objects via properties (back-compat). User
// headers serialize straight into write_bufs — zero dynamic allocations.
//
// The plain-object string path formats the head FIRST (it depends only on
// status/headers) and then copies the body exactly once into its final home
// while the JS borrow is still alive. That is both the UAF fix and the reason
// there is no second memcpy on the common path.
fn stageHandlerResponse(id: usize, result: c.Value) void {
    if (cflags[id].h2_active) {
        http2_mod.respondH2(id, result);
        return;
    }
    const ctx = handler_ctx orelse {
        buildResponse(id, 500, "Internal Server Error");
        return;
    };

    var status: u16 = 200;
    var status_text: []const u8 = "";
    var body_bytes: []const u8 = "";
    var has_body = false;
    var hdrs: ?*headers_mod.HeadersData = null;

    if (c.isObject(result) != 0) {
        if (response_mod.dataFromJS(ctx, result)) |rd| {
            // Response instance: body/headers point into ResponseData, which
            // is owned by `result` and outlives this function. Borrow is safe.
            status = rd.status;
            status_text = rd.statusText();
            if (rd.body()) |b| {
                body_bytes = b;
                has_body = true;
            }
            hdrs = rd.headers;
        } else {
            // Plain JS object fallback: { status, body }.
            const status_val = c.getPropertyStr(ctx, result, "status");
            defer c.freeValue(ctx, status_val);
            status = extractInt(ctx, status_val, 200);

            const suppress = !wantsBodyBytes(id, status);
            const body_out_val = c.getPropertyStr(ctx, result, "body");
            defer c.freeValue(ctx, body_out_val);
            if (c.isString(body_out_val) != 0) {
                if (c.toCString(ctx, body_out_val)) |cstr| {
                    // BORROW LIFETIME: this cstring is freed by the defer below
                    // when THIS block exits. JS_ToCString returns the internal
                    // buffer only for plain-ASCII JS_STRING_KIND_NORMAL strings;
                    // non-ASCII text and >1024-byte String.prototype.slice get a
                    // fresh allocation that IS freed. Head + body are therefore
                    // produced inside this block, never after it.
                    defer c.freeCString(ctx, cstr);
                    const n = std.mem.len(cstr);
                    if (n > MAX_BODY_SIZE) {
                        buildResponse(id, 500, "response body too large");
                        return;
                    }
                    // Advertise the real length even for HEAD (suppress only
                    // drops the bytes), matching the generic path and RFC 9110.
                    const pos = formatHead(id, status, "", null, n, suppress);
                    write_lens[id] = pos;
                    resetBodyStaging(id);
                    if (suppress or n == 0) return;
                    if (pos + n <= WRITE_BUF_SIZE) {
                        @memcpy(write_bufs[id][pos..][0..n], cstr[0..n]);
                        write_lens[id] = pos + n;
                        return;
                    }
                    if (stageBodyBytes(id, cstr[0..n]) == null) {
                        buildResponse(id, 500, "Internal Server Error");
                        return;
                    }
                    publishStagedBody(id, n);
                    return;
                }
            } else if (c.isObject(body_out_val) != 0) {
                // ArrayBuffer storage is owned by body_out_val, which stays
                // alive until this function returns. Borrow is safe.
                var size: usize = 0;
                const p = c.getArrayBuffer(ctx, &size, body_out_val);
                if (p != null and size > 0) {
                    body_bytes = p[0..size];
                    has_body = true;
                }
            }
        }
    }

    // Generic path: Response instance / ArrayBuffer body (owned by `result`).
    const suppress = !wantsBodyBytes(id, status);
    if (has_body and !suppress and body_bytes.len > MAX_BODY_SIZE) {
        buildResponse(id, 500, "response body too large");
        return;
    }
    const pos = formatHead(id, status, status_text, hdrs, body_bytes.len, suppress);
    write_lens[id] = pos;
    resetBodyStaging(id);

    if (suppress or !has_body or body_bytes.len == 0) return;

    if (pos + body_bytes.len <= WRITE_BUF_SIZE) {
        @memcpy(write_bufs[id][pos..][0..body_bytes.len], body_bytes);
        write_lens[id] = pos + body_bytes.len;
        return;
    }
    stageLargeResponse(id, pos, body_bytes.ptr, body_bytes.len);
}
/// Claim a parked slot from a reaction's packed magic. Returns null when the
/// connection was closed, the handler already settled, or the token is stale.
//
// Identity is a GLOBAL 15-bit token, not (slot | truncated slot_gen).
// Rationale: QuickJS stores C-function magic in int16_t, so the old encoding
// had only 6 bits for the generation (slot 9 + gen 6). A client that opens and
// closes 64 connections recycles a slot's counter, after which a late promise
// reaction passed the check and completeParked() wrote the OLD response onto
// the NEW peer's socket. A global counter can only collide after 2^15 parks,
// and handler_parked is re-checked on the slot actually found.
var park_seq: u16 = 0; // 15-bit, 0 reserved for "no token"
var park_token: [MAX_CONN]u16 = [_]u16{0} ** MAX_CONN;

fn claimParkedSlot(magic: c_int) ?usize {
    const token: u16 = @intCast(@as(c_uint, @bitCast(magic)) & 0x7FFF);
    if (token == 0) return null;
    for (0..MAX_CONN) |id| {
        if (park_token[id] != token) continue;
        if (!cflags[id].handler_parked) return null;
        park_token[id] = 0; // one-shot: a duplicated reaction cannot re-claim
        return id;
    }
    return null;
}

fn completeParked(magic: c_int, argc: c_int, argv: [*c]c.Value, rejected: bool) c.Value {
    const id = claimParkedSlot(magic) orelse return c.JS_UNDEFINED;
    cflags[id].handler_parked = false;
    park_token[id] = 0;
    parked_since_ms[id] = 0;
    if (closing_server) cflags[id].keep_alive = false;

    const val: c.Value = if (argc > 0) argv[0] else c.JS_UNDEFINED;
    if (rejected) {
        printException(handler_ctx, val);
        buildResponse(id, 500, "Internal Server Error");
    } else {
        stageHandlerResponse(id, val);
    }
    // H2: the response was already queued by the stageHandlerResponse /
    // buildResponse H2 branches above — flush frames and chain pending
    // multiplexed streams instead of the H1 armWrite path.
    if (cflags[id].h2_active) {
        if (g_loop) |l| {
            http2_mod.completeParkedH2(id, l);
        } else {
            closeConn(id);
        }
        return c.JS_UNDEFINED;
    }
    if (g_loop) |l| {
        states[id] = .writing;
        armWrite(id, l);
    } else {
        closeConn(id);
    }
    return c.JS_UNDEFINED;
}

fn handlerFulfilledCb(
    _: ?*c.Context,
    _: c.Value,
    argc: c_int,
    argv: [*c]c.Value,
    magic: c_int,
) callconv(.c) c.Value {
    return completeParked(magic, argc, argv, false);
}

fn handlerRejectedCb(
    _: ?*c.Context,
    _: c.Value,
    argc: c_int,
    argv: [*c]c.Value,
    magic: c_int,
) callconv(.c) c.Value {
    return completeParked(magic, argc, argv, true);
}

/// Attach onFulfilled/onRejected to a pending handler promise. Zero
/// allocations on the Zig side: the park token travels in the C-function
/// magic (int16), continuations live in the slot columns.
fn parkHandler(id: usize, ctx: ?*c.Context, promise: c.Value) bool {
    park_seq = (park_seq +% 1) & 0x7FFF;
    if (park_seq == 0) park_seq = 1; // 0 = "no token"
    const token: u16 = park_seq;
    const magic: i32 = @intCast(token);
    const ok_fn = c.newCFunctionMagic(ctx, &handlerFulfilledCb, "", 1, c.JS_CFUNC_generic_magic, magic);
    const err_fn = c.newCFunctionMagic(ctx, &handlerRejectedCb, "", 1, c.JS_CFUNC_generic_magic, magic);
    defer c.freeValue(ctx, ok_fn);
    defer c.freeValue(ctx, err_fn);
    if (c.isException(ok_fn) != 0 or c.isException(err_fn) != 0) {
        const exc = c.getException(ctx);
        printException(ctx, exc);
        c.freeValue(ctx, exc);
        return false;
    }
    // Cached process-lifetime "then" atom (setupStrings); lazy fallback if
    // the server started without it. Atom 0 (newAtomLen OOM) → invoke throws,
    // same failure mode as before. No per-park intern/release. // ◀ FIX-3
    if (then_atom == 0) then_atom = c.newAtomLen(ctx, "then", 4); // ◀ FIX-3
    var then_argv = [_]c.Value{ ok_fn, err_fn };
    const then_result = c.invoke(ctx, promise, then_atom, 2, &then_argv);
    defer c.freeValue(ctx, then_result);
    if (c.isException(then_result) != 0) {
        const exc = c.getException(ctx);
        printException(ctx, exc);
        c.freeValue(ctx, exc);
        return false;
    }
    cflags[id].handler_parked = true;
    park_token[id] = token;
    parked_since_ms[id] = nowMs();
    return true;
}
pub fn isHandlerParked(id: usize) bool {
    return cflags[id].handler_parked;
}

/// Current incarnation of a connection slot. Handles carry it so a retained
/// JS object (ServerWebSocket, WebSocket) can never address a recycled slot.
pub fn slotGen(id: usize) u16 {
    return slot_gen[id];
}

/// H2 stream completed (END_STREAM): dispatch unless a handler is parked
/// (a parked slot leaves the stream complete+undispatched = pending, and
/// drainPending chains it after the parked promise settles).
pub fn h2StreamReady(id: usize, stream_id: i32) void {
    if (cflags[id].handler_parked) return;
    http2_mod.dispatchRequest(id, stream_id);
}

pub const MAX_REQ_HEADER_BYTES: usize = 64 * 1024;

fn parseHeaders(raw: []const u8) !*headers_mod.HeadersData {
    const data = headers_mod.acquire() orelse return error.OutOfMemory;
    errdefer data.release();

    var total_bytes: usize = 0;

    if (raw.len >= 10) {
        // Skip request line (up to first CRLF)
        const first_nl = std.mem.indexOfScalar(u8, raw, '\n') orelse raw.len;
        var i: usize = if (first_nl < raw.len) first_nl + 1 else raw.len;
        while (i < raw.len) {
            const line_start = i;
            while (i < raw.len and raw[i] != '\r' and raw[i] != '\n') i += 1;
            const line = raw[line_start..i];
            if (line.len == 0) break;
            if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                const raw_name = line[0..colon];
                const name = std.mem.trimEnd(u8, raw_name, " \t");
                const val = trimOws(line[colon + 1 ..]);
                if (name.len > 0) {
                    total_bytes += name.len + val.len;
                    if (total_bytes > MAX_REQ_HEADER_BYTES) {
                        return error.HeadersTooLarge;
                    }
                    data.appendEntry(name, val);
                }
            }
            while (i < raw.len and (raw[i] == '\r' or raw[i] == '\n')) i += 1;
        }
    }

    return data;
}

pub fn callHandler(id: usize, parsed: *const ParsedRequest, body: []const u8) void {
    callHandlerWithHeaders(id, parsed, body, null);
}

// callHandlerWithHeaders — shared by H1 and H2.
pub fn callHandlerWithHeaders(id: usize, parsed: *const ParsedRequest, body: []const u8, hdrs: ?*headers_mod.HeadersData) void {
    const ctx = handler_ctx orelse {
        if (hdrs) |h| h.release();
        buildResponse(id, 500, "");
        return;
    };
    const handler = handler_fn orelse {
        if (hdrs) |h| h.release();
        buildResponse(id, 500, "");
        return;
    };
    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);

    const url_val = c.newStringLen(ctx, parsed.url.ptr, @intCast(parsed.url.len));
    const method_val = c.newStringLen(ctx, parsed.method.ptr, @intCast(parsed.method.len));
    const body_val = if (body.len > 0)
        c.newStringLen(ctx, body.ptr, @intCast(body.len))
    else
        c.newStringLen(ctx, "", 0);
    const hdrs_val = if (hdrs) |h|
        headers_mod.createJSObject(ctx, h)
    else blk: {
        const empty_h = headers_mod.acquire() orelse break :blk c.JS_UNDEFINED;
        break :blk headers_mod.createJSObject(ctx, empty_h);
    };
    defer c.freeValue(ctx, url_val);
    defer c.freeValue(ctx, method_val);
    defer c.freeValue(ctx, body_val);
    defer c.freeValue(ctx, hdrs_val);

    var argv = [_]c.Value{ url_val, method_val, body_val, hdrs_val };
    var result = c.call(ctx, handler, global, 4, &argv);
    defer c.freeValue(ctx, result);

    if (c.isException(result) != 0) {
        const exc = c.getException(ctx);
        printException(ctx, exc);
        c.freeValue(ctx, exc);
        buildResponse(id, 500, "Internal Server Error");
        return;
    }

    if (promise_class_id != 0 and c.isObject(result) != 0 and
        c.getClassID(result) == promise_class_id)
    {
        const ps = c.promiseState(ctx, result);

        if (ps == 0) {
            if (parkHandler(id, ctx, result)) {
                if (builtin.mode == .Debug)
                    std.debug.print("[allocs] req id={d}: parked\n", .{id});
                return;
            }
            buildResponse(id, 500, "Internal Server Error");
            return;
        }
        if (ps == 2) {
            const pr = c.promiseResult(ctx, result);
            c.freeValue(ctx, result);
            result = pr;
            printException(ctx, pr);
            buildResponse(id, 500, "Internal Server Error");
            return;
        }
        const pr = c.promiseResult(ctx, result);
        c.freeValue(ctx, result);
        result = pr;
    }

    stageHandlerResponse(id, result);
}
pub const ws_class_id_val: c.ClassID = 0;

fn wsSocket(id: usize, ctx: ?*c.Context) ?c.Value {
    if (ws_sockets[id]) |v| return v;
    const obj = api_ws.makeSocket(ctx, @intCast(id), slot_gen[id]) orelse return null;
    ws_sockets[id] = obj;
    return obj;
}

fn wsNotify(id: usize, which: ?c.Value, argc: u32) void {
    const ctx = handler_ctx orelse return;
    const cb = which orelse return;
    if (c.isFunction(ctx, cb) == 0) return;
    const sock = wsSocket(id, ctx) orelse return;
    if (argc == 1) {
        var argv = [_]c.Value{sock};
        _ = c.call(ctx, cb, c.JS_UNDEFINED, 1, &argv);
    } else if (argc == 2) {
        var argv = [_]c.Value{ sock, sock };
        _ = c.call(ctx, cb, c.JS_UNDEFINED, 2, &argv);
    }
}

/// Copy `bytes` into a fresh JS Uint8Array view (binary WS messages arrive
/// as Uint8Array — matches every example in examples/ and Node's ws).
fn u8ArrayFromBytes(ctx: ?*c.Context, bytes: []const u8) c.Value {
    const ab = c.newArrayBufferCopy(ctx, bytes.ptr, bytes.len);
    if (c.getTag(ab) == c.TAG_EXCEPTION) return ab;
    defer c.freeValue(ctx, ab);
    var argv = [_]c.Value{
        ab,
        c.newInt32(ctx, 0),
        c.newInt32(ctx, @intCast(bytes.len)),
    };
    return c.newTypedArray(ctx, 3, &argv, c.JS_TYPED_ARRAY_UINT8);
}

fn wsNotifyMessage(id: usize, msg: []const u8, binary: bool) void {
    const ctx = handler_ctx orelse return;
    const cb = ws_on_message orelse return;
    if (c.isFunction(ctx, cb) == 0) return;
    const sock = wsSocket(id, ctx) orelse return;
    const data_val = if (binary)
        u8ArrayFromBytes(ctx, msg)
    else
        c.newStringLen(ctx, msg.ptr, @intCast(msg.len));
    defer c.freeValue(ctx, data_val);
    var argv = [_]c.Value{ sock, data_val };
    _ = c.call(ctx, cb, c.JS_UNDEFINED, 2, &argv);
}

/// Single reservation chokepoint for every WS writer. Reserves the frame's
/// full footprint (header + payload) before the column is touched, so no
/// sender can write past write_bufs[id]. The per-call-site checks were
/// incomplete (wsSendClose/wsSendCloseEcho had none): with write_lens at its
/// legal maximum of 16374, buf[MAX_HDR..] landed 2 bytes past the column and
/// into the neighbouring slot's buffer.
fn wsReserve(id: usize, n: usize) ?[]u8 {
    const tail = write_lens[id];
    if (tail > WRITE_BUF_SIZE - n) return null;
    return write_bufs[id][tail..][0..n];
}

pub fn wsSendTextUtf8(id: usize, str_val: c.Value, ctx: ?*c.Context) void {
    const s = str_val;
    if (!cflags[id].ws_open or states[id] == .closing) return;
    const cstr = c.toCString(ctx, s) orelse return;
    defer c.freeCString(ctx, cstr);
    const ulen = std.mem.len(cstr);
    if (ulen == 0) return;
    if (ulen > ws.WS_MSG_SIZE) {
        wsSendClose(id, 1009);
        return;
    }
    if (!cflags[id].ws_writing) {
        write_lens[id] = 0;
        write_offsets[id] = 0;
        ws_batch[id] = 0;
    }
    const region = wsReserve(id, ws.MAX_HDR + ulen) orelse return;
    @memcpy(region[ws.MAX_HDR..][0..ulen], cstr[0..ulen]);
    const hlen = ws.buildHeader(region, ws.OP_TEXT, true, ulen);
    if (hlen != ws.MAX_HDR) @memmove(region[hlen..][0..ulen], region[ws.MAX_HDR..][0..ulen]);
    write_lens[id] += @as(usize, hlen) + ulen;
    if (!cflags[id].ws_writing) wsKick(id);
}

pub fn wsSendBinary(id: usize, bytes: []const u8) void {
    if (!cflags[id].ws_open or states[id] == .closing) return;
    if (bytes.len > ws.WS_MSG_SIZE) {
        wsSendClose(id, 1009);
        return;
    }
    if (!cflags[id].ws_writing) {
        write_lens[id] = 0;
        write_offsets[id] = 0;
        ws_batch[id] = 0;
    }
    const region = wsReserve(id, ws.MAX_HDR + bytes.len) orelse return;
    @memcpy(region[ws.MAX_HDR..][0..bytes.len], bytes);
    const hlen = ws.buildHeader(region, ws.OP_BINARY, true, bytes.len);
    // FIX: move bytes.len payload bytes (was hlen — corrupts non-10B headers).
    if (hlen != ws.MAX_HDR) @memmove(region[hlen..][0..bytes.len], region[ws.MAX_HDR..][0..bytes.len]);
    write_lens[id] += @as(usize, hlen) + bytes.len;
    if (!cflags[id].ws_writing) wsKick(id);
}

pub fn wsSendClose(id: usize, code: u16) void {
    if (states[id] == .closing) return;
    if (!cflags[id].ws_open) {
        closeConn(id);
        return;
    }
    if (!cflags[id].ws_writing) {
        write_lens[id] = 0;
        write_offsets[id] = 0;
        ws_batch[id] = 0;
    }
    var payload: [2]u8 = undefined;
    payload[0] = @intCast(code >> 8);
    payload[1] = @intCast(code & 0xff);
    const region = wsReserve(id, ws.MAX_HDR + 2) orelse {
        // Cannot fit: tear the connection down rather than corrupt the column.
        wsShutdown(id);
        closeConn(id);
        return;
    };
    @memcpy(region[ws.MAX_HDR..][0..2], &payload);
    const hlen = ws.buildHeader(region, ws.OP_CLOSE, true, 2);
    if (hlen != ws.MAX_HDR) @memmove(region[hlen..][0..2], region[ws.MAX_HDR..][0..2]);
    write_lens[id] += @as(usize, hlen) + 2;
    cflags[id].ws_close_after_write = true;
    if (!cflags[id].ws_writing) wsKick(id);
}

fn wsSendCloseEcho(id: usize, payload: []const u8) void {
    if (states[id] == .closing) return;
    if (!cflags[id].ws_writing) {
        write_lens[id] = 0;
        write_offsets[id] = 0;
        ws_batch[id] = 0;
    }
    const plen: usize = @min(payload.len, 2);
    const region = wsReserve(id, ws.MAX_HDR + plen) orelse {
        wsShutdown(id);
        closeConn(id);
        return;
    };
    @memcpy(region[ws.MAX_HDR..][0..plen], payload[0..plen]);
    const hlen = ws.buildHeader(region, ws.OP_CLOSE, true, plen);
    if (hlen != ws.MAX_HDR) @memmove(region[hlen..][0..plen], region[ws.MAX_HDR..][0..plen]);
    write_lens[id] += @as(usize, hlen) + plen;
    cflags[id].ws_close_after_write = true;
    if (!cflags[id].ws_writing) wsKick(id);
}

fn wsSendPong(id: usize, payload: []const u8) void {
    if (!cflags[id].ws_writing) {
        write_lens[id] = 0;
        write_offsets[id] = 0;
        ws_batch[id] = 0;
    }
    const plen: usize = @min(payload.len, ws.WS_MSG_SIZE);
    const region = wsReserve(id, ws.MAX_HDR + plen) orelse return;
    @memcpy(region[ws.MAX_HDR..][0..plen], payload[0..plen]);
    const hlen = ws.buildHeader(region, ws.OP_PONG, true, plen);
    if (hlen != ws.MAX_HDR) @memmove(region[hlen..][0..plen], region[ws.MAX_HDR..][0..plen]);
    write_lens[id] += @as(usize, hlen) + plen;
    if (!cflags[id].ws_writing) wsKick(id);
}

// DOD-FIX 4: ws_partial is now a static per-slot byte array (no heap pointer).
fn wsHandleData(id: usize, hdr: ws.FrameHdr, payload: []const u8) bool {
    if (ws.isData(hdr.opcode)) {
        // A new data frame while a fragmented message is open is a protocol
        // error. "Open" is a bit, not `ws_partial_len != 0`: RFC 6455
        // permits a zero-length first fragment, which leaves the length at 0
        // and would otherwise make the legal continuation look spurious.
        if (wsFragmentOpen(id)) {
            wsSendClose(id, 1002);
            return false;
        }
        if (hdr.fin) {
            // RFC 6455 §5.6 / §8.1: a complete text message must be UTF-8.
            if (hdr.opcode == ws.OP_TEXT and !ws.validUtf8(payload)) {
                wsSendClose(id, 1007);
                return false;
            }
            wsNotifyMessage(id, payload, hdr.opcode == ws.OP_BINARY);
            return true;
        }
        if (payload.len > ws.WS_MSG_SIZE) {
            wsSendClose(id, 1009);
            return false;
        }
        wsSetPartialBinary(id, hdr.opcode == ws.OP_BINARY);
        @memcpy(ws_partial[id][0..payload.len], payload);
        ws_partial_len[id] = payload.len;
        wsSetFragmentOpen(id, true);
        return true;
    }
    if (!wsFragmentOpen(id)) {
        wsSendClose(id, 1002); // continuation with nothing to continue
        return false;
    }
    if (ws_partial_len[id] + payload.len > ws.WS_MSG_SIZE) {
        wsSendClose(id, 1009);
        ws_partial_len[id] = 0;
        wsSetFragmentOpen(id, false);
        return false;
    }
    @memcpy(ws_partial[id][ws_partial_len[id]..][0..payload.len], payload);
    ws_partial_len[id] += payload.len;
    if (hdr.fin) {
        const msg = ws_partial[id][0..ws_partial_len[id]];
        // Validate the ASSEMBLED message: a multi-byte code point may be split
        // across fragments, so per-fragment validation would be wrong.
        if (!wsPartialBinary(id) and !ws.validUtf8(msg)) {
            ws_partial_len[id] = 0;
            wsSetFragmentOpen(id, false);
            wsSendClose(id, 1007);
            return false;
        }
        wsNotifyMessage(id, msg, wsPartialBinary(id));
        ws_partial_len[id] = 0;
        wsSetFragmentOpen(id, false);
    }
    return true;
}

fn wsConsume(id: usize, l: *xev.Loop) void {
    var leftover = read_bufs[id][0..buf_lens[id]];
    while (leftover.len > 0) {
        const hdr = ws.parseHeader(leftover) orelse break;
        // RFC 6455 §5.1: every client->server frame MUST be masked. Accepting
        // unmasked frames lets a cache/proxy treat the stream as HTTP, and it
        // deviates from every other server.
        if (!hdr.masked) {
            wsSendClose(id, 1002);
            return;
        }
        // §5.2: reserved opcodes are protocol errors.
        if (!ws.isValidOpcode(hdr.opcode)) {
            wsSendClose(id, 1002);
            return;
        }
        // §5.5: control frames are ≤125 bytes and never fragmented.
        if (!ws.controlFrameOk(hdr)) {
            wsSendClose(id, 1002);
            return;
        }
        if (hdr.payload_len > ws.WS_MSG_SIZE and !ws.isControl(hdr.opcode)) {
            wsSendClose(id, 1009);
            return;
        }
        const total = @as(usize, hdr.header_len) + hdr.payload_len;
        if (leftover.len < total) break;
        const payload = leftover[hdr.header_len..total];
        ws.unmask(payload, hdr.mask);
        switch (hdr.opcode) {
            ws.OP_PING => wsSendPong(id, payload),
            ws.OP_PONG => {},
            ws.OP_CLOSE => {
                wsSendCloseEcho(id, payload);
                return;
            },
            else => {
                if (!wsHandleData(id, hdr, payload)) return;
            },
        }
        leftover = leftover[total..];
    }
    buf_lens[id] = leftover.len;
    if (leftover.len > 0) {
        @memmove(read_bufs[id][0..leftover.len], leftover);
    }
    if (states[id] == .reading and !cflags[id].ws_writing) armReadId(id, l);
}

fn wsNotifyOpen(id: usize) void {
    wsNotify(id, ws_on_open, 1);
}

fn wsNotifyClose(id: usize) void {
    wsNotify(id, ws_on_close, 1);
}

fn wsShutdown(id: usize) void {
    if (!cflags[id].ws_open) return;
    wsNotifyClose(id);
    if (ws_sockets[id]) |v| {
        c.freeValue(handler_ctx, v);
        ws_sockets[id] = null;
    }
    cflags[id].ws_open = false;
    ws_partial_len[id] = 0;
    wsSetPartialBinary(id, false);
    wsSetFragmentOpen(id, false);
    cflags[id].ws_close_after_write = false;
    cflags[id].ws_writing = false;
}

fn tryUpgrade(id: usize, l: *xev.Loop, headers_end: usize, pr: *const ParsedRequest) void {
    // The handshake was fully validated by parseRequest (method GET, HTTP/1.1,
    // Upgrade/Connection tokens, version 13, 24-char base64 key) and an upgrade
    // is rejected unless content_length == 0. So headers_end is the only
    // consumed span, and this subtraction cannot underflow.
    const key = pr.ws_key;
    if (key.len != 24 or headers_end > buf_lens[id]) {
        rejectWith(id, l, 400, "Bad Request");
        return;
    }
    var accept: [28]u8 = undefined;
    ws.computeAccept(key, &accept);
    const w: *[WRITE_BUF_SIZE]u8 = &write_bufs[id];
    var pos: usize = 0;
    pushStr(w, &pos, "HTTP/1.1 101 Switching Protocols\r\n");
    pushStr(w, &pos, "Upgrade: websocket\r\n");
    pushStr(w, &pos, "Connection: Upgrade\r\n");
    pushStr(w, &pos, "Sec-WebSocket-Accept: ");
    @memcpy(w[pos..][0..28], &accept);
    pos += 28;
    pushStr(w, &pos, "\r\n\r\n");
    write_lens[id] = pos;
    const rest = buf_lens[id] - headers_end;
    if (rest > 0) @memmove(read_bufs[id][0..rest], read_bufs[id][headers_end..buf_lens[id]]);
    buf_lens[id] = rest;
    hdr_scan_off[id] = 0;
    req_consumed[id] = 0;
    cflags[id].ws_open = true;
    cflags[id].ws_writing = true;
    cflags[id].ws_close_after_write = false;
    cflags[id].ws_pending_open = true;
    ws_partial_len[id] = 0;
    wsSetPartialBinary(id, false);
    wsSetFragmentOpen(id, false);
    states[id] = .writing;
    write_offsets[id] = 0;
    ws_batch[id] = write_lens[id];
    armWrite(id, l);
}
// CHANGED: clears parked state so a late continuation no-ops.

fn closeConn(id: usize) void {
    http2_mod.removeSession(id);
    if (body_heap[id]) |old| {
        gpa.free(old);
        body_heap[id] = null;
    } // ← FIX
    destroyReqSpill(id);
    body_remaining[id] = 0;
    body_source_off[id] = 0;
    body_lens[id] = 0;
    cflags[id].body_from_heap = false;
    cflags[id].handler_parked = false; // NEW
    park_token[id] = 0; // a token from this incarnation must not be claimable
    parked_since_ms[id] = 0; // NEW
    deadline_ms[id] = 0;
    wsShutdown(id);
    if (states[id] == .closing) return;
    if (tls_on and cflags[id].tls) {
        tls_mod.shutdown(&tls_ctxs[id]); // close_notify
        tls_mod.flush(&tls_ctxs[id]);
        const out = tls_mod.sendRecReady(&tls_ctxs[id]);
        if (out.len > 0) {
            states[id] = .closing;
            cflags[id].tls_close_after_write = true;
            const l = g_loop orelse {
                hardClose(id);
                return;
            };
            fds[id].write(l, &write_comps[id], .{ .slice = out }, u16, &slot_ids[id], writeCb);
            return;
        }
    }
    hardClose(id);
}

fn closeCb(
    ud: ?*u16,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    r: xev.CloseError!void,
) xev.CallbackAction {
    _ = r catch {};
    const raw = ud orelse return .disarm;
    const id: usize = @intCast(raw.*);
    states[id] = .idle;
    deadline_ms[id] = 0;
    freePush(id);
    _ = checkDrainComplete();
    return .disarm;
}

fn watchdogCancelCb(
    _: ?*void,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.CancelError!void,
) xev.CallbackAction {
    _ = r catch {};
    return .disarm;
}

fn shutdownCancelCb(
    _: ?*void,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.CancelError!void,
) xev.CallbackAction {
    _ = r catch {};
    return .disarm;
}

/// Independent hard deadline. Unlike the watchdog this cannot be stopped by a
/// partial drain, so a stuck H2 stream or slow H1 request cannot keep
/// server.close() pending forever.
fn shutdownDeadlineCb(
    _: ?*void,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch {};
    shutdown_timer_started = false;
    if (!closing_server) return .disarm;
    for (0..MAX_CONN) |id| {
        if (states[id] != .idle) {
            hardClose(id);
        }
    }
    _ = checkDrainComplete();
    return .disarm;
}

// NEW: watchdog — one repeating timer (not from the 128-slot JS timer
// pool): expires stalled request reads and fails hung handlers with 504.
// Both passes are dense-column sweeps over MAX_CONN; no per-connection timer
// object is created, so the hot path keeps its zero-allocation contract.
fn watchdogCb(
    _: ?*void,
    l: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch return .disarm;
    if (closing_server and free_count == MAX_CONN and listener_closed) {
        watchdog_started = false;
        _ = checkDrainComplete();
        return .disarm;
    }
    const now = nowMs();

    // Pass 1 — slowloris / idle keep-alive. Only connections WAITING for
    // request bytes are expired: .writing is progress, and a parked handler
    // is governed by HANDLER_TIMEOUT_MS below.
    for (0..MAX_CONN) |id| {
        if (cflags[id].handler_parked) continue;
        if (states[id] != .reading) continue;
        if (deadline_ms[id] == 0 or now < deadline_ms[id]) continue;
        closeConn(id);
    }

    // Pass 2 — parked handlers.
    for (0..MAX_CONN) |id| {
        if (!cflags[id].handler_parked) continue;
        if (now -% parked_since_ms[id] < HANDLER_TIMEOUT_MS) continue;
        cflags[id].handler_parked = false;
        park_token[id] = 0;
        parked_since_ms[id] = 0;
        buildResponse(id, 504, "Gateway Timeout");
        if (cflags[id].h2_active) {
            http2_mod.flushNow(id, l);
            http2_mod.drainPending(id);
            http2_mod.flushNow(id, l);
            continue;
        }
        states[id] = .writing;
        armWrite(id, l);
    }
    if (closing_server) {
        // H2 sessions may finish their last stream after GOAWAY was sent.
        // Nothing else will necessarily write again, so sweep them here.
        // Skip sessions with an armed write: writeCb closes them after the
        // outstanding completion drains, avoiding a double-push of
        // write_comps.
        for (0..MAX_CONN) |id| {
            if (cflags[id].h2_active and
                http2_mod.isShouldClose(id) and
                !http2_mod.isWriteArmed(id))
            {
                closeConn(id);
            }
        }
        if (shutdown_deadline_ms != 0 and now >= shutdown_deadline_ms) {
            for (0..MAX_CONN) |id| {
                if (states[id] != .idle) hardClose(id);
            }
        }
    }
    if (closing_server and free_count == MAX_CONN and listener_closed) {
        watchdog_started = false;
        _ = checkDrainComplete();
        return .disarm;
    }
    watchdog_timer.run(l, &watchdog_comp, WATCHDOG_INTERVAL_MS, void, null, watchdogCb);
    return .disarm;
}

// Bumps the accept counter, resets per-slot state (the cflags reset below
// also clears handler_parked and body_from_heap; park_token and the fragment
// bit are separate columns and are invalidated explicitly).
fn setupSlot(l: *xev.Loop, tcp: xev.TCP) bool {
    const id = freePop() orelse {
        _ = std.c.close(tcp.fd);
        return false;
    };
    fds[id] = tcp;
    slot_gen[id] +%= 1; // NEW
    parked_since_ms[id] = 0; // NEW
    park_token[id] = 0; // the new incarnation owns no park token
    deadline_ms[id] = nowMs() + CONN_TIMEOUT_MS;
    const nodelay: c_int = 1;
    std.posix.setsockopt(
        tcp.fd,
        std.posix.IPPROTO.TCP,
        std.posix.TCP.NODELAY,
        std.mem.asBytes(&nodelay),
    ) catch {};
    states[id] = .reading;
    methods[id] = Method.none;
    buf_lens[id] = 0;
    req_consumed[id] = 0; // F4
    hdr_scan_off[id] = 0;
    write_lens[id] = 0;
    write_offsets[id] = 0;
    if (body_heap[id]) |old| {
        gpa.free(old);
        body_heap[id] = null;
    } // ← FIX
    destroyReqSpill(id);
    body_remaining[id] = 0;
    body_source_off[id] = 0;
    body_lens[id] = 0;
    setReadArmed(id, false);
    cflags[id] = .{ .keep_alive = !closing_server, .ws_read_armed = true, .tls = tls_active };
    http2_mod.resetSlot(id);
    ws_partial_len[id] = 0;
    wsSetPartialBinary(id, false);
    wsSetFragmentOpen(id, false);
    if (tls_on and tls_active) tls_mod.slotInit(&tls_ctxs[id], &tls_iobufs[id]);
    armRead(id, l);
    return true;
}

fn acceptCb(
    _: ?*void,
    l: *xev.Loop,
    _: *xev.Completion,
    r: xev.AcceptError!xev.TCP,
) xev.CallbackAction {
    if (closing_server or !initialized) {
        accept_armed = false;
        if (r) |tcp| {
            _ = std.c.close(tcp.fd);
        } else |_| {}
        _ = checkDrainComplete();
        return .disarm;
    }
    const first = r catch |err| {
        if (closing_server or !initialized) {
            accept_armed = false;
            _ = checkDrainComplete();
            return .disarm;
        }
        // Never silently re-arm: a persistent accept failure with no log
        // looks exactly like a backend stall (see io_uring accept-drain bug).
        if (builtin.mode == .Debug)
            std.debug.print("[http] accept error: {s} — re-arming\n", .{@errorName(err)});
        listener_tcp.accept(l, &accept_comp, void, null, acceptCb);
        return .disarm;
    };
    // DOD-FIX (io_uring stall): libxev creates io_uring sockets BLOCKING
    // (watcher/tcp.zig: "On io_uring we don't use non-blocking sockets…"),
    // so the raw batch drain below would block the event loop inside this
    // callback when the backlog empties. On io_uring the accept SQE re-arm
    // below is cheap (batched SQ submission) — one connection per completion.
    // comptime gate: epoll/kqueue paths are byte-identical to before.
    if (xev.backend != .io_uring) {
        var budget: usize = ACCEPT_BATCH;
        if (setupSlot(l, first)) budget -= 1;
        while (budget > 0) : (budget -= 1) {
            const rc = std.c.accept(listener_tcp.fd, null, null);
            if (std.posix.errno(rc) != .SUCCESS) break;
            const fd: std.posix.socket_t = @intCast(rc);
            if (!setupSlot(l, xev.TCP.initFd(fd))) break;
        }
    } else {
        _ = setupSlot(l, first);
    }
    if (closing_server or !initialized) {
        accept_armed = false;
        _ = checkDrainComplete();
        return .disarm;
    }
    listener_tcp.accept(l, &accept_comp, void, null, acceptCb);
    return .disarm;
}

fn readCb(
    ud: ?*u16,
    l: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    _: xev.ReadBuffer,
    r: xev.ReadError!usize,
) xev.CallbackAction {
    const raw = ud orelse return .disarm;
    const id: usize = @intCast(raw.*);
    setReadArmed(id, false);
    cflags[id].ws_read_armed = false;
    cflags[id].tls_read_armed = false;
    if (states[id] == .closing or states[id] == .idle) return .disarm;
    const n = r catch {
        closeConn(id);
        return .disarm;
    };
    if (n == 0) {
        closeConn(id);
        return .disarm;
    }
    // Progress: extend the read deadline. Covers plain HTTP, TLS handshake
    // records and WS frames alike — anything still trickling bytes keeps the
    // slot; a stalled peer loses it to the watchdog.
    deadline_ms[id] = nowMs() + CONN_TIMEOUT_MS;
    if (tls_on and cflags[id].tls) {
        tls_mod.recvRecAck(&tls_ctxs[id], n);
        tlsPump(id, l);
        return .disarm;
    }
    if (cflags[id].req_body_spill) {
        // Plain sockets were armed to read straight into the spill tail.
        req_spill_len[id] += n;
        continueReqSpill(id, l);
        return .disarm;
    }
    buf_lens[id] += n;
    processPlaintext(id, l);
    return .disarm;
}
/// HTTP/WS state machine over bytes in read_bufs[0..buf_lens]
/// (plaintext for plain HTTP, decrypted app-data when TLS is active).
fn processPlaintext(id: usize, l: *xev.Loop) void {
    // HTTP/2 path runs BEFORE the handler_parked early-return so multiplexed
    // streams keep flowing while one stream's promise is parked.
    if (cflags[id].h2_active) {
        // B1 FIX: iterate instead of recursing (was: tail-call
        // processPlaintext per consumed frame — stack grew ~16KB per
        // frame in a burst; now bounded flat).
        while (true) {
            const used = http2_mod.onRecv(id, read_bufs[id][0..buf_lens[id]], l);
            if (used == http2_mod.FATAL) {
                closeConn(id);
                return;
            }
            const rem = buf_lens[id] - used;
            if (rem == 0) {
                buf_lens[id] = 0;
                break;
            }
            @memmove(read_bufs[id][0..rem], read_bufs[id][used..buf_lens[id]]);
            buf_lens[id] = rem;
            // Progress made: re-feed immediately. Otherwise (incomplete
            // frame, nothing consumed) fall through and wait for more bytes.
            if (used == 0) break;
        }
        states[id] = .reading;
        // NOTE: never tlsPump() here. pumpWrite (via onRecv's flushNow
        // above) already armed the write and its ciphertext; a nested pump
        // would re-write on the same completion (intrusive double-push →
        // libxev "invalid state in submission queue"). Ciphertext drains
        // via writeCb; just rearm the read.
        armRead(id, l);
        return;
    }
    if (cflags[id].handler_parked) {
        return;
    }
    if (cflags[id].ws_open) {
        wsConsume(id, l);
        return;
    }
    const scan_from = if (hdr_scan_off[id] > 3) hdr_scan_off[id] - 3 else 0;
    const he_found = findHeaderEnd(read_bufs[id][0..buf_lens[id]], scan_from);
    if (he_found == null) {
        hdr_scan_off[id] = buf_lens[id];
        if (buf_lens[id] >= READ_BUF_SIZE) {
            rejectWith(id, l, 431, "Request Header Fields Too Large");
            return;
        }
        armRead(id, l);
        return;
    }
    const headers_end = he_found.? + 4;
    hdr_scan_off[id] = 0;
    const pr = parseRequest(read_bufs[id][0..buf_lens[id]], headers_end);
    methods[id] = pr.method_tag;

    // Framing first: an ambiguous message (dup CL, TE, obs-fold, BWS) must
    // never reach a handler, and it must not be reparsed by keep-alive.
    if (!pr.framing_ok) {
        if (pr.too_large) {
            rejectWith(id, l, 413, "Payload Too Large");
        } else {
            rejectWith(id, l, 400, "Bad Request");
        }
        return;
    }
    if (ws_enabled) {
        // Handshake decided by parseRequest's header table — NOT by scanning
        // the whole buffer for "sec-websocket-key:" (that made any request
        // whose BODY contained the token look like an upgrade).
        if (pr.ws_key.len != 0) {
            tryUpgrade(id, l, headers_end, &pr);
            return;
        }
        if (pr.ws_bad) {
            rejectWith(id, l, 400, "Bad Request");
            return;
        }
    }
    if (pr.method.len == 0) {
        rejectWith(id, l, 400, "Bad Request");
        return;
    }
    // Both terms are bounded by READ_BUF_SIZE/REQ_BODY_MAX, so this add
    // cannot wrap.
    const expect = headers_end + pr.content_length;
    if (expect > READ_BUF_SIZE) {
        const buf = ensureReqSpill(id, expect) orelse {
            rejectWith(id, l, 503, "Service Unavailable");
            return;
        };
        // Copy headers + any body already read. buf_lens <= READ_BUF_SIZE <
        // expect, so this cannot include a pipelined next request.
        @memcpy(buf[0..buf_lens[id]], read_bufs[id][0..buf_lens[id]]);
        req_hdr_end[id] = headers_end;
        req_spill_len[id] = buf_lens[id];
        req_spill_want[id] = expect;
        cflags[id].req_body_spill = true;
        cflags[id].keep_alive = pr.keep_alive and !closing_server;
        methods[id] = pr.method_tag;
        hdr_scan_off[id] = 0;
        buf_lens[id] = 0;
        continueReqSpill(id, l);
        return;
    }
    req_consumed[id] = expect; // F4: remember the consumed span for keep-alive
    if (buf_lens[id] < expect) {
        armRead(id, l);
        return;
    }
    cflags[id].keep_alive = pr.keep_alive and !closing_server;
    if (native_echo) {
        buildResponse(id, 200, "{\"message\":\"ok\"}");
    } else {
        const body = read_bufs[id][headers_end .. headers_end + pr.content_length];
        const hdrs = parseHeaders(read_bufs[id][0..headers_end]) catch |err| switch (err) {
            error.HeadersTooLarge => {
                rejectWith(id, l, 431, "Request Header Fields Too Large");
                return;
            },
            error.OutOfMemory => {
                rejectWith(id, l, 503, "Service Unavailable");
                return;
            },
        };
        callHandlerWithHeaders(id, &pr, body, hdrs);
    }
    if (cflags[id].h2_active) {
        http2_mod.flushNow(id, l);
        return;
    }
    if (!cflags[id].handler_parked) {
        states[id] = .writing;
        armWrite(id, l);
    } else {
        states[id] = .reading;
    }
}

//  keep-alive re-arm that preserves pipelined bytes. The finished request
// consumed read_bufs[0..req_consumed]; bytes beyond it belong to the next
// pipelined request and must survive (the old code zeroed buf_lens and
// re-read from offset 0, silently discarding them). Mirrors the WS leftover
// handling in wsConsume.
fn keepAlivePreserve(id: usize) void {
    const leftover = read_bufs[id][req_consumed[id]..buf_lens[id]];
    @memmove(read_bufs[id][0..leftover.len], leftover);
    buf_lens[id] = leftover.len;
    req_consumed[id] = 0;
    hdr_scan_off[id] = 0;
    // Idle keep-alive budget starts when the response finished, not when the
    // request bytes last arrived.
    deadline_ms[id] = nowMs() + CONN_TIMEOUT_MS;
}

fn keepAliveRearm(id: usize, l: *xev.Loop) void {
    keepAlivePreserve(id);
    states[id] = .reading;
    if (buf_lens[id] > 0) {
        if (findHeaderEnd(read_bufs[id][0..buf_lens[id]], 0)) |he| {
            const headers_end = he + 4;
            const pr = parseRequest(read_bufs[id][0..buf_lens[id]], headers_end);
            if (pr.method.len == 0 or buf_lens[id] >= headers_end + pr.content_length) {
                processPlaintext(id, l);
                return;
            }
        }
    }
    armRead(id, l);
}

pub fn writeCb(
    ud: ?*u16,
    l: *xev.Loop,
    _: *xev.Completion,
    tcp: xev.TCP,
    _: xev.WriteBuffer,
    r: xev.WriteError!usize,
) xev.CallbackAction {
    const raw = ud orelse return .disarm;
    const id: usize = @intCast(raw.*);
    const written = r catch {
        closeConn(id);
        return .disarm;
    };

    if (cflags[id].h2_active) {
        const tls_ctx_ptr = if (tls_on and cflags[id].tls) &tls_ctxs[id] else null;
        switch (http2_mod.onWriteComplete(id, written, tcp, l, tls_ctx_ptr)) {
            .drained => {
                if (http2_mod.isShouldClose(id) or (closing_server and !http2_mod.hasActiveStreams(id) and !cflags[id].handler_parked)) {
                    closeConn(id);
                    return .disarm;
                }
                states[id] = .reading;
                if (tls_on and cflags[id].tls) tlsPump(id, l) else armRead(id, l);
            },
            .more_pending => {},
        }
        return .disarm;
    }

    if (tls_on and cflags[id].tls) {
        tls_mod.sendRecAck(&tls_ctxs[id], written);
        const out = tls_mod.sendRecReady(&tls_ctxs[id]);
        if (out.len > 0) {
            tcp.write(l, &write_comps[id], .{ .slice = out }, u16, &slot_ids[id], writeCb);
            return .disarm;
        }
        write_lens[id] = 0;
        write_offsets[id] = 0;
        if (cflags[id].tls_close_after_write) {
            hardClose(id);
            return .disarm;
        }
        if (cflags[id].ws_open) {
            ws_batch[id] = 0;
            cflags[id].ws_writing = false;
            if (cflags[id].ws_pending_open) {
                cflags[id].ws_pending_open = false;
                wsNotifyOpen(id);
            }
            if (cflags[id].ws_close_after_write) {
                wsShutdown(id);
                hardClose(id);
                return .disarm;
            }
        } else if (body_lens[id] > 0) {
            // Large-body chunked write: load the next chunk from the staged body.
            if (write_lens[id] == 0) {
                const n = @min(WRITE_BUF_SIZE, body_remaining[id]);
                if (n > 0) {
                    // Source is the STORED discriminant, never re-derived:
                    // a retained spill outlives its response, so
                    // `body_heap[id] != null` (and `body_lens > BODY_BUF_SIZE`
                    // after reuse) can disagree with where the bytes are.
                    if (cflags[id].body_from_heap) {
                        const hp = body_heap[id].?;
                        @memcpy(write_bufs[id][0..n], hp[body_source_off[id]..][0..n]);
                    } else {
                        @memcpy(write_bufs[id][0..n], body_bufs[id][body_source_off[id]..][0..n]);
                    }
                    write_lens[id] = n;
                    write_offsets[id] = 0;
                    body_source_off[id] += n;
                    body_remaining[id] -= n;
                } else {
                    releaseSpillIfOversized(id); // ← FIX: retain ≤ cap for reuse
                    body_lens[id] = 0;
                    body_remaining[id] = 0;
                    body_source_off[id] = 0;
                    cflags[id].body_from_heap = false;
                }
            }
            if (write_lens[id] > 0) {
                armWrite(id, l);
                return .disarm;
            }
            if (cflags[id].keep_alive) {
                states[id] = .reading;
                keepAlivePreserve(id);
                tlsPump(id, l);
            } else {
                closeConn(id);
            }
            return .disarm;
        }
        if (write_lens[id] > 0) {
            armWrite(id, l);
            return .disarm;
        }
        if (cflags[id].ws_open) {
            if (!cflags[id].ws_read_armed) tlsPump(id, l);
            return .disarm;
        }
        if (cflags[id].keep_alive) {
            states[id] = .reading;
            keepAlivePreserve(id);
            tlsPump(id, l);
        } else {
            closeConn(id);
        }
        return .disarm;
    }

    if (cflags[id].ws_open) {
        write_offsets[id] += written;
        if (write_offsets[id] < ws_batch[id]) {
            ws_batch[id] = write_lens[id];
            tcp.write(l, &write_comps[id], .{ .slice = write_bufs[id][write_offsets[id]..write_lens[id]] }, u16, &slot_ids[id], writeCb);
            return .disarm;
        }
        const staged = write_lens[id] - ws_batch[id];
        if (staged > 0) {
            const src_end = write_lens[id];
            @memmove(write_bufs[id][0..staged], write_bufs[id][(src_end - staged)..src_end]);
            write_lens[id] = staged;
            wsKick(id);
            return .disarm;
        }
        write_lens[id] = 0;
        write_offsets[id] = 0;
        ws_batch[id] = 0;
        cflags[id].ws_writing = false;
        if (cflags[id].ws_pending_open) {
            cflags[id].ws_pending_open = false;
            wsNotifyOpen(id);
        }
        if (cflags[id].ws_close_after_write) {
            wsShutdown(id);
            closeConn(id);
            return .disarm;
        }
        if (!cflags[id].ws_read_armed) {
            states[id] = .reading;
            armReadId(id, l);
        }
        return .disarm;
    }

    write_offsets[id] += written;

    if (body_lens[id] > 0) {
        if (write_offsets[id] >= write_lens[id]) {
            const n = @min(WRITE_BUF_SIZE, body_remaining[id]);
            if (n == 0) {
                releaseSpillIfOversized(id); // ← FIX: retain ≤ cap for reuse
                body_lens[id] = 0;
                body_remaining[id] = 0;
                body_source_off[id] = 0;
                write_lens[id] = 0;
                write_offsets[id] = 0;
                cflags[id].body_from_heap = false;
                if (cflags[id].keep_alive) {
                    keepAliveRearm(id, l);
                } else {
                    closeConn(id);
                }
                return .disarm;
            }
            // Same rule as the TLS path: the stored discriminant decides.
            if (cflags[id].body_from_heap) {
                const hp = body_heap[id].?;
                @memcpy(write_bufs[id][0..n], hp[body_source_off[id]..][0..n]);
            } else {
                @memcpy(write_bufs[id][0..n], body_bufs[id][body_source_off[id]..][0..n]);
            }
            write_lens[id] = n;
            write_offsets[id] = 0;
            body_source_off[id] += n;
            body_remaining[id] -= n;
        }
        if (write_offsets[id] < write_lens[id]) {
            tcp.write(
                l,
                &write_comps[id],
                .{ .slice = write_bufs[id][write_offsets[id]..write_lens[id]] },
                u16,
                &slot_ids[id],
                writeCb,
            );
            return .disarm;
        }
        return .disarm;
    }

    if (write_offsets[id] < write_lens[id]) {
        tcp.write(l, &write_comps[id], .{ .slice = write_bufs[id][write_offsets[id]..write_lens[id]] }, u16, &slot_ids[id], writeCb);
        return .disarm;
    }

    write_offsets[id] = 0;
    if (cflags[id].keep_alive) {
        write_lens[id] = 0;
        keepAliveRearm(id, l);
    } else {
        closeConn(id);
    }
    return .disarm;
}

fn wsKick(id: usize) void {
    const l = g_loop orelse return;
    states[id] = .writing;
    cflags[id].ws_writing = true;
    write_offsets[id] = 0;
    ws_batch[id] = write_lens[id];
    armWrite(id, l);
}

fn armReadId(id: usize, l: *xev.Loop) void {
    cflags[id].ws_read_armed = true;
    armRead(id, l);
}

fn listenerCloseCb(
    _: ?*void,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    r: xev.CloseError!void,
) xev.CallbackAction {
    _ = r catch {};
    listener_closed = true;
    _ = checkDrainComplete();
    return .disarm;
}

fn fireCloseCallbacks() void {
    if (handler_ctx) |ctx| {
        if (close_cb_fn) |cb| {
            close_cb_fn = null;
            const ret = c.call(ctx, cb, c.JS_UNDEFINED, 0, null);
            c.freeValue(ctx, cb);
            if (c.isException(ret) != 0) {
                microtasks.reportUncaught(ctx, "server.close callback error");
            } else {
                c.freeValue(ctx, ret);
            }
        }
        if (close_resolve) |res| {
            close_resolve = null;
            var undef = c.JS_UNDEFINED;
            const ret = c.call(ctx, res, c.JS_UNDEFINED, 1, @ptrCast(&undef));
            c.freeValue(ctx, res);
            c.freeValue(ctx, ret);
        }
        microtasks.pumpMicrotasks(ctx);
    }
}

fn checkDrainComplete() bool {
    if (!closing_server) return false;
    if (free_count != MAX_CONN) return false;
    if (!listener_closed) return false;

    shutdown_deadline_ms = 0;
    if (shutdown_timer_started) {
        shutdown_timer_started = false;
        if (g_loop) |l| {
            shutdown_timer.cancel(l, &shutdown_comp, &shutdown_cancel_comp, void, null, shutdownCancelCb);
        }
    }
    if (watchdog_started) {
        watchdog_started = false;
        if (g_loop) |l| {
            watchdog_timer.cancel(l, &watchdog_comp, &watchdog_cancel_comp, void, null, watchdogCancelCb);
        }
    }
    initialized = false;
    closing_server = false;
    tls_active = false;
    server_running.store(false, .release);

    if (handler_fn) |v| {
        c.freeValue(handler_ctx, v);
        handler_fn = null;
    }
    if (ws_on_open) |v| {
        c.freeValue(handler_ctx, v);
        ws_on_open = null;
    }
    if (ws_on_message) |v| {
        c.freeValue(handler_ctx, v);
        ws_on_message = null;
    }
    if (ws_on_close) |v| {
        c.freeValue(handler_ctx, v);
        ws_on_close = null;
    }
    for (&ws_sockets) |*s| {
        if (s.*) |v| {
            c.freeValue(handler_ctx, v);
            s.* = null;
        }
    }
    fireCloseCallbacks();
    return true;
}

pub fn isRunning() bool {
    return initialized and !closing_server;
}

pub fn isClosingServer() bool {
    return closing_server;
}

/// Called by http2_server after a parked H2 response has been flushed, or
/// after a stream closes. Safe because it runs outside nghttp2 callbacks.
pub fn closeH2Slot(id: usize) void {
    if (id >= MAX_CONN) return;
    // flushNow() may have just armed the H2 response write. Do not arm the
    // TLS shutdown write on the same completion; writeCb checks
    // isShouldClose() after the outstanding write drains.
    if (http2_mod.isWriteArmed(id)) return;
    closeConn(id);
}

pub fn registerCloseWaiter(ctx: ?*c.Context, resolve_val: c.Value, cb_val: c.Value) void {
    if (!initialized) {
        if (c.isFunction(ctx, cb_val) != 0) {
            const ret = c.call(ctx, cb_val, c.JS_UNDEFINED, 0, null);
            if (c.isException(ret) != 0) {
                if (ctx) |jc| microtasks.reportUncaught(jc, "server.close callback error");
            } else {
                c.freeValue(ctx, ret);
            }
        }
        if (c.isFunction(ctx, resolve_val) != 0) {
            var undef = c.JS_UNDEFINED;
            const ret = c.call(ctx, resolve_val, c.JS_UNDEFINED, 1, @ptrCast(&undef));
            c.freeValue(ctx, ret);
        }
        return;
    }
    if (c.isFunction(ctx, resolve_val) != 0) {
        if (close_resolve) |old| c.freeValue(ctx, old);
        close_resolve = c.dupValue(ctx, resolve_val);
    }
    if (c.isFunction(ctx, cb_val) != 0) {
        if (close_cb_fn) |old| c.freeValue(ctx, old);
        close_cb_fn = c.dupValue(ctx, cb_val);
    }
}

/// Initiate graceful server drain:
/// 1. Cancel accept watcher and close listener socket.
/// 2. Close idle keep-alive connections immediately; mark in-flight connections
///    keep_alive = false so they close right after flushing their response.
/// 3. Send HTTP/2 GOAWAY on active H2 sessions.
/// 4. When all 512 slots return to free_list, disarm timers and settle close().
/// 5. An independent timer hard-closes anything still active after 5 s.
pub fn closeServer() void {
    if (!initialized) {
        fireCloseCallbacks();
        return;
    }
    if (closing_server) return;
    closing_server = true;
    shutdown_deadline_ms = nowMs() + SHUTDOWN_DRAIN_MS;

    if (g_loop) |l| {
        if (!shutdown_timer_started) {
            shutdown_timer.run(l, &shutdown_comp, SHUTDOWN_DRAIN_MS, void, null, shutdownDeadlineCb);
            shutdown_timer_started = true;
        }
        if (accept_armed) {
            accept_armed = false;
            accept_cancel_comp = .{
                .op = .{ .cancel = .{ .c = &accept_comp } },
                .userdata = null,
                .callback = noopCancelCb,
            };
            l.add(&accept_cancel_comp);
        }
        if (!listener_closed) {
            listener_tcp.close(l, &listener_close_comp, void, null, listenerCloseCb);
        }
    } else {
        accept_armed = false;
        listener_closed = true;
    }

    for (0..MAX_CONN) |id| {
        if (states[id] == .idle or states[id] == .closing) continue;
        cflags[id].keep_alive = false;
        if (cflags[id].ws_open) {
            closeConn(id);
        } else if (cflags[id].h2_active) {
            if (!http2_mod.hasActiveStreams(id) and !cflags[id].handler_parked) {
                closeConn(id);
            } else if (g_loop) |l| {
                http2_mod.submitGoaway(id, l);
            }
        } else {
            if (states[id] == .reading and !cflags[id].handler_parked and buf_lens[id] == 0 and !cflags[id].req_body_spill) {
                closeConn(id);
            }
        }
    }
    _ = checkDrainComplete();
}

pub fn init(loop: *xev.Loop, port: u16, reuse_port: bool) !void {
    if (initialized) return;
    g_loop = loop;
    closing_server = false;
    listener_closed = false;
    accept_armed = true;
    shutdown_deadline_ms = 0;
    shutdown_timer_started = false;
    if (std.c.getenv("FF_ECHO") != null) native_echo = true;
    for (0..MAX_CONN) |i| {
        slot_ids[i] = @intCast(i);
        free_list[i] = @intCast(i);
    }
    free_count = MAX_CONN;
    read_armed_bits = [_]u64{0} ** 8;
    const addr = std.Io.net.IpAddress.parseIp4("0.0.0.0", port) catch unreachable;
    listener_tcp = try xev.TCP.init(addr);
    const one: c_int = 1;
    _ = std.posix.setsockopt(listener_tcp.fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&one)) catch {};
    if (reuse_port and @hasDecl(std.posix.SO, "REUSEPORT")) {
        _ = std.posix.setsockopt(listener_tcp.fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, std.mem.asBytes(&one)) catch {};
    }
    try listener_tcp.bind(addr);
    try listener_tcp.listen(128);
    var sin: std.posix.sockaddr.in = undefined;
    var slen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
    if (std.c.getsockname(listener_tcp.fd, @ptrCast(&sin), &slen) == 0) {
        bound_port = std.mem.bigToNative(u16, sin.port);
    } else {
        bound_port = port;
    }
    listener_tcp.accept(loop, &accept_comp, void, null, acceptCb);
    if (!watchdog_started) { // NEW
        watchdog_timer = xev.Timer.init() catch unreachable;
        watchdog_timer.run(loop, &watchdog_comp, WATCHDOG_INTERVAL_MS, void, null, watchdogCb);
        watchdog_started = true;
    }
    shutdown_timer = xev.Timer.init() catch unreachable;
    initialized = true;
    server_running.store(true, .release);
    const scheme: []const u8 = if (tls_active) "https" else "http";
    cli.ok("server listening on {s}://localhost:{d}", .{ scheme, bound_port });
    if (ws_enabled) cli.bullet("websocket support enabled", .{});
}

pub fn deinit() void {
    if (handler_ctx) |ctx| {
        if (close_resolve) |v| {
            c.freeValue(ctx, v);
            close_resolve = null;
        }
        if (close_cb_fn) |v| {
            c.freeValue(ctx, v);
            close_cb_fn = null;
        }
    }
    if (!initialized) return;
    initialized = false;
    closing_server = false;
    tls_active = false;
    accept_armed = false;
    listener_closed = true;
    shutdown_deadline_ms = 0;
    shutdown_timer_started = false;
    server_running.store(false, .release);
    watchdog_started = false; // NEW
    for (&states, 0..) |*s, i| {
        if (s.* != .idle) {
            closeConn(i);
        }
    }
    if (handler_fn) |v| {
        c.freeValue(handler_ctx, v);
        handler_fn = null;
    }
    if (ws_on_open) |v| {
        c.freeValue(handler_ctx, v);
        ws_on_open = null;
    }
    if (ws_on_message) |v| {
        c.freeValue(handler_ctx, v);
        ws_on_message = null;
    }
    if (ws_on_close) |v| {
        c.freeValue(handler_ctx, v);
        ws_on_close = null;
    }
    for (&ws_sockets) |*s| {
        if (s.*) |v| {
            c.freeValue(handler_ctx, v);
            s.* = null;
        }
    }
    g_loop = null;
}

// one-time probe capturing QuickJS's internal Promise class id so
// callHandler detects promises with a single JS_GetClassID call.
pub fn setupStrings(ctx: ?*c.Context) void {
    if (promise_class_id != 0) return;
    var cap: [2]c.Value = undefined;
    const p = c.newPromiseCapability(ctx, &cap);
    defer c.freeValue(ctx, p);
    defer c.freeValue(ctx, cap[0]);
    defer c.freeValue(ctx, cap[1]);
    if (c.isObject(p) != 0) promise_class_id = c.getClassID(p);
    // Cache the "then" atom once (parkHandler reuses it; never freed,
    // like promise_class_id). Guarded so a retried probe can't leak. // ◀ FIX-3
    if (then_atom == 0) then_atom = c.newAtomLen(ctx, "then", 4); // ◀ FIX-3
}

// ── Regression test: classifyMethod must never read past the slice ──
// "DELETE" is exactly 6 bytes; the old code read s[6] in the len==6 branch
// (OOB: panics in Debug, silent misclassify as .none in ReleaseFast).
// Exact-length slices make any regression a hard panic under `zig build test`.
test "classifyMethod covers all methods with exact-length slices" {
    const cases = .{
        .{ "GET", Method.get },
        .{ "PUT", Method.put },
        .{ "POST", Method.post },
        .{ "HEAD", Method.head },
        .{ "PATCH", Method.patch },
        .{ "DELETE", Method.delete },
        .{ "OPTIONS", Method.options },
        .{ "", Method.none },
        .{ "TRACE", Method.none },
        .{ "get", Method.none },
    };
    inline for (cases) |case| {
        const s: []const u8 = case[0];
        try std.testing.expectEqual(case[1], classifyMethod(s));
    }
}

// ── Fragment state: the open bit must not overload a length sentinel ──
// RFC 6455 allows a zero-length first fragment. Using `ws_partial_len != 0`
// as "a message is open" made the legal continuation look spurious.
test "ws fragment-open bit is independent of partial length" {
    const id: usize = 402;
    ws_partial_len[id] = 0;
    wsSetFragmentOpen(id, false);
    try std.testing.expect(!wsFragmentOpen(id));

    // Zero-length first fragment: len stays 0, but the message IS open.
    wsSetFragmentOpen(id, true);
    try std.testing.expect(wsFragmentOpen(id));
    try std.testing.expectEqual(@as(usize, 0), ws_partial_len[id]);

    wsSetFragmentOpen(id, false);
    try std.testing.expect(!wsFragmentOpen(id));
    try std.testing.expectEqual(@as(usize, 0), ws_partial_len[id]);

    // Bits are per-slot, not global.
    wsSetFragmentOpen(403, true);
    try std.testing.expect(wsFragmentOpen(403));
    try std.testing.expect(!wsFragmentOpen(id));
    wsSetFragmentOpen(403, false);
}

// ── Regression test: spill reuse must not corrupt small-body sourcing ──
// stageLargeResponse retains ≤256KB spills on the slot. The drain must pick
// its source from the STORED discriminant (cflags.body_from_heap), never from
// body_heap[id] != null (a retained spill outlives its response) nor from
// body_lens > BODY_BUF_SIZE after a retained spill is reused.
test "stageLargeResponse retains spill for reuse and routes by discriminant" {
    const id: usize = 0;
    const big_len = 100 * 1024;
    const big1 = try gpa.alloc(u8, big_len);
    defer gpa.free(big1);
    @memset(big1, 'A');
    const big2 = try gpa.alloc(u8, big_len);
    defer gpa.free(big2);
    @memset(big2, 'B');

    const spill0 = stat_body_spill.load(.monotonic);
    const reuse0 = stat_body_spill_reuse.load(.monotonic);

    // 1. First large stage allocates a spill.
    stageLargeResponse(id, 0, big1.ptr, big_len);
    try std.testing.expect(body_heap[id] != null);
    try std.testing.expectEqual(big_len, body_lens[id]);
    try std.testing.expect(cflags[id].body_from_heap);
    try std.testing.expectEqual(spill0 + 1, stat_body_spill.load(.monotonic));

    // 2. Same-slot large stage reuses — no second free+dupe.
    stageLargeResponse(id, 0, big2.ptr, big_len);
    try std.testing.expectEqual(reuse0 + 1, stat_body_spill_reuse.load(.monotonic));
    try std.testing.expectEqualSlices(u8, big2, body_heap[id].?[0..big_len]);
    try std.testing.expect(cflags[id].body_from_heap);

    // 3. Small body stages into body_bufs even though a spill is retained —
    // the discriminant must flip or the drain reads the stale heap.
    const small = "hello";
    stageLargeResponse(id, 0, small.ptr, small.len);
    try std.testing.expect(body_lens[id] <= BODY_BUF_SIZE);
    try std.testing.expectEqualSlices(u8, small, body_bufs[id][0..small.len]);
    try std.testing.expect(body_heap[id] != null); // still retained
    try std.testing.expect(!cflags[id].body_from_heap);

    // 4. Oversize gate: ≤ cap retained, > cap freed.
    stageLargeResponse(id, 0, big1.ptr, big_len);
    releaseSpillIfOversized(id);
    try std.testing.expect(body_heap[id] != null);
    const huge_len = BODY_SPILL_RETAIN_MAX + 1;
    const huge = try gpa.alloc(u8, huge_len);
    defer gpa.free(huge);
    stageLargeResponse(id, 0, huge.ptr, huge_len);
    releaseSpillIfOversized(id);
    try std.testing.expect(body_heap[id] == null);

    // Leave the slot clean for other tests.
    body_lens[id] = 0;
    body_remaining[id] = 0;
    body_source_off[id] = 0;
    cflags[id].body_from_heap = false;
}

test "statusReason covers every status code" {
    const cases = .{
        .{ 200, "OK" },                    .{ 201, "Created" },           .{ 204, "No Content" },
        .{ 301, "Moved Permanently" },     .{ 304, "Not Modified" },      .{ 400, "Bad Request" },
        .{ 401, "Unauthorized" },          .{ 403, "Forbidden" },         .{ 404, "Not Found" },
        .{ 405, "Method Not Allowed" },    .{ 413, "Payload Too Large" }, .{ 431, "Request Header Fields Too Large" },
        .{ 500, "Internal Server Error" }, .{ 502, "Bad Gateway" },       .{ 503, "Service Unavailable" },
        .{ 418, "Unknown" },               .{ 999, "Unknown" },
    };
    inline for (cases) |case| {
        try std.testing.expectEqualStrings(case[1], statusReason(case[0]));
    }
}

test "formatResponseHeader/pushStr/appendUInt shapes" {
    var w: [512]u8 = undefined;
    var pos: usize = 0;
    appendUInt(&w, &pos, 0);
    try std.testing.expectEqualStrings("0", w[0..pos]);
    pos = 0;
    appendUInt(&w, &pos, 40120);
    try std.testing.expectEqualStrings("40120", w[0..pos]);
    pushStr(&w, &pos, "x");
    try std.testing.expectEqualStrings("40120x", w[0..pos]);
    pos = formatResponseHeader(&w, 200, 5, true);
    try std.testing.expect(std.mem.indexOf(u8, w[0..pos], "HTTP/1.1 200 OK\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, w[0..pos], "Content-Length: 5\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, w[0..pos], "Connection: keep-alive\r\n") != null);
    pos = formatResponseHeader(&w, 204, null, false);
    try std.testing.expect(std.mem.indexOf(u8, w[0..pos], "HTTP/1.1 204 No Content\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, w[0..pos], "Content-Length") == null);
    try std.testing.expect(std.mem.indexOf(u8, w[0..pos], "keep-alive") == null);
    methods[400] = .head;
    try std.testing.expect(!wantsBodyBytes(400, 200));
    methods[400] = .get;
    try std.testing.expect(wantsBodyBytes(400, 200));
    try std.testing.expect(!wantsBodyBytes(400, 204));
    try std.testing.expect(!wantsBodyBytes(400, 304));
    methods[400] = .none;
}

test "buildResponse writes headers+body and honors suppress" {
    const id: usize = 400;
    cflags[id] = .{};
    buildResponse(id, 200, "hi");
    try std.testing.expect(std.mem.indexOf(u8, write_bufs[id][0..write_lens[id]], "HTTP/1.1 200 OK\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, write_bufs[id][0..write_lens[id]], "hi"));
    // 204 suppresses the body and omits content-length.
    buildResponse(id, 204, "hi");
    try std.testing.expect(!std.mem.endsWith(u8, write_bufs[id][0..write_lens[id]], "hi"));
    try std.testing.expect(std.mem.indexOf(u8, write_bufs[id][0..write_lens[id]], "Content-Length") == null);
    cflags[id].keep_alive = true;
    buildResponse(id, 404, "");
    try std.testing.expect(std.mem.indexOf(u8, write_bufs[id][0..write_lens[id]], "Connection: keep-alive\r\n") != null);
    cflags[id] = .{};
    write_lens[id] = 0;
}

test "callHandler without a runtime answers 500" {
    const id: usize = 401;
    cflags[id] = .{};
    const pr = ParsedRequest{
        .method = "GET",
        .url = "/",
        .ws_key = "",
        .content_length = 0,
        .method_tag = .get,
        .keep_alive = true,
        .framing_ok = true,
        .ws_bad = false,
        .too_large = false,
    };
    callHandler(id, &pr, "");
    try std.testing.expect(std.mem.indexOf(u8, write_bufs[id][0..write_lens[id]], "HTTP/1.1 500 Internal Server Error\r\n") != null);
    cflags[id] = .{};
    write_lens[id] = 0;
}

test "parseHeaders enforces MAX_REQ_HEADER_BYTES cap" {
    const raw_small = "GET / HTTP/1.1\r\nHost: example.com\r\nX-Foo: bar\r\n\r\n";
    const hdrs = try parseHeaders(raw_small);
    defer hdrs.release();
    try std.testing.expectEqualStrings("example.com", hdrs.getFirst("host").?);
    try std.testing.expectEqualStrings("bar", hdrs.getFirst("x-foo").?);

    var big_hdr = std.ArrayList(u8).empty;
    defer big_hdr.deinit(gpa);
    try big_hdr.appendSlice(gpa, "GET / HTTP/1.1\r\n");
    var i: usize = 0;
    while (i < 1100) : (i += 1) {
        try big_hdr.appendSlice(gpa, "X-Padding-Header: 12345678901234567890123456789012345678901234567890\r\n");
    }
    try big_hdr.appendSlice(gpa, "\r\n");
    try std.testing.expect(big_hdr.items.len > MAX_REQ_HEADER_BYTES);
    try std.testing.expectError(error.HeadersTooLarge, parseHeaders(big_hdr.items));
}

// ── Framing regression: every ambiguous message must be refused ──
// Each case was a smuggling primitive: duplicate CL, TE without an
// implementation, non-digit CL, an overflowing CL, obs-fold, and BWS
// before the colon.
test "parseRequest rejects ambiguous framing" {
    const cases = [_][]const u8{
        "POST / HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 40\r\n\r\n",
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length: 5abc\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length: 99999999999\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: x\r\n continuation\r\n\r\n",
        "GET / HTTP/1.1\r\nContent-Length : 3\r\n\r\n",
    };
    for (cases) |raw| {
        const he = findHeaderEnd(raw, 0).?;
        const pr = parseRequest(raw, he + 4);
        try std.testing.expect(!pr.framing_ok);
    }
}

test "parseRequest accepts CL above READ_BUF_SIZE up to REQ_BODY_MAX" {
    var buf: [512]u8 = undefined;
    const req = "POST / HTTP/1.1\r\nContent-Length: 65536\r\n\r\n";
    @memcpy(buf[0..req.len], req);
    const pr = parseRequest(buf[0..req.len], req.len);
    try std.testing.expect(pr.framing_ok);
    try std.testing.expect(!pr.too_large);
    try std.testing.expectEqual(@as(usize, 65536), pr.content_length);
}

test "parseRequest marks CL above REQ_BODY_MAX too_large" {
    var buf: [512]u8 = undefined;
    const req = "POST / HTTP/1.1\r\nContent-Length: 2000000\r\n\r\n";
    @memcpy(buf[0..req.len], req);
    const pr = parseRequest(buf[0..req.len], req.len);
    try std.testing.expect(!pr.framing_ok);
    try std.testing.expect(pr.too_large);
}

// ── Handshake regression: only a complete RFC 6455 upgrade may 101 ──
test "parseRequest accepts only a complete WS handshake" {
    const good = "GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
        "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n";
    var he = findHeaderEnd(good, 0).?;
    var pr = parseRequest(good, he + 4);
    try std.testing.expectEqual(@as(usize, 24), pr.ws_key.len);
    try std.testing.expect(!pr.ws_bad);

    // Key in the query string only: must NOT be an upgrade (this is the
    // exact bypass the old whole-buffer findTokenCI scan allowed).
    const query = "GET /?sec-websocket-key:dGhlIHNhbXBsZSBub25jZQ== HTTP/1.1\r\nHost: x\r\n\r\n";
    he = findHeaderEnd(query, 0).?;
    pr = parseRequest(query, he + 4);
    try std.testing.expectEqual(@as(usize, 0), pr.ws_key.len);

    // Key present but missing Upgrade/Version: invalid, not accepted.
    const partial = "GET / HTTP/1.1\r\nHost: x\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n";
    he = findHeaderEnd(partial, 0).?;
    pr = parseRequest(partial, he + 4);
    try std.testing.expectEqual(@as(usize, 0), pr.ws_key.len);
    try std.testing.expect(pr.ws_bad);
}

// ── Oracle test: vector token search must match the scalar reference ──
// Exercises widths around the native lane count plus the `v | 0x20`
// case-fold's false-positive candidates (e.g. needle "-x": '\r' (0x0D)
// folds to the same candidate as '-'), which matchCI must then reject.
// Short-haystack (< needle) cases assert the null guard directly —
// findTokenCIScalar would underflow `len - needle.len + 1` there.
test "findTokenCI simd matches scalar" {
    const needles = [_][]const u8{ "sec-websocket-key:", "a", "A", "-x", ":", "Ab9", "\r\n", "zzzz" };
    // Deterministic pseudo-random haystacks at SIMD-boundary lengths.
    const lens = [_]usize{ 0, 1, 7, 15, 16, 17, 31, 32, 33, 63, 64, 65, 100, 255 };
    var hay: [256]u8 = undefined;
    for (lens) |len| {
        const hlen = @min(len, hay.len);
        for (0..hlen) |i| hay[i] = @intCast((i * 37 + len * 11 + 5) & 0xff);
        for (needles) |n| {
            if (hlen < n.len) {
                try std.testing.expectEqual(@as(?usize, null), findTokenCI(hay[0..hlen], n));
            } else {
                try std.testing.expectEqual(findTokenCIScalar(hay[0..hlen], n), findTokenCI(hay[0..hlen], n));
            }
        }
    }
    // Width-exact boundaries around N with an embedded mixed-case token.
    const N = vec_len_u8;
    var i: usize = 0;
    while (i < 3 * N + 4) : (i += 1) {
        const total = N + i;
        if (total > hay.len) break;
        @memset(hay[0..total], 'q');
        const at = @min(i, total -| 4);
        @memcpy(hay[at..][0..4], "KeY:");
        try std.testing.expectEqual(findTokenCIScalar(hay[0..total], "key:"), findTokenCI(hay[0..total], "key:"));
        try std.testing.expectEqual(findTokenCIScalar(hay[0..total], "KEY:"), findTokenCI(hay[0..total], "KEY:"));
        try std.testing.expectEqual(findTokenCIScalar(hay[0..total], "-x"), findTokenCI(hay[0..total], "-x"));
    }
}
