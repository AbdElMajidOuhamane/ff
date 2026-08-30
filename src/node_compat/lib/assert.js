// Node assert — common surface (ok, equals variants, deep*, throws, ifError, fail).
"use strict";

class AssertionError extends Error {
    constructor(options) {
        const actual = options ? options.actual : undefined;
        const expected = options ? options.expected : undefined;
        const operator = options ? options.operator : "";
        let msg = options ? options.message : undefined;
        if (!msg) {
            msg = inspect(actual) + " " + (operator || "===") + " " + inspect(expected);
        }
        super(msg);
        this.name = "AssertionError";
        this.code = "ERR_ASSERTION";
        this.actual = actual;
        this.expected = expected;
        this.operator = operator;
        this.generatedMessage = !options || !options.message;
    }
}

function inspect(v) {
    if (typeof v === "string") return JSON.stringify(v);
    try { return JSON.stringify(v); } catch (_) { return String(v); }
}

function fail(message, ...rest) {
    if (typeof message === "string" && rest.length > 0) {
        message = message + " " + rest.map(String).join(" ");
    }
    throw new AssertionError({ message: message || "Failed" });
}

function ok(value, message) {
    if (!value) fail(message || "The expression evaluated to a falsy value:\n\n  " + inspect(value));
}

function innerDeepEqual(a, b, strict, seen) {
    if (Object.is(a, b)) return true;
    if (typeof a !== "object" || a === null || typeof b !== "object" || b === null) {
        if (strict) return false;
        return a == b; // loose leaf comparison
    }
    if (seen.has(a) && seen.get(a) === b) return true;
    seen.set(a, b);

    if (a instanceof Date || b instanceof Date) {
        return a instanceof Date && b instanceof Date && a.getTime() === b.getTime();
    }
    if (a instanceof RegExp || b instanceof RegExp) {
        return a instanceof RegExp && b instanceof RegExp &&
            a.source === b.source && a.flags === b.flags;
    }
    if (a instanceof Map || b instanceof Map) {
        if (!(a instanceof Map) || !(b instanceof Map) || a.size !== b.size) return false;
        for (const [k, v] of a) {
            if (!innerDeepEqual(v, b.get(k), strict, seen)) return false;
        }
        return true;
    }
    if (a instanceof Set || b instanceof Set) {
        if (!(a instanceof Set) || !(b instanceof Set) || a.size !== b.size) return false;
        outer: for (const v of a) {
            for (const v2 of b) {
                if (innerDeepEqual(v, v2, strict, seen)) continue outer;
            }
            return false;
        }
        return true;
    }
    const aBuf = (typeof Buffer !== "undefined" && Buffer.isBuffer && Buffer.isBuffer(a)) ||
        (a instanceof Uint8Array);
    const bBuf = (typeof Buffer !== "undefined" && Buffer.isBuffer && Buffer.isBuffer(b)) ||
        (b instanceof Uint8Array);
    if (aBuf || bBuf) {
        if (!(a instanceof Uint8Array) || !(b instanceof Uint8Array) || a.length !== b.length) return false;
        for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
        return true;
    }

    const aKeys = Object.keys(a);
    const bKeys = Object.keys(b);
    if (strict ? aKeys.length !== bKeys.length : aKeys.length > bKeys.length) return false;
    aKeys.sort();
    bKeys.sort();
    for (let i = 0; i < aKeys.length; i++) {
        if (strict && aKeys[i] !== bKeys[i]) return false;
        if (!bKeys.includes(aKeys[i])) return false;
    }
    for (const key of aKeys) {
        if (!innerDeepEqual(a[key], b[key], strict, seen)) return false;
    }
    return true;
}

function deepEqual(a, b, message) {
    if (!innerDeepEqual(a, b, false, new Map())) {
        throw new AssertionError({ actual: a, expected: b, operator: "deepEqual", message });
    }
}

function notDeepEqual(a, b, message) {
    if (innerDeepEqual(a, b, false, new Map())) {
        throw new AssertionError({ actual: a, expected: b, operator: "notDeepEqual", message });
    }
}

