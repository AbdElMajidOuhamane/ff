const std = @import("std");

/// Wraps a child allocator and counts allocation events + byte traffic.
/// Debug-only tool: proves hot paths honor their allocation budgets and
/// catches leaks mechanically (allocs != frees => something didn't clean up).
pub const CountingAllocator = struct {
    base: std.mem.Allocator,
    alloc_count: usize = 0,
    free_count: usize = 0,
    bytes_allocated: usize = 0,
    bytes_freed: usize = 0,

    pub fn reset(self: *CountingAllocator) void {
        self.alloc_count = 0;
        self.free_count = 0;
        self.bytes_allocated = 0;
        self.bytes_freed = 0;
    }

    /// Live-byte invariant: every alloc must be matched by a free.
    pub fn balanced(self: *const CountingAllocator) bool {
        return self.alloc_count == self.free_count and
            self.bytes_allocated == self.bytes_freed;
    }

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.alloc_count += 1;
        self.bytes_allocated += len;
        return self.base.rawAlloc(len, a, ra);
    }

    fn resize(ctx: *anyopaque, memory: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (self.base.rawResize(memory, a, new_len, ra)) {
            if (new_len >= memory.len) {
                self.bytes_allocated += new_len - memory.len;
            } else {
                self.bytes_freed += memory.len - new_len;
            }
            return true;
        }
        return false;
    }

    fn remap(ctx: *anyopaque, memory: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (self.base.rawRemap(memory, a, new_len, ra)) |p| {
            if (new_len >= memory.len) {
                self.bytes_allocated += new_len - memory.len;
            } else {
                self.bytes_freed += memory.len - new_len;
            }
            return p;
        }
        return null;
    }

    fn free(ctx: *anyopaque, memory: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.free_count += 1;
        self.bytes_freed += memory.len;
        self.base.rawFree(memory, a, ra);
    }
};
