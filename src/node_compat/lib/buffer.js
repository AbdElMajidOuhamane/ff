// Buffer — Node semantics over Uint8Array (buffer@6 lineage).
// allocUnsafe is zero-filled (QuickJS always zero-inits; safe superset, documented).
"use strict";

// ── codecs ──────────────────────────────────────────────────
function utf8Encode(s) { return new TextEncoder().encode(s); }
function utf8Decode(u8) { return new TextDecoder("utf-8").decode(u8); }
function latin1Encode(s) { const u = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) u[i] = s.charCodeAt(i) & 0xFF; return u; }
function latin1Decode(u8) { let s = ""; for (let i = 0; i < u8.length; i++) s += String.fromCharCode(u8[i]); return s; }
function asciiEncode(s) { const u = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) u[i] = s.charCodeAt(i) & 0x7F; return u; }
function asciiDecode(u8) { let s = ""; for (let i = 0; i < u8.length; i++) s += String.fromCharCode(u8[i] & 0x7F); return s; }
function ucs2Encode(s) { const u = new Uint8Array(s.length * 2); for (let i = 0; i < s.length; i++) { const c = s.charCodeAt(i); u[i * 2] = c & 0xFF; u[i * 2 + 1] = (c >> 8) & 0xFF; } return u; }
function ucs2Decode(u8) { const n = u8.length & ~1; let s = ""; for (let i = 0; i < n; i += 2) s += String.fromCharCode(u8[i] | (u8[i + 1] << 8)); return s; }

const HEX = "0123456789abcdef";
function hexVal(c) { if (c >= 48 && c <= 57) return c - 48; if (c >= 97 && c <= 102) return c - 87; if (c >= 65 && c <= 70) return c - 55; return -1; }
function hexEncode(u8) { let s = ""; for (let i = 0; i < u8.length; i++) s += HEX[u8[i] >> 4] + HEX[u8[i] & 15]; return s; }
function hexDecode(str) {
    const n = str.length >> 1;
    const u = new Uint8Array(n);
    for (let i = 0; i < n; i++) {
        const hi = hexVal(str.charCodeAt(i * 2));
        const lo = hexVal(str.charCodeAt(i * 2 + 1));
        if (hi < 0 || lo < 0) throw new TypeError("Invalid hex string");
        u[i] = (hi << 4) | lo;
    }
    return u;
}

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const B64URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
const B64REV = (() => { const r = new Int8Array(256).fill(-1); for (let i = 0; i < 64; i++) { r[B64.charCodeAt(i)] = i; r[B64URL.charCodeAt(i)] = i; } return r; })();

function b64Encode(u8, url) {
    const T = url ? B64URL : B64;
    let out = "";
    const n = u8.length;
    let i = 0;
    for (; i + 2 < n; i += 3) {
        const b = (u8[i] << 16) | (u8[i + 1] << 8) | u8[i + 2];
        out += T[(b >> 18) & 63] + T[(b >> 12) & 63] + T[(b >> 6) & 63] + T[b & 63];
    }
    const rem = n - i;
    if (rem === 1) { const b = u8[i] << 16; out += T[(b >> 18) & 63] + T[(b >> 12) & 63] + "=="; }
    else if (rem === 2) { const b = (u8[i] << 16) | (u8[i + 1] << 8); out += T[(b >> 18) & 63] + T[(b >> 12) & 63] + T[(b >> 6) & 63] + "="; }
    return out;
}

function b64Decode(str, url) {
    const R = B64REV;
    let dataChars = 0;
    for (let i = 0; i < str.length; i++) {
        const c = str.charCodeAt(i);
        if (c === 61 || c === 32 || c === 9 || c === 10 || c === 13) continue;
        if (R[c & 0xFF] < 0) throw new TypeError("Invalid base64 string");
        dataChars++;
    }
    const n = Math.floor(dataChars * 3 / 4);
    const u = new Uint8Array(n);
    let p = 0, bits = 0, acc = 0;
    for (let i = 0; i < str.length && p < n; i++) {
        const c = str.charCodeAt(i);
        if (c === 61 || c === 32 || c === 9 || c === 10 || c === 13) continue;
        acc = (acc << 6) | R[c & 0xFF];
        bits += 6;
        if (bits >= 8) { bits -= 8; u[p++] = (acc >> bits) & 0xFF; }
    }
    return u;
}

