// Node stream — minimal Readable/Writable for Express / raw-body patterns.
// Bodies arrive fully buffered from the native server; delivered via microtasks.
"use strict";

const EventEmitter = require("events");

class Readable extends EventEmitter {
    constructor(options) {
        super();
        this.readable = true;
        this.destroyed = false;
        this.readableHighWaterMark = (options && options.highWaterMark) || 16384;
        this._chunks = [];
        this._ended = false;
        this._delivered = false;
        this._flowing = false;
    }

    // Node semantics: push data chunks; push(null) ends the stream.
    push(chunk) {
        if (chunk === null || chunk === undefined) {
            this._ended = true;
            this._maybeFlow();
            return false;
        }
        this._chunks.push(typeof Buffer !== "undefined" && Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
        this._maybeFlow();
        return true;
    }

    _maybeFlow() {
        if (!this._flowing || this._delivered || this.destroyed) return;
        if (this._chunks.length === 0 && !this._ended) return;
        process.nextTick(() => {
            if (this.destroyed || this._delivered) return;
            const chunks = this._chunks;
            this._chunks = [];
            for (const chunk of chunks) this.emit("data", chunk);
            if (this._ended) {
                this._delivered = true;
                this.readable = false;
                this.emit("end");
            }
        });
    }

    on(type, listener) {
        const r = super.on(type, listener);
        if (type === "data" || type === "end") this._flowing = true;
        this._maybeFlow();
        return r;
    }

    once(type, listener) {
        const r = super.once(type, listener);
        if (type === "data" || type === "end") this._flowing = true;
        this._maybeFlow();
        return r;
    }

    addListener(type, listener) { return this.on(type, listener); }

    pause() { this._flowing = false; return this; }
    resume() { this._flowing = true; this._maybeFlow(); return this; }

    read() {
        if (this._chunks.length === 0) return null;
        return this._chunks.shift();
    }

    pipe(dest, options) {
        this.on("data", (chunk) => dest.write(chunk));
        this.on("end", () => {
            if (!options || options.end !== false) dest.end();
        });
        return dest;
    }

    unpipe() { return this; }

    destroy(err) {
        if (this.destroyed) return this;
        this.destroyed = true;
        this.readable = false;
        if (err) this.emit("error", err);
        this.emit("close");
        return this;
    }
}

class Writable extends EventEmitter {
    constructor(options) {
        super();
        this.writable = true;
        this.destroyed = false;
        this.writableEnded = false;
        this.writableFinished = false;
        this._writableState = { ended: false };
    }

    write(chunk, enc, cb) {
        if (typeof enc === "function") { cb = enc; enc = undefined; }
        if (typeof chunk === "string") chunk = Buffer.from(chunk, enc || "utf8");
        this._write(chunk);
        if (cb) process.nextTick(cb);
        return true;
    }

    end(chunk, enc, cb) {
        if (typeof chunk === "function") { cb = chunk; chunk = undefined; }
        if (typeof cb === "function" && typeof enc === "function") { cb = enc; }
        if (chunk !== undefined) this.write(chunk, enc);
        this.writableEnded = true;
        this.writableFinished = true;
        this._writableState.ended = true;
        if (cb) process.nextTick(cb);
        this.emit("finish");
        return this;
    }

    destroy(err) {
        if (this.destroyed) return this;
        this.destroyed = true;
        this.writable = false;
        if (err) this.emit("error", err);
        this.emit("close");
        return this;
    }

    cork() {}
    uncork() {}
    _write(chunk) {} // subclass hook
}

class Duplex extends Readable {
    constructor(options) {
        super(options);
        Writable.call(this, options);
        this.writable = true;
    }
    end(chunk, enc, cb) { return Writable.prototype.end.call(this, chunk, enc, cb); }
    write(chunk, enc, cb) { return Writable.prototype.write.call(this, chunk, enc, cb); }
}

class PassThrough extends Duplex {}

module.exports = {
    Readable,
    Writable,
    Duplex,
    PassThrough,
    finished: (stream, cb) => { if (cb) stream.on("finish", () => cb()); },
    pipeline: () => { throw new Error("stream.pipeline: not implemented"); },
};
