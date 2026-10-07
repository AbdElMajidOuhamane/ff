---
title: Errors and exit codes
description: What throws, what gets swallowed, how uncaught errors surface, and the exit codes you'll see.
order: 3
---

# Errors and exit codes

There are no custom error classes in Fairyfly. You get QuickJS's built-ins
— `Error`, `TypeError`, `SyntaxError`, `RangeError` — plus a handful of
APIs that reject with plain strings.

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
| `setTimeout(fn)`, `queueMicrotask(nonFn)` | **throws** `TypeError` — caught by `try`/`catch` |
| `Database.open()` without a path | **throws** `Database.open requires a file path` |
| `new Request()` without a URL | **throws** `Request requires a URL string as first argument` |
| `new Worker()` without a path | **throws** `Worker requires a module path` |
| `sql` template with no pool | **throws** `no database pool` |
| Postgres `tx` after `commit()` | **throws** `transaction is closed` |
| `fs.readFile` / `writeFile` / `mkdir` / `rm` / `readdir` | **does not throw** — returns `undefined` on failure |
| `fs.readFileAsync()` etc. | **rejects** with the error name, e.g. `FileNotFound` — but a *successful* call hangs the process afterwards (Known issue; see [fs](/docs/api/fs)) |

> **Sync `fs` swallows errors today.** A missing file, a bad directory, an
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

## Unhandled promise rejections are silent

In script context a rejected Promise with no handler prints **nothing** and
the process exits **0**:

```js
Promise.reject(new Error("rej"));   // no output, exit 0
async function f() { throw new Error("x"); }
f();                               // no output, exit 0
```

Always attach a `.catch`, or `await` inside a `try`. In an HTTP handler the
runtime does catch it — a rejected handler Promise becomes a **500**
response.

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

## Server-side failures

| Failure | Response |
|---|---|
| Handler throws or its Promise rejects | `500 Internal Server Error` |
| Handler never settles | `504 Gateway Timeout` after 30 s |
| Response body over 10 MB | `500` |
| Request body over the 4 KB read buffer | `413 Payload Too Large` |

## Exit codes

| Call | Exit code |
|---|---|
| normal end of script | `0` |
| uncaught error | `1` |
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
| `too many timers (max 128)` | timers |
| `setTimeout accepts at most 8 callback arguments` | timers |
| `queueMicrotask requires a function argument` | microtasks |
| `too many workers (max 8)` | `new Worker` |
| `Worker requires a module path` | `new Worker` |
| `value could not be cloned` | `postMessage` with a function/WeakMap/… |
| `Database.open requires a file path` | SQLite |
| `exec requires a SQL string` / `exec: invalid database` | SQLite |
| `transaction requires a function argument` | SQLite |
| `no database pool` | Postgres |
| `sql must be used as a template tag` | Postgres |
| `template arity mismatch` | Postgres |
| `transaction is closed` | Postgres |
| `Request requires a URL string as first argument` | `new Request` |
| `Response.redirect requires a URL` | `Response.redirect` |
| `Invalid URL` | `fetch`, `URL` |
| `fetch requires a URL string or Request as first argument` | `fetch` |
| `FileNotFound` | `fs.*Async` rejection |
| `ffi.dlopen: FFI not compiled in (build with -Dffi=true)` | `ffi` |
| `failed to start server (is the port in use?)` | `http.serve` |

## Gotchas

- `e.message` is `undefined` for `fetch` rejections — check `typeof e`.
- A successful `fs.*Async` call hangs the process afterwards (it prints, then never exits) — Known issue, see [fs](/docs/api/fs).
- Sync `fs` failures are silent; don't write `try/catch` around them
  expecting an exception.
- There is no `process.on("uncaughtException")` and no `unhandledRejection`
  hook — there's nothing to subscribe to.
- Errors thrown inside a `Worker` surface on the parent via `onerror`.

## See also

- [Event loop](/docs/concepts/event-loop)
- [Limitations](/docs/reference/limitations)
- [Compatibility](/docs/reference/compatibility)
- [Testing](/docs/guides/testing)
