// Node crypto shim — native crypto (getRandomValues/UUID/subtle) merged with
// pure-JS createHash (sha1/sha256) for Express etags. Native std.crypto lands in P2.
"use strict";

function rotr(x, n) { return (x >>> n) | (x << (32 - n)); }

// ── SHA1 ────────────────────────────────────────────────────
function sha1(bytes) {
    const ml = bytes.length;
    const total = (((ml + 9) + 63) & ~63);
    const msg = new Uint8Array(total);
    msg.set(bytes, 0);
    msg[ml] = 0x80;
    const bitLenHi = Math.floor(ml / 0x20000000);
    const bitLenLo = (ml << 3) >>> 0;
    msg[total - 8] = (bitLenHi >>> 24) & 0xFF;
    msg[total - 7] = (bitLenHi >>> 16) & 0xFF;
    msg[total - 6] = (bitLenHi >>> 8) & 0xFF;
    msg[total - 5] = bitLenHi & 0xFF;
    msg[total - 4] = (bitLenLo >>> 24) & 0xFF;
    msg[total - 3] = (bitLenLo >>> 16) & 0xFF;
    msg[total - 2] = (bitLenLo >>> 8) & 0xFF;
    msg[total - 1] = bitLenLo & 0xFF;

    let h0 = 0x67452301 | 0, h1 = 0xEFCDAB89 | 0, h2 = 0x98BADCFE | 0, h3 = 0x10325476 | 0, h4 = 0xC3D2E1F0 | 0;
    const w = new Int32Array(80);
    for (let i = 0; i < total; i += 64) {
        for (let j = 0; j < 16; j++) {
            w[j] = (msg[i + j * 4] << 24) | (msg[i + j * 4 + 1] << 16) | (msg[i + j * 4 + 2] << 8) | msg[i + j * 4 + 3];
        }
        for (let j = 16; j < 80; j++) {
            const x = w[j - 3] ^ w[j - 8] ^ w[j - 14] ^ w[j - 16];
            w[j] = (x << 1) | (x >>> 31);
        }
        let a = h0, b = h1, c = h2, d = h3, e = h4;
        for (let j = 0; j < 80; j++) {
            let f, k;
            if (j < 20) { f = (b & c) | (~b & d); k = 0x5A827999; }
            else if (j < 40) { f = b ^ c ^ d; k = 0x6ED9EBA1; }
            else if (j < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC; }
            else { f = b ^ c ^ d; k = 0xCA62C1D6; }
            const t = (((a << 5) | (a >>> 27)) + f + e + k + w[j]) | 0;
            e = d; d = c; c = (b << 30) | (b >>> 2); b = a; a = t;
        }
        h0 = (h0 + a) | 0; h1 = (h1 + b) | 0; h2 = (h2 + c) | 0; h3 = (h3 + d) | 0; h4 = (h4 + e) | 0;
    }
    const out = new Uint8Array(20);
    out[0] = (h0 >>> 24) & 0xFF; out[1] = (h0 >>> 16) & 0xFF; out[2] = (h0 >>> 8) & 0xFF; out[3] = h0 & 0xFF;
    out[4] = (h1 >>> 24) & 0xFF; out[5] = (h1 >>> 16) & 0xFF; out[6] = (h1 >>> 8) & 0xFF; out[7] = h1 & 0xFF;
    out[8] = (h2 >>> 24) & 0xFF; out[9] = (h2 >>> 16) & 0xFF; out[10] = (h2 >>> 8) & 0xFF; out[11] = h2 & 0xFF;
    out[12] = (h3 >>> 24) & 0xFF; out[13] = (h3 >>> 16) & 0xFF; out[14] = (h3 >>> 8) & 0xFF; out[15] = h3 & 0xFF;
    out[16] = (h4 >>> 24) & 0xFF; out[17] = (h4 >>> 16) & 0xFF; out[18] = (h4 >>> 8) & 0xFF; out[19] = h4 & 0xFF;
    return out;
}

// ── SHA256 ──────────────────────────────────────────────────
const K256 = new Int32Array([
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]);

