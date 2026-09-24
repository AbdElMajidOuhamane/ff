const std = @import("std");

const gpa = std.heap.smp_allocator;

/// Frame types on the pipe. Payload for MESSAGE is a JSON string;
/// payload for ERROR is a raw UTF-8 message (not JSON).
pub const FRAME_MESSAGE: u8 = 1;
pub const FRAME_ERROR: u8 = 2;

/// Wire format: u32 little-endian length + u8 type + payload bytes.
/// 4 MB cap guards against a corrupt length prefix causing a huge alloc.
const MAX_FRAME: usize = 4 * 1024 * 1024;

// DOD: reusable per-thread receive scratch — zero heap alloc per frame
// after thread start. Payload is valid only until the next recv on this thread.
threadlocal var recv_scratch: [MAX_FRAME]u8 = undefined;

pub const Frame = struct {
    ftype: u8,
    /// Borrowed from this thread's recv_scratch; valid only until the next
    /// recv on the same thread. Do NOT free.
    payload: []u8,
};

/// One direction of a bidirectional channel. The parent owns one end of
/// each pipe, the worker thread owns the other; a given send_fd has exactly
/// one writer, so frames never interleave.
pub const MessagePort = struct {
    send_fd: std.posix.fd_t,
    recv_fd: std.posix.fd_t,

    /// Create both pipe pairs. Parent writes p2c / reads c2p;
    /// child reads p2c / writes c2p.
    pub fn create() !Channel {
        var p2c: [2]std.posix.fd_t = undefined;
        if (std.c.pipe(&p2c) != 0) return error.PipeCreateFailed;
        errdefer {
            _ = std.c.close(p2c[0]);
            _ = std.c.close(p2c[1]);
        }
        var c2p: [2]std.posix.fd_t = undefined;
        if (std.c.pipe(&c2p) != 0) return error.PipeCreateFailed;
        return .{
            .parent = .{ .send_fd = p2c[1], .recv_fd = c2p[0] },
            .child = .{ .send_fd = c2p[1], .recv_fd = p2c[0] },
        };
    }

    pub fn sendFrame(self: *const MessagePort, ftype: u8, payload: []const u8) !void {
        if (payload.len > MAX_FRAME) return error.FrameTooLarge;
        var hdr: [5]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], @intCast(payload.len), .little);
        hdr[4] = ftype;
        try writeExact(self.send_fd, &hdr);
        if (payload.len > 0) try writeExact(self.send_fd, payload);
    }

    pub fn sendMessage(self: *const MessagePort, json: []const u8) !void {
        return self.sendFrame(FRAME_MESSAGE, json);
    }

    pub fn sendError(self: *const MessagePort, msg: []const u8) !void {
        return self.sendFrame(FRAME_ERROR, msg);
    }

    /// Blocking receive into thread-local scratch (no per-frame heap).
    /// Returns error.EndOfStream when the other end closed its write fd.
    pub fn recvFrameBlocking(self: *const MessagePort) !Frame {
        var hdr: [5]u8 = undefined;
        try readExact(self.recv_fd, &hdr);
        const len: usize = @intCast(std.mem.readInt(u32, hdr[0..4], .little));
        if (len > MAX_FRAME) return error.FrameTooLarge;
        const ftype = hdr[4];
        if (ftype != FRAME_MESSAGE and ftype != FRAME_ERROR) return error.BadFrame;
        const buf = recv_scratch[0..len];
        try readExact(self.recv_fd, buf);
        return .{ .ftype = ftype, .payload = buf };
    }

    /// Non-blocking poll: true if a read would not block (data OR EOF).
    pub fn pollReadable(self: *const MessagePort, timeout_ms: i32) bool {
        var pfd = [_]std.posix.pollfd{
            .{ .fd = self.recv_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const n = std.posix.poll(&pfd, timeout_ms) catch return false;
        return n > 0;
    }

    /// Non-blocking receive. Returns null when no frame is available.
    /// NOTE: EOF is swallowed (returns null). Parent-side slots only die
    /// via terminate(); worker-side loops use recvFrameBlocking so they
    /// observe EndOfStream.
    pub fn tryRecvFrame(self: *const MessagePort) ?Frame {
        if (!self.pollReadable(0)) return null;
        return self.recvFrameBlocking() catch null;
    }

    pub fn closeSend(self: *const MessagePort) void {
        _ = std.c.close(self.send_fd);
    }

    pub fn closeRecv(self: *const MessagePort) void {
        _ = std.c.close(self.recv_fd);
    }

    pub fn closeAll(self: *const MessagePort) void {
        self.closeSend();
        self.closeRecv();
    }
};

pub const Channel = struct {
    parent: MessagePort,
    child: MessagePort,

    pub fn closeAll(self: *const Channel) void {
        self.parent.closeAll();
        self.child.closeAll();
    }
};

fn writeExact(fd: std.posix.fd_t, buf: []const u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = std.c.write(fd, buf[off..].ptr, buf.len - off);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

fn readExact(fd: std.posix.fd_t, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = std.c.read(fd, buf[off..].ptr, buf.len - off);
        if (n == 0) return if (off == 0) error.EndOfStream else error.UnexpectedEof;
        if (n < 0) return error.ReadFailed;
        off += @intCast(n);
    }
}
