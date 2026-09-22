---
title: HTTP Server
description: Start a server with http.serve — from hello-world to a JSON REST API.
order: 1
---

# HTTP Server

`http.serve` starts an HTTP server bound to `0.0.0.0`. Your handler is called per request as `(url, method, body)` — three strings — and returns a `Response`.

## Hello-world server

Create `server.js`:

```js
// server.js
http.serve({ port: 3000 }, (url, method, body) => {
  return new Response("Hello, World!");
});
```

Run it with `ff`:

```sh
ff server.js
```

Verify in another terminal:

```sh
curl http://127.0.0.1:3000/
# Hello, World!
```

The handler can also be `async` (or return a `Promise`) — the connection parks until it settles:

```js
// server.js
http.serve({ port: 3000 }, async (url, method, body) => {
  return new Response("Hello, World!");
});
```

## Listening on a specific port

Pass the port in the options object, or use the shorthand form. When omitted, the port defaults to `3000`:

```js
// Options object
http.serve({ port: 4242 }, handler);

// Shorthand — port number as the first argument
http.serve(4242, handler);

// Default port 3000
http.serve(handler);
```

```sh
ff server.js
curl http://127.0.0.1:4242/
```

> **Note:** The server always binds to `0.0.0.0`. There is no host option, no `--port` flag, and no `FF_PORT` environment variable — the port comes only from your JS.

## Inspecting the incoming request

The handler receives three strings: `url` (path + query string), `method` (e.g. `"GET"`), and `body` (request text, empty string when none). Log them to see what's coming in:

```js
// server.js
http.serve({ port: 3000 }, (url, method, body) => {
  console.log("Method:", method);
  console.log("URL:", url);

  const parsed = new URL(url, "http://localhost");
  console.log("Path:", parsed.pathname);
  console.log("Query:", parsed.searchParams.get("name"));

  console.log("Body:", body);
  return new Response("logged!");
});
```

```sh
ff server.js
curl -X POST "http://127.0.0.1:3000/greet?name=ada" -d "hi"
# server prints:
# Method: POST
# URL: /greet?name=ada
# Path: /greet
# Query: ada
# Body: hi
```

> **Caution:** `body` is always a string. For JSON, parse it yourself with `JSON.parse(body || "{}")` — and guard the parse, since a client can send anything.

## Responding with real data

Return a `Response` with the status, headers, and body you want:

```js
// server.js
http.serve({ port: 3000 }, (url, method, body) => {
  const payload = JSON.stringify({ message: "NOT FOUND" });
  return new Response(payload, {
    status: 404,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
});
```

```sh
ff server.js
curl -i http://127.0.0.1:3000/missing
# HTTP/1.1 404 Not Found
# content-type: application/json; charset=utf-8
#
# {"message":"NOT FOUND"}
```

Three return shapes are accepted:

| Return value | What happens |
|--------------|--------------|
| `Response` | Status, headers, and body sent as-is |
| `{ status, body }` with string or ArrayBuffer body | Sent with that status code |
| `Promise` of either shape above | Connection waits until it settles |

> **Caution:** Anything else — including a bare string — produces an empty `200` response. `return "hello"` does **not** send `"hello"`. Always wrap it: `return new Response("hello")`.

## Routing requests

Match `url` (and `method`) to serve more than one endpoint:

```js
// server.js
http.serve({ port: 3000 }, (url, method, body) => {
  const path = new URL(url, "http://localhost").pathname;

  if (path === "/" && method === "GET") {
    return new Response("Home");
  }
  if (path === "/users/42" && method === "GET") {
    return Response.json({ id: 42, name: "Ada" });
  }
  return new Response("Not found", { status: 404 });
});
```

```sh
ff server.js
curl http://127.0.0.1:3000/          # Home
curl http://127.0.0.1:3000/users/42  # {"id":42,"name":"Ada"}
curl -i http://127.0.0.1:3000/nope   # 404 Not found
```

For larger route trees, put the matching in a small router function or reach for an `ff imprint` routing package.

## Practical example: JSON REST API

A tiny notes API backed by SQLite, zero dependencies:

```js
// server.js
const db = new Database("notes.db");
db.exec(`CREATE TABLE IF NOT EXISTS notes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  text TEXT NOT NULL
)`);
```

Wait — `db.exec` with a single argument and a multi-line schema string works (no params to bind), but schema statements belong in `execNoArgs`. Corrected:

```js
// server.js
const db = new Database("notes.db");
db.execNoArgs(`CREATE TABLE IF NOT EXISTS notes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  text TEXT NOT NULL
)`);

http.serve({ port: 3000 }, (url, method, body) => {
  const path = new URL(url, "http://localhost").pathname;

  // List notes
  if (path === "/notes" && method === "GET") {
    return Response.json(db.rows("SELECT id, text FROM notes"));
  }

  // Create a note
  if (path === "/notes" && method === "POST") {
    const data = JSON.parse(body || "{}");
    if (!data.text) {
      return Response.json({ error: "text is required" }, { status: 400 });
    }
    db.exec("INSERT INTO notes (text) VALUES (?)", [data.text]);
    return Response.json({ id: db.lastInsertRowId(), text: data.text }, { status: 201 });
  }

  return new Response("Not found", { status: 404 });
});
```

```sh
ff server.js
curl http://127.0.0.1:3000/notes
# []

curl -X POST http://127.0.0.1:3000/notes \
  -H "content-type: application/json" -d '{"text":"buy milk"}'
# {"id":1,"text":"buy milk"}

curl http://127.0.0.1:3000/notes
# [{"id":1,"text":"buy milk"}]
```

> **Note:** `db.lastInsertRowId()` is a method — the `()` is required. Without it you'd serialize the function object instead of the id.

## Smoke-testing with FF_ECHO

Set `FF_ECHO` to any value and every request returns canned `200 {"message":"ok"}` without running your handler. Use it to verify the port mapping and deployment before debugging app logic:

```sh
FF_ECHO=1 ff server.js
curl http://127.0.0.1:3000/anything
# {"message":"ok"}
```

## Reference: limits

| Area | Limit | When hit |
|------|-------|----------|
| Concurrent connections | 512 | The 513th waits for a free slot |
| Response body | 64KB per response | Larger bodies are rejected |
| Hung handler | 30s | Connection fails with `504` |
| Bind address | Always `0.0.0.0` | No host option exists |
| Plain protocol | HTTP/1.1 | HTTP/2 needs TLS (see the TLS guide) |

## Troubleshooting

**Empty 200 when I return a string** — wrap it: `return new Response("hello")`. Bare strings are not bodies.

**Connection refused** — confirm the port in `http.serve({ port })` matches your `curl` command or Docker `-p` mapping. No environment variable overrides it.

**504 on slow endpoints** — the 30s handler watchdog fired. Move heavy work to a `Worker` or reply early and finish in the background.

**`id` comes back wrong in JSON** — you wrote `db.lastInsertRowId` without calling it. Always `db.lastInsertRowId()`.

**Stopping the server** — there is no `server.stop()` API. Stop the process with `Ctrl-C`, or call `process.exit(0)` from your code for programmatic shutdown.
