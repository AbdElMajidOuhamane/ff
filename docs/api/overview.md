---
title: API Overview
description: All globals at a glance.
order: 1
---

# API Overview

Fairyfly exposes its API as globals and namespaces. No imports
needed — `fetch`, `console`, `fs`, `process`, `URL`, and the rest
are available in every script. `http` is a namespace with one
method: `http.serve`.

## Globals table

| Name | What it does | Details |
|---|---|---|
| `console` | `log`, `info`, `debug`, `warn`, `error`, `time`, `timeEnd` | [Console](#console) |
| `setTimeout`, `clearTimeout` | Run once after a delay | [Timers](#timers) |
| `setInterval`, `clearInterval` | Run on repeat | [Timers](#timers) |
| `queueMicrotask` | Run before next timer or I/O | [Microtasks](#microtasks) |
| `URL`, `URLSearchParams` | Parse and build URLs | [URL](#url) |
| `Headers`, `Request`, `Response` | Fetch primitives | [Fetch](#fetch) |
| `fetch` | Outbound HTTP client | [Fetch](#fetch) |
| `WebSocket` | Outbound WS client | [WebSocket](#websocket) |
| `Worker` | Multi-threaded JS, up to 8 threads | [Workers](#workers) |
| `Database` | Open SQLite files, run queries, transactions | Built-in, no packages |
| `SQL`, `sql` | Connect to Postgres — queries, types, transactions | [Postgres API](/docs/api/postgres) |
| `fs` | Sync files: read, write, mkdir, rm, readdir | [FS](#fs) |
| `process` | argv, env, cwd, exit, pid | [Process](#process) |
| `crypto` | `randomUUID`, `getRandomValues`, `subtle.digest` | [Crypto](#crypto) |
| `TextEncoder`, `TextDecoder` | UTF-8 encode and decode | [Text](#text) |
| `performance.now` | Milliseconds since start | [Utils](#utils) |
| `btoa`, `atob` | Base64 encode and decode | [Utils](#utils) |

## Console

```js
console.log("plain", 1, true, null);
console.info("info line");
console.debug("debug line");
console.warn("warned here");
console.error("errored", 42);
```

Methods: log, info, debug, warn, error, plus slops, redbal, detail aliases. All return undefined. All accept multiple args, joined with spaces.

Timing:

```js
console.time("t");
// ... work
console.timeEnd("t");
```

Prints elapsed milliseconds for label "t".

## Timers

```js
const id = setTimeout(() => console.log("once"), 30);
clearTimeout(id);

const iv = setInterval(() => console.log("tick"), 20);
clearInterval(iv);
```

setTimeout returns a numeric id. clearTimeout cancels it. Same pair for intervals. Max 128 live timers. Max 8 extra args after ms. Negative delay becomes 0. Full guide: Timers.

## Microtasks

```js
queueMicrotask(() => console.log("microtask"));
console.log("sync");
```

Output:

```text
sync
microtask
```

There is no process.nextTick. Use queueMicrotask.

## URL

```js
const u = new URL("https://user:pass@example.com:8080/path?q=1#hash");
console.log(u.protocol);
console.log(u.hostname);
console.log(u.port);
console.log(u.pathname);
console.log(u.search);
console.log(u.hash);
```

Output:

```text
https:
example.com
8080
/path
?q=1
#hash
```

Mutable — set parts and re-serialize:

```js
const u = new URL("/api/v2", "https://example.com");
u.pathname = "/api/v3";
console.log(u.toString());
```

Query strings:

```js
const p = new URLSearchParams("a=1&b=2&a=3");
console.log(p.get("a"), p.getAll("a"), p.has("b"));
```

Also URL.parse (returns null instead of throwing) and URL.canParse (returns boolean).

## Fetch

```js
const res = await fetch("https://httpbin.org/json");
console.log(res.status, res.ok);
console.log(await res.json());
```

Body readers: .text(), .json(), .arrayBuffer(), .bytes(), .blob(), .formData(). Each sets bodyUsed. Full guide: Fetch Client.

Response helpers for servers:

```js
Response.json({ ok: true });
Response.redirect("/new", 302);
Response.error();
```

## WebSocket

```js
const ws = new WebSocket("ws://127.0.0.1:3000/ws");
ws.onopen = () => ws.send("hello server");
ws.onmessage = (e) => console.log("got:", e.data);
ws.onclose = () => console.log("closed");
```

States: readyState 0 (connecting), 1 (open), 2 (closing), 3 (closed). Binary arrives as Uint8Array. Full guide: WebSocket.

## Workers

Multi-threaded JS execution with up to 8 worker threads. Each worker runs an isolated script and talks to the parent through messages.

```js
// main.js
const w = new Worker("./worker.js");
w.onmessage = (e) => console.log("from worker:", e.data);
w.onerror = (e) => console.error("worker error:", e.message);
w.postMessage("hello worker");
```

```js
// worker.js
onmessage = (e) => {
  console.log("from parent:", e.data);
  postMessage("hello worker");
};
```

What happens:

- `new Worker(path)` spawns a thread running the given file. Path is relative to the current script.
- `w.postMessage(data)` sends a value to the worker. `w.onmessage` receives replies.
- Inside the worker, the global `onmessage` receives parent messages and the global `postMessage` replies.
- `w.onerror` fires on uncaught worker errors. `w.terminate()` stops the worker.
- `options.data` passes an initial value at spawn time, visible as `globalThis.workerData`:

```js
const w = new Worker("./worker.js", { data: { id: 1 } });
```

```js
// worker.js
console.log(globalThis.workerData.id);
```

Limits you will hit:

- Max 8 workers per process.
- Per-worker stack and heap are capped — offload work, don't hoard state.
- Messages are serialized — no shared memory.
- Workers cannot open servers. Keep `http.serve` in the main thread.

## FS

Sync only:

```js
fs.writeFile("out.txt", "Hello from Fairyfly!");
console.log(fs.exists("out.txt"));
console.log(fs.readFile("out.txt"));
fs.mkdir("a/b", true);
console.log(fs.readdir("."));
fs.rm("out.txt", true);
```

Max path 4096 bytes, max read 10MB. Missing files throw.

## Process

```js
console.log(process.argv);
console.log(process.pid, process.platform, process.arch);
console.log(process.cwd());
process.chdir("/tmp");
console.log(process.env.HOME);
process.exit(0);
```

exit code is clamped 0-255. argv includes runtime and script name. Full reference: CLI.

## Crypto

```js
console.log(crypto.randomUUID());
```

Output:

```text
550e8400-e29b-41d4-a716-446655440000
```

Random bytes:

```js
const buf = new Uint8Array(16);
crypto.getRandomValues(buf);
```

Hash:

```js
const hash = await crypto.subtle.digest("SHA-256", new Uint8Array([104, 105]));
console.log(new Uint8Array(hash).length);
```

digest accepts SHA-1, SHA-256, SHA-384, SHA-512. Data is ArrayBuffer or typed array.

## Text

UTF-8 only:

```js
const bytes = new TextEncoder().encode("hello");
console.log(bytes);
console.log(new TextDecoder().decode(bytes));
```

Invalid bytes decode to the replacement character.

## Utils

```js
console.log(performance.now());
console.log(btoa("hello"));
console.log(atob("aGVsbG8="));
```

performance.now is milliseconds since process start. btoa encodes to base64, atob decodes and throws on invalid input.

## What is missing vs Node

- No require, no CommonJS — ESM only (bare imports resolve via node_modules)
- No Buffer — use Uint8Array
- No process.nextTick
- HTTP/1.1 plain; HTTP/2 over TLS only
- No DOM
