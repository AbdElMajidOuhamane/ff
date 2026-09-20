const ffcfg = @import("ffcfg");

pub const bssl = if (ffcfg.bearssl) @import("bearssl_c") else struct {};
