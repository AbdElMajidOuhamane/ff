---
title: WebSocket
description: Real-time chat-style messaging — server upgrades, broadcast, and clients.
order: 3
---

# WebSocket

Fairyfly speaks WebSocket on both sides: upgrade HTTP clients with the `websocket` option (server), or dial out with `new WebSocket(url)` (client). Server and client share the frame protocol but have different APIs — this guide covers both.

## Permissions

Both sides need `--allow-net`:

| Side | Scope checked |
|---|---|
| Server | The underlying `http.serve({ port })` — always `0.0.0.0:<port>`. The `websocket` block adds no separate flag. |
| Client | The URL passed to `new WebSocket(...)` — `host:port`. |

```sh
ff server.js --allow-net=0.0.0.0:3000
ff client.js --allow-net=127.0.0.1:3000
```

- `ws://` defaults to port `80`, `wss://` to `443`. A scope without a port
  matches any port.
- Matching uses the literal host, lowercased. There is no DNS matching:
  `localhost` and `127.0.0.1` are different scopes. `*.example.com` matches
  subdomains but not the apex; `*` grants every host.
- The handshake does not follow redirects, so the client checks once, in the
  constructor.
- TLS trust (`--ca`, `FF_CA_FILE`) is separate and does not grant access.
  Proxy variables need no `--allow-env`; the net check applies to the target,
  not the proxy host.

A denied client URL throws synchronously from the constructor:

```js
try {
  new WebSocket("ws://127.0.0.1:3000/ws");
} catch (e) {
  console.error(e.name, e.code); // PermissionDenied PERMISSION_DENIED
  console.error(e.message);      // WebSocket requires --allow-net for '127.0.0.1:3000'
}
```

Full model: [Permissions](/docs/concepts/permissions).

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
ff server.js --allow-net=0.0.0.0:3000
# in another terminal:
ff client.js --allow-net=127.0.0.1:3000
# got: welcome
# (server echoes "hello" back: got: hello)
```

## Server: upgrading connections

Add a `websocket` block to the options. Its presence enables upgrades; the upgrade itself fires when a request arrives with the handshake headers (`Connection: Upgrade`, `Upgrade: websocket`, `Sec-WebSocket-Key`) — on any path, before your handler runs. The handler only ever sees plain HTTP, so it returns normal responses for every path:

```js
http.serve(
  { port: 3000, websocket: { open, message, close } },
  (url, method, body) => new Response("not found", { status: 404 }),
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

The upgrade shares the listener's net grant; no separate WebSocket flag exists.

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
  (url, method, body) => new Response(`online: ${peers.size}`),
);
```

```sh
ff server.js --allow-net=0.0.0.0:3000
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

```sh
ff client.js --allow-net=127.0.0.1:3000
```

For `wss://`, grant the TLS port:

```sh
ff client.js --allow-net=api.example.com:443
```

| Member | Description |
|--------|-------------|
| `send(data)` | Send text (`string`) |
| `sendBinary(buf)` | Send bytes (`ArrayBuffer` / `Uint8Array`) |
| `close(code?, reason?)` | Graceful close, e.g. `ws.close(1000, "done")` |
| `readyState` | `0` connecting, `1` open, `2` closing, `3` closed |
| `onopen` / `onmessage` / `onclose` / `onerror` | Event handlers; `ev.data` is `string` or `Uint8Array` |

Only `ws://` and `wss://` URLs are accepted. For `wss://` to private CAs, the same trust rules as `fetch` apply (`--ca` for scripts, `FF_CA_FILE` for `ff start`). Trust does not replace `--allow-net` — you need both.

### Client errors

Several shapes, depending on when the failure happens. Synchronous mistakes
throw immediately — the message starts with a `WebSocket: ` prefix:

```js
new WebSocket("http://localhost:3000/");
// TypeError: WebSocket: invalid WebSocket URL (expected ws:// or wss://)
new WebSocket();
// TypeError: WebSocket: WebSocket constructor requires a URL
```

A denied target also throws synchronously, but is a `PermissionDenied` error:

```js
new WebSocket("ws://127.0.0.1:3000/");
// Error: WebSocket requires --allow-net for '127.0.0.1:3000'
// e.name === "PermissionDenied", e.code === "PERMISSION_DENIED"
```

A failed connection at runtime (refused, unreachable) does **not** throw
and does **not** fire `onerror` — you get a bare `onclose`. When the close
does carry an error, `onerror` fires first with an event whose `.message`
is a string (not an `Error`), immediately followed by `onclose`, whose
event carries numeric `.code` and string `.reason`:

```js
ws.onerror = (ev) => console.error("ws error:", ev.message);
ws.onclose = (ev) => console.log("closed:", ev.code, ev.reason);
```

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
ff presence.js --allow-net=0.0.0.0:3000
curl http://127.0.0.1:3000/   # online: 0
# connect two clients -> each receives "online: 1", then "online: 2"
```

Connect the clients with `--allow-net=127.0.0.1:3000`.

## Reference: limits

| Area | Limit | When hit |
|------|-------|----------|
| Client sockets | 64 per process | Extra connects fail |
| Message size | 16384 bytes | Larger frames truncate |
| Handshake URL path | 512 bytes | Longer paths fail |
| Server socket API | `send` / `sendBinary` only | No `id`, `readyState`, or `close` server-side |
| Permission scope | Listener: `0.0.0.0:<port>`; client: URL host and port | Denied before the socket opens |

## Troubleshooting

**`new WebSocket` throws `PermissionDenied`** — the URL's host and port are
outside every `--allow-net` scope. Add the target exactly as written:
`ws://127.0.0.1:3000` needs `--allow-net=127.0.0.1:3000`. `localhost` will
not match `127.0.0.1`.

**Server starts but clients cannot connect** — the listener is checked as
`0.0.0.0:<port>`, even for loopback clients. Grant
`--allow-net=0.0.0.0:3000`, not `127.0.0.1:3000`.

**Upgrade never fires** — the `websocket` block must be present, and the client must send the handshake headers (`Connection: Upgrade`, `Upgrade: websocket`, `Sec-WebSocket-Key` — any real WS client does). No handler branch is needed: the upgrade happens before the handler runs.

**`socket.id` is undefined** — by design. Use a `Set` of socket objects; `peers.has(socket)` is the identity check.

**Binary arrives as `Uint8Array`, not string** — check `typeof data === "string"` first, per the table above.

**Client connect fails** — confirm the `ws://`/`wss://` scheme, the 512-byte path limit, the `--allow-net` target, and (for `wss://`) the CA trust setup from the fetch guide.

## See also

- [Permissions](/docs/concepts/permissions) — flags, scopes, denial contract
- [WebSocket API](/docs/api/websocket) — full reference and proxy notes
- [HTTP Server guide](/docs/guides/http-server) — the underlying listener
- [Limitations](/docs/reference/limitations) — every hard cap