// ── encoding registry ───────────────────────────────────────
const ENC = {
    "utf8": "utf8", "utf-8": "utf8",
    "hex": "hex",
    "base64": "base64", "base64url": "base64url",
    "latin1": "latin1", "binary": "latin1",
    "ascii": "ascii",
    "ucs2": "ucs2", "ucs-2": "ucs2", "utf16le": "ucs2", "utf-16le": "ucs2",
};
function normalizeEncoding(enc) {
    if (enc === undefined || enc === null || enc === "") return "utf8";
    return ENC[String(enc).toLowerCase()];
}

function encodeStr(str, enc) {
    switch (enc) {
        case "utf8": return utf8Encode(str);
        case "latin1": return latin1Encode(str);
        case "ascii": return asciiEncode(str);
        case "ucs2": return ucs2Encode(str);
        case "hex": return hexDecode(str);
        case "base64": return b64Decode(str, false);
        case "base64url": return b64Decode(str, true);
    }
    throw new TypeError("Unknown encoding: " + enc);
}

// ── instance creation ───────────────────────────────────────
function createBuffer(len) {
    const u = new Uint8Array(len);
    Object.setPrototypeOf(u, Buffer.prototype);
    return u;
}
function wrapView(u) {
    Object.setPrototypeOf(u, Buffer.prototype);
    return u;
}
function fromString(str, enc) {
    return wrapView(encodeStr(str, normalizeEncoding(enc) || "utf8"));
}

function from(value, encodingOrOffset, length) {
    if (typeof value === "string") {
        if (encodingOrOffset !== undefined && typeof encodingOrOffset !== "string") {
            throw new TypeError('If "encoding" is defined then it must be a string');
        }
        return fromString(value, encodingOrOffset);
    }
    if (value instanceof ArrayBuffer) {
        return wrapView(new Uint8Array(value));
    }
    if (ArrayBuffer.isView(value)) {
        const u = new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
        const b = createBuffer(u.length);
        b.set(u);
        return b;
    }
    if (Array.isArray(value) || (value && typeof value === "object" && typeof value.length === "number")) {
        const b = createBuffer(value.length >>> 0);
        for (let i = 0; i < value.length; i++) b[i] = value[i] & 0xFF;
        return b;
    }
    if (value && typeof value.valueOf === "function") {
        const v = value.valueOf();
        if (typeof v === "number") return allocUnsafe(v);
    }
    throw new TypeError("The first argument must be of type string or an instance of Buffer, ArrayBuffer, or Array or an Array-like Object.");
}

function alloc(size, fill, encoding) {
    if (typeof size !== "number" || size < 0 || !Number.isFinite(size)) {
        throw new RangeError('The "size" argument must be of type number >= 0. Received ' + String(size));
    }
    const b = createBuffer(size);
    if (fill !== undefined && fill !== 0 && fill !== "") {
        if (typeof fill === "string") b.fill(fill, 0, size, normalizeEncoding(encoding) || "utf8");
        else if (typeof fill === "number" || typeof fill === "bigint") b.fill(Number(fill) & 0xFF);
        else if (fill instanceof Uint8Array) b.fill(fill, 0, size, encoding);
        else throw new TypeError('The "fill" argument must be of type string, number, bigint, or Buffer');
    }
    return b; // default: zero-filled
}
function allocUnsafe(size) {
    if (typeof size !== "number" || size < 0 || !Number.isFinite(size)) {
        throw new RangeError('The "size" argument must be of type number >= 0. Received ' + String(size));
    }
    return createBuffer(size); // zero-filled (documented superset of Node's uninit)
}

function Buffer(arg, encodingOrOffset, length) {
    if (typeof arg === "number") {
        if (typeof encodingOrOffset === "string") {
            throw new TypeError('If "encodingOrOffset" is a string, then the first argument must be of type string or an instance of Buffer, ArrayBuffer, or Array or an Array-like Object.');
        }
        return allocUnsafe(arg);
    }
    return from(arg, encodingOrOffset, length);
}

