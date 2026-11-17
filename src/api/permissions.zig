const std = @import("std");
const c = @import("../c.zig").c;
const perm = @import("../security/permissions.zig");

fn boolVal(v: bool) c.Value {
    return if (v) c.JS_TRUE else c.JS_FALSE;
}

fn getRead(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = ctx;
    _ = this_val;
    _ = argc;
    _ = argv;
    return boolVal(perm.global().isAllowed(.read));
}
fn getWrite(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = ctx;
    _ = this_val;
    _ = argc;
    _ = argv;
    return boolVal(perm.global().isAllowed(.write));
}
fn getNet(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = ctx;
    _ = this_val;
    _ = argc;
    _ = argv;
    return boolVal(perm.global().isAllowed(.net));
}
fn getEnv(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = ctx;
    _ = this_val;
    _ = argc;
    _ = argv;
    return boolVal(perm.global().isAllowed(.env));
}
fn getRun(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = ctx;
    _ = this_val;
    _ = argc;
    _ = argv;
    return boolVal(perm.global().isAllowed(.run));
}
fn getFfi(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = ctx;
    _ = this_val;
    _ = argc;
    _ = argv;
    return boolVal(perm.global().isAllowed(.ffi));
}

fn revokeCallback(ctx: ?*c.Context, this_val: c.Value, argc: c_int, argv: [*c]c.Value) callconv(.c) c.Value {
    _ = this_val;
    if (argc < 1 or c.isObject(argv[0]) == 0) return c.JS_UNDEFINED;
    const name_val = c.getPropertyStr(ctx, argv[0], "name");
    defer c.freeValue(ctx, name_val);
    if (c.isString(name_val) == 0) return c.JS_UNDEFINED;
    var len: usize = 0;
    const cstr = c.toCStringLen(ctx, &len, name_val) orelse return c.JS_UNDEFINED;
    defer c.freeCString(ctx, cstr);
    const kind_str = cstr[0..len];

    const path_val = c.getPropertyStr(ctx, argv[0], "path");
    defer c.freeValue(ctx, path_val);
    const host_val = c.getPropertyStr(ctx, argv[0], "host");
    defer c.freeValue(ctx, host_val);
    const var_val = c.getPropertyStr(ctx, argv[0], "variable");
    defer c.freeValue(ctx, var_val);

    if (std.mem.eql(u8, kind_str, "read")) {
        if (c.isString(path_val) != 0) {
            var plen: usize = 0;
            if (c.toCStringLen(ctx, &plen, path_val)) |pstr| {
                defer c.freeCString(ctx, pstr);
                perm.revokePath(.read, pstr[0..plen]);
                return c.JS_UNDEFINED;
            }
        }
        perm.revoke(.read);
    } else if (std.mem.eql(u8, kind_str, "write")) {
        if (c.isString(path_val) != 0) {
            var plen: usize = 0;
            if (c.toCStringLen(ctx, &plen, path_val)) |pstr| {
                defer c.freeCString(ctx, pstr);
                perm.revokePath(.write, pstr[0..plen]);
                return c.JS_UNDEFINED;
            }
        }
        perm.revoke(.write);
    } else if (std.mem.eql(u8, kind_str, "net")) {
        if (c.isString(host_val) != 0) {
            var hlen: usize = 0;
            if (c.toCStringLen(ctx, &hlen, host_val)) |hstr| {
                defer c.freeCString(ctx, hstr);
                perm.revokeNet(hstr[0..hlen]);
                return c.JS_UNDEFINED;
            }
        }
        perm.revoke(.net);
    } else if (std.mem.eql(u8, kind_str, "env")) {
        if (c.isString(var_val) != 0) {
            var vlen: usize = 0;
            if (c.toCStringLen(ctx, &vlen, var_val)) |vstr| {
                defer c.freeCString(ctx, vstr);
                perm.revokeEnv(vstr[0..vlen]);
                return c.JS_UNDEFINED;
            }
        }
        perm.revoke(.env);
    } else if (std.mem.eql(u8, kind_str, "run")) {
        perm.revoke(.run);
    } else if (std.mem.eql(u8, kind_str, "ffi")) {
        perm.revoke(.ffi);
    }
    return c.JS_UNDEFINED;
}

pub fn setup(ctx: *c.Context) void {
    const global = c.getGlobalObject(ctx);
    defer c.freeValue(ctx, global);

    const obj = c.newObject(ctx);
    // Bind dynamic getters using definePropertyGetSet
    const p_atom_read = c.newAtom(ctx, "read");
    defer c.freeAtom(ctx, p_atom_read);
    _ = c.definePropertyGetSet(ctx, obj, p_atom_read, c.newCFunction(ctx, getRead, "read", 0), c.JS_UNDEFINED, c.PROP_CONFIGURABLE | c.PROP_ENUMERABLE);

    const p_atom_write = c.newAtom(ctx, "write");
    defer c.freeAtom(ctx, p_atom_write);
    _ = c.definePropertyGetSet(ctx, obj, p_atom_write, c.newCFunction(ctx, getWrite, "write", 0), c.JS_UNDEFINED, c.PROP_CONFIGURABLE | c.PROP_ENUMERABLE);

    const p_atom_net = c.newAtom(ctx, "net");
    defer c.freeAtom(ctx, p_atom_net);
    _ = c.definePropertyGetSet(ctx, obj, p_atom_net, c.newCFunction(ctx, getNet, "net", 0), c.JS_UNDEFINED, c.PROP_CONFIGURABLE | c.PROP_ENUMERABLE);

    const p_atom_env = c.newAtom(ctx, "env");
    defer c.freeAtom(ctx, p_atom_env);
    _ = c.definePropertyGetSet(ctx, obj, p_atom_env, c.newCFunction(ctx, getEnv, "env", 0), c.JS_UNDEFINED, c.PROP_CONFIGURABLE | c.PROP_ENUMERABLE);

    const p_atom_run = c.newAtom(ctx, "run");
    defer c.freeAtom(ctx, p_atom_run);
    _ = c.definePropertyGetSet(ctx, obj, p_atom_run, c.newCFunction(ctx, getRun, "run", 0), c.JS_UNDEFINED, c.PROP_CONFIGURABLE | c.PROP_ENUMERABLE);

    const p_atom_ffi = c.newAtom(ctx, "ffi");
    defer c.freeAtom(ctx, p_atom_ffi);
    _ = c.definePropertyGetSet(ctx, obj, p_atom_ffi, c.newCFunction(ctx, getFfi, "ffi", 0), c.JS_UNDEFINED, c.PROP_CONFIGURABLE | c.PROP_ENUMERABLE);

    const revoke_fn = c.newCFunction(ctx, revokeCallback, "revoke", 1);
    _ = c.definePropertyValueStr(ctx, obj, "revoke", revoke_fn, c.PROP_C_W_E);

    _ = c.definePropertyValueStr(ctx, global, "permissions", obj, c.PROP_C_W_E);
}
