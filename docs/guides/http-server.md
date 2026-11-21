---
title: HTTP Server
description: Start a server with http.serve — from hello-world to a JSON REST API.
order: 1
---

# HTTP Server

`http.serve` starts an HTTP server (bound to `0.0.0.0` by default, or `options.hostname`). You can pass either a request handler function `(url, method, body, headers) => Response` or a declarative routes table `{ "GET /path/:id": handler }`.

## Permissions

Servers are deny-by-default. Every `http.serve` needs `--allow-net` on the
bind address (`<hostname>:<port>`, defaulting to `0.0.0.0:<port>`):

```sh
ff server.js --allow-net=0.0.0.0:3000
```

- By default the server binds `0.0.0.0`, so `--allow-net=0.0.0.0:<port>` is
  checked even when clients connect over loopback. If you pass
  `{ hostname: "127.0.0.1" }`, grant `--allow-net=127.0.0.1:<port>` instead.
  (`hostname` accepts IPv4/IPv6 literals only — `"localhost"` throws `TypeError`.)
- A scope without a port (`--allow-net=0.0.0.0`) covers every port.
- The same grant covers HTTP, WebSocket upgrades, and TLS on that port.
- `tls.cert` / `tls.key` file paths need `--allow-read`; inline PEM does not.
  `FF_CERT` / `FF_KEY` used by `ff start` are CLI reads and need no runtime
  grant.
- `FF_ECHO` is runtime config and needs no `--allow-env`, but echo mode does
  **not** bypass the listener's `--allow-net` check.
- Denial is synchronous:

```js
try {
  http.serve({ port: 3000 }, handler);
} catch (e) {
  console.error(e.name, e.code); // PermissionDenied PERMISSION_DENIED
  console.error(e.message);      // http.serve requires --allow-net for '0.0.0.0:3000'
}
```

Full model: [Permissions](/docs/concepts/permissions).

## Hello-world server

Create `server.js`:

```js
// server.js
http.serve({ port: 3000 }, (url, method, body, headers) => {
  return new Response("Hello, World!");
});
```

Run it with `ff`:

```sh
ff server.js --allow-net=0.0.0.0:3000
```

Verify in another terminal:

```sh
curl http://127.0.0.1:3000/
# Hello, World!
```

The handler can also be `async` (or return a `Promise`) — the connection parks until it settles:

```js
// server.js
http.serve({ port: 3000 }, async (url, method, body, headers) => {
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

// Options object with the default port 3000
http.serve({}, handler);
```

### Port reuse (`reusePort`)

To allow multiple server processes to bind to the same port using kernel load balancing (`SO_REUSEPORT`), set `reusePort: true`:

```js
http.serve({ port: 3000, reusePort: true }, handler);
```

By default `reusePort` is `false` (safe standard `SO_REUSEADDR` is always enabled). Note that on Linux all processes sharing a port must set `reusePort: true`.

```sh
ff server.js --allow-net=0.0.0.0:4242
curl http://127.0.0.1:4242/
```

> **Note:** By default the server binds `0.0.0.0`; pass `{ hostname: "127.0.0.1" }` (any IPv4 or IPv6 literal) to bind a specific address. There is no `--port` flag and no `FF_PORT` environment variable — the port comes only from your JS, and the `--allow-net` scope must match `<hostname>:<port>`.

> **Note:** `http.serve(handler)` (one argument) is **not** supported by the
> current runtime; it throws `TypeError: http.serve: http.serve requires (options, handler)`.
> Use `http.serve(3000, handler)` or `http.serve({}, handler)` instead.

## Inspecting the incoming request

The handler receives `(url, method, body, headers)` (or `(url, method, body, headers, params)` when using a routes table):
- `url`: request path + query string (string)
- `method`: HTTP method string exactly as sent by the client (`curl -X post` yields `"post"` — normalize with `.toUpperCase()` if needed)
- `body`: request text (string, empty when none)
- `headers`: web-standard `Headers` instance (populated for both HTTP/1.1 and HTTP/2). On HTTP/1.1 it is parsed only when the handler declares four or more parameters: a handler whose `fn.length < 4` receives `undefined` and the runtime only validates the headers (`arguments` or a rest parameter forces full parsing). On HTTP/2 regular headers are always parsed and passed when present

### Working with request headers

