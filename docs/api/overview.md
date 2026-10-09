---
title: API overview
description: Every global Fairyfly injects, one row each, linking to its full reference.
order: 1
---

# API overview

Everything below is available with **no imports** — Fairyfly injects these
globals into every script. Bare specifiers still resolve through
`node_modules` for packages (see [Packages](/docs/guides/packages)).

## Globals

| Global | What it is | Reference |
|---|---|---|
| `console` | Output, colored aliases, `time`/`timeLog`/`timeEnd` | [console](/docs/api/console) |
| `setTimeout`, `clearTimeout` | One-shot timer (max 128 live) | [Timers](/docs/guides/timers) |
| `setInterval`, `clearInterval` | Repeating timer | [Timers](/docs/guides/timers) |
| `queueMicrotask` | Run before the next timer or I/O callback | [Event loop](/docs/concepts/event-loop) |
| `performance` | `performance.now()` — monotonic ms | [performance](/docs/api/performance) |
| `URL`, `URLSearchParams` | WHATWG URL parser, query strings | [URL](/docs/api/url) |
| `Headers` | Case-insensitive header collection | [Request/Response](/docs/api/request-response) |
| `Request` | Fetch request object | [Request/Response](/docs/api/request-response) |
| `Response` | Fetch response object + `json`/`redirect`/`error` | [Request/Response](/docs/api/request-response) |
| `Blob` | Immutable binary blob | [Blob/FormData](/docs/api/blobs-formdata) |
| `FormData` | `multipart/form-data` container | [Blob/FormData](/docs/api/blobs-formdata) |
| `TextEncoder`, `TextDecoder` | UTF-8 string ↔ bytes | [Text encoding](/docs/api/text-encoding) |
| `fetch` | HTTP client (16 slots, HTTP/1.1) | [fetch](/docs/api/fetch) |
| `WebSocket` | WebSocket client (max 64 sockets) | [WebSocket](/docs/api/websocket) |
| `Worker` | OS-thread worker (max 8) | [Worker](/docs/api/worker) |
| `http` | `http.serve(options, handler)` | [http](/docs/api/http) |
| `fs` | Sync + Promise filesystem calls | [fs](/docs/api/fs) |
| `process` | `argv`, `env`, `exit`, `pid`, `memoryUsage`… | [process](/docs/api/process) |
| `crypto` | `randomUUID`, `getRandomValues`, `subtle.digest` | [crypto](/docs/api/crypto) |
| `btoa`, `atob` | Base64 encode / decode | [crypto](/docs/api/crypto) |
| `Database` | SQLite (`Database.open(path)`) | [SQLite](/docs/api/sqlite) |
| `sql`, `SQL` | Postgres tagged templates + pool | [Postgres](/docs/api/postgres) |
| `ffi` | C-ABI shared libraries (`--allow-ffi`) | [FFI](/docs/api/ffi) |
| `import.meta.url` | `file://` URL of the current module | [Modules](/docs/guides/modules) |

### Timer handles

`setTimeout` / `setInterval` return a `Timeout` **object** (pass it to
`clearTimeout` / `clearInterval`, or call its methods):

```js
const t = setTimeout(() => console.log("later"), 5000);
t.unref();      // don't hold the process open
t.refresh();    // restart the countdown
t.hasRef();     // boolean
t.ref();        // hold the process again
```

### Static helpers you'll use constantly

```js
Response.json({ ok: true });              // Response with JSON content-type
Response.redirect("/login");              // 302 status only — no Location header
URL.parse("not a url");                   // null instead of throwing
new URL("/a/b", "https://x.example");     // base resolution
crypto.randomUUID();                      // v4 UUID
Database.open("app.db");                  // SQLite
```

Full tables: [Response statics and Database methods](#quick-reference).

## Quick reference

### `Response` statics

| Method | Signature | Description |
|---|---|---|
| `Response.json(value, init?)` | `(any, { status?, headers? }) → Response` | JSON response shortcut |
| `Response.redirect(url, status?)` | `(string, number?) → Response` | Redirect status (default 302) — Known issue: no `Location` header emitted |
| `Response.error()` | `() → Response` | Error response, status `0` |

### `Database` methods

| Method | Signature | Description |
|---|---|---|
| `Database.open(path)` | `(string) → Database` | Open or create a database |
| `db.exec(sql, params?)` | `(string, Array?) → undefined` | One statement, bound params |
| `db.execNoArgs(sql)` | `(string) → undefined` | Multi-statement SQL, no params |
| `db.row(sql, params?)` | `(string, Array?) → object \| null` | First row |
| `db.rows(sql, params?)` | `(string, Array?) → object[]` | All rows |
| `db.changes()` | `() → number` | Rows affected by the last write |
| `db.lastInsertRowId()` | `() → number` | Rowid of the last insert |
| `db.transaction(fn)` | `(Function) → any` | Auto-commit / rollback |
| `db.busyTimeout(ms)` | `(number) → undefined` | Busy timeout (default 5000) |
| `db.close()` | `() → undefined` | Close the handle |

### `sql` / `SQL` methods

| Method | Signature | Description |
|---|---|---|
| `` sql`…` `` | `` (template) → Promise<rows> `` | Parameterized query |
| `sql.unsafe(str, params?)` | `(string, Array?) → Promise<rows>` | String-built, still parameterized |
| `sql.connect()` | `() → Promise<rows>` | Probe the pool — resolves with the `SELECT 1` rows |
| `sql.begin()` | `() → Promise<Tx>` | Transaction on one connection |
| `sql.close()` | `() → undefined` | Close the default pool |
| `tx.commit()` / `tx.rollback()` | `() → Promise<rows>` | End the transaction (resolves `[]`) |
| `new SQL(dsn)` | `(string) → SQL` | Pool bound to a DSN |

## Not provided

These common Node/browser globals are **absent** — with the substitute to
use instead:

| Missing | Use instead |
|---|---|
| `Buffer` | `Uint8Array` / `ArrayBuffer` |
| `require()` / CommonJS | `import` / `export` |
| `process.nextTick` | `queueMicrotask(fn)` |
| `setImmediate` | `setTimeout(fn, 0)` |
| `structuredClone` | built into `postMessage`; clone by messaging yourself |
| `AbortController` / `signal` | not supported by `fetch` |
| `addEventListener` on `WebSocket` | `ws.onopen = …` style handlers |
| `TextEncoder#encodeInto` | `encode()` |
| `process.stdout.write` | `console.log` (goes to **stderr**) |
| DOM, `window` | backend runtime |

Full list with rationale: [Compatibility](/docs/reference/compatibility).

## See also

- [Event loop](/docs/concepts/event-loop) — how these globals interact
- [Limitations](/docs/reference/limitations) — every hard cap
- [CLI](/docs/reference/cli) — how to run your code
