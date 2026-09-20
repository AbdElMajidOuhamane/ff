//! Hand-written Zig bindings for nghttp2 (HTTP/2 framing + HPACK).
//! Mirrors nghttp2 v1.70.0 public API (lib/includes/nghttp2/nghttp2.h).
//! Alternative to translateC: explicit extern declarations, no generated code.

const std = @import("std");

// ── Scalar types ──────────────────────────────────────────────────

/// Signed pointer-sized int used for recv/send lengths and error codes.
pub const ssize = isize;

// ── Opaque types ──────────────────────────────────────────────────

pub const Session = opaque {};
pub const SessionCallbacks = opaque {};
pub const RcBuf = opaque {};
pub const Option = opaque {};

// ── Frame header ──────────────────────────────────────────────────

pub const FrameHd = extern struct {
    length: usize,
    stream_id: i32,
    type: u8,
    flags: u8,
    reserved: u8,
};

// ── Header category (which kind of HEADERS frame) ─────────────────

pub const HCAT_RESPONSE: c_int = 0;
pub const HCAT_REQUEST: c_int = 1;
pub const HCAT_PUSH_RESPONSE: c_int = 2;
pub const HCAT_HEADERS: c_int = 3;

// ── Frame structs ─────────────────────────────────────────────────

pub const PrioritySpec = extern struct {
    stream_id: i32,
    weight: i32,
    exclusive: u8,
};

pub const Headers = extern struct {
    hd: FrameHd,
    padlen: usize,
    pri_spec: PrioritySpec,
    nva: ?*anyopaque,
    nvlen: usize,
    cat: c_int,
};

pub const Priority = extern struct {
    hd: FrameHd,
    pri_spec: PrioritySpec,
};

pub const RstStream = extern struct {
    hd: FrameHd,
    error_code: u32,
};

pub const SettingsEntry = extern struct {
    settings_id: i32,
    value: u32,
};

pub const Settings = extern struct {
    hd: FrameHd,
    niv: usize,
    iv: ?*SettingsEntry,
};

pub const PushPromise = extern struct {
    hd: FrameHd,
    padlen: usize,
    promised_stream_id: i32,
    nva: ?*anyopaque,
    nvlen: usize,
};

pub const Ping = extern struct {
    hd: FrameHd,
    opaque_data: [8]u8,
};

pub const Goaway = extern struct {
    hd: FrameHd,
    last_stream_id: i32,
    error_code: u32,
    opaque_data_len: usize,
    opaque_data: ?[*]u8,
};

pub const WindowUpdate = extern struct {
    hd: FrameHd,
    window_size_increment: i32,
};

pub const Extension = extern struct {
    hd: FrameHd,
    payload: ?*anyopaque,
};

pub const Frame = extern struct {
    hd: FrameHd,
    // Union overlay: read the member matching hd.type.
    // Largest member is Goaway; overlay raw bytes to stay ABI-compatible.
    payload: [32]u8,

    pub fn headers(self: *const Frame) *const Headers {
        return @ptrCast(self);
    }
};

// ── Name/value pair ───────────────────────────────────────────────

pub const Nv = extern struct {
    name: [*]const u8,
    value: [*]const u8,
    namelen: usize,
    valuelen: usize,
    flags: u8,
};

// ── Data provider ─────────────────────────────────────────────────

pub const DataSource = extern union {
    fd: c_int,
    ptr: ?*anyopaque,
};

pub const DataProvider = extern struct {
    source: DataSource,
    read_callback: ?*const fn (
        session: ?*Session,
        stream_id: i32,
        buf: [*]u8,
        length: usize,
        data_flags: *u32,
        source: ?*DataSource,
        user_data: ?*anyopaque,
    ) callconv(.c) ssize,
};

// ── Callback function types ───────────────────────────────────────

pub const SendCallback2 = *const fn (
    session: ?*Session,
    data: [*]const u8,
    length: usize,
    flags: c_int,
    user_data: ?*anyopaque,
) callconv(.c) ssize;

pub const OnFrameRecvCallback = *const fn (
    session: ?*Session,
    frame: *const Frame,
    user_data: ?*anyopaque,
) callconv(.c) c_int;

pub const OnBeginHeadersCallback = *const fn (
    session: ?*Session,
    frame: *const Frame,
    user_data: ?*anyopaque,
) callconv(.c) c_int;

pub const OnHeaderCallback = *const fn (
    session: ?*Session,
    frame: *const Frame,
    name: [*]const u8,
    namelen: usize,
    value: [*]const u8,
    valuelen: usize,
    flags: u8,
    user_data: ?*anyopaque,
) callconv(.c) c_int;

