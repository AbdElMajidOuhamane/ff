---
title: http API
description: http.serve reference — signatures, options, handler contract, and helpers.
order: 16
---

# `http` API

The `http` module starts servers. It has one function, `http.serve`, plus the response helpers you return from your handler.

## Permissions

`http.serve` listens on the network, so it always needs `--allow-net` on the
bind address:

```sh
ff server.js --allow-net=0.0.0.0:3000
```

- The server binds `0.0.0.0` by default, configurable via `options.hostname`
  (IPv4/IPv6 literals only, e.g. `"127.0.0.1"`, `"::1"`). `--allow-net` checks
  `<hostname>:<port>` (default `0.0.0.0:<port>`). Granting `127.0.0.1:3000` works
  when `{ hostname: "127.0.0.1" }` is set (`localhost` is rejected because host
  names are not resolved).
- A scope without a port matches every port: `--allow-net=0.0.0.0` is enough
  for any default-bound listener port.
- The same grant covers HTTP, WebSocket upgrades, and TLS on that port.
- A denied listener throws synchronously from `http.serve`:

```js
try {
  http.serve({ port: 3000 }, handler);
} catch (e) {
  console.error(e.name, e.code); // PermissionDenied PERMISSION_DENIED
  console.error(e.message);      // http.serve requires --allow-net for '0.0.0.0:3000'
}
```

### TLS files need `read`

`tls.cert` and `tls.key` are either inline PEM (the string starts with
`-----BEGIN `) or a file path. Inline PEM needs no file permission; a path
needs `--allow-read` on that file:

```sh
ff server.js \
  --allow-net=0.0.0.0:3000 \
  --allow-read=cert.pem,key.pem
```

A denied TLS path throws `PermissionDenied` with messages like
`http.serve tls.cert requires --allow-read for 'cert.pem'` (and the same for
`tls.key`) before the listener starts. Path scopes follow the normal rules:
resolved against the launch cwd, symlink-checked, and not moved by
`process.chdir()`.

The `FF_CERT` / `FF_KEY` env vars used by `ff start` are read by the CLI and do
**not** need `--allow-read`. Only paths passed to `http.serve({ tls })` are
runtime reads.

Full model: [Permissions](/docs/concepts/permissions).

## Quick look

```js
// server.js
http.serve({ port: 3000 }, (url, method, body) => {
  return new Response("hello");
});
```

```sh
ff server.js --allow-net=0.0.0.0:3000
curl http://127.0.0.1:3000/
# hello
```

## `http.serve(signatures)`

Two call shapes are accepted, and both return a server handle (`{ port, close }`):

```js
const srv = http.serve(3000, handler);           // port shorthand
const srv = http.serve({ port: 4242 }, handler); // options object
const srv = http.serve({ port: 3000 }, routes);  // declarative routes object
```

| Signature | Port used | Returns |
|-----------|-----------|---------|
| `http.serve(port, handlerOrRoutes)` | `port` (`0` picks an ephemeral OS port) | `{ port: number, close(callback?): Promise<void> }` |
| `http.serve(options, handlerOrRoutes)` | `options.port`, or `3000` when omitted | `{ port: number, close(callback?): Promise<void> }` |

By default the server binds `0.0.0.0`. Pass `options.hostname` (an IPv4/IPv6 literal, e.g. `"127.0.0.1"` or `"::1"`, max 128 bytes) to bind a specific interface. When `port: 0` is passed, `srv.port` contains the actual bound port assigned by the OS.

> **Note:** the one-argument form `http.serve(handler)` is **not** supported by
> the current runtime — it throws `TypeError: http.serve: http.serve requires (options, handler)`.
> Use `http.serve(3000, handler)` or `http.serve({}, handler)` for the default port.

## Options reference

