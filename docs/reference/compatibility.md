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

**Web standard:** `fetch` · `Request` · `Response` · `Headers` · `ReadableStream` · `AbortController` · `AbortSignal` · `structuredClone` · `URL` ·
`URLSearchParams` · `Blob` · `FormData` · `TextEncoder` · `TextDecoder` ·
`WebSocket` · `setTimeout` · `setInterval` · `clearTimeout` · `clearInterval` ·
`crypto` (`randomUUID`, `getRandomValues`, `subtle.digest`, `subtle.importKey`, `subtle.sign`, `subtle.verify`, `subtle.exportKey`, `bcrypt.hash`, `bcrypt.verify`)
· `btoa` · `atob` · `performance` · `queueMicrotask` · `DOMException`

**Fairyfly:** `http` · `tcp` · `udp` · `fs` · `process` · `child_process` · `Database` ·
`sql` · `SQL` · `Worker` · `ffi` · `ff` (`ff.cron`) · `permissions` · `console`

**Engine (QuickJS-ng):** `Promise` · `Map`/`Set`/`WeakMap`/`WeakSet` ·
`Proxy` · `Reflect` · `Symbol` · `Iterator` · `Atomics` ·
`SharedArrayBuffer` · `FinalizationRegistry` · `WeakRef` ·
`AggregateError` · `DisposableStack`/`AsyncDisposableStack` ·
`Float16Array` · `BigInt` · `escape`/`unescape` · `eval`

## Permissions (vs Node and Bun)

Node and Bun run with the process's full authority. Fairyfly is
**deny-by-default**:

| Capability | Node / Bun | Fairyfly |
|---|---|---|
| Read files | always | `--allow-read=<path>` (`--deny-read=<path>`) |
| Write files | always | `--allow-write=<path>` (`--deny-write=<path>`) |
| Outbound network / listen | always | `--allow-net=<host>[:port]` (`--deny-net=<host>[:port]`) |
| `process.env` | full environment | `--allow-env=<name>` |
| Child processes | always | `--allow-run=<program>` |
| Native addons / FFI | always | `--allow-ffi` |

The escape hatch is `--allow-all`, and active permissions can be narrowed or dropped one-way at runtime via `permissions.revoke(...)`. Program loading (`import`, `new Worker(path)`), `process.argv`, `cwd`, `exit`, `pid`, `platform`, `arch`, `on`, `once`, `off`, `removeListener`, `stdout`, `stdin`, `memoryUsage`, `stats`, self-`kill`, and CLI commands (`ff imprint`, `ff fmt`, `ff upgrade`, `ff compile`) are not gated. Full model: [Permissions](/docs/concepts/permissions).

## Missing vs Node

| Node API | Status | Use instead |
|---|---|---|
| `Buffer` | absent | `Uint8Array`, `ArrayBuffer` |
| `require()` / `module.exports` | absent | `import` / `export` (ESM only) |
| `__dirname` / `__filename` | absent | `new URL(".", import.meta.url)` |
| `process.nextTick` | absent | `queueMicrotask(fn)` |
| `process.stdout.write` / `process.stdin` | **present** | Direct sync `stdout.write` and 64 KiB `stdin.read` / `readSync` (no Node EventEmitter stream methods or `process.stderr`; `console.*` → **stderr**) |
| `process.exitCode` | absent | `process.exit(n)` |
| `process.on("exit"…)` | partial | `process.on` / `once` / `off` support POSIX signals (`SIGINT`, `SIGTERM`, `SIGHUP`, `SIGUSR1`, `SIGUSR2`), not `"exit"` |
| `setImmediate` | absent | `setTimeout(fn, 0)` |
| `structuredClone` | **present** | Deep binary structured clone (max 4 MB) |
| `path` / `os` / `util` / `events` | absent | string ops, `URL`, arrays |
| `stream` | absent | arrays, `Response.text()`, `ReadableStream` |
| `child_process` | partial | `spawn` / `exec` / `execSync` — no streams, stdin, or fork |
| `net` / `tls` / `http` modules | absent | globals `http.serve` (+ [TLS](/docs/guides/tls)), `tcp.connect`, `udp.socket` |
| `worker_threads` | absent | global `Worker` |
| `zlib` | absent | `crypto.subtle.digest` won't help — use `ffi` |
| `fs.promises` | absent | `fs.readFileAsync()` and friends |
| `crypto.createHash` / `createHmac` | absent | `crypto.subtle.digest` / `crypto.subtle.sign` (HMAC) |
| `AbortController` / `AbortSignal` | **present** | Supported by `fetch`, `Request`, `setTimeout`, `setInterval`, and `http.serve` |
| `setTimeout().unref()` (Node Timer) | partial | returns a `Timeout` **object** on main thread (`t.unref()`, `t.ref()`, `t.refresh()`, `t.hasRef()`), numeric ID in Workers |
| `DOMException` | **present** | (QuickJS builtin) |

## Missing vs browsers

