// Node StringDecoder — utf8 (streaming via TextDecoder), latin1, ascii, hex.
"use strict";

class StringDecoder {
    constructor(encoding = "utf8") {
        const enc = String(encoding).toLowerCase();
        if (enc === "utf8" || enc === "utf-8") {
            this._enc = "utf8";
            this._decoder = new TextDecoder("utf-8");
        } else if (enc === "latin1" || enc === "binary") {
            this._enc = "latin1";
        } else if (enc === "ascii") {
            this._enc = "ascii";
        } else if (enc === "hex") {
            this._enc = "hex";
        } else {
            throw new TypeError("Unknown encoding: " + encoding);
        }
    }

    write(buf) {
        const bytes = toU8(buf);
        switch (this._enc) {
            case "utf8":
                return this._decoder.decode(bytes, { stream: true });
            case "latin1": {
                let s = "";
                for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
                return s;
            }
            case "ascii": {
                let s = "";
                for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i] & 0x7F);
                return s;
            }
            case "hex": {
                const hex = "0123456789abcdef";
                let s = "";
                for (let i = 0; i < bytes.length; i++) {
                    s += hex[bytes[i] >> 4] + hex[bytes[i] & 15];
                }
                return s;
            }
        }
        return "";
    }

    end(buf) {
        let out = "";
        if (buf !== undefined && buf !== null) out = this.write(buf);
        if (this._enc === "utf8") out += this._decoder.decode();
        return out;
    }
}

function toU8(buf) {
    if (buf instanceof Uint8Array) return buf;
    if (buf instanceof ArrayBuffer) return new Uint8Array(buf);
    if (buf && buf.buffer instanceof ArrayBuffer) {
        return new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
    }
    if (typeof Buffer !== "undefined" && Buffer.isBuffer && Buffer.isBuffer(buf)) return buf;
    return new Uint8Array(0);
}

module.exports = { StringDecoder };