```js
const server = http.serve(
  {
    port: 3000,                       // default 3000 (0 for ephemeral port)
    hostname: "0.0.0.0",              // default "0.0.0.0" (IPv4/IPv6 literal only)
    reusePort: false,                 // optional — enables SO_REUSEPORT
    signal: ac.signal,                // optional — AbortSignal that calls server.close()
    tls: { cert: "...", key: "..." }, // optional — enables HTTPS/WSS/HTTP2 on the port
    websocket: {                      // optional — enables WebSocket upgrades
      open: (socket) => {},
      message: (socket, data) => {},
      close: (socket) => {},
    },
  },
  handler,
);
```

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `port` | `number` | `3000` | Listen port (`0` lets the OS pick an available port). Must be an integer in `0..65535`; anything else throws `TypeError: http.serve: port must be an integer in 0..65535` |
| `hostname` | `string` | `"0.0.0.0"` | Bind IPv4 or IPv6 literal (`max 128` B; hostnames such as `"localhost"` throw `TypeError`) |
| `reusePort` | `boolean` | `false` | Enables `SO_REUSEPORT` on the listening socket |
| `signal` | `AbortSignal` | none | Aborting the signal triggers `server.close()` |
| `tls` | `{ cert, key }` | none | PEM certificate + private key. Inline PEM (`-----BEGIN `) or file path (each file read up to 512 KB; BearSSL decoded DER caps: 32 KB chain / 4 certs, 8 KB key). Serves HTTPS/WSS/HTTP/2 **only** (replaces plain HTTP/WS on that listener) |
| `websocket.open` | `(socket) => void` | none | Fires when a client completes the upgrade |
| `websocket.message` | `(socket, data) => void` | none | Fires once per complete message (fragments are assembled first); `data` is a string (text) or `Uint8Array` (binary) |
| `websocket.close` | `(socket) => void` | none | Fires when a client disconnects |

## Graceful shutdown: `server.close()` and signals

`server.close(callback?)` stops accepting new connections and drains existing
ones cleanly:

- Closes the listening socket immediately so new connections are refused.
- Closes idle HTTP/1.1 keep-alive sockets and active WebSocket connections.
- Marks in-flight HTTP/1.1 requests with `Connection: close` so each socket
  closes as soon as its response finishes flushing.
- Sends HTTP/2 `GOAWAY` on active H2 sessions and closes them once active
  streams complete.
- Enforces a 5s hard drain deadline (`SHUTDOWN_DRAIN_MS = 5000`) that force-closes any still-active sockets so `server.close()` cannot hang indefinitely.
- Resolves the returned `Promise<void>` (and invokes optional `callback`) once
  all 512 connection slots are free, allowing the event loop to exit naturally.

```js
const server = http.serve({ port: 3000 }, handler);

process.once("SIGTERM", async () => {
  await server.close();
  console.log("drained cleanly");
});
```

If you do **not** register your own `SIGINT` or `SIGTERM` listener via
`process.on` / `process.once`, `http.serve` automatically traps `SIGINT` and
`SIGTERM` and calls `server.close()` for you.

When the `websocket` block is present, a request is upgraded **before your
handler runs** only if it is a `GET` on HTTP/1.1 with no body,
`Connection: Upgrade`, `Upgrade: websocket`, `Sec-WebSocket-Version: 13`,
and exactly one valid 24-character base64 `Sec-WebSocket-Key`. A request
that carries upgrade headers but fails any check is answered `400 Bad
Request` and never reaches the handler. An upgraded request never reaches
the handler and no `{ status: 101 }` branch is needed (a handler that would
return 404 still gets the `101`). The handler serves plain HTTP only:

```js
// server.js
http.serve(
  {
    port: 3000,
    websocket: {
      open: (socket) => socket.send("welcome"),
      message: (socket, data) => socket.send(data),
      close: (socket) => console.log("bye"),
    },
  },
  (url, method, body) => new Response("http here, ws upgrades on this port"),
);
```

WebSocket upgrades share the listener's net grant:
`--allow-net=<hostname>:<port>` (default `0.0.0.0:3000`).

Server sockets expose `send` / `sendBinary` only — track peers by object reference in a `Set` (see the WebSocket guide).

## Handler reference

The handler argument can be a request function or a declarative routes table. Plain function handlers receive `(url, method, body, headers)`:

| Argument | Type | Example |
|----------|------|---------|
| `url` | `string` | `"/greet?name=ada"` (path + query) |
| `method` | `string` | `"GET"`, `"POST"` — exactly as the client sent it (`curl -X post` yields `"post"`); normalize case before comparing |
| `body` | `string` | Request text, `""` when none |
| `headers` | `Headers \| undefined` | Web-standard `Headers` populated with incoming request headers (HTTP/1.1 and HTTP/2). On HTTP/1.1, parsed only when the handler declares 4+ parameters (routes use arity 5; `arguments` or `...` forces arity 4); a handler whose `fn.length < 4` receives `undefined` and only header validation runs. On HTTP/2, regular headers are always parsed and passed when present |