Object.setPrototypeOf(Buffer, Uint8Array);
Buffer.prototype = Object.create(Uint8Array.prototype);
Buffer.prototype.constructor = Buffer;

// ── statics ─────────────────────────────────────────────────
Buffer.from = from;
Buffer.alloc = alloc;
Buffer.allocUnsafe = allocUnsafe;
Buffer.allocUnsafeSlow = allocUnsafe;
Buffer.poolSize = 8192;
Buffer.isBuffer = (b) => b instanceof Buffer;
Buffer.isEncoding = (enc) => normalizeEncoding(enc) !== undefined;

Buffer.concat = function (list, totalLength) {
    if (!Array.isArray(list)) throw new TypeError('"list" argument must be an Array of Buffer or Uint8Array instances');
    let len = 0;
    for (const b of list) {
        if (!(b instanceof Uint8Array)) throw new TypeError('"list" argument must be an Array of Buffer or Uint8Array instances');
        len += b.length;
    }
    if (totalLength === undefined) totalLength = len;
    else if (typeof totalLength !== "number" || totalLength < 0) throw new RangeError('The "totalLength" argument must be of type number >= 0');
    const out = createBuffer(totalLength);
    let p = 0;
    for (const b of list) {
        if (p >= totalLength) break;
        const n = Math.min(b.length, totalLength - p);
        out.set(b.subarray(0, n), p);
        p += n;
    }
    return out;
};

Buffer.byteLength = function (value, encoding) {
    if (typeof value === "string") {
        const e = normalizeEncoding(encoding) || "utf8";
        switch (e) {
            case "utf8": return utf8Encode(value).length;
            case "latin1": case "ascii": return value.length;
            case "ucs2": return value.length * 2;
            case "hex": return Math.floor(value.length / 2);
            case "base64": case "base64url": {
                let n = 0;
                for (let i = 0; i < value.length; i++) {
                    const c = value.charCodeAt(i);
                    if (c === 61 || c === 32 || c === 9 || c === 10 || c === 13) continue;
                    n++;
                }
                return Math.floor(n * 3 / 4);
            }
        }
    }
    if (value instanceof Uint8Array) return value.length;
    if (value instanceof ArrayBuffer) return value.byteLength;
    if (ArrayBuffer.isView(value)) return value.byteLength;
    throw new TypeError('The "string" argument must be of type string or an instance of Buffer or ArrayBuffer.');
};

Buffer.compare = function (a, b) {
    if (!(a instanceof Uint8Array) || !(b instanceof Uint8Array)) {
        throw new TypeError('The arguments must be of type Buffer or Uint8Array');
    }
    const n = a.length < b.length ? a.length : b.length;
    for (let i = 0; i < n; i++) {
        if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
    }
    return a.length === b.length ? 0 : (a.length < b.length ? -1 : 1);
};

// ── instance methods ────────────────────────────────────────
Buffer.prototype.toString = function (encoding, start, end) {
    const len = this.length;
    let s = start === undefined ? 0 : start;
    let e = end === undefined ? len : end;
    if (s < 0) s = 0;
    if (e > len) e = len;
    if (s >= e) return "";
    const sub = this.subarray(s, e);
    const enc = normalizeEncoding(encoding) || "utf8";
    switch (enc) {
        case "utf8": return utf8Decode(sub);
        case "latin1": return latin1Decode(sub);
        case "ascii": return asciiDecode(sub);
        case "ucs2": return ucs2Decode(sub);
        case "hex": return hexEncode(sub);
        case "base64": return b64Encode(sub, false);
        case "base64url": return b64Encode(sub, true);
    }
    throw new TypeError("Unknown encoding: " + encoding);
};

Buffer.prototype.write = function (string, offset, length, encoding) {
    let off = 0, len = this.length, enc;
    if (offset !== undefined) {
        if (typeof offset === "string") {
            enc = normalizeEncoding(offset);
            offset = length; length = undefined; // (str, enc) form
        }
        if (offset !== undefined) {
            if (typeof offset !== "number") throw new TypeError('The "offset" argument must be of type number');
            off = offset;
            if (length !== undefined) {
                if (typeof length === "string") { enc = normalizeEncoding(length); length = undefined; }
                else if (typeof length !== "number") throw new TypeError('The "length" argument must be of type number');
                else len = length;
            }
        }
    }
    enc = (enc !== undefined ? enc : normalizeEncoding(encoding)) || "utf8";
    if (off < 0 || off > this.length) throw new RangeError('The "offset" argument is out of range');
    if (len < 0) throw new RangeError('The "length" argument is out of range');
    len = Math.min(len, this.length - off);
    if (typeof string !== "string") string = String(string);
    const bytes = encodeStr(string, enc);
    const n = Math.min(bytes.length, len);
    for (let i = 0; i < n; i++) this[off + i] = bytes[i];
    return n;
};

