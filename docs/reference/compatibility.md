---
title: Compatibility
description: What's present, what's missing vs Node and browsers, and the substitutions to use.
order: 3
---

# Compatibility

Fairyfly targets **web-standard** APIs (fetch, URL, WebSocket, Headers)
with a deliberately small Node-shaped subset (`process`, `fs`, `console`).
This page is the gap list.

## What is present

Every global in `Object.getOwnPropertyNames(globalThis)`:

**Web standard:** `fetch` · `Request` · `Response` · `Headers` · `URL` ·
`URLSearchParams` · `Blob` · `FormData` · `TextEncoder` · `TextDecoder` ·
`WebSocket` · `crypto` (`randomUUID`, `getRandomValues`, `subtle.digest`)
· `btoa` · `atob` · `performance` · `queueMicrotask` · `DOMException`

**Fairyfly:** `http` · `fs` · `process` · `Database` · `sql` · `SQL` ·
`Worker` · `ffi` · `console`

**Engine (QuickJS-ng):** `Promise` · `Map`/`Set`/`WeakMap`/`WeakSet` ·
`Proxy` · `Reflect` · `Symbol` · `Iterator` · `Atomics` ·
`SharedArrayBuffer` · `FinalizationRegistry` · `WeakRef` ·
`AggregateError` · `DisposableStack`/`AsyncDisposableStack` ·
`Float16Array` · `BigInt` · `escape`/`unescape` · `eval`

## Missing vs Node

| Node API | Status | Use instead |
|---|---|---|
| `Buffer` | absent | `Uint8Array`, `ArrayBuffer` |
| `require()` / `module.exports` | absent | `import` / `export` (ESM only) |
| `__dirname` / `__filename` | absent | `new URL(".", import.meta.url)` |
| `process.nextTick` | absent | `queueMicrotask(fn)` |
| `process.stdout.write` | absent | `console.log` → **stderr** |
| `process.exitCode` | absent | `process.exit(n)` |
| `process.on("exit"…)` | absent | nothing to subscribe to |
| `setImmediate` | absent | `setTimeout(fn, 0)` |
| `structuredClone` | absent as global | clone via `postMessage` |
| `path` / `os` / `util` / `events` | absent | string ops, `URL`, arrays |
| `stream` | absent | arrays, `Response.text()` |
| `child_process` | absent | `Worker`, or spawn yourself |
| `net` / `tls` / `http` modules | absent | global `http.serve` (+ [TLS](/docs/guides/tls)) |
| `worker_threads` | absent | global `Worker` |
| `zlib` | absent | `crypto.subtle.digest` won't help — use `ffi` |
| `fs.promises` | absent | `fs.readFileAsync()` and friends |
| `crypto.createHash` / `createHmac` | absent | `crypto.subtle.digest` |
| `AbortController` / `signal` | absent | not supported by `fetch` |
| `setTimeout().unref()` (Node Timer) | partial | returns a `Timeout` **object**: `t.unref()`, `t.refresh()`, `t.hasRef()` |
| `DOMException` | **present** | (QuickJS builtin) |

## Missing vs browsers

| Browser API | Status | Use instead |
|---|---|---|
| `window`, `document`, DOM | absent | backend runtime |
| `addEventListener` | absent | `on…` properties (`ws.onmessage = …`) |
| `localStorage` / `sessionStorage` | absent | `fs` or SQLite |
| `ReadableStream` / `WritableStream` | absent | `arrayBuffer()` / `text()` |
| `TextEncoder#encodeInto` | absent | `encode()` |
| `EventSource` (SSE) | absent | raw `http.serve` with `content-type: text/event-stream` |
| `structuredClone` | absent | `postMessage` |
| `URL.canParse` / `URL.parse` | **present** | |
| `Response.json` / `Response.redirect` | **present** | |
| `fetch` `signal` | absent | timeouts: `Promise.race` |

## Behavioural deviations

These are the ones that bite during a port:

| Area | Deviation |
|---|---|
| `console.*` | Writes to **stderr**; all arguments printed; `warn` is yellow, `error` red — non-standard colours |
| Unhandled rejections | **Silent**, exit `0` (Node exits `1`) |
| Sync `fs` failures | Return `undefined`, **never throw** — the error is lost |
| `fetch` rejection | Rejects with a **string** (`"Network error"`), not an `Error` |
| `btoa` | Non-Latin-1 input does **not** throw — it UTF-8-encodes first (`btoa("😀")` → `"8J+YgA=="`) |
| `atob` | Throws `TypeError: atob: invalid base64 input` |
| `Headers.size` / `URLSearchParams.size` | **Methods** — `h.size()`, not `h.size` |
| `Headers.getAll(name)` | Non-standard; returns `string[]` |
| `TextDecoder` | Always lossy (`fatal: true` ignored); labels ignored — always UTF-8 |
| `performance.now()` | Origin is the **first call**, not navigation/start |
| `process.exit(300)` | Clamps to `255`; `-5` → `0`; non-numeric → `0` |
| Uncaught error format | `Error: TypeError: msg` + stack, exit `1` |
| `setTimeout(fn, …)` | Returns a `Timeout` **object**, not a number |
| `WebSocket` | Single `on…` handler per event; no `addEventListener` |
| Worker files | Evaluated as **classic scripts** — `import`/`export` throws |

## Porting checklist

```diff
- const chunks = [];
- res.on("data", (c) => chunks.push(c));
- res.on("end", () => Buffer.concat(chunks));
+ const buf = await res.bytes();

- process.stdout.write("hello");
+ console.log("hello");              // stderr — redirect explicitly

- try { fs.readFileSync(p); } catch { … }
+ if (fs.exists(p)) fs.readFileSync(p);   // sync fs never throws

- require("./util")
+ import { helper } from "./util.js";     // extensions are probed

- process.nextTick(fn)
+ queueMicrotask(fn)
```

## See also

- [API overview](/docs/api/overview) — every global, linked
- [Limitations](/docs/reference/limitations) — every hard cap
- [Modules](/docs/guides/modules) — ESM resolution rules
- [Errors and exit codes](/docs/concepts/errors)
