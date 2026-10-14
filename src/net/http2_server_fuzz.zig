const std = @import("std");
const assert = std.debug.assert;
const fuzz = @import("../testing/fuzz.zig");
const h2s = @import("http2_server.zig");
const h2 = @import("nghttp2_c.zig");

// HTTP/2 session state machine without network: drive the nghttp2
// callbacks directly with synthetic frames. Catches OOB/overflow in
// header capping, stream-slot reuse, body staging and response queueing.
// No loop, no sockets: flushNow/pumpWrite/drainPending (which need a live
// xev loop and armed completions) are deliberately never called.

pub const events_smoke: usize = 5_000;
pub const events_default: ?usize = null;

// Slot 7: the TEST binary's h2 tests use 0-3 and http tests use 0/400+;
// the fuzz binary is standalone, but stay clear anyway.
const SLOT: usize = 7;
// Caps mirror http2_server.zig (MAX_METHOD/MAX_PATH/MAX_BODY_SIZE/
// MAX_STREAMS); if those change and this trips, update both.
const CAP_METHOD: usize = 16;
const CAP_PATH: usize = 2048;
const CAP_BODY: usize = 10 * 1024 * 1024;
const CAP_STREAMS: usize = 100;
const CAP_OUTPUT: usize = 4 * 1024 * 1024;

const Op = enum { begin, header, data, frame, close, send, read, submit, recycle, bad_user };

const hdr_names = [_][]const u8{ ":method", ":path", ":scheme", ":authority", "content-length", ":custom", "", "te", "connection" };
const hdr_vals = [_][]const u8{ "GET", "POST", "/", "/index.html", "/a?b=c&d=e", "999", "", "trailers", "keep-alive" };
const frame_types = [_]u8{ h2.HEADERS, h2.DATA, h2.RST_STREAM, h2.GOAWAY, 0x2, 0x4, 0x6, 0x9, 0xff };
const statuses = [_]u16{ 200, 201, 204, 301, 404, 500, 999 };
const bodies = [_][]const u8{ "", "hi", "hello-body", "x" };

