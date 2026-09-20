const std = @import("std");

pub const PoolSlice = struct { off: u32 = 0, len: u32 = 0 };
comptime {
    std.debug.assert(@sizeOf(PoolSlice) == 8);
}
