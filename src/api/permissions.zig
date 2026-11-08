const c = @import("../c.zig").c;
const perm = @import("../security/permissions.zig");

fn boolVal(v: bool) c.Value {
    return if (v) c.JS_TRUE else c.JS_FALSE;
}

pub fn setup(ctx: *c.Context) void {
    const p = perm.global();
    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);

    const obj = c.newObject(ctx);
    _ = c.definePropertyValueStr(ctx, obj, "read", boolVal(p.isAllowed(.read)), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "write", boolVal(p.isAllowed(.write)), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "net", boolVal(p.isAllowed(.net)), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "env", boolVal(p.isAllowed(.env)), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "run", boolVal(p.isAllowed(.run)), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, obj, "ffi", boolVal(p.isAllowed(.ffi)), c.PROP_C_W_E);
    _ = c.definePropertyValueStr(ctx, global, "permissions", obj, c.PROP_C_W_E);
}
