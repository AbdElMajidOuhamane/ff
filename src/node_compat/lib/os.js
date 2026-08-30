// Node os — pure subset; hostname/cpus delegate to native hooks on process.
"use strict";

const isWindows = process.platform === "win32";

const os = {
    EOL: isWindows ? "\r\n" : "\n",
    arch: () => process.arch,
    platform: () => process.platform,
    type: () => isWindows ? "Windows_NT" : (process.platform === "darwin" ? "Darwin" : "Linux"),
    release: () => isWindows ? "10" : (process.platform === "darwin" ? "24.0.0" : "6.1.0"),
    tmpdir: () => {
        const t = process.env.TMPDIR || process.env.TEMP ||
            (isWindows ? "C:\\Windows\\TEMP" : "/tmp");
        return t.replace(/[\\/]+$/, "") || "/";
    },
    homedir: () => process.env.HOME || process.env.USERPROFILE || "",
    hostname: () => {
        if (typeof process._hostname === "function") {
            const h = process._hostname();
            if (h) return h;
        }
        return process.env.HOSTNAME || process.env.COMPUTERNAME || "localhost";
    },
    uptime: () => (typeof process._uptime === "function" ? process._uptime() : 0),
    loadavg: () => (typeof process._loadavg === "function" ? process._loadavg() : [0, 0, 0]),
    totalmem: () => (typeof process._totalmem === "function" ? process._totalmem() : 0),
    freemem: () => (typeof process._freemem === "function" ? process._freemem() : 0),
    cpus: () => {
        const n = typeof process._nCpus === "function" ? process._nCpus() : 1;
        const arr = [];
        for (let i = 0; i < n; i++) {
            arr.push({ model: "generic", speed: 0, times: { user: 0, nice: 0, sys: 0, idle: 0, irq: 0 } });
        }
        return arr;
    },
    userInfo: () => ({
        username: process.env.USER || process.env.USERNAME || "",
        uid: -1, gid: -1, shell: null, homedir: os.homedir(),
    }),
    endianness: () => "LE",
    availParallelism: () => (typeof process._nCpus === "function" ? process._nCpus() : 1),
};

os.constants = {
    signals: {},
    errno: {},
    priority: {},
};

module.exports = os;
