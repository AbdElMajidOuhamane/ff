---
title: Quickstart
description: Run your first script and server in five minutes.
order: 3
---

# Quickstart

## Install (once)

```sh
curl -fsSL https://raw.githubusercontent.com/AbdElMajidOuhamane/ff/main/install.sh | sh
```

Prebuilt for macOS (Apple silicon / Intel) and Linux (x86_64 / ARM64),
SHA-256 verified, installs to `~/.local/bin/ff`. Docker and source builds:
[Installation](/docs/getting-started/installation).

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

Run it:

```sh
ff server.js
```

Test it in another terminal:

```sh
curl http://127.0.0.1:3000/
# hello from fairyfly
curl http://127.0.0.1:3000/nope
# not found
```

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
ff todos.js
# [ { id: 1, text: "Buy milk", done: 0 } ]
```

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

- [HTTP Server guide](/docs/guides/http-server) — routing, JSON APIs, TLS
- [Testing](/docs/guides/testing) — the `check`/`done` pattern
- [CLI](/docs/reference/cli) — `init`, `start`, `imprint`, `test`, and the rest
