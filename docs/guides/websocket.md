---
title: WebSocket
description: Real-time chat-style messaging — server upgrades, broadcast, and clients.
order: 3
---

# WebSocket

Fairyfly speaks WebSocket on both sides: upgrade HTTP clients with the `websocket` option on `http.serve` (server), or dial out with `new WebSocket(url)` (client). Server and client share the RFC 6455 frame protocol but have different APIs — this guide walks through both, then covers the shared limits.

If you already know the shape and just need signatures, the [`WebSocket` API reference](/docs/api/websocket) is the denser version of this page.

## Quick look: echo server + client

Server (`server.js`) — the `websocket` block makes upgrades automatic; echo everything back:

```js
// server.js
const peers = new Set();

http.serve(
  {
    port: 3000,
    websocket: {
      open: (socket) => {
        peers.add(socket);
        socket.send("welcome");
      },
      message: (socket, data) => socket.send(data),
      close: (socket) => peers.delete(socket),
    },
  },
  (url, method, body) => new Response("http here, ws upgrades on this port"),
);
```

Client (`client.js`) — connect, send, print:

```js
// client.js
const ws = new WebSocket("ws://127.0.0.1:3000/ws");
ws.onopen = () => ws.send("hello");
ws.onmessage = (ev) => console.log("got:", ev.data);
```

```sh
ff server.js
# in another terminal:
ff client.js
# got: welcome
# (server echoes "hello" back: got: hello)
```

A plain `.js` file is a classic script, so wrap async work in `(async () => { … })()`; top-level `await` is only valid in a `.mjs` file.

## Server: upgrading connections

Add a `websocket` **object** to the `http.serve` options. Its presence is what enables upgrades on that server; every key inside it is optional:

```js
http.serve({ port: 3000, websocket: {} }, handler); // upgrades on, no callbacks
```

The upgrade itself fires on **any request whose headers contain `Sec-WebSocket-Key:`** — any path, any method, before your handler runs. That one header is the whole trigger; there is no path routing to configure. So the handler only ever sees plain HTTP, and returns normal responses for every path:

```js
http.serve(
  { port: 3000, websocket: { open, message, close } },
  (url, method, body) => new Response("not found", { status: 404 }),
);
```

A handler that would return `404` still gets overridden by the `101` for a handshake request — the upgrade happens first, and the handler is never called for it.

### Handlers

| Handler | Fires | Arguments |
|---------|-------|-----------|
| `open` | Client completes the upgrade (after the `101` is written) | `(socket)` |
| `message` | Per reassembled message | `(socket, data)` — `string` for text, `Uint8Array` for binary |
| `close` | Client disconnects (or the connection dies) | `(socket)` |

All three are optional; omit any you don't need. Always check the type of `data` first — text and binary arrive differently:

```text
message: (socket, data) => {
  if (typeof data === "string") console.log("text:", data);
  else console.log("binary bytes:", data.length);
},
```

Because `open` fires after the handshake response is flushed, sending from `open` is safe: the first message is written right after the `101`.

## Server: sending and broadcast

Server sockets expose exactly two methods — `send` (text) and `sendBinary` (bytes). There is no `socket.id`, no `readyState`, and no server-side `close`. Identify peers by object reference in a `Set`:

```js
// server.js — chat room that broadcasts to everyone
const peers = new Set();

http.serve(
  {
    port: 3000,
    websocket: {
      open: (socket) => peers.add(socket),
      message: (socket, data) => {
        for (const peer of peers) peer.send(data);
      },
      close: (socket) => peers.delete(socket),
    },
  },
  (url, method, body) => new Response(`online: ${peers.size}`),
);
```

```sh
ff server.js
curl http://127.0.0.1:3000/   # online: 0  (peers counted via Set size)
```

`send` takes a string; `sendBinary` takes bytes (an `ArrayBuffer` or any typed-array view):

```text
socket.send("hi");
socket.sendBinary(new Uint8Array([1, 2, 3]));
```

Both return `undefined`, and neither throws:

- `send` ignores non-string input and empty strings.
- Sending after the peer has gone away is a **no-op** (it neither throws nor queues).
- A send bigger than 16384 bytes closes the connection with code `1009` instead of sending.

> **Caution:** because sends after disconnect are silent no-ops, always remove the socket in `close`, and never keep an object around to send to after that. Identity is the object itself — there is no id or index to store.

## Server: control frames

The control plane is automatic; your `message` handler only sees data frames:

| Incoming | Server does |
|----------|-------------|
| `Ping` | Replies with `Pong` (same payload) |
| `Pong` | Ignores |
| `Close` | Echoes `Close`, tears down, then fires `websocket.close` |

Fragmented data frames are reassembled before `message` fires. An over-sized or malformed frame closes the connection (`1009` for too big, `1002` for protocol errors).

## Client: connecting and messaging

```js
// client.js
const ws = new WebSocket("ws://127.0.0.1:3000/ws");

ws.onopen = () => {
  console.log("open, state:", ws.readyState); // 1
  ws.send("hello");                              // text
  ws.send(new Uint8Array([9, 9]));               // binary
};

ws.onmessage = (ev) => console.log("got:", ev.data);
ws.onclose = (ev) => console.log("closed:", ev.code, ev.reason);
ws.onerror = (ev) => console.error("ws error:", ev.message);
```

