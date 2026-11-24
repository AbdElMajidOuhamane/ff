---
title: Errors and exit codes
description: What throws, what gets swallowed, how uncaught errors surface, and the exit codes you'll see.
order: 3
---

# Errors and exit codes

There are no custom error classes in Fairyfly. You get QuickJS's built-ins
— `Error`, `TypeError`, `SyntaxError`, `RangeError`, `ReferenceError`,
`InternalError` (used by `--cpu-budget` interrupts and internal failures),
`DOMException` — plus a handful of APIs that reject with plain strings.

Permission failures are ordinary `Error` objects with extra properties:
`name` is `PermissionDenied` and `code` is `PERMISSION_DENIED`. There is no
`PermissionDenied` constructor, so check `e.code` rather than using
`instanceof`.

## Uncaught errors

An exception that escapes your script prints the message and stack to
**stderr**, then the process exits **1**:

```js
// ff boom.js
throw new Error("boom");
```

```
$ ff boom.js
Error: Error: boom
    at <eval> (boom.js:1:11)

$ echo $?
1
```

Note the doubled `Error: Error:` prefix, the `at <eval>` frame carrying
`file:line:column`, and the blank line before the shell prompt.

`try` / `catch` works as usual — for the APIs listed below.

## What throws (and what doesn't)

| API | Behaviour |
|---|---|
| `setTimeout(nonFn)`, `queueMicrotask(nonFn)` | **throws** `TypeError` — caught by `try`/`catch` (`setTimeout(fn)` with an omitted delay defaults `ms` to `0`) |
| `Database.open()` without a path | **throws** `Database.open requires a file path` |
| `new Request()` without a URL | **throws** `Request requires a URL string as first argument` |
| `new Worker()` without a path | **throws** `Worker requires a module path` |
| `sql.unsafe` / `sql.begin` / `sql.connect` with no pool | **throws** `no database pool` (`sql` template tag throws `@errorName(err)`, e.g. `PoolFailed` or `BadDsn`) |
| Postgres `tx` after `commit()` | **throws** `transaction is closed` |
| Postgres unsupported `sslmode` | **throws** `sslmode must be 'disable' or 'verify-full'` (options object), `invalid database URL` (DSN), or `UnsupportedSslMode` (global tag) |
| `fs.readFile` / `mkdir` / `rm` / `readdir` | **does not throw on I/O errors** — returns `undefined`; **throws `PermissionDenied`** when the path is outside the matching `--allow-read` / `--allow-write` scope |
| `fs.writeFile` / `fs.writeFileAsync` | sync `fs.writeFile` **returns `undefined` without throwing in JS** on I/O errors or data `> 10 MiB` (nothing written); `fs.writeFileAsync` `> 10 MiB` **throws `TypeError` synchronously** before creating a Promise; permission denial **throws `PermissionDenied`** |
| `fs.readFileAsync()` etc. | **rejects** with the error name, e.g. `FileNotFound` — permission denial/bad args/`writeFileAsync` `> 10 MiB` throw synchronously; settled jobs exit the event loop cleanly |
| `process.chdir()` | **throws `PermissionDenied`** when the target is outside `--allow-read`; a missing or unreachable path is still a silent no-op |
| `process.env` | **never throws** — names outside `--allow-env` are absent (`undefined`) |
| `fetch` / `WebSocket` / `http.serve` (+ `tls` paths) / `tcp.connect` / `udp.*` / `Response.file` / `Database.open` / `child_process` (`execSync` reports `child_process.execSync`) / `process.kill` / `SQL` | **throw `PermissionDenied`** before I/O without the matching flag; a redirect-hop denial rejects `fetch` with a string instead |
| `ffi.dlopen` / `ffi.callback` / all other `ffi` entry points | **throw `PermissionDenied`** without `--allow-ffi` |

> **Sync `fs` swallows I/O errors today.** A missing file, a bad directory, an
> unreadable path — all return `undefined` with no exception. Always check
> `fs.exists()` first, or use the Promise variants, which report the real
> error:

