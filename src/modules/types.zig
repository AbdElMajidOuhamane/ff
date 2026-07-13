pub const ImportType = enum {
    default,
    named,
    namespace,
};

pub const Import = struct {
    specifier: []const u8,
    local_name: []const u8,
    export_name: []const u8,
    import_type: ImportType,
};

pub const ExportType = enum {
    default,
    named,
    reexport,
};

pub const Export = struct {
    export_type: ExportType,
    name: []const u8,
    local_name: []const u8,
    source: ?[]const u8,
};
