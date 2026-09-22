---
title: Introduction
order: 1
description: What Fairyfly is, when to use it, and the three rules every developer must know.
---

# Introduction

Fairyfly is a lightweight backend JavaScript runtime built with Zig and QuickJS. It runs on a single OS thread with an event loop powered by xev (epoll on Linux, kqueue on macOS).

> 138k req/sec · 0.66ms p50 · 5MB RSS on Apple silicon

## When to use Fairyfly

- Cold start matters (CLI tools, edge functions, short-lived jobs)
- Memory is capped (strict container limits)
- You want the whole runtime to fit in your head (under 10k lines of Zig)

## When NOT to use Fairyfly

- Browser parity — no DOM, no `window` object
- npm ecosystem — no automatic `node_modules` resolution

If you need those, use Node.js, Bun, or Deno instead.

## What's inside

Everything ships in a single binary. No `npm install` needed for core features.

| Feature | Details |
|---------|---------|
| HTTP/HTTPS Server | 512 connection slots, SoA layout, HTTP/2 via nghttp2 |
| TLS | BearSSL, zero-alloc hot path, TLS 1.2 only |
| SQLite | Embedded database, single-file amalgamation |
| WebSocket | Server and client, text and binary frames |
| Workers | Up to 8 threads, cooperative concurrency |
| Fetch | Outbound HTTP client with async support |
| Crypto | randomUUID, getRandomValues, subtle.digest |
| File System | Sync read, write, mkdir, rm, readdir |
| Timers | setTimeout, setInterval, queueMicrotask |
| URL | Full WHATWG URL API |

## Three rules

### Rule 1: ESM only, extensions mandatory

Every import must include the `.js` extension.

```js
// math.js
export function add(a, b) {
  return a + b;
}

// main.js
import { add } from "./math.js";
console.log(add(2, 3)); // 5
```

Bare specifiers like `import "lodash"` resolve by walking up `node_modules/` directories, but only pure-JS ESM packages work.

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
