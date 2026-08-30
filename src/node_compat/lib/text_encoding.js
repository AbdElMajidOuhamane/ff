// UTF-8 TextEncoder/TextDecoder — WHATWG-shaped, streaming-capable.
// Zero reallocation on encode: two-pass (count, then fill).
"use strict";

function utf8EncodeInto(input, dest) {
    let p = 0;
    for (let i = 0; i < input.length; ) {
        let cp = input.codePointAt(i);
        const units = cp > 0xFFFF ? 2 : 1;
        i += units;
        if (cp >= 0xD800 && cp <= 0xDFFF) cp = 0xFFFD; // lone surrogate
        let need;
        if (cp < 0x80) need = 1;
        else if (cp < 0x800) need = 2;
        else if (cp < 0x10000) need = 3;
        else need = 4;
        if (p + need > dest.length) return { read: i - units, written: p };
        if (need === 1) dest[p++] = cp;
        else if (need === 2) {
            dest[p++] = 0xC0 | (cp >> 6);
            dest[p++] = 0x80 | (cp & 63);
        } else if (need === 3) {
            dest[p++] = 0xE0 | (cp >> 12);
            dest[p++] = 0x80 | ((cp >> 6) & 63);
            dest[p++] = 0x80 | (cp & 63);
        } else {
            dest[p++] = 0xF0 | (cp >> 18);
            dest[p++] = 0x80 | ((cp >> 12) & 63);
            dest[p++] = 0x80 | ((cp >> 6) & 63);
            dest[p++] = 0x80 | (cp & 63);
        }
    }
    return { read: input.length, written: p };
}

class TextEncoder {
    get encoding() { return "utf-8"; }
    encode(input) {
        const s = String(input);
        let n = 0;
        for (let i = 0; i < s.length; ) {
            const cp = s.codePointAt(i);
            i += cp > 0xFFFF ? 2 : 1;
            if (cp >= 0xD800 && cp <= 0xDFFF) n += 3;
            else if (cp < 0x80) n += 1;
            else if (cp < 0x800) n += 2;
            else if (cp < 0x10000) n += 3;
            else n += 4;
        }
        const out = new Uint8Array(n);
        utf8EncodeInto(s, out);
        return out;
    }
    encodeInto(source, dest) {
        return utf8EncodeInto(String(source), dest);
    }
}

class TextDecoder {
    constructor(label = "utf-8", options = {}) {
        const l = String(label).toLowerCase();
        if (l !== "utf-8" && l !== "utf8" && l !== "unicode-1-1-utf-8") {
            throw new RangeError("The encoding label provided ('" + label + "') is invalid.");
        }
        this._encoding = "utf-8";
        this._fatal = !!options.fatal;
        this._ignoreBOM = !!options.ignoreBOM;
        this._pending = null; // undecoded bytes across stream=true calls
    }
    get encoding() { return this._encoding; }
    get fatal() { return this._fatal; }
    get ignoreBOM() { return this._ignoreBOM; }

    _decodeBytes(bytes) {
        const units = [];
        let i = 0;
        let cp = 0, seen = 0, min = 0;
        const flushBad = () => {
            if (this._fatal) throw new TypeError("The encoded data is not valid.");
            units.push(0xFFFD);
            cp = 0; seen = 0;
        };
        while (i < bytes.length) {
            const b = bytes[i++];
            if (seen === 0) {
                if (b < 0x80) units.push(b);
                else if (b >= 0xC2 && b <= 0xDF) { cp = b & 0x1F; seen = 1; min = 0x80; }
                else if (b >= 0xE0 && b <= 0xEF) { cp = b & 0x0F; seen = 2; min = 0x800; }
                else if (b >= 0xF0 && b <= 0xF4) { cp = b & 0x07; seen = 3; min = 0x10000; }
                else flushBad();
            } else if ((b & 0xC0) === 0x80) {
                cp = (cp << 6) | (b & 0x3F);
                if (--seen === 0) {
                    if (cp < min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) flushBad();
                    else if (cp < 0x10000) units.push(cp);
                    else {
                        units.push(0xD800 + ((cp - 0x10000) >> 10), 0xDC00 + ((cp - 0x10000) & 0x3FF));
                    }
                }
            } else {
                i--; // re-process this byte as a lead
                flushBad();
            }
        }
        if (seen !== 0 && this._fatal) throw new TypeError("The encoded data is not valid.");
        // Build the string in bounded chunks (avoids fromCharCode arg limits).
        let out = "";
        for (let s = 0; s < units.length; s += 0x8000) {
            out += String.fromCharCode.apply(null, units.slice(s, s + 0x8000));
        }
        return out;
    }

    decode(input, options = {}) {
        let bytes;
        if (input instanceof Uint8Array) bytes = input;
        else if (input instanceof ArrayBuffer) bytes = new Uint8Array(input);
        else if (input && input.buffer instanceof ArrayBuffer) {
            bytes = new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
        } else bytes = new Uint8Array(0);

        let stream = !!options.stream;
        if (this._pending && this._pending.length) {
            const merged = new Uint8Array(this._pending.length + bytes.length);
            merged.set(this._pending, 0);
            merged.set(bytes, this._pending.length);
            bytes = merged;
            this._pending = null;
        }
        // If streaming, hold back a trailing partial sequence (max 3 bytes).
        let hold = 0;
        if (stream) {
            let j = bytes.length;
            while (j > 0 && j > bytes.length - 3) {
                const b = bytes[j - 1];
                if ((b & 0xC0) === 0x80) j--;
                else break;
            }
            const lead = j > 0 ? bytes[j - 1] : 0;
            if (j > 0 && lead >= 0xC0) {
                hold = bytes.length - (j - 1);
                if (hold < (lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : 2)) {
                    this._pending = bytes.slice(bytes.length - hold);
                    bytes = bytes.subarray(0, bytes.length - hold);
                } else this._pending = null;
            }
        }
        let out = this._decodeBytes(bytes);
        if (!this._ignoreBOM && out.charCodeAt(0) === 0xFEFF) out = out.slice(1);
        return out;
    }
}

globalThis.TextEncoder = TextEncoder;
globalThis.TextDecoder = TextDecoder;