Return one of:

| Return value | Effect |
|--------------|--------|
| `Response` | Status, headers, and body sent as-is (including `ReadableStream` bodies on HTTP/1.1) |
| `{ status, body }` (`string \| ArrayBuffer \| ReadableStream`) | Sent with that status code (any `headers` property on plain objects is ignored — use `new Response`) |
| `Promise` of either shape | Connection parks until it settles |
| Anything else (incl. bare strings or bare `ReadableStream`) | Empty `200` response (or `501` for bare `ReadableStream` over HTTP/2) |

### Routes object (`http.serve(options, routes)`)

Pass a routes table as the second argument instead of a function:

```js
http.serve(
  { port: 3000 },
  {
    "GET /users/:id": (url, method, body, headers, params) =>
      Response.json({ id: params.id }),
    "/health": () => Response.json({ ok: true }),
    "*": () => new Response("Fallback", { status: 404 }),
  },
);
```

- **Key forms**: `"METHOD /path"` (method matched case-insensitively, whitespace trimmed), `"/path"` (matches any method), or `"*"` (wildcard fallback, 0 params). Keys must be `< 512` bytes; evaluated in enumeration order (first match wins).
- **Parameters**: `:param` segments capture any non-empty segment (`> 0` chars), up to 16 params per route, passed as `params` (5th handler arg `(url, method, body, headers, params)`). Query strings (`?...`) are stripped before matching.
- **Built-in responses**: oversized URLs are rejected before routing by the request-head limits (`431` on HTTP/1.1, `400` on HTTP/2); path matches with a mismatched method return `405 Method Not Allowed`; unmatched routes (or non-function values) return `404 Not Found`. Works on both HTTP/1.1 and HTTP/2.

### Streaming responses (HTTP/1.1)

Return `new Response(stream, init?)` or `{ status, body: stream }` with a [`ReadableStream`](/docs/api/streams):

- **HTTP/1.1**: emits `Transfer-Encoding: chunked` (default `content-type: text/plain` if unset). Accepts `string`, `Uint8Array`, and `ArrayBuffer` chunks; chunks `> 16352` bytes are copied into the write buffer one slice per write, and the JS buffer is retained until its last slice drains (mutating a `Uint8Array` before then affects the not-yet-written slices). Supports both `controller.enqueue()` push and `pull(controller)`. `controller.close()` writes `0\r\n\r\n` and keeps keep-alive; `controller.error()` closes the connection. `HEAD`/`204`/`304` suppress the body.
- **HTTP/2**: returns `501` status only (chunked streaming is HTTP/1.1 only).

Async handlers work — the 30s watchdog still applies:

```js
http.serve({ port: 3000 }, async (url, method, body) => {
  const res = await fetch("https://example.com/");
  return new Response(await res.text());
});
```

An async handler that calls out needs grants for **both** sides:

```sh
ff server.js \
  --allow-net=0.0.0.0:3000,example.com:443
```

The listener is granted by `0.0.0.0:3000`; the outbound `fetch` is granted by
`example.com:443`. One repeatable flag can carry both scopes.

## Response helpers

Build responses with the global `Response` class:

```js
return new Response("text");                          // 200 (HTTP/1.1 server adds text/plain)
return new Response("missing", { status: 404 });      // custom status
return Response.json({ hello: "world" });             // JSON + content-type, optional init
return Response.json({ id: 1 }, { status: 201 });     // with status
return Response.file("./public/index.html");        // file from disk (needs --allow-read)
return Response.redirect("/new-path");                // 302 status only — no Location header
return Response.redirect("/moved", 301);              // 301 status only — no Location header
```