function sha256(bytes) {
    const ml = bytes.length;
    const total = (((ml + 9) + 63) & ~63);
    const msg = new Uint8Array(total);
    msg.set(bytes, 0);
    msg[ml] = 0x80;
    const bitLen = ml * 8;
    msg[total - 8] = (Math.floor(bitLen / 4294967296) >>> 24) & 0xFF;
    msg[total - 7] = (Math.floor(bitLen / 4294967296) >>> 16) & 0xFF;
    msg[total - 6] = (Math.floor(bitLen / 4294967296) >>> 8) & 0xFF;
    msg[total - 5] = Math.floor(bitLen / 4294967296) & 0xFF;
    msg[total - 4] = (bitLen >>> 24) & 0xFF;
    msg[total - 3] = (bitLen >>> 16) & 0xFF;
    msg[total - 2] = (bitLen >>> 8) & 0xFF;
    msg[total - 1] = bitLen & 0xFF;

    const h = new Int32Array([
        0x6a09e667 | 0, 0xbb67ae85 | 0, 0x3c6ef372 | 0, 0xa54ff53a | 0,
        0x510e527f | 0, 0x9b05688c | 0, 0x1f83d9ab | 0, 0x5be0cd19 | 0,
    ]);
    const w = new Int32Array(64);
    for (let i = 0; i < total; i += 64) {
        for (let j = 0; j < 16; j++) {
            w[j] = (msg[i + j * 4] << 24) | (msg[i + j * 4 + 1] << 16) | (msg[i + j * 4 + 2] << 8) | msg[i + j * 4 + 3];
        }
        for (let j = 16; j < 64; j++) {
            const s0 = rotr(w[j - 15], 7) ^ rotr(w[j - 15], 18) ^ (w[j - 15] >>> 3);
            const s1 = rotr(w[j - 2], 17) ^ rotr(w[j - 2], 19) ^ (w[j - 2] >>> 10);
            w[j] = (w[j - 16] + s0 + w[j - 7] + s1) | 0;
        }
        let a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
        for (let j = 0; j < 64; j++) {
            const S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
            const ch = (e & f) ^ (~e & g);
            const t1 = (hh + S1 + ch + K256[j] + w[j]) | 0;
            const S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
            const maj = (a & b) ^ (a & c) ^ (b & c);
            const t2 = (S0 + maj) | 0;
            hh = g; g = f; f = e; e = (d + t1) | 0; d = c; c = b; b = a; a = (t1 + t2) | 0;
        }
        h[0] = (h[0] + a) | 0; h[1] = (h[1] + b) | 0; h[2] = (h[2] + c) | 0; h[3] = (h[3] + d) | 0;
        h[4] = (h[4] + e) | 0; h[5] = (h[5] + f) | 0; h[6] = (h[6] + g) | 0; h[7] = (h[7] + hh) | 0;
    }
    const out = new Uint8Array(32);
    for (let i = 0; i < 8; i++) {
        out[i * 4] = (h[i] >>> 24) & 0xFF;
        out[i * 4 + 1] = (h[i] >>> 16) & 0xFF;
        out[i * 4 + 2] = (h[i] >>> 8) & 0xFF;
        out[i * 4 + 3] = h[i] & 0xFF;
    }
    return out;
}

// ── codecs (local — buffer.js internals are module-private) ─
const HEXC = "0123456789abcdef";
function hexEncode(u8) {
    let s = "";
    for (let i = 0; i < u8.length; i++) s += HEXC[u8[i] >> 4] + HEXC[u8[i] & 15];
    return s;
}
const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
function b64Encode(u8) {
    let out = "";
    const n = u8.length;
    let i = 0;
    for (; i + 2 < n; i += 3) {
        const b = (u8[i] << 16) | (u8[i + 1] << 8) | u8[i + 2];
        out += B64[(b >> 18) & 63] + B64[(b >> 12) & 63] + B64[(b >> 6) & 63] + B64[b & 63];
    }
    const rem = n - i;
    if (rem === 1) { const b = u8[i] << 16; out += B64[(b >> 18) & 63] + B64[(b >> 12) & 63] + "=="; }
    else if (rem === 2) { const b = (u8[i] << 16) | (u8[i + 1] << 8); out += B64[(b >> 18) & 63] + B64[(b >> 12) & 63] + B64[(b >> 6) & 63] + "="; }
    return out;
}

// ── Hash class ──────────────────────────────────────────────
class Hash {
    constructor(algo) {
        const a = String(algo).toLowerCase().replace(/-/g, "");
        if (a === "sha1") this._fn = sha1;
        else if (a === "sha256") this._fn = sha256;
        else throw new Error("createHash: algorithm '" + algo + "' not implemented (available: sha1, sha256)");
        this._chunks = [];
        this._len = 0;
    }
    update(data, inputEncoding) {
        if (typeof data === "string") data = Buffer.from(data, inputEncoding || "utf8");
        else if (!(data instanceof Uint8Array)) data = Buffer.from(data);
        this._chunks.push(data);
        this._len += data.length;
        return this;
    }
    digest(encoding) {
        const all = new Uint8Array(this._len);
        let p = 0;
        for (const c of this._chunks) { all.set(c, p); p += c.length; }
        const digest = this._fn(all);
        if (encoding === "hex") return hexEncode(digest);
        if (encoding === "base64") return b64Encode(digest);
        return Buffer.from(digest); // binary default
    }
}

function createHash(algo) { return new Hash(algo); }

function randomBytes(size, cb) {
    const u8 = new Uint8Array(size);
    globalThis.crypto.getRandomValues(u8);
    const buf = Buffer.from(u8);
    if (typeof cb === "function") { process.nextTick(() => cb(null, buf)); return undefined; }
    return buf;
}

// Merge native crypto (getRandomValues/randomUUID/subtle) with the shim APIs.
const native = (typeof globalThis.crypto !== "undefined") ? globalThis.crypto : {};
const crypto = Object.assign({}, native, {
    createHash,
    randomBytes,
});
crypto.webcrypto = native;

module.exports = crypto;
