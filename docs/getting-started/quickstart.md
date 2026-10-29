---
title: Quickstart
description: Run your first script and server in five minutes.
order: 3
---

# Quickstart

Get the binary, run a script, start a server, open a database. Native APIs are
deny-by-default, so the server and database commands carry the flags they need.

## Install (once)

```sh
curl -fsSL https://raw.githubusercontent.com/AbdElMajidOuhamane/ff/main/install.sh | sh
```

Prebuilt for macOS (Apple silicon / Intel) and Linux (x86_64 / ARM64),
SHA-256 verified, installs to `~/.local/bin/ff`. Docker and source builds:
[Installation](/docs/getting-started/installation).

## Permissions

`ff hello.js` needs no flags: it touches only core JS. Anything native needs a
grant on the launch command:

```sh
ff server.js --allow-net=0.0.0.0:3000
ff todos.js --allow-read=app.db --allow-write=.
ff tool.js --allow-run=git
ff addon.js --allow-ffi
```

- Flags are CLI-only. There is no `ff.json` field or environment variable that
  grants access.
- Scopes are comma-split and repeatable: `--allow-read=src,views`.
- A bare flag grants the whole category: `--allow-net` means any host and port.
- Missing access throws `PermissionDenied` (`code: "PERMISSION_DENIED"`) before
  I/O starts. FFI uses the same shape without a scope suffix:
  `ffi.dlopen requires --allow-ffi`.
- `--allow-run` and `--allow-ffi` are trust-equivalent to full access.
  Permissions catch mistakes; they are not an OS sandbox.

Full model: [Permissions](/docs/concepts/permissions).

## Run a file

Create `hello.js`:

```js
// hello.js
console.log("hello from fairyfly");
```

Run it:

```sh
ff hello.js
# hello from fairyfly
```

> **Note:** There is no bundled `examples/` directory — always create the file first (or scaffold with `ff init -y demo`).

## Run inline code

```sh
ff -e 'console.log("hello from fairyfly")'
# hello from fairyfly
```

## Minimal server

Create `server.js`:

```js
// server.js
http.serve({ port: 3000 }, (url, method, body) => {
  const path = url.split("?")[0];
  if (path === "/") return { status: 200, body: "hello from fairyfly" };
  return { status: 404, body: "not found" };
});
```

Run it with the listener scope:

```sh
ff server.js --allow-net=0.0.0.0:3000
```

Test it in another terminal:

```sh
curl http://127.0.0.1:3000/
# hello from fairyfly
curl http://127.0.0.1:3000/nope
# not found
```

The listener always binds `0.0.0.0`, so the scope must name `0.0.0.0:3000`;
`--allow-net=127.0.0.1:3000` does not match.

`http.serve` accepts two call shapes: `http.serve(3000, handler)` and
`http.serve({ port: 3000 }, handler)`. The one-argument
`http.serve(handler)` form is not supported — it throws
`TypeError: http.serve requires (options, handler)`.

The handler receives `(url, method, body)` strings and returns a `Response` (or a `{ status, body }` object, as above). Full contract: [HTTP Server guide](/docs/guides/http-server).

## SQLite

```js
// todos.js
const db = Database.open("app.db");
db.execNoArgs("CREATE TABLE IF NOT EXISTS todos (id INTEGER PRIMARY KEY, text TEXT, done INTEGER)");
db.exec("INSERT INTO todos (text, done) VALUES (?, ?)", ["Buy milk", 0]);
console.log(JSON.stringify(db.rows("SELECT * FROM todos"), null, 2));
db.close();
```

```sh
ff todos.js --allow-read=app.db --allow-write=.
# [
#   {
#     "id": 1,
#     "text": "Buy milk",
#     "done": 0
#   }
# ]
```

SQLite opens the database read/write and creates `app.db-wal` and `app.db-shm`
beside it, so the parent directory needs `--allow-write`. `:memory:` is exempt
from all path checks.

No packages to install. SQLite is built into the runtime — full reference: [SQLite API](/docs/api/sqlite).

## Timers

```js
setTimeout(() => console.log("once"), 100);
const iv = setInterval(() => console.log("tick"), 50);
setTimeout(() => clearInterval(iv), 250);
```

Max 128 live timers. Full guide: [Timers](/docs/guides/timers).

## Console

```js
console.log("plain", 1, true, null);
console.info("info", "line");
console.debug("debug", "line");
console.warn("warned", "here");
console.error("errored", 42);
```

Methods: `log`, `info`, `debug`, `warn`, `error`, `slops`, `redbal`, `detail`. All return `undefined`.

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

No `process.nextTick`. Use `queueMicrotask`.

## Next steps

- [Permissions](/docs/concepts/permissions) — deny-by-default rules, scopes, denial contract
- [Examples](/docs/reference/examples) — runnable snippets with their flags
- [HTTP Server guide](/docs/guides/http-server) — routing, JSON APIs, TLS
- [Testing](/docs/guides/testing) — the `check`/`done` pattern
- [CLI](/docs/reference/cli) — `init`, `start`, `imprint`, `test`, and the rest