The `headers` parameter provides standard `Headers` methods:
- `headers.get(name)`: returns the header value (case-insensitive), or `null` if absent. Multi-value headers are comma-joined (`"a, b"`), except `Cookie` which joins with `"; "` per RFC 9113 §8.2.3, and `Set-Cookie` which returns the first value (use `getAll` to retrieve all).
- `headers.has(name)`: returns `true` if present, `false` otherwise.
- `headers.getAll(name)`: returns an array of all values for the header name.
- The HTTP/1.1 request **head** (request line plus header block) must fit the 4 KB read buffer; HTTP/2 caps header name+value bytes at 64 KiB (pseudo-headers excluded). Exceeding either limit returns `431 Request Header Fields Too Large`.

```js
// server.js
http.serve({ port: 3000 }, (url, method, body, headers) => {
  console.log("Method:", method);
  console.log("URL:", url);

  const parsed = new URL(url, "http://localhost");
  console.log("Path:", parsed.pathname);
  console.log("Query:", parsed.searchParams.get("name"));
  console.log("User-Agent:", headers.get("user-agent"));

  console.log("Body:", body);
  return new Response("logged!");
});
```

```sh
ff server.js --allow-net=0.0.0.0:3000
curl -X POST "http://127.0.0.1:3000/greet?name=ada" -d "hi"
# server prints:
# Method: POST
# URL: /greet?name=ada
# Path: /greet
# Query: ada
# User-Agent: curl/...
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
ff server.js --allow-net=0.0.0.0:3000
curl -i http://127.0.0.1:3000/missing
# HTTP/1.1 404 Not Found
# content-type: application/json; charset=utf-8
#
# {"message":"NOT FOUND"}
```

Three return shapes are accepted:

| Return value | What happens |
|--------------|--------------|
| `Response` | Status, headers, and body sent as-is (including `ReadableStream` bodies on HTTP/1.1) |
| `{ status, body }` with `string`, `ArrayBuffer`, or `ReadableStream` body | Sent with that status code (any `headers` key on plain objects is ignored — use `new Response`) |
| `Promise` of either shape above | Connection waits until it settles |

> **Caution:** Anything else — including a bare string or bare `ReadableStream` — produces an empty `200` response (or `501` for bare `ReadableStream` over HTTP/2). `return "hello"` does **not** send `"hello"`. Always wrap it: `return new Response("hello")`.

## Routing requests

Use a declarative routes table as the second argument to `http.serve`, or match paths manually inside a single handler function:

```js
// Declarative routes table
http.serve(
  { port: 3000 },
  {
    "GET /": () => new Response("Home"),
    "GET /users/:id": (url, method, body, headers, params) =>
      Response.json({ id: params.id, name: "Ada" }),
    "/health": () => Response.json({ ok: true }), // any method
    "*": () => new Response("Not found", { status: 404 }),
  },
);
```

Route keys (`< 512` B) support `"METHOD /path"`, `"/path"` (any method), and `"*"` (wildcard fallback), with up to 16 `:param` segments passed as the 5th arg `params` to `(url, method, body, headers, params)`. Query strings are stripped before matching. Oversized URLs never reach routing — the request head is bounded first (`431` on HTTP/1.1, `400` on HTTP/2). Method mismatches get `405`, and unmatched routes get `404` (both protocols).

Or match `url` (and `method`) manually:

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
ff server.js --allow-net=0.0.0.0:3000
curl http://127.0.0.1:3000/          # Home
curl http://127.0.0.1:3000/users/42  # {"id":42,"name":"Ada"}
curl -i http://127.0.0.1:3000/nope   # 404 Not found
```

## Streaming responses (HTTP/1.1)

Return `new Response(stream)` (or `{ status, body: stream }`) with a [`ReadableStream`](/docs/api/streams) to stream chunks over HTTP/1.1 `Transfer-Encoding: chunked`:

```js
http.serve({ port: 3000 }, () => {
  const stream = new ReadableStream({
    start(controller) {
      controller.enqueue("chunk 1\n");
      setTimeout(() => {
        controller.enqueue("chunk 2\n");
        controller.close();
      }, 100);
    },
  });
  return new Response(stream);
});
```

Chunks larger than `16352` bytes (the 16 KB write buffer minus chunk framing) are emitted one slice per write, copied into the write buffer. The JS buffer is retained until its last slice drains, so mutating a `Uint8Array` before then affects the not-yet-written slices. Over HTTP/2, `ReadableStream` responses return `501` status only.

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
ff server.js \
  --allow-net=0.0.0.0:3000 \
  --allow-read=notes.db \
  --allow-write=.
curl http://127.0.0.1:3000/notes
# []

curl -X POST http://127.0.0.1:3000/notes \
  -H "content-type: application/json" -d '{"text":"buy milk"}'
# {"id":1,"text":"buy milk"}

curl http://127.0.0.1:3000/notes
# [{"id":1,"text":"buy milk"}]
```