Buffer.prototype.copy = function (target, targetStart = 0, sourceStart = 0, sourceEnd = this.length) {
    if (!(target instanceof Uint8Array)) throw new TypeError('The "target" argument must be an instance of Buffer or Uint8Array');
    if (targetStart < 0 || sourceStart < 0 || sourceEnd > this.length) throw new RangeError("Out of range index");
    const n = Math.min(sourceEnd - sourceStart, target.length - targetStart);
    if (n <= 0) return 0;
    target.set(this.subarray(sourceStart, sourceStart + n), targetStart);
    return n;
};

function subWrap(b, start, end) {
    const len = b.length;
    let s = start === undefined ? 0 : (start | 0);
    let e = end === undefined ? len : (end | 0);
    if (s < 0) s = len + s;
    if (e < 0) e = len + e;
    if (s < 0) s = 0;
    if (e > len) e = len;
    if (e < s) e = s;
    // Explicit view over the SAME buffer — no species constructor involved.
    const v = new Uint8Array(b.buffer, b.byteOffset + s, e - s);
    return Object.setPrototypeOf(v, Buffer.prototype);
}
Buffer.prototype.slice = function (start, end) { return subWrap(this, start, end); };
Buffer.prototype.subarray = function (start, end) { return subWrap(this, start, end); };

Buffer.prototype.fill = function (val, start, end, encoding) {
    let s = start === undefined ? 0 : start;
    let e = end === undefined ? this.length : end;
    if (s < 0) s = 0;
    if (e > this.length) e = this.length;
    if (s >= e) return this;
    if (typeof val === "number") {
        Uint8Array.prototype.fill.call(this, Number(val) & 0xFF, s, e);
        return this;
    }
    if (typeof val === "string") {
        const pat = fromString(val, normalizeEncoding(encoding) || "utf8");
        if (pat.length === 0) throw new TypeError('The "value" argument must not be an empty string');
        for (let i = s; i < e; i += pat.length) {
            this.set(pat.subarray(0, Math.min(pat.length, e - i)), i);
        }
        return this;
    }
    if (val instanceof Uint8Array) {
        if (val.length === 0) throw new TypeError('The "value" argument must not be an empty buffer');
        for (let i = s; i < e; i += val.length) {
            this.set(val.subarray(0, Math.min(val.length, e - i)), i);
        }
        return this;
    }
    Uint8Array.prototype.fill.call(this, Number(val) & 0xFF, s, e);
    return this;
};

Buffer.prototype.equals = function (other) {
    return other instanceof Uint8Array && other.length === this.length && Buffer.compare(this, other) === 0;
};

Buffer.prototype.indexOf = function (value, byteOffset, encoding) {
    if (typeof value === "number") return Uint8Array.prototype.indexOf.call(this, value & 0xFF, byteOffset);
    if (typeof value === "string") {
        if (typeof byteOffset === "string") { encoding = byteOffset; byteOffset = undefined; }
        value = fromString(value, normalizeEncoding(encoding) || "utf8");
    }
    if (!(value instanceof Uint8Array)) throw new TypeError('The "value" argument must be of type number or string or Buffer');
    let off = byteOffset === undefined ? 0 : (byteOffset | 0);
    if (off < 0) off = this.length + off;
    if (off < 0) off = 0;
    if (value.length === 0) return off <= this.length ? off : -1;
    outer: for (let i = off; i <= this.length - value.length; i++) {
        for (let j = 0; j < value.length; j++) {
            if (this[i + j] !== value[j]) continue outer;
        }
        return i;
    }
    return -1;
};

