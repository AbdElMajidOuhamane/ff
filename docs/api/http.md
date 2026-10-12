---
title: http API
description: http.serve reference — signatures, options, handler contract, and helpers.
order: 16
---

# `http` API

The `http` module starts servers. It has one function, `http.serve`, plus the response helpers you return from your handler. The server always binds `0.0.0.0`; plain listeners speak HTTP/1.1, and adding TLS unlocks HTTPS, WSS, and HTTP/2 on the same port.

## Quick look

```js
// server.js
http.serve({ port: 3000 }, (url, method, body) => {
  return new Response("hello");
});
```

```sh
ff server.js
curl http://127.0.0.1:3000/
# hello
```

## `http.serve(options, handler)`

`http.serve` takes exactly **two** arguments: an options value first, a handler function second. Calling it with **one** argument throws before anything starts:

```js
http.serve(handler);
// TypeError: http.serve: http.serve requires (options, handler)
```

The first argument is either an options object or a port number:

```js
http.serve({ port: 4242 }, handler); // options object
http.serve(4242, handler);           // port shorthand
http.serve({}, handler);             // no options — port 3000
```

| First argument | Port used |
|----------------|-----------|
| `{ port }` object | `options.port`, or `3000` when `port` is missing/invalid |
| number | that number |
| anything else (`null`, `undefined`, a string, …) | `3000` |

- The port is coerced with QuickJS `toInt32`; a non-numeric value falls back to `3000`.
- The server always binds `0.0.0.0`. There is **no host option**, no `--port` flag, and no `FF_PORT` env var.
- The handler must be a function, or `http.serve` throws `TypeError: http.serve: handler must be a function`.

### Return value

`http.serve` returns **`undefined`**. There is no server handle, no `.port`, and no `.stop()` — the port is whatever you passed, and the only way to stop serving is to end the process (`Ctrl-C`, or `process.exit(0)` from your code).

> **Note:** A process has one listener. A second `http.serve` call does not open a new port — the first listener is reused, its port is ignored, and the handler is replaced. A listener is either plain or TLS, decided by the options on the call that started it.

## Options reference

