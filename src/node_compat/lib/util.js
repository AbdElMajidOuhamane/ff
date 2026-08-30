// Node util — format / formatWithOptions / promisify / inherits / deprecate / types / inspect.
"use strict";

function refPrefix(value, seen, str) {
    const e = seen.get(value);
    return e && e.revisited ? "<ref *" + e.id + "> " + str : str;
}

function formatKey(k) {
    return /^[A-Za-z_$][A-Za-z0-9_$]*$/.test(k) ? k : quoteString(k);
}

function quoteString(s) {
    return "'" + String(s)
        .replace(/\\/g, "\\\\")
        .replace(/'/g, "\\'")
        .replace(/\n/g, "\\n")
        .replace(/\r/g, "\\r")
        .replace(/\t/g, "\\t") + "'";
}

function inspect(value, opts, seen, depth) {
    if (opts === undefined || typeof opts !== "object") opts = {};
    const maxDepth = opts.depth !== undefined ? opts.depth : 2;
    if (seen === undefined) seen = new Map();
    if (depth === undefined) depth = 0;

    if (value === null) return "null";
    if (value === undefined) return "undefined";
    const t = typeof value;
    if (t === "number") return Number.isNaN(value) ? "NaN" : String(value);
    if (t === "bigint") return String(value) + "n";
    if (t === "boolean") return String(value);
    if (t === "symbol") return value.toString();
    if (t === "string") return quoteString(value);
    if (t === "function") {
        return value.name ? "[Function: " + value.name + "]" : "[Function (anonymous)]";
    }

    if (seen.has(value)) {
        const entry = seen.get(value);
        entry.revisited = true;
        return "[Circular *" + entry.id + "]";
    }
    if (depth > maxDepth) return Array.isArray(value) ? "[Array]" : "[Object]";
    seen.rc = (seen.rc || 0) + 1;
    seen.set(value, { id: seen.rc, revisited: false });

    try {
        if (typeof Buffer !== "undefined" && Buffer.isBuffer(value)) {
            let hex = "";
            for (let i = 0; i < Math.min(value.length, 512); i++) {
                hex += (i > 0 ? " " : "") + value[i].toString(16).padStart(2, "0");
            }
            return value.length === 0 ? "<Buffer>" : "<Buffer " + hex + ">";
        }
        if (value instanceof Error) {
            return value.stack || ("[" + value.name + ": " + value.message + "]");
        }
        if (value instanceof Date) {
            return isNaN(value.getTime()) ? "Invalid Date" : value.toISOString();
        }
        if (value instanceof RegExp) return value.toString();
        if (value instanceof Map) {
            const parts = [];
            for (const [k, v] of value) {
                parts.push(inspect(k, opts, seen, depth + 1) + " => " + inspect(v, opts, seen, depth + 1));
            }
            return refPrefix(value, seen, "Map(" + value.size + ") {" + (parts.length ? " " + parts.join(", ") + " " : "") + "}");
        }
        if (value instanceof Set) {
            const parts = [];
            for (const v of value) parts.push(inspect(v, opts, seen, depth + 1));
            return refPrefix(value, seen, "Set(" + value.size + ") {" + (parts.length ? " " + parts.join(", ") + " " : "") + "}");
        }
        if (ArrayBuffer.isView(value) && !(value instanceof Uint8Array)) {
            const name = value.constructor && value.constructor.name || "TypedArray";
            const items = [];
            for (let i = 0; i < Math.min(value.length, 100); i++) items.push(String(value[i]));
            return name + "(" + value.length + ") [" + items.join(", ") + "]";
        }
        if (Array.isArray(value)) {
            if (value.length === 0) return "[]";
            const parts = value.map((v) => inspect(v, opts, seen, depth + 1));
            return refPrefix(value, seen, "[ " + parts.join(", ") + " ]");
        }
        const keys = Object.keys(value);
        if (keys.length === 0) {
            const proto = Object.getPrototypeOf(value);
            const cname = proto && proto.constructor && proto.constructor.name;
            return cname && cname !== "Object" ? cname + " {}" : "{}";
        }
        const parts = keys.map((k) => formatKey(k) + ": " + inspect(value[k], opts, seen, depth + 1));
        return refPrefix(value, seen, "{ " + parts.join(", ") + " }");
    } finally {
        seen.delete(value);
    }
}

// ── format ──────────────────────────────────────────────────
function format(f) {
    if (typeof f !== "string") {
        const args = Array.prototype.slice.call(arguments);
        if (args.length === 0) return "";
        let out = "";
        for (let i = 0; i < args.length; i++) {
            out += (i > 0 ? " " : "") + (typeof args[i] === "string" ? args[i] : inspect(args[i]));
        }
        return out;
    }
    let argIndex = 1;
    let out = "";
    let i = 0;
    while (i < f.length) {
        const ch = f[i];
        if (ch !== "%") { out += ch; i++; continue; }
        const spec = f[i + 1];
        if (spec === "%") { out += "%"; i += 2; continue; }
        const arg = arguments[argIndex];
        if (spec === "s") { out += typeof arg === "string" ? arg : inspect(arg); argIndex++; i += 2; continue; }
        if (spec === "d" || spec === "i") {
            out += String(typeof arg === "bigint" ? arg : parseInt(arg, 10));
            argIndex++; i += 2; continue;
        }
        if (spec === "f") { out += String(parseFloat(arg)); argIndex++; i += 2; continue; }
        if (spec === "j") {
            try { out += JSON.stringify(arg); } catch (_) { out += "[Circular]"; }
            argIndex++; i += 2; continue;
        }
        if (spec === "o" || spec === "O") { out += inspect(arg); argIndex++; i += 2; continue; }
        out += "%"; i++; // unknown specifier: literal
    }
    for (; argIndex < arguments.length; argIndex++) {
        const a = arguments[argIndex];
        out += " " + (typeof a === "string" ? a : inspect(a));
    }
    return out;
}

function formatWithOptions(inspectOpts, f, ...args) {
    // P0 subset: inspect options (colors/depth) are ignored — debug runs
    // colorless because tty.isatty() is stubbed false.
    return format(f, ...args);
}

// ── promisify / callbackify ─────────────────────────────────
const kCustomPromisified = Symbol.for("nodejs.util.promisify.custom");

function promisify(fn) {
    if (typeof fn !== "function") throw new TypeError('The "original" argument must be of type Function');
    const source = fn[kCustomPromisified] || fn;
    const promisified = function (...args) {
        return new Promise((resolve, reject) => {
            source.call(this, ...args, (err, ...values) => {
                if (err) reject(err);
                else resolve(values.length > 1 ? values : values[0]);
            });
        });
    };
    promisified.__proto__ = source.__proto__ === Function.prototype ? Function.prototype : source.__proto__;
    Object.defineProperty(promisified, "name", { value: "promisified_" + (source.name || "anonymous") });
    return promisified;
}
promisify.custom = kCustomPromisified;

function callbackify(fn) {
    if (typeof fn !== "function") throw new TypeError('The "original" argument must be of type Function');
    return function (...args) {
        const cb = args.pop();
        if (typeof cb !== "function") throw new TypeError('The last argument must be of type Function');
        fn.apply(this, args).then(
            (value) => cb(null, value),
            (err) => cb(err)
        );
    };
}

// ── misc ────────────────────────────────────────────────────
// Node-exact legacy branch: modules without .prototype (e.g. passing the
// `stream` module object itself, as `send` does) get a prototype assigned,
// not setPrototypeOf — QuickJS throws on setPrototypeOf(x, undefined).
function inherits(ctor, superCtor) {
    if (ctor === undefined || ctor === null) {
        throw new TypeError("The constructor must be of type Function");
    }
    if (superCtor === undefined || superCtor === null) {
        throw new TypeError("The super constructor must be of type Function");
    }
    // Node-exact: only undefined/null are rejected — non-function superCtors
    // (e.g. the `stream` module object, as `send` passes) take the assign branch.
    if (superCtor.prototype === undefined) {
        superCtor.prototype = Object.create(ctor.prototype, {
            constructor: { value: ctor, enumerable: false, writable: true, configurable: true },
        });
    } else {
        Object.setPrototypeOf(ctor.prototype, superCtor.prototype);
    }
    ctor.super_ = superCtor;
}

function deprecate(fn, msg) {
    let warned = false;
    function deprecated(...args) {
        if (!warned) {
            warned = true;
            console.warn("(node) " + msg + " -- Deprecation warning");
        }
        return fn.apply(this, args);
    }
    return deprecated;
}

const types = {
    isDate: (v) => v instanceof Date,
    isPromise: (v) => v instanceof Promise,
    isMap: (v) => v instanceof Map,
    isSet: (v) => v instanceof Set,
    isRegExp: (v) => v instanceof RegExp,
    isUint8Array: (v) => v instanceof Uint8Array,
    isArrayBufferView: (v) => ArrayBuffer.isView(v),
    isAnyArrayBuffer: (v) => v instanceof ArrayBuffer,
    isFunction: (v) => typeof v === "function",
    isPrimitive: (v) => v === null || (typeof v !== "object" && typeof v !== "function"),
};

module.exports = {
    format,
    formatWithOptions,
    inspect,
    promisify,
    callbackify,
    inherits,
    deprecate,
    types,
    isArray: Array.isArray,
    isBoolean: (v) => typeof v === "boolean",
    isNull: (v) => v === null,
    isNullOrUndefined: (v) => v === null || v === undefined,
    isNumber: (v) => typeof v === "number",
    isString: (v) => typeof v === "string",
    isSymbol: (v) => typeof v === "symbol",
    isUndefined: (v) => v === undefined,
    isObject: (v) => v !== null && typeof v === "object",
    isFunction: (v) => typeof v === "function",
    isBuffer: (v) => typeof Buffer !== "undefined" && Buffer.isBuffer(v),
    log: (...args) => console.log("log:", ...args),
};
