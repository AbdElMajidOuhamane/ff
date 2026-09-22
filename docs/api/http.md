---
title: http API
description: http.serve reference — signatures, options, handler contract, and helpers.
order: 1
---

# `http` API

The `http` module starts servers. It has one function, `http.serve`, plus the response helpers you return from your handler.

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

## `http.serve(signatures)`

Three call shapes are accepted:

```js
http.serve(handler);                 // default port 3000
http.serve(4242, handler);           // port shorthand
http.serve({ port: 4242 }, handler); // options object
```

| Signature | Port used |
|-----------|-----------|
| `http.serve(handler)` | `3000` |
| `http.serve(port, handler)` | `port` |
| `http.serve(options, handler)` | `options.port`, or `3000` when omitted |

The server binds to `0.0.0.0`. There is no host option.

## Options reference

```js
http.serve(
  {
    port: 3000,                       // default 3000
    tls: { cert: "...", key: "..." }, // optional — enables HTTPS/WSS on the same port
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
| `tls` | `{ cert, key }` | none | PEM certificate + private key. Each value is either inline PEM (starts with `-----BEGIN`) or a file path. Cert max 512KB, key max 256KB. Enables HTTPS and WSS alongside plain HTTP/WS |
| `websocket.open` | `(socket) => void` | none | Fires when a client completes the upgrade |
| `websocket.message` | `(socket, data) => void` | none | Fires per frame; `data` is a string (text) or `Uint8Array` (binary) |
| `websocket.close` | `(socket) => void` | none | Fires when a client disconnects |

When the `websocket` block is present, upgrade is triggered by the `Sec-WebSocket-Key` header. On the WebSocket path your handler must return `{ status: 101 }`:

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
  (url, method, body) => {
    if (url === "/ws") return { status: 101 };
    return new Response("http here, ws on /ws");
  },
);
```

Server sockets expose `send` / `sendBinary` only — track peers by object reference in a `Set` (see the WebSocket guide).

## Handler reference

The handler is called as `(url, method, body)` — all three are strings:

| Argument | Type | Example |
|----------|------|---------|
| `url` | `string` | `"/greet?name=ada"` (path + query) |
| `method` | `string` | `"GET"`, `"POST"` |
| `body` | `string` | Request text, `""` when none |

Return one of:

| Return value | Effect |
|--------------|--------|
| `Response` | Status, headers, and body sent as-is |
| `{ status, body }` (`string` or `ArrayBuffer` body) | Sent with that status code |
| `Promise` of either shape | Connection parks until it settles |
| Anything else (incl. bare strings) | Empty `200` response |

Async handlers work — the 30s watchdog still applies:

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
return Response.redirect("/new-path");                // 302 redirect
return Response.redirect("/moved", 301);              // redirect with status
```

| Helper | Signature | Notes |
|--------|-----------|-------|
| `new Response(body, init?)` | `body`: `string \| ArrayBuffer \| null`; `init`: `{ status?, headers? }` | Default `content-type` is `text/plain` when the body has none |
| `Response.json(data, init?)` | any JSON-serializable `data` | Sets `content-type: application/json` |
| `Response.redirect(url, status?)` | redirect target + status (default 302) | Follows the standard redirect semantics |
| `Response.error()` | — | Status `0`, type `"error"` (fetch-network-error shape) |

Read bodies back with `text()` / `json()` / `arrayBuffer()` / `bytes()` / `blob()` / `formData()` — all work on `Request` and `Response`. Each body reads once (`bodyUsed` goes `true`).

Headers are case-insensitive and lowercased internally:

```js
const h = new Headers({ "Content-Type": "text/html" });
h.get("content-type"); // "text/html"
h.set("x-id", "1");
h.append("x-id", "2");
h.getAll("x-id");      // ["1", "2"]
h.has("x-id"); h.delete("x-id");
h.entries(); h.keys(); h.values(); h.forEach((v, k) => {});
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
curl -i http://127.0.0.1:3000/old      # 301 to /json
curl -X POST http://127.0.0.1:3000/echo -d hi  # hi
```

## Limits (summary)

Full table lives in the Limitations reference; the ones that bite here: 512 concurrent connections, 64KB max response body, 30s handler watchdog (→ `504`), plain listeners speak HTTP/1.1 (HTTP/2 needs TLS).

## See also

- [HTTP Server guide](/guides/http-server) — tutorial version of this page
- [WebSocket guide](/guides/websocket) — `send` / `sendBinary` patterns
- [TLS guide](/guides/tls) — `tls: { cert, key }` in depth
- [Limitations](/reference/limitations) — every hard cap
