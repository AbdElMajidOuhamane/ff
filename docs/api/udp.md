---
title: udp API
description: udp.socket reference — POSIX-style datagram sockets: bind, sendto, recvfrom, and connected send/recv.
order: 6
---

# `udp` API

Native UDP datagram sockets, exposed with the literal POSIX call names:
`sock.bind`, `sock.connect`, `sock.sendto`, `sock.recvfrom`, `sock.send`,
`sock.recv`, `sock.getsockname`, `sock.getpeername`, `sock.close`. If you've
written a UDP socket in C, the shape is already familiar — only the
promise-based `sendto` / `recvfrom` are new.

Payloads are **binary only** (`Uint8Array` / `ArrayBuffer`) and addresses
are **IP literals only** — there is no DNS lookup on this path. Sending and
receiving are asynchronous; `bind`, `connect`, `getsockname`, `getpeername`,
and `close` are synchronous.

## Quick look

```js
// echo.js — two sockets in one process
(async () => {
  const server = udp.socket();
  server.bind({ address: "127.0.0.1" });          // port 0 → ephemeral
  const port = server.getsockname().port;

  const client = udp.socket();
  const sent = await client.sendto(new TextEncoder().encode("ping"), {
    address: "127.0.0.1",
    port,
  });

  const buf = new Uint8Array(1500);
  const [data, from] = await server.recvfrom(buf);
  console.log(from.address, from.port, sent, new TextDecoder().decode(data));

  server.close();
  client.close();
})();
```

```sh
ff echo.js
# 127.0.0.1 54321 4 ping
```

## Modules vs scripts

`ff` treats a file as an ES module only when its name ends in `.mjs` or
its first code is `import`/`export`. A plain `.js` file runs as a classic
script, where top-level `await` is a syntax error — so the examples on
this page wrap async code in `(async () => { ... })()`. Save any of them
with a `.mjs` extension if you'd rather use top-level `await` as written.

## `udp.socket(family?)`

Creates a UDP socket — the equivalent of `socket(2)`.

```js
const a = udp.socket();        // "inet"  — AF_INET
const b = udp.socket("inet");  // explicit IPv4
const c = udp.socket("inet6"); // AF_INET6
```

| Argument | Values | Default |
|----------|--------|---------|
| `family` | `"inet"`, `"inet6"` | `"inet"` |

| Situation | Result |
|-----------|--------|
| Unknown family string | throws `udp.socket: family must be "inet" or "inet6"` |
| Non-string `family` argument | ignored — IPv4 (`"inet"`) is used |
| All 64 sockets in use | throws `udp.socket: no socket slots available` |

A socket is not bound by creation. Its local address starts as the
family's wildcard (`0.0.0.0:0` or `[::]:0`), and the kernel assigns an
ephemeral local port on the first `bind`, `connect`, or `sendto`.

## Methods

| Method | Kind | Description |
|--------|------|-------------|
| `bind(opts)` | sync | `bind(2)` — set the local address/port |
| `connect(opts)` | sync | `connect(2)` — set the default peer |
| `sendto(data, addr)` | `Promise<number>` | `sendto(2)` — send one datagram to `addr` |
| `recvfrom(buf)` | `Promise<[view, addr]>` | `recvfrom(2)` — receive one datagram + sender |
| `send(data)` | `Promise<number>` | `send(2)` — connected sockets only |
| `recv(buf)` | `Promise<view>` | `recv(2)` — connected sockets only |
| `getsockname()` | sync | `getsockname(2)` — local `{ address, port, family }` |
| `getpeername()` | sync | `getpeername(2)` — peer `{ address, port, family }` |
| `close()` | sync | `close(2)` — idempotent; rejects pending ops |

### `bind({ address?, port? })`

```js
sock.bind({});                              // 0.0.0.0, ephemeral port
sock.bind({ address: "127.0.0.1" });        // IPv4 loopback, ephemeral port
sock.bind({ address: "127.0.0.1", port: 9000 });
sock.bind({ address: "::1", port: 9000 });  // on an "inet6" socket
```

| Option | Type | Default |
|--------|------|---------|
| `address` | `string` (IP literal) | `"0.0.0.0"` (`"::"` on an `"inet6"` socket) |
| `port` | `number` 0–65535 | `0` (kernel picks an ephemeral port) |