pub const OnDataChunkRecvCallback = *const fn (
    session: ?*Session,
    flags: u8,
    stream_id: i32,
    data: [*]const u8,
    len: usize,
    user_data: ?*anyopaque,
) callconv(.c) c_int;

pub const OnStreamCloseCallback = *const fn (
    session: ?*Session,
    stream_id: i32,
    error_code: u32,
    user_data: ?*anyopaque,
) callconv(.c) c_int;

pub const OnFrameSendCallback = *const fn (
    session: ?*Session,
    frame: *const Frame,
    user_data: ?*anyopaque,
) callconv(.c) c_int;

// ── Frame types ───────────────────────────────────────────────────

pub const DATA: u8 = 0x0;
pub const HEADERS: u8 = 0x1;
pub const PRIORITY: u8 = 0x2;
pub const RST_STREAM: u8 = 0x3;
pub const SETTINGS: u8 = 0x4;
pub const PUSH_PROMISE: u8 = 0x5;
pub const PING: u8 = 0x6;
pub const GOAWAY: u8 = 0x7;
pub const WINDOW_UPDATE: u8 = 0x8;
pub const CONTINUATION: u8 = 0x9;

// ── Flags ─────────────────────────────────────────────────────────

pub const FLAG_NONE: u8 = 0;
pub const FLAG_END_STREAM: u8 = 0x1;
pub const FLAG_END_HEADERS: u8 = 0x4;
pub const FLAG_ACK: u8 = 0x1;
pub const FLAG_PADDED: u8 = 0x8;
pub const FLAG_PRIORITY: u8 = 0x20;

// ── Settings IDs ──────────────────────────────────────────────────

pub const SETTINGS_HEADER_TABLE_SIZE: i32 = 0x1;
pub const SETTINGS_ENABLE_PUSH: i32 = 0x2;
pub const SETTINGS_MAX_CONCURRENT_STREAMS: i32 = 0x3;
pub const SETTINGS_INITIAL_WINDOW_SIZE: i32 = 0x4;
pub const SETTINGS_MAX_FRAME_SIZE: i32 = 0x5;
pub const SETTINGS_MAX_HEADER_LIST_SIZE: i32 = 0x6;

// ── NV flags ──────────────────────────────────────────────────────

pub const NV_FLAG_NONE: u8 = 0;
pub const NV_FLAG_NO_INDEX: u8 = 0x01;
pub const NV_FLAG_NO_COPY_NAME: u8 = 0x02;
pub const NV_FLAG_NO_COPY_VALUE: u8 = 0x04;

// ── DATA flags ────────────────────────────────────────────────────

pub const DATA_FLAG_NONE: u32 = 0;
pub const DATA_FLAG_EOF: u32 = 0x1;
pub const DATA_FLAG_NO_END_STREAM: u32 = 0x2;
pub const DATA_FLAG_NO_COPY: u32 = 0x4;

// ── Error codes (RFC 7540 §7) ─────────────────────────────────────

pub const NO_ERROR: u32 = 0x0;
pub const PROTOCOL_ERROR: u32 = 0x1;
pub const INTERNAL_ERROR: u32 = 0x2;
pub const FLOW_CONTROL_ERROR: u32 = 0x3;
pub const SETTINGS_TIMEOUT: u32 = 0x4;
pub const STREAM_CLOSED: u32 = 0x5;
pub const FRAME_SIZE_ERROR: u32 = 0x6;
pub const REFUSED_STREAM: u32 = 0x7;
pub const CANCEL: u32 = 0x8;
pub const COMPRESSION_ERROR: u32 = 0x9;
pub const CONNECT_ERROR: u32 = 0xa;
pub const ENHANCE_YOUR_CALM: u32 = 0xb;
pub const INADEQUATE_SECURITY: u32 = 0xc;
pub const HTTP_1_1_REQUIRED: u32 = 0xd;

// ── Library error codes (negative) ────────────────────────────────

pub const ERR_INVALID_ARGUMENT: c_int = -501;
pub const ERR_WOULDBLOCK: c_int = -505;
pub const ERR_EOF: c_int = -507;
pub const ERR_TEMPORAL_CALLBACK_FAILURE: c_int = -521;
pub const ERR_CALLBACK_FAILURE: c_int = -902;

// ── Client magic ──────────────────────────────────────────────────

pub const CLIENT_MAGIC = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
pub const CLIENT_MAGIC_LEN: usize = 24;

// ── Callbacks object lifecycle ────────────────────────────────────

pub extern fn nghttp2_session_callbacks_new(callbacks_ptr: *?*SessionCallbacks) c_int;
pub extern fn nghttp2_session_callbacks_del(callbacks: ?*SessionCallbacks) void;

pub extern fn nghttp2_session_callbacks_set_send_callback2(
    cbs: ?*SessionCallbacks,
    send_callback: ?SendCallback2,
) void;

