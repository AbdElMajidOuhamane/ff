---
title: WebSocket
description: Real-time chat-style messaging — server upgrades, broadcast, and clients.
order: 3
---

# `WebSocket` API

Fairyfly speaks WebSocket on both sides: **server** upgrades are enabled by the `websocket` option on `http.serve`, and **clients** dial out with `new WebSocket(url)`. Server and client share the RFC 6455 frame protocol but expose different APIs — this page is the reference for both.

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

A `.js` file is a classic script, so keep `await` inside an async wrapper (as the UDP page does). Top-level `await` needs a `.mjs` extension.

## Server: enabling upgrades

Pass an object as `options.websocket`. Its presence alone enables upgrades on that server — the value is not required to be anything else, and every key inside it is optional:

```js
http.serve({ port: 3000, websocket: {} }, handler); // upgrades on, no callbacks
```

| Key | Type | Default | Fires |
|-----|------|---------|-------|
| `websocket.open` | `(socket) => void` | none | Client completes the upgrade |
| `websocket.message` | `(socket, data) => void` | none | Per message; `data` is `string` (text) or `Uint8Array` (binary) |
| `websocket.close` | `(socket) => void` | none | Client disconnects (or the connection is torn down) |

### What triggers the upgrade

When `websocket` is set, the server upgrades **any request whose header block contains a `Sec-WebSocket-Key:` header** — on any path, before your handler runs. There is no path matching and no method check: the presence of that one header is the entire trigger. A real client sends it as part of the handshake; `curl -H 'Sec-WebSocket-Key: x' http://127.0.0.1:3000/` would also get a `101`.

Consequences:

- Your handler **never sees** an upgraded request. A handler that returns `404` still gets overridden by the `101`.
- Your handler keeps serving plain HTTP for every request that lacks the header.
- Returning a `{ status: 101 }` branch from the handler is pointless — upgrades happen before the handler.

```js
http.serve(
  { port: 3000, websocket: { open, message, close } },
  (url, method, body) => new Response("not found", { status: 404 }),
);
```

The server sends the `101 Switching Protocols` response itself (computing `Sec-WebSocket-Accept` from your key). `websocket.open` fires only **after** that response is written.

### The `data` argument

Text frames arrive as a `string`; binary frames arrive as a fresh `Uint8Array`. Always branch on the type:

```text
message: (socket, data) => {
  if (typeof data === "string") console.log("text:", data);
  else console.log("binary bytes:", data.length);
},
```

Fragmented messages are reassembled before `message` fires, so `data` is always a whole message. For binary, the `Uint8Array` is a copy — mutating it does not affect the wire.

## Server: the socket object

Server sockets are opaque objects of the internal `ServerWebSocket` class with exactly two methods. There is **no** `id`, **no** `readyState`, and **no** server-side `close`.

| Member | Signature | Description |
|--------|-----------|-------------|
| `send(data)` | `(string) => undefined` | Send a **text** frame. No-op if `data` is not a string, is empty, or the socket is no longer open |
| `sendBinary(buf)` | `(ArrayBuffer \| TypedArray) => undefined` | Send a **binary** frame from raw bytes |

```text
socket.send("hello");
socket.sendBinary(new Uint8Array([1, 2, 3]));         // typed-array view
socket.sendBinary(new Uint8Array([1, 2, 3]).buffer);  // ArrayBuffer
```

Both methods return `undefined` and never throw. Identify peers by **object reference** — the socket object is stable for the life of one connection:

```js
const peers = new Set();
// open:    peers.add(socket)
// message: for (const peer of peers) peer.send(data)
// close:   peers.delete(socket)
// peers.has(socket)  ->  true while the client is connected
```

> **Caution:** sending after the client has disconnected does nothing — it does not queue and does not throw. Always drop the socket in `close`, and never keep a reference to send after that. A returned value cannot be used to target a connection: identity is the object itself.

### Broadcast pattern

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

Sends are batched onto the connection's write pipeline, so a burst of `send` calls from one callback is fine. If the per-connection outbound buffer is full, an individual send is silently dropped (it is never queued unboundedly).

### Control frames are handled for you

The server implements the RFC 6455 control plane automatically:

| Incoming | Server behavior |
|----------|-----------------|
| `Ping` | Automatically replies with a `Pong` carrying the same payload |
| `Pong` | Ignored |
| `Close` | Echoes a `Close` back, then tears the connection down and fires `websocket.close` |

Your `message` handler is only ever called for **data** frames; control frames never reach it.

## Client: `new WebSocket(url)`

The client class is registered globally as `WebSocket`. Only one instance shape exists:

```js
// client.js
const ws = new WebSocket("ws://127.0.0.1:3000/ws");

ws.onopen = () => {
  console.log("open, state:", ws.readyState); // 1
  ws.send("hello");                              // text frame
  ws.send(new Uint8Array([9, 9]));               // binary frame (TypedArray)
};

ws.onmessage = (ev) => console.log("got:", ev.data);
ws.onclose = (ev) => console.log("closed:", ev.code, ev.reason);
ws.onerror = (ev) => console.error("ws error:", ev.message);
```

### Constructor

| Argument | Type | Required | Description |
|----------|------|----------|-------------|
| `url` | `string` | yes | `ws://…` (plain) or `wss://…` (TLS). Anything else throws |

Only `ws://` and `wss://` are accepted. `http://`/`https://` throw `TypeError: WebSocket: invalid WebSocket URL (expected ws:// or wss://)`.

The URL is parsed as `scheme://host[:port][path]`:

| Piece | Rule |
|-------|------|
| scheme | `ws://` → plain, default port `80`; `wss://` → TLS, default port `443` |
| host | required; max **255** bytes. DNS names are allowed (resolved by the OS) |
| port | optional; a non-numeric port makes the URL invalid |
| path | optional, defaults to `/`; max **512** bytes; a `#fragment` is stripped |

### Members

| Member | Description |
|--------|-------------|
| `send(data)` | `string` → text frame; `ArrayBuffer` / `TypedArray` → binary frame. Returns `undefined` |
| `close(code?, reason?)` | Begin a graceful close. `code` defaults to `1000`; `reason` is truncated to 123 bytes |
| `readyState` | `0` connecting, `1` open, `2` closing, `3` closed |

`send` is type-driven: only `string`, `ArrayBuffer`, or a buffer view produce a frame. A number, object, or `null` is silently ignored. An empty string sends nothing. Sending while not open (still connecting, or after close) is a no-op.

`close(code, reason)` sets `readyState` to `2` immediately and sends a Close frame; when the peer (or the ~5s timeout) completes the handshake, `readyState` becomes `3` and `onclose` fires.

### Constants

Both the constructor and each instance expose the four state constants:

```js
WebSocket.CONNECTING // 0     ws.CONNECTING // 0
WebSocket.OPEN       // 1     ws.OPEN       // 1
WebSocket.CLOSING    // 2     ws.CLOSING    // 2
WebSocket.CLOSED     // 3     ws.CLOSED     // 3

ws.readyState === WebSocket.OPEN; // true once onopen has fired
```

### Events

There is **no `addEventListener`**. Assign the handler properties:

| Property | Event object fields | When |
|----------|---------------------|------|
| `onopen` | `type` | Handshake completed |
| `onmessage` | `type`, `data` (`string` or `Uint8Array`) | One message received |
| `onerror` | `type`, `message` (string, **not** an `Error`) | A connection/handshake failure, just before `onclose` |
| `onclose` | `type`, `code` (number), `reason` (string) | Connection closed |

Every event has a `type` string (`"open"`, `"message"`, `"error"`, `"close"`).

### Client errors

**Synchronous constructor mistakes** throw a `TypeError` immediately. Every message is prefixed with `WebSocket: `:

```js
new WebSocket();                    // TypeError: WebSocket: WebSocket constructor requires a URL
new WebSocket(123);                 // TypeError: WebSocket: WebSocket URL must be a string
new WebSocket("http://x/");         // TypeError: WebSocket: invalid WebSocket URL (expected ws:// or wss://)
```

With all 64 client slots taken, the constructor throws `TypeError: WebSocket: WebSocket: no connection slots available`.

**Runtime failures** (refused, unreachable, TLS problem, bad handshake) do not throw. The worker reports them by setting an error message on the slot, and the main thread fires `onerror` **first** (with a string `.message`), then `onclose` with `.code === 1006` and an empty `.reason`:

```js
ws.onerror = (ev) => console.error("ws error:", ev.message); // plain string
ws.onclose = (ev) => console.log("closed:", ev.code, ev.reason); // 1006, ""
```

The `.message` values are `"connect failed"`, `"handshake failed"`, `"invalid host"`, or `"invalid url"`. If a close is initiated with no error recorded, `onerror` does **not** fire — you get only `onclose`.

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

## Reference: limits

| Area | Limit | When hit |
|------|-------|----------|
| Server connections | 512 per process | Listener stops accepting; extra clients cannot connect |
| Client sockets | 64 per process | Constructor throws `TypeError: WebSocket: … no connection slots available` |
| Message / frame size (server) | 16384 bytes | Oversized outbound send — or an oversized/fragmented inbound frame — closes the connection with code `1009` |
| Message / frame size (client) | 16384 bytes | An outbound `send` larger than the cap sends **nothing**; an inbound message larger than the cap closes the connection (`1009`) |
| Client URL host | 255 bytes | Constructor throws |
| Client URL path | 512 bytes | Constructor throws |
| Server handshake request | 4096 bytes of headers | Not a WS frame limit — the whole HTTP request header block must fit the server read buffer |
| Close reason | 123 bytes | Truncated (client) |
| Server socket API | `send` / `sendBinary` only | No `id`, `readyState`, or `close` server-side |

> The server **closes** an over-limit connection (`1009`); the client **drops** an over-limit `send` silently. Size your payloads below 16384 bytes on both ends.

## Troubleshooting

**Upgrade never fires** — the `websocket` block must be present (an object), and the request must carry a `Sec-WebSocket-Key` header. No handler branch is needed: the upgrade happens before the handler runs.

**`socket.id` is undefined** — by design. Use a `Set` of socket objects; `peers.has(socket)` is the identity check.

**Binary arrives as `Uint8Array`, not string** — check `typeof data === "string"` first, per the table above.

**`ws.sendBinary` is not a function (client)** — `sendBinary` exists only on **server** sockets. On the client, pass bytes to `send`: `ws.send(new Uint8Array([…]))`.

**Client connect fails** — confirm the `ws://`/`wss://` scheme and that the host/path fit the limits above. For `wss://` to a private CA, the same trust rules as `fetch` apply (`--ca` for `ff <file>`/`ff -e`, `FF_CA_FILE` for `ff start`).

**`onerror` fires with a string message then `onclose` with `1006`** — that is a runtime connect/handshake failure (see Client errors). Nothing was thrown.

## See also

- [WebSocket guide](/docs/guides/websocket) — tutorial version of this page
- [http](/docs/api/http) — the `websocket` server option
- [udp](/docs/api/udp) — raw datagram transport
- [Limitations](/docs/reference/limitations) — every hard cap