| Member | Description |
|--------|-------------|
| `send(data)` | `string` → text frame; `ArrayBuffer` / `TypedArray` → binary frame |
| `close(code?, reason?)` | Graceful close, e.g. `ws.close(1000, "done")` |
| `readyState` | `0` connecting, `1` open, `2` closing, `3` closed |
| `onopen` / `onmessage` / `onclose` / `onerror` | Event handler properties; `ev.data` is `string` or `Uint8Array` |

There is **no `addEventListener`** — assign the `on*` properties, as above. There is also **no client `sendBinary`**: pass bytes straight to `send`. The constants are available both per-instance and on the constructor (`ws.OPEN === WebSocket.OPEN === 1`).

`close()` sets `readyState` to `2` right away and sends a Close frame; once the peer (or a ~5s timeout) replies, the state becomes `3` and `onclose` fires.

Only `ws://` and `wss://` URLs are accepted (everything else throws). The host may be a DNS name (up to 255 bytes) or an IP literal; the path defaults to `/` and is capped at 512 bytes. For `wss://` to private CAs, the same trust rules as `fetch` apply (`--ca` for `ff <file>`/`ff -e`, `FF_CA_FILE` for `ff start`).

### Client errors

Two shapes, depending on when the failure happens.

**Synchronous mistakes throw immediately**, always with a `WebSocket: ` prefix:

```js
new WebSocket("http://localhost:3000/");
// TypeError: WebSocket: invalid WebSocket URL (expected ws:// or wss://)
new WebSocket();
// TypeError: WebSocket: WebSocket constructor requires a URL
```

**Runtime failures** (refused, unreachable, TLS failure, bad handshake) do **not** throw. Instead the client fires `onerror` with an event whose `.message` is a plain string (not an `Error`) — one of `"connect failed"`, `"handshake failed"`, `"invalid host"`, or `"invalid url"` — immediately followed by `onclose` with `.code === 1006` and an empty `.reason`:

```js
ws.onerror = (ev) => console.error("ws error:", ev.message); // a string
ws.onclose = (ev) => console.log("closed:", ev.code, ev.reason); // 1006, ""
```

A close that carries no recorded error fires `onclose` alone (no `onerror`). `onerror` is for failures; a normal close is not an error.

## Practical example: presence counter

Track who's online and push the count to every client on join/leave:

```js
// presence.js
const peers = new Set();
const count = () => `online: ${peers.size}`;
const broadcast = () => {
  for (const peer of peers) peer.send(count());
};

http.serve(
  {
    port: 3000,
    websocket: {
      open: (socket) => {
        peers.add(socket);
        broadcast();
      },
      message: (socket, data) => socket.send(`echo: ${data}`),
      close: (socket) => {
        peers.delete(socket);
        broadcast();
      },
    },
  },
  (url, method, body) => new Response(count()),
);
```

```sh
ff presence.js
curl http://127.0.0.1:3000/   # online: 0
# connect two clients -> each receives "online: 1", then "online: 2"
```

## Practical example: a small room with names

Because sockets are opaque, keep the metadata you need in a `Map` keyed by the socket object:

```js
// room.js
const names = new Map(); // socket -> name

http.serve(
  {
    port: 3000,
    websocket: {
      open: (socket) => socket.send("send your name"),
      message: (socket, data) => {
        if (!names.has(socket)) {
          names.set(socket, String(data));
          for (const s of names.keys()) s.send(`${names.get(socket)} joined`);
          return;
        }
        for (const s of names.keys()) s.send(`${names.get(socket)}: ${data}`);
      },
      close: (socket) => {
        const name = names.get(socket) ?? "someone";
        names.delete(socket);
        for (const s of names.keys()) s.send(`${name} left`);
      },
    },
  },
  () => new Response("ws only"),
);
```

## Reference: limits

| Area | Limit | When hit |
|------|-------|----------|
| Server connections | 512 per process | Listener stops accepting new connections |
| Client sockets | 64 per process | The constructor throws `TypeError: WebSocket: … no connection slots available` |
| Message size | 16384 bytes | Server closes with `1009`; client silently drops an oversized `send` |
| Server handshake headers | 4096 bytes | A request header block larger than the server read buffer is rejected |
| Client URL host | 255 bytes | Constructor throws |
| Client URL path | 512 bytes | Constructor throws |
| Server socket API | `send` / `sendBinary` only | No `id`, `readyState`, or `close` server-side |

## Troubleshooting

**Upgrade never fires** — the `websocket` value must be an object, and the request must carry a `Sec-WebSocket-Key` header (any real WS client does). No handler branch is needed: the upgrade happens before the handler runs.

**`socket.id` is undefined** — by design. Use a `Set` (or `Map`) of socket objects; `peers.has(socket)` is the identity check.

**`ws.sendBinary is not a function`** — `sendBinary` is server-only. On the client, call `ws.send(bytes)`.

**Binary arrives as `Uint8Array`, not string** — check `typeof data === "string"` first.

**A `send` of a big payload vanished** — over 16384 bytes the client drops it silently, and the server closes the connection with `1009`. Keep messages under the cap.

**Client connect fails** — confirm the `ws://`/`wss://` scheme, the host/path size limits, and (for `wss://`) the CA trust setup from the fetch guide. Watch `onerror` for the reason string; nothing is thrown.

## See also

- [WebSocket API reference](/docs/api/websocket) — dense reference for both sides
- [http](/docs/api/http) — the `websocket` server option
- [Fetch Client guide](/docs/guides/fetch-client) — `--ca` / `FF_CA_FILE` trust setup
- [Limitations](/docs/reference/limitations) — every hard cap