Buffer.prototype.lastIndexOf = function (value, byteOffset, encoding) {
    if (typeof value === "number") return Uint8Array.prototype.lastIndexOf.call(this, value & 0xFF, byteOffset);
    if (typeof value === "string") {
        if (typeof byteOffset === "string") { encoding = byteOffset; byteOffset = undefined; }
        value = fromString(value, normalizeEncoding(encoding) || "utf8");
    }
    if (!(value instanceof Uint8Array)) throw new TypeError('The "value" argument must be of type number or string or Buffer');
    let off = byteOffset === undefined ? this.length - value.length : (byteOffset | 0);
    if (off < 0) off = this.length + off;
    if (off > this.length - value.length) off = this.length - value.length;
    outer: for (let i = off; i >= 0; i--) {
        for (let j = 0; j < value.length; j++) {
            if (this[i + j] !== value[j]) continue outer;
        }
        return i;
    }
    return -1;
};

Buffer.prototype.includes = function (value, byteOffset, encoding) {
    return this.indexOf(value, byteOffset, encoding) !== -1;
};

Buffer.prototype.toJSON = function () {
    return { type: "Buffer", data: Array.from(this) };
};

// ── bounds + int/float accessors ────────────────────────────
function chk(len, need, off) {
    if (typeof off !== "number" || off < 0 || off + need > len) {
        throw new RangeError("Attempt to access memory outside buffer bounds");
    }
}
function checkInt(value, min, max, name) {
    if (typeof value !== "number" || !Number.isFinite(value) || Math.floor(value) !== value || value < min || value > max) {
        throw new RangeError('The value of "' + name + '" is out of range. It must be an integer. Received ' + String(value));
    }
}
Buffer.prototype._dv = function () {
    if (this.__dv === undefined) {
        Object.defineProperty(this, "__dv", {
            value: new DataView(this.buffer, this.byteOffset, this.byteLength),
            writable: true, configurable: true, enumerable: false,
        });
    }
    return this.__dv;
};

Buffer.prototype.readUInt8 = function (o = 0) { chk(this.length, 1, o); return this[o]; };
Buffer.prototype.readInt8 = function (o = 0) { chk(this.length, 1, o); const v = this[o]; return v & 0x80 ? v - 0x100 : v; };

Buffer.prototype.readUInt16LE = function (o = 0) { chk(this.length, 2, o); return this[o] | (this[o + 1] << 8); };
Buffer.prototype.readUInt16BE = function (o = 0) { chk(this.length, 2, o); return (this[o] << 8) | this[o + 1]; };
Buffer.prototype.readInt16LE = function (o = 0) { chk(this.length, 2, o); const v = this[o] | (this[o + 1] << 8); return v & 0x8000 ? v - 0x10000 : v; };
Buffer.prototype.readInt16BE = function (o = 0) { chk(this.length, 2, o); const v = (this[o] << 8) | this[o + 1]; return v & 0x8000 ? v - 0x10000 : v; };

Buffer.prototype.readUInt32LE = function (o = 0) { chk(this.length, 4, o); return (this[o] | (this[o + 1] << 8) | (this[o + 2] << 16) | (this[o + 3] << 24)) >>> 0; };
Buffer.prototype.readUInt32BE = function (o = 0) { chk(this.length, 4, o); return ((this[o] << 24) | (this[o + 1] << 16) | (this[o + 2] << 8) | this[o + 3]) >>> 0; };
Buffer.prototype.readInt32LE = function (o = 0) { chk(this.length, 4, o); return (this[o] | (this[o + 1] << 8) | (this[o + 2] << 16) | (this[o + 3] << 24)) | 0; };
Buffer.prototype.readInt32BE = function (o = 0) { chk(this.length, 4, o); return ((this[o] << 24) | (this[o + 1] << 16) | (this[o + 2] << 8) | this[o + 3]) | 0; };