```js
// Reliable: async variants reject with the error name
try {
  const text = await fs.readFileAsync("config.json", "utf8");
} catch (e) {
  console.error("cannot read config:", e.message); // "FileNotFound"
}

// Sync: guard with exists()
if (fs.exists("config.json")) {
  const text = fs.readFile("config.json");
}
```

Permission denial is separate from I/O failure — it throws even for sync calls:

```js
try {
  fs.readFile("/etc/passwd");
} catch (e) {
  console.log(e.name);    // "PermissionDenied"
  console.log(e.code);    // "PERMISSION_DENIED"
  console.log(e.message); // "fs.readFile requires --allow-read for '/etc/passwd'"
}
```

## Unhandled promise rejections

Unhandled rejected Promises (including top-level `await` rejections in `.js`,
`.ffbc`, and `--standalone` binaries) are tracked via QuickJS's
`JS_SetHostPromiseRejectionTracker`, printed to **stderr**, and cause the
process to exit **1** once the event loop drains:

```js
Promise.reject(new Error("rej"));   // Uncaught (in promise): Error: rej -> exit 1
async function f() { throw new Error("x"); }
f();                                // Uncaught (in promise): Error: x -> exit 1
```

Attaching a `.catch()` handler on the same turn (or `await`ing inside a
`try`/`catch`) marks the rejection as handled and exits **0**. In an HTTP
handler, a rejected handler Promise becomes a **500** response.

## `fetch` rejects with strings

Failed fetches reject with a **string**, not an `Error`, so `e.message` is
`undefined`:

```js
try {
  await fetch("notaurl");
} catch (e) {
  console.log(typeof e);        // "string"
  console.log(e);               // "Invalid URL" | "Network error" | "Too many redirects"
}
```

A diagnostic line also goes to stderr:

```
[fetch] request failed: ConnectionRefused url=http://127.0.0.1:1/
```

Permission denial is different:

- The **initial** `fetch` check throws an `Error` named `PermissionDenied` with
  `code: "PERMISSION_DENIED"` before the request is submitted. In an `async`
  function that surfaces as a rejected promise.
- A denial on a **redirect hop** rejects the fetch promise with a plain string:
  `PermissionDenied: fetch requires --allow-net`. That string has no
  `.message` and no `.code`.

## Server-side failures

| Failure | Response |
|---|---|
| Handler throws or its Promise rejects | `500 Internal Server Error` |
| Handler never settles | `504 Gateway Timeout` after 30 s |
| Response body over 10 MB | `500` |
| HTTP/2 `ReadableStream` response body | `501 Not Implemented` |
| Route-object URL over 4096 bytes | `414 URI Too Long` |
| HTTP/1.1 malformed framing | `400 Bad Request` |
| Request headers over 4 KB (HTTP/1.1) or 64 KB (HTTP/2) | `431 Request Header Fields Too Large` |
| Request body over 1 MB (HTTP/1.1) | `413 Payload Too Large` (HTTP/2 caps at 10 MB/stream, 16 MB/session) |
| Request body spill exceeds 64 MB global budget (HTTP/1.1) | `503 Service Unavailable` |

A permission denial is not a handler failure: `http.serve` checks its bind scope
when the server starts, and `fs` / `fetch` denials inside a handler are thrown
as normal JavaScript exceptions (uncaught → `500`).

## Exit codes

| Call | Exit code |
|---|---|
| normal end of script | `0` |
| uncaught error | `1` |
| unhandled promise rejection | `1` |
| uncaught permission denial | `1` |
| `--wall-timeout` exceeded | `124` |
| `SIGINT` / `SIGTERM` (armed, no custom handler or server) | `130` / `143` |
| `process.exit(300)` | `255` (clamped) |
| `process.exit(-5)` | `0` (clamped) |
| event-loop failure | `1` |

```js
process.exit(300);
// $ ff exit.js; echo $?
// 255
```

## Message catalogue

Strings you'll see in practice — useful for assertions in tests:

