// Node http — createServer/IncomingMessage/ServerResponse bridged onto the
// native fairyfly HTTP server via the (url, method, body, rawHeaders) contract.
"use strict";

const EventEmitter = require("events");
const stream = require("stream");
const net = require("net");

// ── header block parsing (native passes the raw request head) ──
function parseHeaderBlock(raw) {
    const lines = raw.split("\r\n");
    const rawHeaders = [];
    const headers = {};
    let first = true;
    for (const line of lines) {
        if (first) { first = false; continue; } // request line
        if (line.length === 0) continue;
        const ci = line.indexOf(":");
        if (ci === -1) continue;
        const name = line.slice(0, ci).trim();
        const value = line.slice(ci + 1).trim();
        rawHeaders.push(name, value);
        const lname = name.toLowerCase();
        if (headers[lname] === undefined) headers[lname] = value;
        else if (Array.isArray(headers[lname])) headers[lname].push(value);
        else headers[lname] = [headers[lname], value];
    }
    return { rawHeaders, headers };
}

// ── IncomingMessage ─────────────────────────────────────────
class IncomingMessage extends stream.Readable {
    constructor(method, url, rawHeaders, bodyStr) {
        super();
        this.method = method;
        this.url = url;
        this.httpVersion = "1.1";
        this.rawHeaders = [];
        this.headers = {};
        if (typeof rawHeaders === "string" && rawHeaders.length > 0) {
            const parsed = parseHeaderBlock(rawHeaders);
            this.rawHeaders = parsed.rawHeaders;
            this.headers = parsed.headers;
        }
        this.socket = new net.Socket();
        this.connection = this.socket;
        this.complete = true;
        if (typeof bodyStr === "string" && bodyStr.length > 0) {
            this.push(Buffer.from(bodyStr, "utf8"));
        }
        this.push(null);
    }
    get readableEnded() { return this._delivered === true; }
    get(path_) { // minimal; Express's own request.js usually provides this
        const v = this.headers[String(path_).toLowerCase()];
        return v === undefined ? undefined : (Array.isArray(v) ? v[0] : v);
    }
}

// ── ServerResponse ──────────────────────────────────────────
class ServerResponse extends stream.Writable {
    constructor() {
        super();
        this.statusCode = 200;
        this.statusMessage = undefined;
        this._headers = Object.create(null);
        this.headersSent = false;
        this.finished = false;
        this.writableEnded = false;
        this.writableFinished = false;
        this._bodyChunks = [];
        this._bodyLen = 0;
        this.socket = new net.Socket();
        this.connection = this.socket;
    }

    setHeader(name, value) {
        this._headers[String(name).toLowerCase()] = String(value);
        return this;
    }
    getHeader(name) {
        const v = this._headers[String(name).toLowerCase()];
        return v === undefined ? undefined : v;
    }
    getHeaders() {
        const out = {};
        for (const k of Object.keys(this._headers)) out[k] = this._headers[k];
        return out;
    }
    getHeaderNames() { return Object.keys(this._headers); }
    removeHeader(name) { delete this._headers[String(name).toLowerCase()]; return this; }
    hasHeader(name) { return this._headers[String(name).toLowerCase()] !== undefined; }

    writeHead(statusCode, reasonOrHeaders, headers) {
        this.statusCode = statusCode;
        let extra;
        if (typeof reasonOrHeaders === "string") {
            this.statusMessage = reasonOrHeaders;
            extra = headers;
        } else if (reasonOrHeaders && typeof reasonOrHeaders === "object") {
            extra = reasonOrHeaders;
        }
        if (extra) {
            for (const k of Object.keys(extra)) this.setHeader(k, extra[k]);
        }
        this.headersSent = true;
        return this;
    }

    write(chunk, enc, cb) {
        if (this.finished) throw new Error("write after end");
        if (typeof chunk === "function") { cb = chunk; chunk = undefined; }
        if (typeof enc === "function") { cb = enc; enc = undefined; }
        if (chunk !== undefined && chunk !== null) {
            if (typeof chunk === "string") chunk = Buffer.from(chunk, enc || "utf8");
            this._bodyChunks.push(chunk);
            this._bodyLen += chunk.length;
        }
        this.headersSent = true;
        if (cb) process.nextTick(cb);
        return true;
    }

    end(chunk, enc, cb) {
        if (this.finished) return this;
        if (typeof chunk === "function") { cb = chunk; chunk = undefined; }
        if (typeof enc === "function") { cb = enc; enc = undefined; }
        if (chunk !== undefined && chunk !== null) this.write(chunk, enc);
        this.finished = true;
        this.writableEnded = true;
        this.writableFinished = true;
        this.headersSent = true;
        this.emit("prefinish");
        this.emit("finish");
        if (cb) process.nextTick(cb);
        return this;
    }

    flushHeaders() { return this; }
    writeContinue() { return this; }

