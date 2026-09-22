---
title: WebSocket
description: Real-time chat-style messaging — server upgrades, broadcast, and clients.
order: 3
---

# WebSocket

Fairyfly speaks WebSocket on both sides: upgrade HTTP clients with the `websocket` option (server), or dial out with `new WebSocket(url)` (client). Server and client share the frame protocol but have different APIs — this guide covers both.

## Quick look: echo server + client

Server (`server.js`) — upgrade on `/ws`, echo everything back:

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
  (url, method, body) => {
    if (url === "/ws") return { status: 101 };
    return new Response("http here, ws on /ws");
  },
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

## Server: upgrading connections

Add a `websocket` block to the options. Its presence enables upgrades; the upgrade itself fires when a request arrives with a `Sec-WebSocket-Key` header. On the WebSocket path, your handler returns `{ status: 101 }` — every other path returns normal HTTP:

```js
http.serve(
  { port: 3000, websocket: { open, message, close } },
  (url, method, body) => {
    if (url === "/ws") return { status: 101 };
    return new Response("not found", { status: 404 });
  },
);
```

| Handler | Fires | Arguments |
|---------|-------|-----------|
| `open` | Client completes the upgrade | `(socket)` |
| `message` | Per frame | `(socket, data)` — `string` for text, `Uint8Array` for binary |
| `close` | Client disconnects | `(socket)` |

Always check the type of `data` first — text and binary arrive differently:

```js
message: (socket, data) => {
  if (typeof data === "string") console.log("text:", data);
  else console.log("binary bytes:", data.length);
},
```

## Server: sending and broadcast

Server sockets have exactly two methods — `send` (text) and `sendBinary` (bytes). There is no `socket.id`, no `readyState`, and no server-side `close`. Identify peers by object reference in a `Set`:

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
  (url, method, body) => {
    if (url === "/room") return { status: 101 };
    return new Response(`online: ${peers.size}`);
  },
);
```

```sh
ff server.js
curl http://127.0.0.1:3000/   # online: 0  (peers counted via Set size)
```

Send binary with `sendBinary`:

```js
socket.sendBinary(new Uint8Array([1, 2, 3]).buffer);
```

> **Caution:** `socket.send` after the client disconnected fails — always remove sockets in `close`, and never store an index or id on them (none exists).

## Client: connecting and messaging

```js
// client.js
const ws = new WebSocket("ws://127.0.0.1:3000/ws");

ws.onopen = () => {
  console.log("open, state:", ws.readyState); // 1
  ws.send("hello");
  ws.sendBinary(new Uint8Array([9, 9]).buffer);
};

ws.onmessage = (ev) => console.log("got:", ev.data);
ws.onclose = () => console.log("closed");
ws.onerror = (e) => console.error("ws error:", e.message);
```

| Member | Description |
|--------|-------------|
| `send(data)` | Send text (`string`) |
| `sendBinary(buf)` | Send bytes (`ArrayBuffer` / `Uint8Array`) |
| `close(code?, reason?)` | Graceful close, e.g. `ws.close(1000, "done")` |
| `readyState` | `0` connecting, `1` open, `2` closing, `3` closed |
| `onopen` / `onmessage` / `onclose` / `onerror` | Event handlers; `ev.data` is `string` or `Uint8Array` |

Only `ws://` and `wss://` URLs are accepted. For `wss://` to private CAs, the same trust rules as `fetch` apply (`--ca` for scripts, `FF_CA_FILE` for `ff start`).

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
  (url, method, body) => {
    if (url === "/presence") return { status: 101 };
    return new Response(count());
  },
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
| Client sockets | 64 per process | Extra connects fail |
| Message size | 16384 bytes | Larger frames truncate |
| Handshake URL path | 512 bytes | Longer paths fail |
| Server socket API | `send` / `sendBinary` only | No `id`, `readyState`, or `close` server-side |

## Troubleshooting

**Upgrade never fires** — the client must send `Sec-WebSocket-Key` (any real WS client does), the `websocket` block must be present, and the handler must return `{ status: 101 }` on that path.

**`socket.id` is undefined** — by design. Use a `Set` of socket objects; `peers.has(socket)` is the identity check.

**Binary arrives as `Uint8Array`, not string** — check `typeof data === "string"` first, per the table above.

**Client connect fails** — confirm the `ws://`/`wss://` scheme, the 512-byte path limit, and (for `wss://`) the CA trust setup from the fetch guide.
