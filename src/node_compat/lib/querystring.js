// Node querystring — escape emits %20 (NOT '+'); parse decodes '+' as space.
// Verified against Node oracle.
"use strict";

function qsEscape(str) {
    return encodeURIComponent(String(str)); // Node: no '+' substitution
}

function qsUnescape(str) {
    return decodeURIComponent(String(str)); // Node's exported unescape: no '+' handling
}

function decodeQS(str) {
    // internal parse decoder: '+' means space (verified: parse("a=x+y") -> "x y")
    return decodeURIComponent(String(str).replace(/\+/g, " "));
}

function parse(qs, sep, eq, options) {
    const obj = Object.create(null);
    if (typeof qs !== "string" || qs.length === 0) return obj;

    if (typeof sep !== "string") sep = "&";
    if (typeof eq !== "string") eq = "=";

    const maxKeys = options && typeof options.maxKeys === "number"
        ? (options.maxKeys > 0 ? options.maxKeys : Infinity)
        : 1000;

    const pairs = qs.split(sep);
    let keys = 0;
    for (let i = 0; i < pairs.length; i++) {
        const pair = pairs[i];
        if (pair.length === 0) continue;
        const eqi = pair.indexOf(eq);
        let key, val;
        if (eqi === -1) {
            key = decodeQS(pair);
            val = "";
        } else {
            key = decodeQS(pair.slice(0, eqi));
            val = decodeQS(pair.slice(eqi + eq.length));
        }
        if (obj[key] === undefined) {
            obj[key] = val;
        } else if (Array.isArray(obj[key])) {
            obj[key].push(val);
        } else {
            obj[key] = [obj[key], val];
        }
        if (++keys >= maxKeys) break;
    }
    return obj;
}

function stringify(obj, sep, eq, options) {
    if (typeof sep !== "string") sep = "&";
    if (typeof eq !== "string") eq = "=";
    let out = "";
    for (const key of Object.keys(obj)) {
        const value = obj[key];
        const k = qsEscape(key) + eq;
        if (Array.isArray(value)) {
            for (let i = 0; i < value.length; i++) {
                if (out.length) out += sep;
                out += k + qsEscape(value[i]);
            }
        } else {
            if (out.length) out += sep;
            out += k + qsEscape(value);
        }
    }
    return out;
}

module.exports = {
    parse,
    stringify,
    escape: qsEscape,
    unescape: qsUnescape,
    defaultEncoder: qsEscape,
    defaultDecoder: qsUnescape,
};