Buffer.prototype.readUIntLE = function (o = 0, l = 1) { chk(this.length, l, o); let v = 0; for (let i = l - 1; i >= 0; i--) v = v * 256 + this[o + i]; return v; };
Buffer.prototype.readUIntBE = function (o = 0, l = 1) { chk(this.length, l, o); let v = 0; for (let i = 0; i < l; i++) v = v * 256 + this[o + i]; return v; };
Buffer.prototype.readIntLE = function (o = 0, l = 1) { chk(this.length, l, o); let v = 0; for (let i = l - 1; i >= 0; i--) v = v * 256 + this[o + i]; const s = this[o + l - 1] & 0x80; return s ? v - Math.pow(2, 8 * l) : v; };
Buffer.prototype.readIntBE = function (o = 0, l = 1) { chk(this.length, l, o); let v = 0; for (let i = 0; i < l; i++) v = v * 256 + this[o + i]; const s = this[o] & 0x80; return s ? v - Math.pow(2, 8 * l) : v; };

Buffer.prototype.readFloatLE = function (o = 0) { chk(this.length, 4, o); return this._dv().getFloat32(o, true); };
Buffer.prototype.readFloatBE = function (o = 0) { chk(this.length, 4, o); return this._dv().getFloat32(o, false); };
Buffer.prototype.readDoubleLE = function (o = 0) { chk(this.length, 8, o); return this._dv().getFloat64(o, true); };
Buffer.prototype.readDoubleBE = function (o = 0) { chk(this.length, 8, o); return this._dv().getFloat64(o, false); };
Buffer.prototype.readBigInt64LE = function (o = 0) { chk(this.length, 8, o); return this._dv().getBigInt64(o, true); };
Buffer.prototype.readBigInt64BE = function (o = 0) { chk(this.length, 8, o); return this._dv().getBigInt64(o, false); };
Buffer.prototype.readBigUInt64LE = function (o = 0) { chk(this.length, 8, o); return this._dv().getBigUint64(o, true); };
Buffer.prototype.readBigUInt64BE = function (o = 0) { chk(this.length, 8, o); return this._dv().getBigUint64(o, false); };

function wchk(len, need, off) { if (typeof off !== "number" || off < 0 || off + need > len) throw new RangeError("Attempt to write outside buffer bounds"); }

Buffer.prototype.writeUInt8 = function (v, o = 0) { checkInt(v, 0, 255, "value"); wchk(this.length, 1, o); this[o] = v; return o + 1; };
Buffer.prototype.writeInt8 = function (v, o = 0) { checkInt(v, -128, 127, "value"); wchk(this.length, 1, o); this[o] = v & 0xFF; return o + 1; };

Buffer.prototype.writeUInt16LE = function (v, o = 0) { checkInt(v, 0, 65535, "value"); wchk(this.length, 2, o); this[o] = v & 0xFF; this[o + 1] = (v >>> 8) & 0xFF; return o + 2; };
Buffer.prototype.writeUInt16BE = function (v, o = 0) { checkInt(v, 0, 65535, "value"); wchk(this.length, 2, o); this[o] = (v >>> 8) & 0xFF; this[o + 1] = v & 0xFF; return o + 2; };
Buffer.prototype.writeInt16LE = function (v, o = 0) { checkInt(v, -32768, 32767, "value"); wchk(this.length, 2, o); this[o] = v & 0xFF; this[o + 1] = (v >> 8) & 0xFF; return o + 2; };
Buffer.prototype.writeInt16BE = function (v, o = 0) { checkInt(v, -32768, 32767, "value"); wchk(this.length, 2, o); this[o] = (v >> 8) & 0xFF; this[o + 1] = v & 0xFF; return o + 2; };

Buffer.prototype.writeUInt32LE = function (v, o = 0) { checkInt(v, 0, 4294967295, "value"); wchk(this.length, 4, o); this[o] = v & 0xFF; this[o + 1] = (v >>> 8) & 0xFF; this[o + 2] = (v >>> 16) & 0xFF; this[o + 3] = (v >>> 24) & 0xFF; return o + 4; };
Buffer.prototype.writeUInt32BE = function (v, o = 0) { checkInt(v, 0, 4294967295, "value"); wchk(this.length, 4, o); this[o] = (v >>> 24) & 0xFF; this[o + 1] = (v >>> 16) & 0xFF; this[o + 2] = (v >>> 8) & 0xFF; this[o + 3] = v & 0xFF; return o + 4; };
Buffer.prototype.writeInt32LE = function (v, o = 0) { checkInt(v, -2147483648, 2147483647, "value"); wchk(this.length, 4, o); this[o] = v & 0xFF; this[o + 1] = (v >> 8) & 0xFF; this[o + 2] = (v >> 16) & 0xFF; this[o + 3] = (v >> 24) & 0xFF; return o + 4; };
Buffer.prototype.writeInt32BE = function (v, o = 0) { checkInt(v, -2147483648, 2147483647, "value"); wchk(this.length, 4, o); this[o] = (v >> 24) & 0xFF; this[o + 1] = (v >> 16) & 0xFF; this[o + 2] = (v >> 8) & 0xFF; this[o + 3] = v & 0xFF; return o + 4; };

