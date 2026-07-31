const std = @import("std");
const engine = @import("../engine/engine.zig");

const c = @cImport({
    @cInclude("time.h");
});

const bench_files = [_][]const u8{
    "bench/fib.js",
    "bench/sort.js",
    "bench/string.js",
    "bench/object.js",
    "bench/json.js",
    "bench/loop.js",
    "bench/closure.js",
    "bench/array.js",
};

pub fn run(io: std.Io,init : std.process.Init) !void {
    const dir = std.Io.Dir.cwd();
    const allocator = std.heap.page_allocator;

    std.debug.print("\n  Fairyfly Bench\n\n", .{});

    const runtime = try engine.Runtime.init(init.minimal.args);
    defer {
        runtime.event_loop.deinit();
        std.heap.page_allocator.destroy(runtime.event_loop);
        runtime.deinit();
        std.heap.page_allocator.destroy(runtime);
    }
    var total_ms: i64 = 0;
    var bench_count: u32 = 0;

    for (bench_files) |path| {
        const content = dir.readFileAlloc(io, path, allocator, .limited(10 * 1024 * 1024)) catch {
            std.debug.print("  {s: <25} read error\n", .{path});
            continue;
        };
        defer allocator.free(content);
        const source: [:0]const u8 = content.ptr[0..content.len :0];

        var path_z_buf = allocator.alloc(u8, path.len + 1) catch continue;
        defer allocator.free(path_z_buf);
        @memcpy(path_z_buf[0..path.len], path);
        path_z_buf[path.len] = 0;
        const path_z: [:0]const u8 = path_z_buf[0..path.len :0];

        var start_ts: c.struct_timespec = undefined;
        var end_ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &start_ts);
        _ = runtime.eval(source, path_z);
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &end_ts);

        const elapsed_ns = (@as(i64, @intCast(end_ts.tv_sec)) - @as(i64, @intCast(start_ts.tv_sec))) * 1_000_000_000 +
            (@as(i64, @intCast(end_ts.tv_nsec)) - @as(i64, @intCast(start_ts.tv_nsec)));
        const elapsed_ms = @divTrunc(elapsed_ns, 1_000_000);

        total_ms += elapsed_ms;
        bench_count += 1;

        std.debug.print("  {s: <25} {d}ms\n", .{ path, elapsed_ms });
    }

    std.debug.print("\n  Total: {d}ms ({d} benchmarks)\n\n", .{ total_ms, bench_count });
}
