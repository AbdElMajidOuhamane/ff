const std = @import("std");

pub const RuntimeLimits = struct {
    heap_bytes: usize = 64 * 1024 * 1024,
    stack_bytes: usize = 1024 * 1024,
    worker_heap_bytes: usize = 32 * 1024 * 1024,
    cpu_budget_ms: u32 = 0, // 0 = disabled
    env_file: ?[]const u8 = null,
};

pub const LimitsError = error{
    InvalidHeapSize,
    InvalidStackSize,
    InvalidWorkerHeapSize,
    InvalidCpuBudget,
    MissingEnvFilePath,
    InvalidByteSize,
};

var global_limits: RuntimeLimits = .{};
var initialized: bool = false;

pub fn get() *const RuntimeLimits {
    return &global_limits;
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
            global_limits.stack_bytes = parseByteSize(val) catch return error.InvalidStackSize;
        } else if (std.mem.eql(u8, a, "--max-stack")) {
            const val = it.next() orelse return error.InvalidStackSize;
            global_limits.stack_bytes = parseByteSize(val) catch return error.InvalidStackSize;
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
    // stack 128 KB..64 MB
    if (global_limits.stack_bytes < 128 * 1024 or global_limits.stack_bytes > 64 * 1024 * 1024) {
        return error.InvalidStackSize;
    }
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
