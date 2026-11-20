---
title: API overview
description: Every global Fairyfly injects, one row each, linking to its full reference.
order: 1
---

# API overview

Everything below is available with **no imports** — Fairyfly injects these
globals into every script. Bare specifiers still resolve through
`node_modules` for packages (see [Packages](/docs/guides/packages)).

Native capabilities are **deny-by-default**. The Permission column names the
flag a global needs; `—` means it is always available. Full model:
[Permissions](/docs/concepts/permissions).

## Globals

| Global | What it is | Permission | Reference |
|---|---|---|---|
| `console` | Output, colored aliases, `time`/`timeLog`/`timeEnd` | — | [console](/docs/api/console) |
| `setTimeout`, `clearTimeout` | One-shot timer (max 128 live) | — | [Timers](/docs/guides/timers) |
| `setInterval`, `clearInterval` | Repeating timer | — | [Timers](/docs/guides/timers) |
| `queueMicrotask` | Run before the next timer or I/O callback | — | [Event loop](/docs/concepts/event-loop) |
| `performance` | `performance.now()` — monotonic ms | — | [performance](/docs/api/performance) |
| `URL`, `URLSearchParams` | WHATWG URL parser, query strings | — | [URL](/docs/api/url) |
| `Headers` | Case-insensitive header collection | — | [Request/Response](/docs/api/request-response) |
| `Request` | Fetch request object | — | [Request/Response](/docs/api/request-response) |
| `Response` | Fetch response object + `json`/`redirect`/`error`/`file` | — (`read` for `Response.file`) | [Request/Response](/docs/api/request-response) |
| `ReadableStream` | WHATWG readable stream with `pull` on demand, controller (`enqueue`/`close`/`error`), `getReader()`, `cancel()`, `locked`. Supports HTTP/1.1 chunked streaming (large chunks sliced transparently); HTTP/2 stream bodies return 501. | — | [ReadableStream](/docs/api/streams) |
| `AbortController`, `AbortSignal` | Cancellation controller + signal (`abort()`, `timeout(ms)`) | — | [fetch](/docs/api/fetch) |
| `structuredClone` | Deep binary structured clone (max 4 MB) | — | [Worker](/docs/api/worker) |
| `Blob` | Immutable binary blob | — | [Blob/FormData](/docs/api/blobs-formdata) |
| `FormData` | `multipart/form-data` container | — | [Blob/FormData](/docs/api/blobs-formdata) |
| `TextEncoder`, `TextDecoder` | UTF-8 string ↔ bytes | — | [Text encoding](/docs/api/text-encoding) |
| `fetch` | HTTP client (16 slots, HTTP/1.1) | `net` | [fetch](/docs/api/fetch) |
| `WebSocket` | WebSocket client (max 64 sockets) | `net` | [WebSocket](/docs/api/websocket) |
| `Worker` | OS-thread worker (max 8) | — (restricted scope) | [Worker](/docs/api/worker) |
| `http` | `http.serve(options, handler)` with `hostname` + routes support | `net` (+ `read` for TLS files) | [http](/docs/api/http) |
| `tcp` | Direct TCP socket client (`tcp.connect`, max 128 sockets) | `net` | [tcp](/docs/api/tcp) |
| `ff` | Runtime utilities + cron scheduler (`ff.cron`, max 32 jobs) | — | [Cron](/docs/api/cron) |
| `udp` | Datagram sockets (`udp.socket`, max 64) | `net` | [udp](/docs/api/udp) |
| `fs` | Sync + Promise filesystem calls | `read` / `write` | [fs](/docs/api/fs) |
| `process` | `argv`, `env`, `stdout`, `stdin`, `exit`, `pid`, `on`, `kill`, `memoryUsage`… | `env`; `read` for `chdir`; `run` for external `kill` | [process](/docs/api/process) |
| `child_process` | Subprocesses: `spawn` / `exec` / `execSync` (max 8, POSIX) | `run` | [child_process](/docs/api/child-process) |
| `crypto` | `randomUUID`, `getRandomValues`, `subtle` (`digest`, HMAC `importKey`/`sign`/`verify`/`exportKey`), `bcrypt` (`hash`, `verify` off-event-loop) | — | [crypto](/docs/api/crypto) |
| `btoa`, `atob` | Base64 encode / decode | — | [crypto](/docs/api/crypto) |
| `Database` | SQLite (`Database.open(path)`) | `read` + `write` | [SQLite](/docs/api/sqlite) |
| `sql`, `SQL` | Postgres tagged templates + pool | `net` (+ `read` for `sslrootcert`); global `sql` also `env` | [Postgres](/docs/api/postgres) |
| `ffi` | C-ABI shared libraries (`--allow-ffi`) | `ffi` | [FFI](/docs/api/ffi) |
| `permissions` | Enabled categories as live booleans + `revoke({ name, path?, host?, variable? })` | — | [Permissions](/docs/concepts/permissions) |
| `import.meta.url` | `file://` URL of imported modules (`undefined` in entry modules) | — | [Modules](/docs/guides/modules) |

Notes:

- `process.argv`, `platform`, `arch`, `pid`, `cwd`, `exit`, `on`, `once`,
  `off`, `removeListener`, `stdout`, `stdin`, `memoryUsage`, and `stats` are not
  gated. Only `process.env` (`env`), `process.chdir` (`read` on the target), and
  `process.kill` to a PID other than `process.pid` (`run` for `"kill"`) need a
  flag.