| Helper | Signature | Notes |
|--------|-----------|-------|
| `new Response(body, init?)` | `body`: `string \| ArrayBuffer \| Uint8Array \| ReadableStream \| null`; `init`: `{ status?, statusText?, headers? }` | Defaults to `200`/`OK`; adds **no** `content-type` header (the HTTP/1.1 server supplies `Content-Type: text/plain` for body-bearing responses that have none; HTTP/2 does not) |
| `Response.json(data, init?)` | `(any, { status?, statusText?, headers? })` | Sets `content-type: application/json` |
| `Response.file(path)` | `(string) → Response` | Synchronous read (`--allow-read`, 50 MB file cap; `http.serve` enforces 10 MB response cap), guesses `Content-Type` by extension |
| `Response.redirect(url, status?)` | redirect target + status (default 302) | Known issue: sets the status but **no `Location` header**, so no client follows it — send `Location` yourself (see [fetch Gotchas](/docs/api/fetch#gotchas)) |
| `Response.error()` | — | Status `0`, type `"error"` (fetch-network-error shape) |

Read bodies back with `text()` / `json()` / `arrayBuffer()` / `bytes()` / `blob()` / `formData()` — all work on `Request` and `Response`. Bodies can be re-read freely (`Response.bodyUsed` flips to `true` after the first read as an informational flag, while `Request.bodyUsed` stays `false`; `bytes()` returns `ArrayBuffer`).

Headers are case-insensitive and lowercased internally:

```js
const h = new Headers({ "Content-Type": "text/html" });
h.get("content-type"); // "text/html"
h.set("x-id", "1");
h.append("x-id", "2");
h.getAll("x-id");      // ["1", "2"]
h.has("x-id");         // true
h.delete("x-id");
h.entries(); h.keys(); h.values();
h.forEach((value, key) => console.log(key, value));
```

## Full example

```js
// server.js
http.serve({ port: 3000 }, (url, method, body) => {
  const path = new URL(url, "http://localhost").pathname;

  if (path === "/json") return Response.json({ ok: true });
  if (path === "/old") return Response.redirect("/json", 301);
  if (path === "/echo" && method === "POST") {
    return new Response(body, {
      headers: { "content-type": "text/plain" },
    });
  }
  return new Response("not found", { status: 404 });
});
```

```sh
ff server.js --allow-net=0.0.0.0:3000
curl http://127.0.0.1:3000/json        # {"ok":true}
curl -i http://127.0.0.1:3000/old      # 301 without Location (clients won't follow)
curl -X POST http://127.0.0.1:3000/echo -d hi  # hi
```

## Runtime config: `FF_ECHO`

`FF_ECHO` is read by the runtime, not by JavaScript, so it needs no
`--allow-env`. Setting any value (even empty) makes every HTTP/1.1 request
return `200 {"message":"ok"}` without invoking your handler. HTTP/2 requests
are not intercepted and still run the handler:

```sh
FF_ECHO=1 ff server.js --allow-net=0.0.0.0:3000
```

The listener still needs its net grant — echo mode bypasses the handler, not
the permission check. See the [env guide](/docs/guides/env#ff_echo--smoke-mode).

## Limits (summary)

Full table lives in the Limitations reference; the ones that bite here: 512 concurrent connections (513th accepted and immediately closed), 4 KB HTTP/1.1 request head — request line plus headers (→ `431`; 64 KiB of header bytes for HTTP/2), 1 MB max HTTP/1.1 request body (4 KB static buffer spills to the heap, 64 MB global spill budget; → `413` / `503`; HTTP/2 allows 10 MB per stream / 16 MB per session), 10 MB max buffered response body (the 64 KB HTTP/1.1 staging buffer spills to the heap, 64 MB process-wide spill budget; `ReadableStream` chunked streaming on HTTP/1.1, `501` on HTTP/2), 30s read deadline without progress (a trickling request is never expired; also the keep-alive idle timeout), 30s handler watchdog (→ `504`), strict HTTP framing (ambiguous Content-Length/Transfer-Encoding, obs-fold, or BWS rejected with 400 Bad Request), Response status validated to `100..999` (out-of-range falls back to `200`, or `302` for `Response.redirect`), plain listeners speak HTTP/1.1 (HTTP/2 needs TLS), bind defaults to `0.0.0.0` (configurable via `options.hostname`).

## See also

- [Permissions](/docs/concepts/permissions) — flags, scopes, denial contract
- [HTTP Server guide](/docs/guides/http-server) — tutorial version of this page
- [WebSocket guide](/docs/guides/websocket) — `send` / `sendBinary` patterns
- [TLS guide](/docs/guides/tls) — `tls: { cert, key }` in depth
- [Limitations](/docs/reference/limitations) — every hard cap