pub fn main(gpa: std.mem.Allocator, args: fuzz.FuzzArgs) !void {
    _ = gpa;
    var prng = std.Random.DefaultPrng.init(args.seed);
    const rand = prng.random();
    const enabled = fuzz.swarmTake(rand, 10);
    comptime assert(10 == @typeInfo(Op).@"enum".fields.len);

    _ = h2s.initSession(SLOT) orelse return error.NoSession;
    var buf: [8192]u8 = undefined;
    var big: [4096]u8 = undefined;
    var out: [4096]u8 = undefined;
    var events: usize = 0;
    while (args.events_max == null or events < args.events_max.?) : (events += 1) {
        // Bound per-session growth (≤8KB appended/event worst case).
        if (events > 0 and events % 200 == 0) {
            h2s.removeSession(SLOT);
            _ = h2s.initSession(SLOT) orelse return error.NoSession;
        }
        var sess = h2s.getSession(SLOT) orelse return error.LostSession;
        const op = fuzz.randomEnum(rand, Op);
        if (!enabled[@intFromEnum(op)]) continue;
        switch (op) {
            .begin => {
                var fr = baseFrame(randSid(rand), h2.HEADERS, 0);
                _ = h2s.beginHeadersCb(null, &fr, udata());
            },
            .header => {
                const r = rand.float(f64);
                const n: []const u8 = if (r < 0.3) ":method" else if (r < 0.5) ":path" else if (r < 0.8)
                    fuzz.pick(rand, []const u8, &hdr_names)
                else
                    fuzz.randomSlice(rand, &buf);
                var v: []const u8 = if (rand.float(f64) < 0.7)
                    fuzz.pick(rand, []const u8, &hdr_vals)
                else
                    fuzz.randomSlice(rand, &buf);
                // Overlong values must be capped, never overflow the buffers.
                if (rand.float(f64) < 0.2) v = fuzz.randomSlice(rand, &big);
                var fr = baseFrame(randSid(rand), h2.HEADERS, 0);
                _ = h2s.headerCb(null, &fr, n.ptr, n.len, v.ptr, v.len, 0, udata());
            },
            .data => {
                const chunk = fuzz.randomSlice(rand, &buf);
                _ = h2s.dataChunkCb(null, 0, randSid(rand), chunk.ptr, chunk.len, udata());
            },
            .frame => {
                var fl: u8 = rand.int(u8);
                if (rand.boolean()) fl |= h2.FLAG_END_STREAM;
                var fr = baseFrame(randSid(rand), fuzz.pick(rand, u8, &frame_types), fl);
                rand.bytes(fr.payload[0..]);
                _ = h2s.frameRecvCb(null, &fr, udata());
            },
            .close => {
                _ = h2s.streamCloseCb(null, randSid(rand), 0, udata());
            },
            .send => {
                const chunk = fuzz.randomSlice(rand, &buf);
                _ = h2s.sendCb(null, chunk.ptr, chunk.len, 0, udata());
            },
            .read => {
                // Stage a response half the time so the copy path runs;
                // otherwise the EOF path runs.
                if (rand.boolean()) {
                    const sid = if (rand.boolean()) liveSidOrRand(rand, sess) else randSid(rand);
                    h2s.submitResponse(SLOT, sid, fuzz.pick(rand, u16, &statuses), null, fuzz.pick(rand, []const u8, &bodies));
                }
                var flags: u32 = 0;
                const n = rand.intRangeAtMost(usize, 0, out.len);
                _ = h2s.bodyReadCb(null, randSid(rand), &out, n, &flags, null, udata());
            },
            .submit => {
                const sid = if (rand.boolean()) liveSidOrRand(rand, sess) else randSid(rand);
                h2s.submitResponse(SLOT, sid, fuzz.pick(rand, u16, &statuses), null, fuzz.pick(rand, []const u8, &bodies));
            },
            .recycle => {
                h2s.removeSession(SLOT);
                _ = h2s.initSession(SLOT) orelse return error.NoSession;
                sess = h2s.getSession(SLOT) orelse return error.LostSession;
            },
            .bad_user => {
                // Null and out-of-range user_data must be rejected safely:
                // slotFromPtr maps them to null before any table access.
                const bad = [_]?*anyopaque{ null, @ptrFromInt(0), @ptrFromInt(1), @ptrFromInt(0xdead_beef), @ptrFromInt(std.math.maxInt(usize)) };
                const u = bad[rand.intRangeLessThan(usize, 0, bad.len)];
                var fr = baseFrame(1, h2.HEADERS, h2.FLAG_END_STREAM);
                _ = h2s.beginHeadersCb(null, &fr, u);
                _ = h2s.frameRecvCb(null, &fr, u);
                _ = h2s.streamCloseCb(null, 1, 0, u);
                var flags: u32 = 0;
                _ = h2s.bodyReadCb(null, 1, &out, 64, &flags, null, u);
                const chunk = "x";
                _ = h2s.sendCb(null, chunk.ptr, chunk.len, 0, u);
            },
        }
        try checkSession(sess);
    }
    h2s.removeSession(SLOT);
}

/// Mirror of http2_server slotToPtr: slot id as a pointer (slot+1 so slot
/// 0 never becomes NULL). Never dereferenced by either side.
fn udata() ?*anyopaque {
    return @ptrFromInt(SLOT + 1);
}

fn baseFrame(stream_id: i32, typ: u8, flags: u8) h2.Frame {
    return .{
        .hd = .{ .length = 0, .stream_id = stream_id, .type = typ, .flags = flags, .reserved = 0 },
        .payload = [_]u8{0} ** 32,
    };
}

fn randSid(rand: std.Random) i32 {
    if (rand.boolean()) {
        const small = [_]i32{ 1, 3, 5, 7, 9, 0, -1, 2 };
        return small[rand.intRangeLessThan(usize, 0, small.len)];
    }
    return rand.int(i32);
}

fn liveSidOrRand(rand: std.Random, sess: *h2s.Session) i32 {
    var ids: [CAP_STREAMS]i32 = undefined;
    var n: usize = 0;
    for (0..CAP_STREAMS) |i| {
        if (sess.stream_flags[i].in_use) {
            ids[n] = sess.stream_ids[i];
            n += 1;
        }
    }
    if (n > 0 and rand.boolean()) return ids[rand.intRangeLessThan(usize, 0, n)];
    return randSid(rand);
}

fn checkSession(sess: *h2s.Session) !void {
    for (0..CAP_STREAMS) |i| {
        if (!sess.stream_flags[i].in_use) continue;
        if (sess.streams[i].method_len > CAP_METHOD) return error.MethodOverflow;
        if (sess.streams[i].path_len > CAP_PATH) return error.PathOverflow;
        if (sess.streams[i].body.items.len > CAP_BODY) return error.BodyOverflow;
    }
    if (sess.output.items.len > CAP_OUTPUT) return error.OutputRunaway;
}