- `Worker` loading is a program-loading carve-out: `new Worker(path)` does not
  need `read`. Workers expose a restricted global set (console, timers,
  `queueMicrotask`, `postMessage`, `self`, `workerData`, `structuredClone`,
  `performance`, `btoa`/`atob`, and `crypto` except `crypto.bcrypt`) — none of
  the native I/O globals (`fs`, `fetch`, `http`, `Database`, `sql`, `process`,
  `child_process`, `ffi`, `tcp`, `udp`) exist inside a Worker.
- `http` needs `net` for its bound `hostname:port` (defaults to `0.0.0.0:<port>`).
  `read` is only checked when `tls.cert` / `tls.key` are file paths rather than inline PEM.
- `sql` / `SQL` checks `net` against the target host:port. If TLS is configured with `sslrootcert`, `read` on the CA bundle is also checked. The global `sql` pool checks `env` to discover `DATABASE_URL` / `PG*` settings.
- `Database.open(":memory:")` needs no path permission.
- `tcp`: Client-only socket API (`tcp.connect(host, port)`, max 128 sockets). Hosts must be IPv4/IPv6 literals (e.g. `127.0.0.1` or `::1`). Reads and writes are capped at 16 KB per call. Requires `--allow-net`.
- `ff.cron`: In-process cron scheduler running strictly in UTC (max 32 jobs; no cancel/unref). Shares the 128-slot timer table. Supports 5-field cron syntax (`minute hour dom month dow`, Vixie OR match for restricted DOM/DOW, ranges, and steps e.g. `0-30/5 * * * *`) and interval `@every <N>ms|s|m`. Rejects expressions with no match within 366 days at registration.

### Timer handles

`setTimeout` / `setInterval` return a `Timeout` **object** on the main thread
(inside a `Worker`, timers return numeric IDs without `.ref()`/`.unref()` methods;
`clearTimeout` / `clearInterval` accept either):

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
permissions.net;                          // true when --allow-net is active
```

Full tables: [Response statics and Database methods](#quick-reference).

## Quick reference

### `Response` statics

| Method | Signature | Description |
|---|---|---|
| `Response.json(value, init?)` | `(any, { status?, headers? }) → Response` | JSON response shortcut |
| `Response.redirect(url, status?)` | `(string, number?) → Response` | Redirect status (default 302) — Known issue: no `Location` header emitted |
| `Response.error()` | `() → Response` | Error response, status `0` |
| `Response.file(path)` | `(string) → Response` | Sync file response (needs `--allow-read`, 50 MB read cap, MIME by extension) |

### `Database` methods

| Method | Signature | Description |
|---|---|---|
| `Database.open(path)` | `(string) → Database` | Open or create a database; needs `read` + `write` on the file and `write` on its parent |
| `db.exec(sql, params?)` | `(string, Array?) → undefined` | One statement, bound params |
| `db.execNoArgs(sql)` | `(string) → undefined` | Multi-statement SQL, no params |
| `db.row(sql, params?)` | `(string, Array?) → object \| null` | First row |
| `db.rows(sql, params?)` | `(string, Array?) → object[]` | All rows |
| `db.changes()` | `() → number` | Rows affected by the last write |
| `db.lastInsertRowId()` | `() → number` | Rowid of the last insert |
| `db.transaction(fn)` | `(Function) → any` | Auto-commit / rollback |
| `db.busyTimeout(ms)` | `(number) → undefined` | Busy timeout (default 5000) |
| `db.close()` | `() → undefined` | Close the handle |

`Database.open(":memory:")` is exempt from the path gates.

### `sql` / `SQL` methods

| Method | Signature | Description |
|---|---|---|
| `` sql`…` `` | `` (template) → Promise<rows> `` | Parameterized query (also `` tx`…` `` in transactions) |
| `sql.unsafe(str, params?)` | `(string, Array?) → Promise<rows>` | String-built, still parameterized (also `tx.unsafe`) |
| `sql.connect()` | `() → Promise<rows>` | Probe the pool — resolves with the `SELECT 1` rows |
| `sql.begin()` | `() → Promise<Tx>` | Transaction on one connection |
| `sql.close()` | `() → undefined` | Close the pool (`sql` or `new SQL(...)` instance) |
| `tx.commit()` / `tx.rollback()` | `() → Promise<rows>` | End the transaction (resolves `[]`) |
| `new SQL(dsn | options)` | `(string | object) → SQL` | Pool bound to a DSN or options object (`{ host, port, user, password, database, max, sslmode, sslrootcert }`) |

`new SQL(dsn | options)` checks `net` against the target host and port (and `read` on `sslrootcert` if TLS is enabled). The global `sql`
also needs `env` if it should read `PG_TEST_DSN` / `DATABASE_URL` / `PG*` (including `PGSSLMODE`, `PGSSLROOTCERT`) at
startup; otherwise it falls back to `127.0.0.1:5432`.

## Not provided

These common Node/browser globals are **absent** — with the substitute to
use instead:

| Missing | Use instead |
|---|---|
| `Buffer` | `Uint8Array` / `ArrayBuffer` |
| `require()` / CommonJS | `import` / `export` |
| `process.nextTick` | `queueMicrotask(fn)` |
| `setImmediate` | `setTimeout(fn, 0)` |
| `addEventListener` on `WebSocket` | `ws.onopen = …` style handlers |
| `TextEncoder#encodeInto` | `encode()` |
| `process.stderr` / Node stream events on stdio | `console.*` (stderr), `process.stdout.write`, `process.stdin.read()` / `readSync()` |
| DOM, `window` | backend runtime |

Full list with rationale: [Compatibility](/docs/reference/compatibility).

## See also

- [Permissions](/docs/concepts/permissions) — flags, scopes, error contract
- [Event loop](/docs/concepts/event-loop) — how these globals interact
- [Limitations](/docs/reference/limitations) — every hard cap
- [CLI](/docs/reference/cli) — how to run your code