| Message | Thrown by |
|---|---|
| `setTimeout requires a function as first argument` | timers |
| `too many timers (max 128)` | timers (`setTimeout`, `setInterval`, `AbortSignal.timeout`); `ff.cron` throws `failed to schedule cron timer (timer table full)` when the shared 128-slot table is full |
| `setTimeout accepts at most 8 callback arguments` | timers |
| `queueMicrotask requires a function argument` | microtasks |
| `WebSocket: WebSocket constructor requires a URL` | `new WebSocket` |
| `WebSocket: send buffer full` | client `WebSocket` (`ws.send` / `ws.sendBinary`) |
| `subtle.importKey: algorithm must be 'HMAC' or { name: 'HMAC', hash: 'SHA-...' }` | `crypto.subtle.importKey` |
| `too many workers (max 8)` | `new Worker` |
| `Worker requires a module path` | `new Worker` |
| `value could not be cloned` | `postMessage` / `structuredClone` with a function/WeakMap/native object/… |
| `Database.open requires a file path` | SQLite |
| `exec requires a SQL string` / `exec: invalid database` | SQLite |
| `transaction requires a function argument` | SQLite |
| `no database pool` | `sql.unsafe` / `sql.begin` / `sql.connect` (tag `` sql`...` `` throws `@errorName(err)`) |
| `sql must be used as a template tag` | Postgres |
| `template arity mismatch` | Postgres |
| `transaction is closed` | Postgres |
| `sslmode must be 'disable' or 'verify-full'` | Postgres |
| `SQL: TLS setup failed (...)` | Postgres TLS |
| `fs.writeFileAsync: data exceeds the 10 MiB limit` | `fs.writeFileAsync` (throws `TypeError` synchronously; sync `fs.writeFile` currently returns `undefined` without throwing in JS) |
| `Request requires a URL string as first argument` | `new Request` |
| `Response.redirect requires a URL` | `Response.redirect` |
| `Invalid URL` | `fetch`, `URL` |
| `fetch requires a URL string or Request as first argument` | `fetch` |
| `FileNotFound` | `fs.*Async` rejection |
| `ffi.dlopen: FFI not compiled in (build with -Dffi=true)` | `ffi` |
| `http.serve: failed to start server (is the port in use?)` | `http.serve` |
| `fs.readFile requires --allow-read for '<path>'` | `fs` — `Error` named `PermissionDenied`, code `PERMISSION_DENIED` |
| `process.chdir requires --allow-read for '<path>'` | `process.chdir` — `PermissionDenied` |
| `fetch requires --allow-net for '<host>:<port>'` | `fetch` — `PermissionDenied` |
| `http.serve requires --allow-net for '<hostname>:<port>'` | `http.serve` (default `0.0.0.0:<port>`) — `PermissionDenied` |
| `Database.open requires --allow-read for '<path>'` | SQLite — `PermissionDenied` |
| `child_process requires --allow-run for '<program>'` | `child_process` — `PermissionDenied` |
| `process.kill requires --allow-run for 'kill'` | `process.kill` (external PID) — `PermissionDenied` |
| `ffi.dlopen requires --allow-ffi` | `ffi` — `PermissionDenied`, no scope suffix |
| `PermissionDenied: fetch requires --allow-net` | `fetch` redirect — plain string |

## Gotchas

- `e.message` is `undefined` for ordinary `fetch` rejections and redirect
  permission denials — check `typeof e`. Initial permission errors are real
  `Error` objects.
- Sync `fs` **I/O** failures are silent; don't write `try/catch` around them
  expecting an exception. Permission denials do throw.
- `process.env` never throws; a disallowed variable is just `undefined`.
- There is no `PermissionDenied` constructor — check `e.code` or `e.name`.
- FFI denials are `PermissionDenied` too; the message is bare
  (`ffi.read requires --allow-ffi`) because there is no scope.
- There is no `process.on("uncaughtException")` and no `unhandledRejection`
  hook — there's nothing to subscribe to.
- Errors thrown inside a `Worker` surface on the parent via `onerror`.

## See also

- [Permissions](/docs/concepts/permissions)
- [Event loop](/docs/concepts/event-loop)
- [Limitations](/docs/reference/limitations)
- [Compatibility](/docs/reference/compatibility)
- [Testing](/docs/guides/testing)
