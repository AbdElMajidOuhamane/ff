const std = @import("std");
const builtin = @import("builtin");

const page = std.heap.page_size_min;

pub const WORKER_STACK_MIN: usize = 8 * 1024 * 1024;

pub const RuntimeLimits = struct {
    heap_bytes: usize = 64 * 1024 * 1024,
    stack_bytes: usize = 1024 * 1024,
    worker_heap_bytes: usize = 32 * 1024 * 1024,
    cpu_budget_ms: u32 = 0, // 0 = disabled
    wall_timeout_ms: u32 = 0, // 0 = disabled
    max_log_bytes: usize = 0, // 0 = unlimited
    sandbox: bool = false,
    env_file: ?[]const u8 = null,
    // derived once; never recomputed on a hot path
    native_stack_bytes: usize = 0,
    stack_max_bytes: usize = 0,
    worker_stack_bytes: usize = WORKER_STACK_MIN,
};

pub const LimitsError = error{
    InvalidHeapSize,
    InvalidStackSize,
    InvalidWorkerHeapSize,
    InvalidCpuBudget,
    InvalidWallTimeout,
    InvalidMaxLogBytes,
    MissingEnvFilePath,
    MissingStackSizeValue,
    InvalidByteSize,
    NativeStackTooSmall,
    StackSizeExceedsNative,
};

pub const WALL_TIMEOUT_MAX_MS: u32 = 3_600_000;
pub const MAX_LOG_BYTES_CAP: usize = 100 * 1024 * 1024;

pub fn parseWallTimeout(s: []const u8) LimitsError!u32 {
    const ms = std.fmt.parseInt(u32, s, 10) catch return error.InvalidWallTimeout;
    if (ms > WALL_TIMEOUT_MAX_MS) return error.InvalidWallTimeout;
    return ms;
}

pub fn parseMaxLogBytes(s: []const u8) LimitsError!usize {
    const bytes = parseByteSize(s) catch return error.InvalidMaxLogBytes;
    if (bytes > MAX_LOG_BYTES_CAP) return error.InvalidMaxLogBytes;
    return bytes;
}

var global_limits: RuntimeLimits = .{};
var initialized: bool = false;

pub fn get() *const RuntimeLimits {
    return &global_limits;
}

pub fn safeStackMax(native: usize) usize {
    return std.mem.alignBackward(usize, native / 2, page);
}

pub fn workerStackFor(stack_bytes: usize) usize {
    const page_sz = std.heap.pageSize();
    const doubled = std.math.mul(usize, stack_bytes, 2) catch std.math.maxInt(usize);
    return @max(WORKER_STACK_MIN, std.mem.alignForward(usize, doubled, page_sz));
}

pub fn detectNativeMainStack() usize {
    if (comptime builtin.os.tag.isDarwin()) {
        const darwin = struct {
            extern "c" fn pthread_get_stacksize_np(std.c.pthread_t) usize;
        };
        const sz = darwin.pthread_get_stacksize_np(std.c.pthread_self());
        if (sz >= 512 * 1024) return sz;
        return 8 * 1024 * 1024;
    } else if (comptime builtin.os.tag == .linux) {
        if (std.posix.getrlimit(.STACK)) |rl| {
            if (rl.cur == std.math.maxInt(@TypeOf(rl.cur))) {
                return 16 * 1024 * 1024;
            }
            if (rl.cur >= 512 * 1024) {
                return @intCast(rl.cur);
            }
        } else |_| {}
        return 8 * 1024 * 1024;
    } else {
        return 8 * 1024 * 1024;
    }
}

pub fn setCpuBudget(ms: u32) void {
    global_limits.cpu_budget_ms = ms;
}

