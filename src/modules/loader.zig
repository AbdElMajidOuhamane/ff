const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const Import = types.Import;
const Export = types.Export;
const parse = @import("parse.zig");

pub const Module = struct {
    allocator: Allocator,
    source: []const u8,
    path: []const u8,
    dir: []const u8,
    imports: std.ArrayList(Import),
    exports: std.ArrayList(Export),

    pub fn init(allocator: Allocator, source: []const u8, path: []const u8, dir: []const u8) Module {
        return .{
            .allocator = allocator,
            .source = source,
            .path = path,
            .dir = dir,
            .imports = .empty,
            .exports = .empty,
        };
    }

    pub fn deinit(self: *Module) void {
        self.imports.deinit(self.allocator);
        self.exports.deinit(self.allocator);
    }

    pub fn parseImports(self: *Module) !void {
        try parse.parseImports(self.allocator, self.source, &self.imports);
    }

    pub fn parseExports(self: *Module) !void {
        try parse.parseExports(self.allocator, self.source, &self.exports);
    }
};