    // Bridge hook: produce the native contract { status, headersRaw, body }.
    // body is handed to the native as an exact-size ArrayBuffer (binary-safe).
    _finalize() {
        const body = Buffer.concat(this._bodyChunks);
        const headers = {};
        for (const k of Object.keys(this._headers)) headers[k] = this._headers[k];
        const suppress = this.statusCode === 204 || this.statusCode === 304;
        let hasCL = false;
        for (const k of Object.keys(headers)) {
            if (k === "content-length") hasCL = true;
        }
        if (!hasCL && !suppress) headers["content-length"] = String(body.length);
        if (suppress && hasCL) delete headers["content-length"];
        let raw = "";
        for (const k of Object.keys(headers)) raw += k + ": " + headers[k] + "\r\n";
        return {
            status: this.statusCode,
            headersRaw: raw,
            body: body.length > 0 ? body.buffer : "",
        };
    }
}

// ── Server ──────────────────────────────────────────────────
class Server extends EventEmitter {
    constructor(listener, options) {
        super();
        this._listener = listener;
        this._options = options || {};
        this._port = 0;
        this.listening = false;
    }

    listen(port, ...rest) {
        const cb = rest.find((r) => typeof r === "function");
        let p = typeof port === "number" ? port : (typeof port === "string" ? parseInt(port, 10) : 3000);
        if (!Number.isFinite(p) || p <= 0) p = 3000;
        this._port = p;
        const self = this;
        globalThis.http.serve({ port: p }, function (url, method, body, rawHeaders) {
            return handleRequest(self._listener, url, method, body, rawHeaders);
        });
        this.listening = true;
        this.emit("listening");
        if (cb) process.nextTick(cb);
        return this;
    }

    close(cb) {
        this.listening = false;
        if (cb) process.nextTick(cb);
        this.emit("close");
        return this;
    }

    address() { return { address: "0.0.0.0", family: "IPv4", port: this._port }; }
}

// ── bridge: native (url, method, body, rawHeaders) → Node shapes ──
function handleRequest(listener, url, method, bodyStr, rawHeaders) {
    const req = new IncomingMessage(method, url, rawHeaders, bodyStr);
    const res = new ServerResponse();
    return new Promise((resolve) => {
        res.on("finish", () => resolve(res._finalize()));
        try {
            listener(req, res);
        } catch (err) {
            // last-resort: Express's own error handling normally ends res first
            resolve({
                status: 500,
                headersRaw: "Content-Type: text/plain\r\n",
                body: "Internal Server Error",
            });
        }
    });
}

function createServer(listener, options) {
    return new Server(listener, options);
}

// ── constants ───────────────────────────────────────────────
const METHODS = [
    "ACL", "BIND", "CHECKOUT", "CONNECT", "COPY", "DELETE", "GET", "HEAD",
    "LINK", "LOCK", "M-SEARCH", "MERGE", "MKACTIVITY", "MKCALENDAR", "MKCOL",
    "MOVE", "NOTIFY", "OPTIONS", "PATCH", "POST", "PROPFIND", "PROPPATCH",
    "PURGE", "PUT", "QUERY", "REBIND", "REPORT", "SEARCH", "SOURCE",
    "SUBSCRIBE", "TRACE", "UNBIND", "UNLINK", "UNLOCK", "UNSUBSCRIBE",
];

const STATUS_CODES = {
    100: "Continue", 101: "Switching Protocols", 102: "Processing", 103: "Early Hints",
    200: "OK", 201: "Created", 202: "Accepted", 203: "Non-Authoritative Information",
    204: "No Content", 205: "Reset Content", 206: "Partial Content",
    300: "Multiple Choices", 301: "Moved Permanently", 302: "Found", 303: "See Other",
    304: "Not Modified", 305: "Use Proxy", 307: "Temporary Redirect", 308: "Permanent Redirect",
    400: "Bad Request", 401: "Unauthorized", 402: "Payment Required", 403: "Forbidden",
    404: "Not Found", 405: "Method Not Allowed", 406: "Not Acceptable",
    407: "Proxy Authentication Required", 408: "Request Timeout", 409: "Conflict",
    410: "Gone", 411: "Length Required", 412: "Precondition Failed",
    413: "Payload Too Large", 414: "URI Too Long", 415: "Unsupported Media Type",
    416: "Range Not Satisfiable", 417: "Expectation Failed", 418: "I'm a Teapot",
    421: "Misdirected Request", 422: "Unprocessable Entity", 423: "Locked",
    424: "Failed Dependency", 425: "Too Early", 426: "Upgrade Required",
    428: "Precondition Required", 429: "Too Many Requests",
    431: "Request Header Fields Too Large", 451: "Unavailable For Legal Reasons",
    500: "Internal Server Error", 501: "Not Implemented", 502: "Bad Gateway",
    503: "Service Unavailable", 504: "Gateway Timeout", 505: "HTTP Version Not Supported",
    506: "Variant Also Negotiates", 507: "Insufficient Storage", 508: "Loop Detected",
    509: "Bandwidth Limit Exceeded", 510: "Not Extended", 511: "Network Authentication Required",
};

module.exports = {
    createServer,
    Server,
    IncomingMessage,
    ServerResponse,
    METHODS,
    STATUS_CODES,
    maxHeaderSize: 16384,
    globalAgent: { keepAlive: false, maxSockets: Infinity },
    Agent: function Agent() { throw new Error("http.Agent: client requests not implemented"); },
    request: () => { throw new Error("http.request: client requests not implemented"); },
    get: () => { throw new Error("http.get: client requests not implemented"); },
    validateHeaderName: () => {},
    validateHeaderValue: () => {},
};