function deepStrictEqual(a, b, message) {
    if (!innerDeepEqual(a, b, true, new Map())) {
        throw new AssertionError({ actual: a, expected: b, operator: "deepStrictEqual", message });
    }
}

function notDeepStrictEqual(a, b, message) {
    if (innerDeepEqual(a, b, true, new Map())) {
        throw new AssertionError({ actual: a, expected: b, operator: "notDeepStrictEqual", message });
    }
}

function strictEqual(a, b, message) {
    if (a !== b) {
        throw new AssertionError({ actual: a, expected: b, operator: "strictEqual", message });
    }
}

function notStrictEqual(a, b, message) {
    if (a === b) {
        throw new AssertionError({ actual: a, expected: b, operator: "notStrictEqual", message });
    }
}

function equal(a, b, message) {
    if (a != b) {
        throw new AssertionError({ actual: a, expected: b, operator: "==", message });
    }
}

function notEqual(a, b, message) {
    if (a == b) {
        throw new AssertionError({ actual: a, expected: b, operator: "!=", message });
    }
}

function expectedException(actual, expected) {
    if (typeof expected !== "function" && typeof expected !== "object") return false;
    if (typeof expected === "function") return actual instanceof expected;
    if (!(actual instanceof Error)) return false;
    if (typeof expected.name === "string" && actual.name !== expected.name) return false;
    if (typeof expected.message === "string" && actual.message !== expected.message) return false;
    if (expected.message instanceof RegExp && !expected.message.test(actual.message)) return false;
    for (const key of Object.keys(expected)) {
        if (key === "name" || key === "message") continue;
        if (!innerDeepEqual(actual[key], expected[key], true, new Map())) return false;
    }
    return true;
}

function throws(fn, error, message) {
    let threw = false;
    let actual;
    try {
        fn();
    } catch (e) {
        threw = true;
        actual = e;
    }
    if (!threw) {
        const details = message || (typeof error === "function" ? error.name || "function" : error) || "error";
        fail("Missing expected exception: " + details);
    }
    if (error !== undefined && !expectedException(actual, error)) {
        throw new AssertionError({
            actual, expected: error, operator: "throws",
            message: "Unexpected error:\n\n" + (actual && actual.stack || String(actual)),
        });
    }
    return actual;
}

function doesNotThrow(fn, error, message) {
    let actual;
    try {
        fn();
    } catch (e) {
        actual = e;
    }
    if (actual !== undefined) {
        throw new AssertionError({
            actual, expected: error, operator: "doesNotThrow",
            message: "Got unwanted exception" + (message ? ": " + message : "") + ":\n" + (actual && actual.stack || String(actual)),
        });
    }
}

function ifError(err) {
    if (err !== undefined && err !== null) {
        let message = "ifError got unwanted exception: ";
        if (typeof err === "object" && typeof err.message === "string") {
            message += err.message;
        } else {
            message += String(err);
        }
        throw new AssertionError({ actual: err, expected: null, operator: "ifError", message });
    }
}

const assert = ok;
assert.ok = ok;
assert.fail = fail;
assert.equal = equal;
assert.notEqual = notEqual;
assert.deepEqual = deepEqual;
assert.notDeepEqual = notDeepEqual;
assert.strictEqual = strictEqual;
assert.notStrictEqual = notStrictEqual;
assert.deepStrictEqual = deepStrictEqual;
assert.notDeepStrictEqual = notDeepStrictEqual;
assert.throws = throws;
assert.doesNotThrow = doesNotThrow;
assert.ifError = ifError;
assert.AssertionError = AssertionError;

// strict: loose members replaced by strict counterparts
const strict = ok;
strict.ok = ok;
strict.fail = fail;
strict.equal = strictEqual;
strict.notEqual = notStrictEqual;
strict.deepEqual = deepStrictEqual;
strict.notDeepEqual = notDeepStrictEqual;
strict.strictEqual = strictEqual;
strict.notStrictEqual = notStrictEqual;
strict.deepStrictEqual = deepStrictEqual;
strict.notDeepStrictEqual = notDeepStrictEqual;
strict.throws = throws;
strict.doesNotThrow = doesNotThrow;
strict.ifError = ifError;
strict.AssertionError = AssertionError;
assert.strict = strict;

module.exports = assert;