Buffer.prototype.writeUIntLE = function (v, o = 0, l = 1) { checkInt(v, 0, Math.pow(2, 8 * l) - 1, "value"); wchk(this.length, l, o); let x = v; for (let i = 0; i < l; i++) { this[o + i] = x & 0xFF; x = Math.floor(x / 256); } return o + l; };
Buffer.prototype.writeUIntBE = function (v, o = 0, l = 1) { checkInt(v, 0, Math.pow(2, 8 * l) - 1, "value"); wchk(this.length, l, o); let x = v; for (let i = l - 1; i >= 0; i--) { this[o + i] = x & 0xFF; x = Math.floor(x / 256); } return o + l; };
Buffer.prototype.writeIntLE = function (v, o = 0, l = 1) { checkInt(v, -Math.pow(2, 8 * l - 1), Math.pow(2, 8 * l - 1) - 1, "value"); wchk(this.length, l, o); let x = v < 0 ? v + Math.pow(2, 8 * l) : v; for (let i = 0; i < l; i++) { this[o + i] = x & 0xFF; x = Math.floor(x / 256); } return o + l; };
Buffer.prototype.writeIntBE = function (v, o = 0, l = 1) { checkInt(v, -Math.pow(2, 8 * l - 1), Math.pow(2, 8 * l - 1) - 1, "value"); wchk(this.length, l, o); let x = v < 0 ? v + Math.pow(2, 8 * l) : v; for (let i = l - 1; i >= 0; i--) { this[o + i] = x & 0xFF; x = Math.floor(x / 256); } return o + l; };

Buffer.prototype.writeFloatLE = function (v, o = 0) { wchk(this.length, 4, o); this._dv().setFloat32(o, v, true); return o + 4; };
Buffer.prototype.writeFloatBE = function (v, o = 0) { wchk(this.length, 4, o); this._dv().setFloat32(o, v, false); return o + 4; };
Buffer.prototype.writeDoubleLE = function (v, o = 0) { wchk(this.length, 8, o); this._dv().setFloat64(o, v, true); return o + 8; };
Buffer.prototype.writeDoubleBE = function (v, o = 0) { wchk(this.length, 8, o); this._dv().setFloat64(o, v, false); return o + 8; };
Buffer.prototype.writeBigInt64LE = function (v, o = 0) { wchk(this.length, 8, o); this._dv().setBigInt64(o, v, true); return o + 8; };
Buffer.prototype.writeBigInt64BE = function (v, o = 0) { wchk(this.length, 8, o); this._dv().setBigInt64(o, v, false); return o + 8; };
Buffer.prototype.writeBigUInt64LE = function (v, o = 0) { wchk(this.length, 8, o); this._dv().setBigUint64(o, v, true); return o + 8; };
Buffer.prototype.writeBigUInt64BE = function (v, o = 0) { wchk(this.length, 8, o); this._dv().setBigUint64(o, v, false); return o + 8; };

Buffer.prototype.swap16 = function () { if (this.length % 2 !== 0) throw new RangeError("Buffer size must be a multiple of 16-bits"); for (let i = 0; i < this.length; i += 2) { const t = this[i]; this[i] = this[i + 1]; this[i + 1] = t; } return this; };
Buffer.prototype.swap32 = function () { if (this.length % 4 !== 0) throw new RangeError("Buffer size must be a multiple of 32-bits"); for (let i = 0; i < this.length; i += 4) { const a = this[i], b = this[i + 1]; this[i] = this[i + 3]; this[i + 3] = a; this[i + 1] = this[i + 2]; this[i + 2] = b; } return this; };

module.exports = Buffer;
module.exports.Buffer = Buffer;
globalThis.Buffer = Buffer;
