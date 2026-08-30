// Node zlib — load-time stub. Express's `send` requires zlib at module init
// for precompressed-file support; runtime calls are not implemented yet.
"use strict";

function notImplemented(name) {
    return function () {
        throw new Error("zlib." + name + ": not implemented");
    };
}

const constants = {
    Z_NO_COMPRESSION: 0, Z_BEST_SPEED: 1, Z_BEST_COMPRESSION: 9, Z_DEFAULT_COMPRESSION: -1,
    Z_FILTERED: 1, Z_HUFFMAN_ONLY: 2, Z_RLE: 3, Z_FIXED: 4, Z_DEFAULT_STRATEGY: 0,
    Z_OK: 0, Z_STREAM_END: 1, Z_NO_FLUSH: 0, Z_SYNC_FLUSH: 2, Z_FULL_FLUSH: 3, Z_FINISH: 4,
    Z_BLOCK: 5, Z_PARTIAL_FLUSH: 1,
    Z_MIN_WINDOWBITS: 8, Z_MAX_WINDOWBITS: 15, Z_DEFAULT_WINDOWBITS: 15,
    Z_MIN_MEMLEVEL: 1, Z_MAX_MEMLEVEL: 9, Z_DEFAULT_MEMLEVEL: 8,
    Z_MIN_CHUNK: 64, Z_MAX_CHUNK: Infinity, Z_DEFAULT_CHUNK: 16384,
};

const syncFns = ["gzipSync", "gunzipSync", "inflateSync", "inflateSync",
    "deflateRawSync", "inflateRawSync", "unzipSync", "brotliCompressSync", "brotliDecompressSync"];
const asyncFns = ["gzip", "gunzip", "inflate", "deflate", "deflateRaw", "inflateRaw",
    "unzip", "brotliCompress", "brotliDecompress"];
const streamFns = ["createGzip", "createGunzip", "createDeflate", "createInflate",
    "createDeflateRaw", "createInflateRaw", "createUnzip", "createBrotliCompress", "createBrotliDecompress"];

const zlib = { constants };

for (const name of syncFns) zlib[name] = notImplemented(name);
for (const name of asyncFns) zlib[name] = notImplemented(name);
for (const name of streamFns) zlib[name] = notImplemented(name);

module.exports = zlib;