pub fn initFromArgs(args: std.process.Args) LimitsError!void {
    if (initialized) return;
    initialized = true;

    // Check environment variables first
    if (std.c.getenv("FF_MAX_HEAP")) |val| {
        const span = std.mem.span(val);
        const bytes = parseByteSize(span) catch return error.InvalidHeapSize;
        global_limits.heap_bytes = bytes;
    }
    if (std.c.getenv("FF_CPU_BUDGET")) |val| {
        const span = std.mem.span(val);
        const ms = std.fmt.parseInt(u32, span, 10) catch return error.InvalidCpuBudget;
        global_limits.cpu_budget_ms = ms;
    }
    if (std.c.getenv("FF_WALL_TIMEOUT")) |val| {
        const span = std.mem.span(val);
        global_limits.wall_timeout_ms = try parseWallTimeout(span);
    }

    var worker_heap_explicit = false;
    var it = args.iterate();
    while (it.next()) |a| {
        if (std.mem.startsWith(u8, a, "--max-heap=")) {
            const val = a["--max-heap=".len..];
            global_limits.heap_bytes = parseByteSize(val) catch return error.InvalidHeapSize;
        } else if (std.mem.eql(u8, a, "--max-heap")) {
            const val = it.next() orelse return error.InvalidHeapSize;
            global_limits.heap_bytes = parseByteSize(val) catch return error.InvalidHeapSize;
        } else if (std.mem.startsWith(u8, a, "--max-stack=")) {
            const val = a["--max-stack=".len..];
            if (val.len == 0) return error.MissingStackSizeValue;
            global_limits.stack_bytes = parseByteSize(val) catch return error.InvalidByteSize;
        } else if (std.mem.eql(u8, a, "--max-stack")) {
            const val = it.next() orelse return error.MissingStackSizeValue;
            if (val.len == 0 or std.mem.startsWith(u8, val, "-")) return error.MissingStackSizeValue;
            global_limits.stack_bytes = parseByteSize(val) catch return error.InvalidByteSize;
        } else if (std.mem.startsWith(u8, a, "--worker-heap=")) {
            const val = a["--worker-heap=".len..];
            global_limits.worker_heap_bytes = parseByteSize(val) catch return error.InvalidWorkerHeapSize;
            worker_heap_explicit = true;
        } else if (std.mem.eql(u8, a, "--worker-heap")) {
            const val = it.next() orelse return error.InvalidWorkerHeapSize;
            global_limits.worker_heap_bytes = parseByteSize(val) catch return error.InvalidWorkerHeapSize;
            worker_heap_explicit = true;
        } else if (std.mem.startsWith(u8, a, "--cpu-budget=")) {
            const val = a["--cpu-budget=".len..];
            const ms = std.fmt.parseInt(u32, val, 10) catch return error.InvalidCpuBudget;
            global_limits.cpu_budget_ms = ms;
        } else if (std.mem.eql(u8, a, "--cpu-budget")) {
            const val = it.next() orelse return error.InvalidCpuBudget;
            const ms = std.fmt.parseInt(u32, val, 10) catch return error.InvalidCpuBudget;
            global_limits.cpu_budget_ms = ms;
        } else if (std.mem.startsWith(u8, a, "--wall-timeout=")) {
            const val = a["--wall-timeout=".len..];
            global_limits.wall_timeout_ms = try parseWallTimeout(val);
        } else if (std.mem.eql(u8, a, "--wall-timeout")) {
            const val = it.next() orelse return error.InvalidWallTimeout;
            global_limits.wall_timeout_ms = try parseWallTimeout(val);
        } else if (std.mem.startsWith(u8, a, "--max-log-bytes=")) {
            const val = a["--max-log-bytes=".len..];
            global_limits.max_log_bytes = try parseMaxLogBytes(val);
        } else if (std.mem.eql(u8, a, "--max-log-bytes")) {
            const val = it.next() orelse return error.InvalidMaxLogBytes;
            global_limits.max_log_bytes = try parseMaxLogBytes(val);
        } else if (std.mem.eql(u8, a, "--simple-sandbox")) {
            global_limits.sandbox = true;
        } else if (std.mem.eql(u8, a, "--env-file")) {
            const path = it.next() orelse return error.MissingEnvFilePath;
            global_limits.env_file = path;
        } else if (std.mem.startsWith(u8, a, "--env-file=")) {
            const val = a["--env-file=".len..];
            if (val.len == 0) return error.MissingEnvFilePath;
            global_limits.env_file = val;
        }
    }

    // Range checks
    // heap 8 MB..4 GB
    if (global_limits.heap_bytes < 8 * 1024 * 1024 or global_limits.heap_bytes > 4 * 1024 * 1024 * 1024) {
        return error.InvalidHeapSize;
    }
    // stack bounds check against detected native stack
    global_limits.native_stack_bytes = detectNativeMainStack();
    global_limits.stack_max_bytes = safeStackMax(global_limits.native_stack_bytes);
    if (global_limits.stack_max_bytes < 128 * 1024) {
        return error.NativeStackTooSmall;
    }
    if (global_limits.stack_bytes < 128 * 1024) {
        return error.InvalidStackSize;
    }
    if (global_limits.stack_bytes > global_limits.stack_max_bytes) {
        return error.StackSizeExceedsNative;
    }
    global_limits.worker_stack_bytes = workerStackFor(global_limits.stack_bytes);
    // worker heap 1 MB..heap_bytes (default clamped to min(32MB, heap))
    if (!worker_heap_explicit) {
        global_limits.worker_heap_bytes = @min(32 * 1024 * 1024, global_limits.heap_bytes);
    } else {
        if (global_limits.worker_heap_bytes < 1024 * 1024 or global_limits.worker_heap_bytes > global_limits.heap_bytes) {
            return error.InvalidWorkerHeapSize;
        }
    }
    // cpu-budget 0..3 600 000 ms
    if (global_limits.cpu_budget_ms > 3_600_000) {
        return error.InvalidCpuBudget;
    }
}