```js
http.serve(
  {
    port: 3000,                       // default 3000
    tls: { cert: "...", key: "..." }, // optional — enables HTTPS/WSS/H2 on the same port
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
| `port` | `number` | `3000` | Listen port |
| `tls` | `{ cert, key }` | none | PEM certificate + private key. Each value is either inline PEM (starts with `-----BEGIN `) or a file path. File paths are read with a **512 KB** cap (both cert and key through this option). Enables HTTPS, WSS, and HTTP/2 on the same port — see the [TLS guide](/docs/guides/tls) |
| `websocket` | `object` | none | Presence alone enables upgrades; its keys are optional callbacks (below) |
| `websocket.open` | `(socket) => void` | none | Fires when a client completes the upgrade (after the `101` is written) |
| `websocket.message` | `(socket, data) => void` | none | Fires per reassembled message; `data` is a `string` (text) or `Uint8Array` (binary) |
| `websocket.close` | `(socket) => void` | none | Fires when a client disconnects |

If `tls` is present but `cert`/`key` are not strings, `http.serve` throws `TypeError: http.serve: tls.cert and tls.key must be strings (PEM content or file path)`. If the provider can't be read or parsed, the server refuses to start (you never get a silent plain-HTTP fallback). A binary built with `-Dbearssl=false` throws `TypeError: http.serve: built without TLS …` when you pass `tls`.

## Response headers: what you control

When you return a `Response`, its status, `content-type`, and custom headers are sent. A few things are always managed by the runtime and cannot be overridden from your `Response`:

- `content-length` — computed from the body you return.
- `connection` — set to `keep-alive` when the connection is kept open.
- `transfer-encoding` — never emitted; framing is `content-length` only.
- Header names/values containing `\r` or `\n` are dropped (header-injection guard).
- If the body is non-empty and you set no `content-type`, `text/plain` is used.

## WebSocket upgrades

When `options.websocket` is an **object**, the server upgrades **before** your handler runs whenever a request's headers contain `Sec-WebSocket-Key:` (case-insensitive). That single header is the trigger — the runtime does **not** also require `Connection: Upgrade` or `Upgrade: websocket`. The `101 Switching Protocols` response is written for the handshake, so the handler never sees it and no `{ status: 101 }` branch is needed (a handler that would return `404` still gets the `101`). The handler serves plain HTTP only:

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

Server sockets expose `send` / `sendBinary` only — track peers by object reference in a `Set` (see the [WebSocket guide](/docs/guides/websocket)).

## Handler reference

The handler is called as `(url, method, body)` — all three are strings:

| Argument | Type | Example |
|----------|------|---------|
| `url` | `string` | `"/greet?name=ada"` (path + query) |
| `method` | `string` | `"GET"`, `"POST"` — exactly as the client sent it (`curl -X post` yields `"post"`); normalize case before comparing |
| `body` | `string` | Request text, `""` when none |

Return one of:

| Return value | Effect |
|--------------|--------|
| `Response` | Status, headers, and body sent as-is |
| `{ status, body }` (`string` or `ArrayBuffer` body) | Sent with that status code |
| `Promise` of either shape | Connection parks until it settles; a rejection → `500` |
| Anything else (incl. bare strings) | Empty `200` response |

A handler that **throws** (or returns a rejected promise) produces `500 Internal Server Error`. Async handlers work — the 30s watchdog still applies:

```js
http.serve({ port: 3000 }, async (url, method, body) => {
  const res = await fetch("https://example.com/");
  return new Response(await res.text());
});
```

## Response helpers

Build responses with the global `Response` class:

```js
return new Response("text");                          // 200 text/plain by default
return new Response("missing", { status: 404 });      // custom status
return Response.json({ hello: "world" });             // JSON + content-type, optional init
return Response.json({ id: 1 }, { status: 201 });     // with status
return Response.redirect("/new-path");                // 302 status only — no Location header
return Response.redirect("/moved", 301);              // 301 status only — no Location header
```

| Helper | Signature | Notes |
|--------|-----------|-------|
| `new Response(body, init?)` | `body`: `string \| ArrayBuffer \| Uint8Array \| null`; `init`: `{ status?, statusText?, headers? }` | Default `content-type` is `text/plain` when the body has none |
| `Response.json(data, init?)` | any JSON-serializable `data` | Sets `content-type: application/json` |
| `Response.redirect(url, status?)` | redirect target + status (default 302) | Known issue: sets the status but **no `Location` header**, so no client follows it — send `Location` yourself (see [fetch Gotchas](/docs/api/fetch#gotchas)) |
| `Response.error()` | — | Status `0`, type `"error"` (fetch-network-error shape) |

Read bodies back with `text()` / `json()` / `arrayBuffer()` / `bytes()` / `blob()` / `formData()` — all work on `Request` and `Response`. Bodies are **re-readable** (`bodyUsed` is a construction-time snapshot that always stays `false`); `bytes()` returns an `ArrayBuffer`, not a `Uint8Array`. See [Request / Response / Headers](/docs/api/request-response).

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
ff server.js
curl http://127.0.0.1:3000/json        # {"ok":true}
curl -i http://127.0.0.1:3000/old      # 301 without Location (clients won't follow)
curl -X POST http://127.0.0.1:3000/echo -d hi  # hi
```

## Limits (summary)

Full table lives in the [Limitations reference](/docs/reference/limitations); the ones that bite here:

| Area | Limit | When hit |
|------|-------|----------|
| Concurrent connections | 512 | Once every slot is busy, new connections are accepted then immediately closed — they are **not** queued |
| Request size | 4096 bytes (request line + headers + body share one read buffer) | A declared body that pushes the total past 4096 → `413 Payload Too Large`; a header block that never terminates within 4096 closes the connection |
| Response body | 10 MB hard cap | Beyond 10 MB → `500`; bodies up to 64 KB stage in a per-slot static buffer, larger ones spill to the heap |
| Response headers | 2048 bytes | User headers are dropped once the block would exceed the cap |
| Hung handler | 30s watchdog | A still-pending handler promise → `504 Gateway Timeout` |
| Plain protocol | HTTP/1.1 | HTTP/2 needs TLS + ALPN |

## See also

- [HTTP Server guide](/docs/guides/http-server) — tutorial version of this page
- [WebSocket guide](/docs/guides/websocket) — `send` / `sendBinary` patterns
- [TLS guide](/docs/guides/tls) — `tls: { cert, key }` in depth
- [HTTP/2 guide](/docs/guides/http2) — the same port serving h2
- [Limitations](/docs/reference/limitations) — every hard cap
