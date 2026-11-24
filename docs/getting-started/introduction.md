---
title: Introduction
order: 1
description: What Fairyfly is, when to use it, and the three rules every developer must know.
---

# Introduction

Fairyfly is a lightweight backend JavaScript runtime built with Zig and QuickJS. It runs on a single OS thread with an event loop powered by libxev (io_uring on Linux by default, or epoll via `-Dio_uring=false`, kqueue on macOS).

> 138k req/sec · 0.66ms p50 · 5MB RSS on Apple silicon

## When to use Fairyfly

- Cold start matters (CLI tools, edge functions, short-lived jobs)
- Memory is capped (strict container limits)
- You want the whole runtime to fit in your head (~41k lines of Zig across 85 files)

## When NOT to use Fairyfly

- Browser parity — no DOM, no `window` object
- Full npm ecosystem — only pure-JS ESM packages work (`ff imprint`; no CommonJS, no `node:` builtins)

If you need those, use Node.js, Bun, or Deno instead.

## What's inside

Everything ships in a single binary. No `npm install` needed for core features.

| Feature | Details |
|---------|---------|
| HTTP/HTTPS Server | 512 connection slots, SoA layout, HTTP/2 via nghttp2, declarative routes, HTTP/1.1 chunked streaming |
| TLS | BearSSL, zero-alloc hot path, TLS 1.2 (HTTPS, WSS, Postgres `verify-full`) |
| SQLite | Embedded database, single-file amalgamation |
| Postgres | Built-in wire client, connection pool, transactions, TLS `verify-full` |
| WebSocket & Sockets | Server & client WebSocket, `tcp.connect` (128 slots), `udp.socket` (64 slots) |
| Streams & Responses | `ReadableStream` (on-demand `pull`, HTTP/1.1 chunked) and `Response.file(path)` |
| Workers | Up to 8 threads, cooperative concurrency, configurable `--worker-heap` |
| Fetch | Outbound HTTP client with async + `AbortSignal` support |
| Crypto | `randomUUID`, `getRandomValues`, `subtle` (`digest`, HMAC `importKey`/`sign`/`verify`/`exportKey`), `bcrypt` (`hash`/`verify`), `btoa`/`atob` |
| File System & Stdio | Sync read/write/mkdir/rm/readdir (+ `*Async` variants), `process.stdout.write`, `process.stdin.read`/`readSync` |
| Subprocesses & FFI | `child_process` (`spawn`/`exec`/`execSync`) and `ffi` (`dlopen` on source builds) |
| Permissions | Deny-by-default `--allow-*` and `--deny-*` CLI flags, one-way `permissions.revoke()` |
| Timers & Cron | `setTimeout`, `setInterval`, `queueMicrotask`, `ff.cron` (UTC cron & `@every` intervals) |
| Limits & Packaging | `--max-heap`, `--max-stack`, `--worker-heap`, `--cpu-budget`, `--env-file`, `ff compile` / `--standalone` |
| URL | Full WHATWG URL API |

## Three rules

### Rule 1: ESM only, extensions optional

Imports are ESM (there is no `require`). A relative specifier may omit
the `.js` extension — the loader then probes `X.js`, then `X/index.js`:

```js
// math.js
export function add(a, b) {
  return a + b;
}

// main.js
import { add } from "./math.js";   // "./math" works too
console.log(add(2, 3)); // 5
```

Non-`.js` extensions (`.mjs`, …) are **not** probed — write those out.

Bare specifiers like `import "marked"` resolve by walking up `node_modules/` directories, but only pure-JS ESM packages work.

### Rule 2: No CommonJS, no require()

There is no `require()` function. No `module.exports`. No `__dirname` or `__filename` globals.

Use `import`/`export` and `import.meta.url` instead.

```js
// Wrong — these do not exist
const fs = require("fs");
const __dirname = path.dirname(__filename);

// Right
import { readFile } from "./utils.js";
const dir = new URL(".", import.meta.url).pathname;
```

### Rule 3: No process.nextTick

Use `queueMicrotask()` instead. It runs before the next timer or I/O event, just like `process.nextTick` in Node.js.

```js
queueMicrotask(() => console.log("runs next"));
console.log("runs first");
```

Output:

```text
runs first
runs next
```
