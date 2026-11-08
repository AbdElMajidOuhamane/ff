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

**Web standard:** `fetch` · `Request` · `Response` · `Headers` · `AbortController` · `AbortSignal` · `structuredClone` · `URL` ·
`URLSearchParams` · `Blob` · `FormData` · `TextEncoder` · `TextDecoder` ·
`WebSocket` · `crypto` (`randomUUID`, `getRandomValues`, `subtle.digest`, `subtle.importKey`, `subtle.sign`, `subtle.verify`, `subtle.exportKey`)
· `btoa` · `atob` · `performance` · `queueMicrotask` · `DOMException`

**Fairyfly:** `http` · `udp` · `fs` · `process` · `child_process` · `Database` ·
`sql` · `SQL` · `Worker` · `ffi` · `permissions` · `console`

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
| Read files | always | `--allow-read=<path>` |
| Write files | always | `--allow-write=<path>` |
| Outbound network / listen | always | `--allow-net=<host>[:port]` |
| `process.env` | full environment | `--allow-env=<name>` |
| Child processes | always | `--allow-run=<program>` |
| Native addons / FFI | always | `--allow-ffi` |

The escape hatch is `--allow-all`. Program loading (`import`,
`new Worker(path)`), `process.argv`, `cwd`, `exit`, `pid`, and CLI commands
(`ff imprint`, `ff fmt`, `ff upgrade`, `ff compile`) are not gated. Full model:
[Permissions](/docs/concepts/permissions).

## Missing vs Node

| Node API | Status | Use instead |
|---|---|---|
| `Buffer` | absent | `Uint8Array`, `ArrayBuffer` |
| `require()` / `module.exports` | absent | `import` / `export` (ESM only) |
| `__dirname` / `__filename` | absent | `new URL(".", import.meta.url)` |
| `process.nextTick` | absent | `queueMicrotask(fn)` |
| `process.stdout.write` | absent | `console.log` → **stderr** |
| `process.exitCode` | absent | `process.exit(n)` |
| `process.on("exit"…)` | partial | `process.on` / `once` / `off` support POSIX signals (`SIGINT`, `SIGTERM`, `SIGHUP`, `SIGUSR1`, `SIGUSR2`), not `"exit"` |
| `setImmediate` | absent | `setTimeout(fn, 0)` |
| `structuredClone` | **present** | Deep binary structured clone (max 4 MB) |
| `path` / `os` / `util` / `events` | absent | string ops, `URL`, arrays |
| `stream` | absent | arrays, `Response.text()` |
| `child_process` | partial | `spawn` / `exec` / `execSync` — no streams, stdin, or fork |
| `net` / `tls` / `http` modules | absent | global `http.serve` (+ [TLS](/docs/guides/tls)) |
| `worker_threads` | absent | global `Worker` |
| `zlib` | absent | `crypto.subtle.digest` won't help — use `ffi` |
| `fs.promises` | absent | `fs.readFileAsync()` and friends |
| `crypto.createHash` / `createHmac` | absent | `crypto.subtle.digest` / `crypto.subtle.sign` (HMAC) |
| `AbortController` / `AbortSignal` | **present** | Supported by `fetch`, `Request`, `setTimeout`, `setInterval`, and `http.serve` |
| `setTimeout().unref()` (Node Timer) | partial | returns a `Timeout` **object**: `t.unref()`, `t.refresh()`, `t.hasRef()` |
| `DOMException` | **present** | (QuickJS builtin) |

## Missing vs browsers

| Browser API | Status | Use instead |
|---|---|---|
| `window`, `document`, DOM | absent | backend runtime |
| `addEventListener` | partial | Present on `AbortSignal`; use `on…` properties on `WebSocket` / `Worker` (`ws.onmessage = …`) |
| `localStorage` / `sessionStorage` | absent | `fs` or SQLite |
| `ReadableStream` / `WritableStream` | absent | `arrayBuffer()` / `text()` |
| `TextEncoder#encodeInto` | absent | `encode()` |
| `EventSource` (SSE) | absent | raw `http.serve` with `content-type: text/event-stream` |
| `structuredClone` | **present** | |
| `URL.canParse` / `URL.parse` | **present** | |
| `Response.json` / `Response.redirect` | **present** | |
| `fetch` `signal` | **present** | `AbortController` / `AbortSignal.timeout(ms)` |

## Behavioural deviations

These are the ones that bite during a port:

| Area | Deviation |
|---|---|
| Native permissions | **Deny-by-default**; Node/Bun run with full access — pass `--allow-*` |
| `console.*` | Writes to **stderr**; all arguments printed; `warn` is yellow, `error` red — non-standard colours |
| Unhandled rejections / jobs | Bare unhandled promise rejections are silent (exit `0`); uncaught errors in queued microtasks or timer callbacks print to stderr and exit `1` |
| Sync `fs` failures | Return `undefined` on ordinary **I/O** failure; `writeFile` throws if data > 10 MiB; permission denial **throws** `PermissionDenied` |
| `process.env` | Filtered snapshot — only `--allow-env` names are present |
| `process.chdir` | Needs `read` on the target; outside the scope it throws `PermissionDenied` |
| `fetch` rejection | Ordinary failures reject with a **string** (`"Network error"`); initial permission denial is an `Error`; redirect-hop denial is a string |
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
| `child_process` | No streams/events — use `wait()` + captured `stdout`/`stderr`; children are not killed on exit |

## Porting checklist

```diff
- const chunks = [];
- res.on("data", (c) => chunks.push(c));
- res.on("end", () => Buffer.concat(chunks));
+ const buf = await res.bytes();

- process.stdout.write("hello");
+ console.log("hello");              // stderr — redirect explicitly

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
