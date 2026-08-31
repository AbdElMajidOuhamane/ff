const std = @import("std");
const Allocator = std.mem.Allocator;
const loader = @import("loader.zig");
const Module = loader.Module;

// NOTE: DOD-FIX 8 (u32-keyed cache) was reverted. The cross-Module
// key coordination required a shared arena that the codebase doesn't
// have, and the StringHashMap is fine in practice for the cache sizes
// this runtime sees.
pub const ModuleCache = struct {
    map: std.StringHashMap(*Module),

    pub fn init(allocator: Allocator) ModuleCache {
        return .{ .map = std.StringHashMap(*Module).init(allocator) };
    }

    pub fn deinit(self: *ModuleCache) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.map.deinit();
    }

    pub fn get(self: *ModuleCache, path: []const u8) ?*Module {
        return self.map.get(path);
    }

    pub fn put(self: *ModuleCache, path: []const u8, module: *Module) !void {
        try self.map.put(path, module);
    }
};
