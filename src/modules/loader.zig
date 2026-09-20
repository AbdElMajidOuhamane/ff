const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const Import = types.Import;
const Export = types.Export;
const PoolSlice = types.PoolSlice;
const parse = @import("parse.zig");

pub const Module = struct {
    allocator: Allocator,
    source: []const u8,
    path: []const u8,
    dir: []const u8,
    imports: std.ArrayList(Import),
    exports: std.ArrayList(Export),
   
    strings: std.ArrayList(u8),

    pub fn init(allocator: Allocator, source: []const u8, path: []const u8, dir: []const u8) Module {
        return .{
            .allocator = allocator,
            .source = source,
            .path = path,
            .dir = dir,
            .imports = .empty,
            .exports = .empty,
            .strings = .empty,
        };
    }

    pub fn deinit(self: *Module) void {
       
        self.imports.deinit(self.allocator);
        self.exports.deinit(self.allocator);
        self.strings.deinit(self.allocator);
    }

    pub fn sliceAt(self: *const Module, ps: PoolSlice) []const u8 {
        return self.strings.items[ps.off .. ps.off + ps.len];
    }

    fn interner(self: *Module) parse.Interner {
        return .{ .allocator = self.allocator, .strings = &self.strings };
    }

    pub fn parseImports(self: *Module) !void {
        try parse.parseImports(self.allocator, self.interner(), self.source, &self.imports);
    }

    pub fn parseExports(self: *Module) !void {
        try parse.parseExports(self.allocator, self.interner(), self.source, &self.exports);
    }
};
