// Node net — Socket/Server stubs (Express reads socket metadata only).
"use strict";

const EventEmitter = require("events");

class Socket extends EventEmitter {
    constructor(options) {
        super();
        this.remoteAddress = "127.0.0.1";
        this.remotePort = 0;
        this.localAddress = "127.0.0.1";
        this.localPort = 0;
        this.destroyed = false;
        this.writable = true;
        this.readable = true;
    }
    setEncoding() { return this; }
    setKeepAlive() { return this; }
    setNoDelay() { return this; }
    write() { return false; }
    end() { this.destroyed = true; this.emit("close"); return this; }
    destroy() { this.destroyed = true; this.emit("close"); return this; }
}

class Server extends EventEmitter {
    listen() { return this; }
    close(cb) { if (cb) process.nextTick(cb); this.emit("close"); return this; }
    address() { return { address: "0.0.0.0", port: 0 }; }
}

function createConnection() { return new Socket(); }

module.exports = {
    Socket,
    Server,
    createConnection,
    connect: createConnection,
    isIP: (s) => (/^\d+\.\d+\.\d+\.\d+$/.test(s) ? 4 : (/^[0-9a-fA-F:]+$/.test(s) ? 6 : 0)),
};