pub fn parseByteSize(s: []const u8) LimitsError!usize {
    if (s.len == 0) return error.InvalidByteSize;
    var multiplier: usize = 1;
    var num_slice = s;
    const last = s[s.len - 1];
    if (last == 'k' or last == 'K') {
        multiplier = 1024;
        num_slice = s[0 .. s.len - 1];
    } else if (last == 'm' or last == 'M') {
        multiplier = 1024 * 1024;
        num_slice = s[0 .. s.len - 1];
    } else if (last == 'g' or last == 'G') {
        multiplier = 1024 * 1024 * 1024;
        num_slice = s[0 .. s.len - 1];
    } else if (std.ascii.endsWithIgnoreCase(s, "mb")) {
        multiplier = 1024 * 1024;
        num_slice = s[0 .. s.len - 2];
    } else if (std.ascii.endsWithIgnoreCase(s, "gb")) {
        multiplier = 1024 * 1024 * 1024;
        num_slice = s[0 .. s.len - 2];
    } else if (std.ascii.endsWithIgnoreCase(s, "kb")) {
        multiplier = 1024;
        num_slice = s[0 .. s.len - 2];
    }

    const n = std.fmt.parseInt(usize, num_slice, 10) catch return error.InvalidByteSize;
    return std.math.mul(usize, n, multiplier) catch return error.InvalidByteSize;
}

test "safeStackMax aligns backward to half of native" {
    const page_sz = std.heap.page_size_min;
    try std.testing.expectEqual(4 * 1024 * 1024, safeStackMax(8 * 1024 * 1024));
    try std.testing.expectEqual(8 * 1024 * 1024, safeStackMax(16 * 1024 * 1024));
    const odd_size = 8 * 1024 * 1024 + page_sz + 1;
    const expected = std.mem.alignBackward(usize, odd_size / 2, page_sz);
    try std.testing.expectEqual(expected, safeStackMax(odd_size));
}

test "workerStackFor ensures at least 8MB and at least 2x JS stack" {
    try std.testing.expectEqual(WORKER_STACK_MIN, workerStackFor(1024 * 1024));
    try std.testing.expectEqual(WORKER_STACK_MIN, workerStackFor(4 * 1024 * 1024));
    try std.testing.expectEqual(16 * 1024 * 1024, workerStackFor(8 * 1024 * 1024));
    // Test runtime page-alignment on non-power-of-2 byte inputs
    const aligned_odd = workerStackFor(5_000_000);
    try std.testing.expect(aligned_odd >= 10_000_000);
    try std.testing.expectEqual(@as(usize, 0), aligned_odd % std.heap.pageSize());
}

test "detectNativeMainStack returns plausible value" {
    const sz = detectNativeMainStack();
    try std.testing.expect(sz >= 512 * 1024);
}

test "RuntimeLimits struct layout" {
    try std.testing.expect(@sizeOf(RuntimeLimits) <= 128);
    try std.testing.expect(@alignOf(RuntimeLimits) == @alignOf(usize));
}

test "parseWallTimeout validates bounds" {
    try std.testing.expectEqual(@as(u32, 0), try parseWallTimeout("0"));
    try std.testing.expectEqual(@as(u32, 5000), try parseWallTimeout("5000"));
    try std.testing.expectEqual(WALL_TIMEOUT_MAX_MS, try parseWallTimeout("3600000"));
    try std.testing.expectError(error.InvalidWallTimeout, parseWallTimeout("3600001"));
    try std.testing.expectError(error.InvalidWallTimeout, parseWallTimeout("-1"));
    try std.testing.expectError(error.InvalidWallTimeout, parseWallTimeout("abc"));
}

test "parseMaxLogBytes validates size and cap" {
    try std.testing.expectEqual(@as(usize, 0), try parseMaxLogBytes("0"));
    try std.testing.expectEqual(@as(usize, 64 * 1024), try parseMaxLogBytes("64KB"));
    try std.testing.expectEqual(@as(usize, 10 * 1024 * 1024), try parseMaxLogBytes("10MB"));
    try std.testing.expectEqual(MAX_LOG_BYTES_CAP, try parseMaxLogBytes("100MB"));
    try std.testing.expectError(error.InvalidMaxLogBytes, parseMaxLogBytes("101MB"));
    try std.testing.expectError(error.InvalidMaxLogBytes, parseMaxLogBytes(""));
}

test "parseByteSize handles all unit suffixes and rejects invalid input" {
    try std.testing.expectEqual(@as(usize, 1024), try parseByteSize("1024"));
    try std.testing.expectEqual(@as(usize, 4 * 1024), try parseByteSize("4k"));
    try std.testing.expectEqual(@as(usize, 4 * 1024), try parseByteSize("4K"));
    try std.testing.expectEqual(@as(usize, 4 * 1024), try parseByteSize("4KB"));
    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), try parseByteSize("2m"));
    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), try parseByteSize("2M"));
    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), try parseByteSize("2MB"));
    try std.testing.expectEqual(@as(usize, 1024 * 1024 * 1024), try parseByteSize("1g"));
    try std.testing.expectEqual(@as(usize, 1024 * 1024 * 1024), try parseByteSize("1G"));
    try std.testing.expectEqual(@as(usize, 1024 * 1024 * 1024), try parseByteSize("1GB"));
    try std.testing.expectError(error.InvalidByteSize, parseByteSize(""));
    try std.testing.expectError(error.InvalidByteSize, parseByteSize("abc"));
    try std.testing.expectError(error.InvalidByteSize, parseByteSize("99999999999999999999GB"));
}
