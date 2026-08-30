// Node fs shim — re-exports the native fs global with Node sync-name aliases.
// The native implementations are synchronous under the hood, so the aliasing
// is semantically accurate (not a sync-wrapping-over-async approximation).
"use strict";

const native = globalThis.fs || {};

const fs = Object.assign({}, native, {
    // Node sync-name aliases
    readFileSync: native.readFile,
    writeFileSync: native.writeFile,
    existsSync: native.exists,
    mkdirSync: native.mkdir,
    rmdirSync: native.rm,
    rmSync: native.rm,
    readdirSync: native.readdir,

    // Not yet implemented (static-file serving lands with fs.stat in E3)
    statSync: function () { throw new Error("fs.statSync: not implemented"); },
    lstatSync: function () { throw new Error("fs.lstatSync: not implemented"); },
    createReadStream: function () { throw new Error("fs.createReadStream: not implemented"); },
    createWriteStream: function () { throw new Error("fs.createWriteStream: not implemented"); },

    promises: {},
    constants: { F_OK: 0, R_OK: 4, W_OK: 2, X_OK: 1 },
});

module.exports = fs;