A missing `address` falls back to the wildcard; a non-string `address` is
treated as missing. A missing or non-numeric `port` defaults to `0`. The
address must match the socket's family — binding `"127.0.0.1"` on an
`"inet6"` socket fails.

Read the chosen port back with `sock.getsockname().port`. Invalid input
throws (`bind: invalid address`, `bind: invalid port`, or
`bind: failed (address in use?)`).

### `connect({ address, port })`

Both fields are **required**. `connect(2)` on a UDP socket doesn't do any
network handshake — it just records the default peer so you can use
`send` / `recv`:

```js
sock.connect({ address: "127.0.0.1", port: 9000 });
sock.getpeername(); // { address: "127.0.0.1", port: 9000, family: "inet" }
```

Missing pieces throw `connect: address required` / `connect: port required`;
a non-literal or mismatched address throws `connect: invalid address` or
`connect: <ErrorName>`.

### `await sock.sendto(data, { address, port })`

Sends one datagram and resolves with the number of bytes sent:

```js
const n = await sock.sendto(new Uint8Array([1, 2, 3]), {
  address: "127.0.0.1",
  port: 9000,
});
```

`data` may be an `ArrayBuffer`, a `Uint8Array`, or any typed-array view;
its bytes are copied out by the send. Both destination fields are
required (`sendto: address required` / `sendto: port required`), and the
address must be an IP literal (`sendto: invalid address`).

### `await sock.recvfrom(buf)`

Receives up to `buf.length` bytes and resolves with `[data, sender]`:

```js
const buf = new Uint8Array(1500);
const [data, from] = await sock.recvfrom(buf);
// data — Uint8Array view of the received bytes (see Zero-copy below)
// from — { address: "127.0.0.1", port: 54321, family: "inet" }
```

`buf` must be a `Uint8Array` or `ArrayBuffer` (otherwise
`recvfrom: NotABuffer`). Only **one receive** may be pending per socket; a
second `recvfrom` before the first settles throws `recvfrom: RecvPending`.
`recvfrom` works on connected sockets too, still reporting the sender.

### `await sock.send(data)` / `await sock.recv(buf)`

Connected-socket forms that skip the address argument. Both throw
`send: socket is not connected` / `recv: socket is not connected` when the
socket hasn't been connected. `recv` resolves the data view directly (no
sender object):

```js
sock.connect({ address: "127.0.0.1", port: 9000 });
await sock.send(new TextEncoder().encode("ping"));

const buf = new Uint8Array(1500);
const data = await sock.recv(buf);
```

`send`/`recv` accept the same `data` / `buf` types as `sendto` /
`recvfrom`. On a connected socket the send uses the OS `send(2)` path and
skips the address argument entirely.

### `getsockname()` / `getpeername()`

Both return an address object. `getpeername()` throws
`getpeername: socket is not connected` until `connect` is called:

```js
const addr = sock.getsockname();
// { address: "0.0.0.0", port: 0, family: "inet" } — before bind
```

Before any bind the local address is the family wildcard with port `0`;
after `bind({ port: 0 })` it reports the kernel-assigned port.

### `close()`

Returns `undefined` immediately; safe to call twice. Pending
`sendto` / `recvfrom` promises reject with `recvfrom: socket closed` /
`send: socket closed`, further method calls throw `...: socket is closed`,
and the slot is recycled once the kernel side drains. Closing is also what
the GC finalizer does if you leak a socket.

```js
const p = sock.recvfrom(new Uint8Array(1500));
sock.close();
await p; // rejects: recvfrom: socket closed
```

## Data and buffers

| Direction | Accepted types | Result |
|-----------|----------------|--------|
| `send` / `sendto` data | `ArrayBuffer`, `Uint8Array`, any TypedArray view | bytes sent (number) |
| `recv` / `recvfrom` buffer | `Uint8Array` or `ArrayBuffer` only | zero-copy view of the received bytes |

`recvfrom` / `recv` are **zero-copy**: the resolved view aliases your buffer.

- `Uint8Array` input → `buf.subarray(0, n)` (same backing `ArrayBuffer`,
  same element layout).
- `ArrayBuffer` input → `new Uint8Array(buf, 0, n)`.

The view is valid as long as you still hold `buf` — the operation keeps the
backing store alive until it settles.

If the datagram is larger than your buffer, it is truncated to
`buf.length` and the rest is discarded (standard UDP behavior — size your
buffer to 65507 if that matters).

## Addresses

Address objects always have this shape:

```js
const peer = { address: "2001:db8::1", port: 9000, family: "inet6" };
```

- `address` — IP literal. IPv4 is dotted-decimal; IPv6 uses the RFC 5952
  compressed form (`::1`, `2001:db8::1`) with lowercase hex and the
  longest zero run compressed.
- `port` — `0`–`65535`.
- `family` — `"inet"` or `"inet6"`.
- No DNS: `"example.com"` is rejected with `...: invalid address`.

## Errors

Two shapes. **Argument/state validation throws synchronously** (a `bind`,
`connect`, `getsockname`, or `getpeername` call). **Send/receive failures
reject the returned promise** (a `send`/`sendto`/`recv`/`recvfrom` call).

| Message | Thrown / rejected by |
|---------|----------------------|
| `udp.socket: family must be "inet" or "inet6"` | `udp.socket(family)` |
| `udp.socket: no socket slots available` | `udp.socket()` — 64 in use |
| `bind: options object required ({ address?, port? })` | `bind` without an object |
| `bind: invalid address` / `bind: invalid port` | `bind` argument validation |
| `bind: failed (address in use?)` | `bind(2)` failed |
| `connect: options object required ({ address, port })` | `connect` without an object |
| `connect: address required` / `connect: port required` | `connect` missing a field |
| `connect: invalid address` | non-literal / family mismatch |
| `sendto: requires (data, { address, port })` | `sendto` without a destination object |
| `sendto: address required` / `sendto: port required` | `sendto` destination validation |
| `sendto: invalid address` | destination is not an IP literal |
| `send: requires data (ArrayBuffer or TypedArray)` | `send` without data |
| `send: socket is not connected` / `recv: socket is not connected` | connected-only methods |
| `send: MessageTooLong` | data > 65507 bytes |
| `send: NotABuffer` | data is not a buffer |
| `send: SendQueueFull` | more than 64 sends in flight |
| `recvfrom: NotABuffer` | buffer isn't `Uint8Array` / `ArrayBuffer` |
| `recvfrom: RecvPending` | a second receive while one is pending |
| `send failed` / `recvfrom failed` | the OS send/receive failed |
| `...: socket is closed` | any method after `close()` |
| `...: socket closed` | **rejection** of an op pending at `close()` |

> `MessageTooLong`, `SendQueueFull`, and `NotABuffer` are rejected on the
> promise for send paths; the notes above call out the two that target
> `send` specifically.

## Full example

```js
// udp-echo.js — connected client pings an echo server; both in one process.
(async () => {
  const server = udp.socket();
  server.bind({ address: "127.0.0.1" });
  const port = server.getsockname().port;

  // Server: reply to one datagram, then stop.
  const serving = (async () => {
    const buf = new Uint8Array(1500);
    const [data, from] = await server.recvfrom(buf);
    await server.sendto(data, { address: from.address, port: from.port });
    server.close();
  })();

  // Connected client
  const client = udp.socket();
  client.connect({ address: "127.0.0.1", port });

  await client.send(new TextEncoder().encode("ping"));
  const reply = await client.recv(new Uint8Array(1500));
  console.log(new TextDecoder().decode(reply)); // ping

  await serving;
  client.close();
})();
```

```sh
ff udp-echo.js
# ping
```

## IPv6 example

```js
// udp6.js
(async () => {
  const server = udp.socket("inet6");
  server.bind({ address: "::1", port: 0 });
  const { port } = server.getsockname();

  const client = udp.socket("inet6");
  client.connect({ address: "::1", port });
  await client.send(new TextEncoder().encode("v6"));

  const [data, from] = await server.recvfrom(new Uint8Array(64));
  console.log(from.family, from.address, new TextDecoder().decode(data));
  // inet6 ::1 v6

  server.close();
  client.close();
})();
```

## Limits

| Limit | Value |
|-------|-------|
| Concurrent sockets | 64 (shared pool) |
| In-flight sends | 64 |
| Maximum datagram | 65507 bytes (larger sends reject with `send: MessageTooLong`) |
| Pending receives per socket | 1 |
| Addresses | IP literals only (no DNS) |
| Missing features | no `setsockopt`, no multicast, no broadcast helpers, no DNS |

## See also

- [WebSocket](/docs/api/websocket) — message-framed transport over TCP
- [http](/docs/api/http) — TCP servers
- [API overview](/docs/api/overview) — every injected global
- [Limitations](/docs/reference/limitations) — every hard cap
