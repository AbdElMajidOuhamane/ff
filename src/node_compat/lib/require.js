// Node require layer — resolution in JS, evaluation via __evalCJS.
"use strict";

const __path = __builtinRequire("path");

const jsonCache = new Map();

// Read a file as text; directories and unreadable paths return null.
function tryRead(p) {
    try {
        const src = __fsReadFile(p);
        if (typeof src === "string") return src;
    } catch (_) {}
    return null;
}

function loadAsFileOrDir(target) {
    // as file — readFile on a directory throws, so tryRead filters dirs out
    for (const p of [target, target + ".js", target + ".json"]) {
        if (__fsExists(p)) {
            const src = tryRead(p);
            if (src !== null) return { path: p, source: src };
        }
    }
    // as directory
    if (__fsExists(target)) {
        const pkgPath = __path.join(target, "package.json");
        if (__fsExists(pkgPath)) {
            const pkgSrc = tryRead(pkgPath);
            if (pkgSrc !== null) {
                try {
                    const main = JSON.parse(pkgSrc).main;
                    if (typeof main === "string" && main.length > 0) {
                        const mainPath = __path.resolve(target, main);
                        for (const p of [mainPath, mainPath + ".js", __path.join(mainPath, "index.js")]) {
                            if (__fsExists(p)) {
                                const src = tryRead(p);
                                if (src !== null) return { path: p, source: src };
                            }
                        }
                    }
                } catch (_) { /* malformed package.json: fall through */ }
            }
        }
        for (const p of [__path.join(target, "index.js"), __path.join(target, "index.json")]) {
            if (__fsExists(p)) {
                const src = tryRead(p);
                if (src !== null) return { path: p, source: src };
            }
        }
    }
    return null;
}

function resolve(name, fromFile) {
    if (name.startsWith("./") || name.startsWith("../") || name.startsWith("/")) {
        const base = fromFile ? __path.dirname(fromFile) : ".";
        const found = loadAsFileOrDir(__path.resolve(base, name));
        if (found === null) throw new Error("Cannot find module '" + name + "'");
        return found;
    }
    // bare specifier: node_modules walk-up
    let dir = fromFile ? __path.dirname(__path.resolve(fromFile)) : process.cwd();
    while (true) {
        const found = loadAsFileOrDir(__path.join(dir, "node_modules", name));
        if (found !== null) return found;
        const parent = __path.dirname(dir);
        if (parent === dir) break;
        dir = parent;
    }
    throw new Error("Cannot find module '" + name + "'");
}

function jsRequire(name, fromFile) {
    if (typeof name !== "string" || name.length === 0) {
        throw new TypeError("require: module name must be a non-empty string");
    }
    let n = name;
    if (n.length > 5 && n.startsWith("node:")) n = n.slice(5);

    const b = __builtinRequire(n);
    if (b !== undefined) return b;

    const r = resolve(n, fromFile);
    if (r.path.endsWith(".json")) {
        if (jsonCache.has(r.path)) return jsonCache.get(r.path);
        const parsed = JSON.parse(r.source);
        jsonCache.set(r.path, parsed);
        return parsed;
    }
    const moduleRequire = (dep) => jsRequire(dep, r.path);
    return __evalCJS(r.path, r.source, moduleRequire);
}

globalThis.require = function (name) {
    return jsRequire(name, undefined);
};