| Browser API | Status | Use instead |
|---|---|---|
| `window`, `document`, DOM | absent | backend runtime |
| `addEventListener` | partial | Present on `AbortSignal`; use `on…` properties on `WebSocket` / `Worker` (`ws.onmessage = …`) |
| `localStorage` / `sessionStorage` | absent | `fs` or SQLite |
| `ReadableStream` | **present** | WHATWG stream support (`getReader`, `locked`, `cancel`, `pull` callback on demand, `controller.enqueue`/`close`/`error`/`desiredSize`). HTTP/1.1 chunked response streaming slices payloads larger than `16352` bytes (~16 KB); HTTP/2 returns `501` for stream bodies |
| `WritableStream` | absent | `arrayBuffer()` / `text()` |
| `TextEncoder#encodeInto` | absent | `encode()` |
| `EventSource` (SSE) | absent | raw `http.serve` with `content-type: text/event-stream` |
| `structuredClone` | **present** | |
| `URL.canParse` / `URL.parse` | **present** | |
| `Response.json` / `Response.redirect` / `Response.error` / `Response.file` | **present** | `Response.file(path)` requires `--allow-read` |
| `fetch` `signal` | **present** | `AbortController` / `AbortSignal.timeout(ms)` |

## Behavioural deviations

These are the ones that bite during a port:

| Area | Deviation |
|---|---|
| Native permissions | **Deny-by-default**; Node/Bun run with full access — pass `--allow-*` |
| `console.*` | Writes to **stderr**; all arguments printed; `warn` is yellow, `error` red — non-standard colours |
| Unhandled rejections / jobs | Unhandled Promise rejections (including top-level `await` in `.js`/`.ffbc`/`--standalone`) and uncaught errors in queued microtasks or timer callbacks print to stderr (`Uncaught (in promise): ...`) and exit `1` |
| Sync `fs` failures | Return `undefined` on ordinary **I/O** failure (and on sync `writeFile` > 10 MiB, which currently writes nothing without throwing in JS; `fs.writeFileAsync` > 10 MiB throws `TypeError` synchronously); permission denial **throws** `PermissionDenied` |
| `process.env` | Filtered snapshot — only `--allow-env` names are present |
| `process.chdir` | Needs `read` on the target; outside the scope it throws `PermissionDenied` |
| `fetch` rejection | Ordinary failures reject with a **string** (`"Network error"`); initial permission denial is an `Error`; redirect-hop denial is a string |
| `btoa` | Non-Latin-1 input does **not** throw — it UTF-8-encodes first (`btoa("😀")` → `"8J+YgA=="`) |
| `atob` | Throws `TypeError: atob: invalid base64 input` |
| `Headers.size` / `URLSearchParams.size` / `FormData.size` | **Methods** — `h.size()`, not `h.size` |
| `Headers.getAll(name)` | Non-standard; returns `string[]` |
| `TextDecoder` | Always lossy (`fatal: true` ignored); labels ignored — always UTF-8 |
| `performance.now()` | Origin is the **first call**, not navigation/start |
| `process.exit(300)` | Clamps to `255`; `-5` → `0`; non-numeric → `0` |
| Uncaught error format | `Error: TypeError: msg` + stack, exit `1` |
| `setTimeout(fn, …)` | Returns a `Timeout` **object** on the main thread (numeric ID in Workers) |
| `WebSocket` | Single `on…` handler per event; no `addEventListener` |
| Worker files | Evaluated as **classic scripts** — `import`/`export` throws |
| `child_process` | No streams/events — use `wait()` + captured `stdout`/`stderr`; children are not killed on exit |
| Stream binary chunk borrow | Oversized `Uint8Array` / `ArrayBuffer` stream chunks (> `16352` bytes) are sliced zero-copy across consecutive HTTP chunk writes by borrowing the backing memory rather than copying/transferring. In-place mutations made to the buffer mid-stream are reflected in subsequent slices. |
| HTTP/2 stream body | Stream response bodies over HTTP/2 return `501 Not Implemented` (HTTP/1.1 chunked streaming is fully supported). |

## Porting checklist

```diff
- const chunks = [];
- res.on("data", (c) => chunks.push(c));
- res.on("end", () => Buffer.concat(chunks));
+ const buf = await res.bytes();

- process.stdin.on("data", (c) => …);
+ const chunk = await process.stdin.read(); // 64 KiB read(), or readSync() (console.* -> stderr)

- try { fs.readFileSync(p); } catch { … }
+ if (fs.exists(p)) fs.readFileSync(p);   // I/O errors are swallowed; permission denial throws

- require("./util")
+ import { helper } from "./util.js";     // extensions are probed

- process.nextTick(fn)
+ queueMicrotask(fn)
```

Native access needs an explicit grant at launch:

```diff
- ff server.js
+ ff server.js --allow-net=0.0.0.0:3000 --allow-read=./public

- ff tool.js
+ ff tool.js --allow-run=git --allow-env=PATH,HOME
```

## See also

- [Permissions](/docs/concepts/permissions) — flags, scopes, error contract
- [API overview](/docs/api/overview) — every global, linked
- [Limitations](/docs/reference/limitations) — every hard cap
- [Modules](/docs/guides/modules) — ESM resolution rules
- [Errors and exit codes](/docs/concepts/errors)
