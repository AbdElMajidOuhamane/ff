---
title: HTTP Server
description: Start a server with http.serve — from hello-world to a JSON REST API.
order: 1
---

# HTTP Server

`http.serve` starts an HTTP server bound to `0.0.0.0`. You pass it an options object (or a port number) and a handler; the handler is called per request as `(url, method, body)` — three strings — and returns a `Response`. Add `tls` and the same port also serves HTTPS, WSS, and HTTP/2.

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

## Calling shapes and the port

`http.serve` takes **two** arguments. The first is the options value (an object or a number); the second is the handler. Passing only a handler throws, so there is no one-argument form:

```js
http.serve({ port: 4242 }, handler); // options object
http.serve(4242, handler);           // port shorthand
http.serve({}, handler);             // no options — default port 3000

http.serve(handler);
// TypeError: http.serve: http.serve requires (options, handler)
```

When the port is omitted (or isn't a number), the default is `3000`:

```js
// server.js
http.serve({}, (url, method, body) => new Response("default port"));
```

```sh
ff server.js
curl http://127.0.0.1:3000/
# default port
```

`http.serve` returns `undefined`: there is no handle, no `server.port`, and no `server.stop()`. The listener runs until you end the process.

> **Note:** The server always binds to `0.0.0.0`. There is no host option, no `--port` flag, and no `FF_PORT` environment variable — the port comes only from your JS.

## Inspecting the incoming request

The handler receives three strings: `url` (path + query string), `method`, and `body` (request text, empty string when none). `method` is passed **exactly as the client sent it** — `curl -X post` gives you `"post"`, so normalize case before comparing. Log the values to see what's coming in:

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
| `Promise` of either shape above | Connection parks until it settles (a rejection → `500`) |

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

A tiny notes API backed by SQLite, zero dependencies. Schema statements
belong in `db.execNoArgs` (multi-statement, no params); single statements
with bound params use `db.exec`:

```js
// server.js
const db = Database.open("notes.db");
db.execNoArgs(`CREATE TABLE IF NOT EXISTS notes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  text TEXT NOT NULL
)`);

http.serve({ port: 3000 }, (url, method, body) => {
  const path = new URL(url, "http://localhost").pathname;

  // List notes
  if (path === "/notes" && method === "GET") {
    return Response.json(db.rows("SELECT id, text FROM notes ORDER BY id"));
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

## Handling request bodies and limits

The request line, headers, and body all share one 4096-byte read buffer. A request whose headers parse but whose declared body pushes the total past 4096 bytes gets `413 Payload Too Large`; a header block that never finishes within 4096 bytes closes the connection. Keep request bodies small, or stream them from the client in pieces your handler concatenates.

The response body has a 10 MB hard cap (bodies up to 64 KB sit in a per-slot buffer, larger ones spill to the heap; over 10 MB → `500`). Response headers are capped at 2048 bytes, and a handler that stays pending for 30s is failed with `504 Gateway Timeout`.

## Smoke-testing with FF_ECHO

Set `FF_ECHO` to any value and every request served over HTTP/1.1 — plain or TLS, but not HTTP/2 — returns a canned `200 {"message":"ok"}` without running your handler. Use it to verify the port mapping and deployment before debugging app logic:

```sh
FF_ECHO=1 ff server.js
curl http://127.0.0.1:3000/anything
# {"message":"ok"}
```

`FF_ECHO` is read once when the listener starts. Any value (including an empty string) enables it; only leaving it unset disables it.

## Reference: limits

| Area | Limit | When hit |
|------|-------|----------|
| Concurrent connections | 512 | Once all slots are busy, new connections are accepted then immediately closed — not queued |
| Request size | 4096 bytes total (request line + headers + body share one read buffer) | Declared body past the cap → `413 Payload Too Large`; unterminated headers → connection closed |
| Response body | 10 MB hard cap | 64 KB stage buffer spills to the heap; beyond 10 MB → `500` |
| Response headers | 2048 bytes | User headers past the cap are dropped |
| Hung handler | 30s | Connection fails with `504` |
| Bind address | Always `0.0.0.0` | No host option exists |
| Plain protocol | HTTP/1.1 | HTTP/2 needs TLS (see the [TLS guide](/docs/guides/tls)) |

## Troubleshooting

**Empty 200 when I return a string** — wrap it: `return new Response("hello")`. Bare strings are not bodies.

**`http.serve requires (options, handler)`** — you called it with one argument. Pass an options object (or a number) first: `http.serve({ port: 3000 }, handler)`.

**Connection refused** — confirm the port in `http.serve({ port })` matches your `curl` command or Docker `-p` mapping. No environment variable overrides it.

**504 on slow endpoints** — the 30s handler watchdog fired. Move heavy work to a `Worker` or reply early and finish in the background.

**`id` comes back wrong in JSON** — you wrote `db.lastInsertRowId` without calling it. Always `db.lastInsertRowId()`.

**Stopping the server** — there is no `server.stop()` API. Stop the process with `Ctrl-C`, or call `process.exit(0)` from your code for programmatic shutdown.
