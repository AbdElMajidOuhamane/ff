const std = @import("std");
const engine = @import("../engine/engine.zig");
pub fn run(io: std.Io, init: std.process.Init) !void {
    const dir = std.Io.Dir.cwd();
    const allocator = std.heap.page_allocator;
    const ff_content = dir.readFileAlloc(io, "ff.json", allocator, .limited(1024 * 1024)) catch {
        std.debug.print("No ff.json found. Run 'ff init' first.\n", .{});
        return;
    };
    defer allocator.free(ff_content);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, ff_content, .{}) catch {
        std.debug.print("ff.json is not valid JSON.\n", .{});
        return;
    };
    defer parsed.deinit();
    const main_val = parsed.value.object.get("main") orelse {
        std.debug.print("ff.json is missing the 'main' field.\n", .{});
        return;
    };
    const main_name = main_val.string;
    var main_name_buf = allocator.alloc(u8, main_name.len + 1) catch return;
    defer allocator.free(main_name_buf);
    @memcpy(main_name_buf[0..main_name.len], main_name);
    main_name_buf[main_name.len] = 0;
    const main_name_z: [:0]const u8 = main_name_buf[0..main_name.len :0];
    const js_content = dir.readFileAlloc(io, main_name, allocator, .limited(10 * 1024 * 1024)) catch {
        std.debug.print("Could not open '{s}'.\n", .{main_name});
        return;
    };
    defer allocator.free(js_content);
    const source: [:0]const u8 = allocator.dupeZ(u8, js_content) catch return;
    defer allocator.free(source);
    const runtime = try engine.Runtime.init(init.minimal.args);
    // DOD-FIX 9: boot_arena is the sole owner of `runtime` and
    // `runtime.event_loop`. Runtime.deinit() frees the arena.
    defer {
        engine.deinitNetwork();
        runtime.event_loop.deinit();
        runtime.deinit();
    }
    _ = runtime.evalModule(source, main_name_z);
    try runtime.event_loop.run();
}
