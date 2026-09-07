pub const ImportType = enum {
    default,
    named,
    namespace,
};

// DOD-FIX 7: strings are now PoolSlice handles into a Module-owned arena.
pub const Import = struct {
    specifier: PoolSlice,
    local_name: PoolSlice,
    export_name: PoolSlice,
    import_type: ImportType,
};

pub const ExportType = enum {
    default,
    named,
    reexport,
};

pub const Export = struct {
    export_type: ExportType,
    name: PoolSlice,
    local_name: PoolSlice,
    source: ?PoolSlice,
};

pub const PoolSlice = @import("../types/pool_slice.zig").PoolSlice;