SQLite opens the database read/write and writes WAL siblings next to it; the
file needs both grants and the parent directory needs `write`.

> **Note:** `db.lastInsertRowId()` is a method — the `()` is required. Without it you'd serialize the function object instead of the id.

## Smoke-testing with FF_ECHO

Set `FF_ECHO` to any value and every HTTP/1.1 request returns canned `200 {"message":"ok"}` without running your handler (HTTP/2 requests still run the handler). Use it to verify the port mapping and deployment before debugging app logic:

```sh
FF_ECHO=1 ff server.js --allow-net=0.0.0.0:3000
curl http://127.0.0.1:3000/anything
# {"message":"ok"}
```

Echo mode is runtime configuration, so it needs no `--allow-env`. It still
needs the listener grant.

## Reference: limits

| Area | Limit | When hit |
|------|-------|----------|
| Concurrent connections | 512 | 513th connection is accepted and immediately closed (does not wait) |
| Request head (HTTP/1.1) | 4 KB (request line + header block) | Beyond → `431 Request Header Fields Too Large` |
| Request headers (HTTP/2) | 64 KiB | Beyond → `431 Request Header Fields Too Large` |
| Request body (HTTP/1.1) | 1 MB hard cap (4 KB static buffer spills to heap; 64 MB global spill budget) | Beyond 1 MB → `413 Payload Too Large`; global budget exhausted → `503 Service Unavailable` (HTTP/2 allows 10 MB/stream, 16 MB/session) |
| Response body | 10 MB hard cap (buffered) | 64 KB HTTP/1.1 stage buffer spills to the heap (64 MB process-wide spill budget, up to 256 KB retained per slot); beyond 10 MB → `500`; spill budget exhausted → `503` for `Response`/`ArrayBuffer` bodies, `500` for plain `{status, body}` objects (`ReadableStream` is chunked on HTTP/1.1, `501` on HTTP/2) |
| Read/idle deadline | 30s without progress | A connection that receives no bytes for 30s while waiting for request headers/body is closed; the deadline restarts on every read, so a trickling client is never expired. The same 30s budget is the keep-alive idle timeout. Sockets stalled during a response write are not timed out. |
| Hung handler | 30s | Connection fails with `504` |
| Framing strictness | Duplicate/ambiguous Content-Length, Transfer-Encoding, obs-fold, or BWS | Connection terminated with `400 Bad Request` |
| Response status | 100..999 | Out-of-range falls back to default (`200`, or `302` for `Response.redirect`) |
| Bind address | Default `0.0.0.0` (`options.hostname`) | IPv4/IPv6 literals only; `--allow-net` checks `<hostname>:<port>` |
| Plain protocol | HTTP/1.1 | HTTP/2 needs TLS (see the TLS guide) |

## Troubleshooting

**`http.serve` throws `PermissionDenied`** — the listener's host/port is outside
every `--allow-net` scope. Grant `--allow-net=<hostname>:<port>` (default
`0.0.0.0:<port>`; `127.0.0.1` only matches when `{ hostname: "127.0.0.1" }`
is set, and `"localhost"` is not accepted).

**TLS fails with `PermissionDenied` on `tls.cert` / `tls.key`** — the path is
outside `--allow-read`. Add the file (and any symlink target) to the scope, or
pass inline PEM, which needs no file grant.

**Empty 200 when I return a string** — wrap it: `return new Response("hello")`. Bare strings are not bodies.

**Connection refused** — confirm the port in `http.serve({ port })` matches your `curl` command or Docker `-p` mapping. No environment variable overrides it.

**504 on slow endpoints** — the 30s handler watchdog fired. Move heavy work to a `Worker` or reply early and finish in the background.

**`id` comes back wrong in JSON** — you wrote `db.lastInsertRowId` without calling it. Always `db.lastInsertRowId()`.

**Stopping the server** — `http.serve` returns `{ port, close }`. Call `await server.close()` (or pass `{ signal }` to `http.serve`) to stop accepting new connections and drain active requests cleanly. `SIGINT` and `SIGTERM` also trigger `server.close()` automatically when no custom listener is registered for that signal.

## See also

- [Permissions](/docs/concepts/permissions) — flags, scopes, denial contract
- [http API](/docs/api/http) — full `http.serve` reference
- [TLS guide](/docs/guides/tls) — HTTPS/WSS setup
- [Limitations](/docs/reference/limitations) — every hard cap