pub extern fn nghttp2_session_callbacks_set_on_frame_recv_callback(
    cbs: ?*SessionCallbacks,
    on_frame_recv_callback: ?OnFrameRecvCallback,
) void;

pub extern fn nghttp2_session_callbacks_set_on_begin_headers_callback(
    cbs: ?*SessionCallbacks,
    on_begin_headers_callback: ?OnBeginHeadersCallback,
) void;

pub extern fn nghttp2_session_callbacks_set_on_header_callback(
    cbs: ?*SessionCallbacks,
    on_header_callback: ?OnHeaderCallback,
) void;

pub extern fn nghttp2_session_callbacks_set_on_data_chunk_recv_callback(
    cbs: ?*SessionCallbacks,
    on_data_chunk_recv_callback: ?OnDataChunkRecvCallback,
) void;

pub extern fn nghttp2_session_callbacks_set_on_stream_close_callback(
    cbs: ?*SessionCallbacks,
    on_stream_close_callback: ?OnStreamCloseCallback,
) void;

pub extern fn nghttp2_session_callbacks_set_on_frame_send_callback(
    cbs: ?*SessionCallbacks,
    on_frame_send_callback: ?OnFrameSendCallback,
) void;

// ── Session lifecycle ─────────────────────────────────────────────

pub extern fn nghttp2_session_server_new(
    session_ptr: *?*Session,
    callbacks: ?*const SessionCallbacks,
    user_data: ?*anyopaque,
) c_int;

pub extern fn nghttp2_session_del(session: ?*Session) void;

// ── I/O ───────────────────────────────────────────────────────────

pub extern fn nghttp2_session_mem_recv2(
    session: ?*Session,
    input: [*]const u8,
    inlen: usize,
) ssize;

pub extern fn nghttp2_session_send(session: ?*Session) c_int;

pub extern fn nghttp2_session_want_read(session: ?*Session) c_int;
pub extern fn nghttp2_session_want_write(session: ?*Session) c_int;

// ── Submit frames ─────────────────────────────────────────────────

pub extern fn nghttp2_submit_settings(
    session: ?*Session,
    flags: u8,
    iv: ?[*]const SettingsEntry,
    niv: usize,
) c_int;

pub extern fn nghttp2_submit_response2(
    session: ?*Session,
    stream_id: i32,
    nva: ?[*]const Nv,
    nvlen: usize,
    data_prd: ?*const DataProvider,
) i32;

pub extern fn nghttp2_submit_rst_stream(
    session: ?*Session,
    flags: u8,
    stream_id: i32,
    error_code: u32,
) c_int;

pub extern fn nghttp2_submit_goaway(
    session: ?*Session,
    flags: u8,
    last_stream_id: i32,
    error_code: u32,
    opaque_data: ?[*]const u8,
    opaque_data_len: usize,
) c_int;

pub extern fn nghttp2_submit_window_update(
    session: ?*Session,
    flags: u8,
    stream_id: i32,
    window_size_increment: i32,
) c_int;

pub extern fn nghttp2_submit_ping(
    session: ?*Session,
    flags: u8,
    opaque_data: ?[*]const u8,
) c_int;

// ── Stream utilities ──────────────────────────────────────────────

pub extern fn nghttp2_session_get_stream_user_data(
    session: ?*Session,
    stream_id: i32,
) ?*anyopaque;

pub extern fn nghttp2_session_set_stream_user_data(
    session: ?*Session,
    stream_id: i32,
    stream_user_data: ?*anyopaque,
) c_int;

// ── Error strings ─────────────────────────────────────────────────

pub extern fn nghttp2_strerror(lib_error_code: c_int) [*:0]const u8;

// ── Tests ─────────────────────────────────────────────────────────

test "nghttp2 constants are correct" {
    try std.testing.expectEqual(@as(u8, 0x1), HEADERS);
    try std.testing.expectEqual(@as(u8, 0x0), DATA);
    try std.testing.expectEqual(@as(u8, 0x4), SETTINGS);
    try std.testing.expectEqual(@as(u8, 0x1), FLAG_END_STREAM);
    try std.testing.expectEqual(@as(i32, 0x3), SETTINGS_MAX_CONCURRENT_STREAMS);
    try std.testing.expectEqual(@as(usize, 24), CLIENT_MAGIC_LEN);
    try std.testing.expectEqualStrings("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", CLIENT_MAGIC);
}

test "nghttp2 callbacks object lifecycle" {
    var cbs: ?*SessionCallbacks = null;
    try std.testing.expectEqual(@as(c_int, 0), nghttp2_session_callbacks_new(&cbs));
    try std.testing.expect(cbs != null);
    nghttp2_session_callbacks_del(cbs);
}
