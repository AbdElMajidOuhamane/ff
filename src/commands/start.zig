const std = @import("std");
const engine = @import("../engine/engine.zig");
pub fn run(io: std.Io,init:std.process.Init) !void {
    const dir = std.Io.Dir.cwd();
    const allocator = std.heap.page_allocator;
    // 1. Read ff.json directly with readFileAlloc
    const ff_content = dir.readFileAlloc(io, "ff.json", allocator, .limited(1024 * 1024)) catch {
        std.debug.print("No ff.json found. Run 'ff init' first.\n", .{});
        return;
    };
    defer allocator.free(ff_content);
    // 2. Parse JSON
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, ff_content, .{}) catch {
        std.debug.print("ff.json is not valid JSON.\n", .{});
        return;
    };
    defer parsed.deinit();
    // 3. Get "main" field
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
    // 4. Read the JS file
    const js_content = dir.readFileAlloc(io, main_name, allocator, .limited(10 * 1024 * 1024)) catch {
        std.debug.print("Could not open '{s}'.\n", .{main_name});
        return;
    };
    defer allocator.free(js_content);
    const source: [:0]const u8 = allocator.dupeZ(u8, js_content) catch return;
    defer allocator.free(source);
    // 5. Run it
     const runtime = try engine.Runtime.init(init.minimal.args);
    defer {
        engine.deinitNetwork();                         
        runtime.event_loop.deinit();
        std.heap.page_allocator.destroy(runtime.event_loop);
        runtime.deinit();
        std.heap.page_allocator.destroy(runtime);
    }
    _ = runtime.evalModule(source, main_name_z);
    try runtime.event_loop.run();
}
