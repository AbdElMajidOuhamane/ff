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
are **IP literals only** — there is no DNS lookup on this path.

## Permissions

UDP needs `--allow-net` on the addresses it uses:

| Call | Checked scope |
|---|---|
| `bind({ address, port })` | Local address and port |
| `connect({ address, port })` | Peer address and port |
| `sendto(data, { address, port })` | Destination address and port |
| `send(data)` | None — inherits the grant from `connect` |
| `recv(buf)` / `recvfrom(buf)` | None — no source filter |

```sh
ff echo.js --allow-net=127.0.0.1
```

- Addresses are **IP literals**, so there is no DNS or hostname matching.
  `--allow-net=localhost` does not cover `127.0.0.1`.
- A scope with no port matches every port. That is the usual choice for
  ephemeral binds: `--allow-net=127.0.0.1`.
- Port `0` is checked **literally** for an ephemeral bind. A scope like
  `--allow-net=127.0.0.1:9000` will deny `bind({ address: "127.0.0.1" })`,
  because the check runs with port `0` before the kernel picks one.
- IPv6 addresses with a port need brackets in the flag:
  `--allow-net=[::1]:9000`. Without a port, `--allow-net=::1` is fine.
- Denial is synchronous and uses the standard shape:

```js
try {
  sock.bind({ address: "127.0.0.1", port: 9000 });
} catch (e) {
  console.error(e.name, e.code); // PermissionDenied PERMISSION_DENIED
  console.error(e.message);      // udp.bind requires --allow-net for '127.0.0.1:9000'
}
```

`connect` and `sendto` throw the same way, before any promise is created or
any datagram is sent. `send` on a connected socket does not re-check the
destination; the `connect` grant is reused.

> **Incoming traffic is not filtered.** UDP is connectionless: once a socket
> is bound, `recv` / `recvfrom` accept datagrams from **any** source, even
> sources outside every `--allow-net` scope. Binding to `0.0.0.0` exposes the
> socket on all interfaces. Filter `from.address` in JavaScript when source
> identity matters.

Full model: [Permissions](/docs/concepts/permissions).

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
ff echo.js --allow-net=127.0.0.1
# 127.0.0.1 54321 4 ping
```

## Modules vs scripts

`ff` treats a file as an ES module only when its name ends in `.mjs` or
its first code is `import`/`export`. A plain `.js` file runs as a classic
script, where top-level `await` is a syntax error — so the examples on
this page wrap async code in `(async () => { ... })()`. Save any of them
with a `.mjs` extension if you'd rather use top-level `await` as written.

## `udp.socket(family?)`

Creates a UDP socket — the equivalent of `socket(2)`. Creating a socket is not
permission-gated; `bind`, `connect`, and `sendto` are.

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
| All 64 sockets in use | throws `udp.socket: no socket slots available` |

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
| `address` | `string` (IP literal) | `"0.0.0.0"` (`"::"` for `inet6`) |
| `port` | `number` 0–65535 | `0` (kernel picks an ephemeral port) |

Read the chosen port back with `sock.getsockname().port`. Invalid input
throws (`bind: invalid address`, `bind: invalid port`, or
`bind: failed (address in use?)`).

The permission check uses the **requested** address and port. For an ephemeral
bind that means port `0`; use a portless scope unless you pin the port.

```sh
ff server.js --allow-net=127.0.0.1        # ephemeral or any port
ff server.js --allow-net=127.0.0.1:9000   # only port 9000
```

### `connect({ address, port })`

Both fields are **required**. `connect(2)` on a UDP socket doesn't do any
network handshake — it just records the default peer so you can use
`send` / `recv`:

```js
sock.connect({ address: "127.0.0.1", port: 9000 });
sock.getpeername(); // { address: "127.0.0.1", port: 9000, family: "inet" }
```

`connect` is permission-checked against the peer:

```sh
ff client.js --allow-net=127.0.0.1:9000
```

### `await sock.sendto(data, { address, port })`

Sends one datagram and resolves with the number of bytes sent:

```js
const n = await sock.sendto(new Uint8Array([1, 2, 3]), {
  address: "127.0.0.1",
  port: 9000,
});
```

`sendto` is checked against the destination on every call:

```sh
ff client.js --allow-net=127.0.0.1:9000
```

A denial throws synchronously, before the promise is returned.

### `await sock.recvfrom(buf)`

Receives up to `buf.length` bytes and resolves with `[data, sender]`:

```js
const buf = new Uint8Array(1500);
const [data, from] = await sock.recvfrom(buf);
// data — Uint8Array view of the received bytes (see Zero-copy below)
// from — { address: "127.0.0.1", port: 54321, family: "inet" }
```

Only **one receive** may be pending per socket; a second `recvfrom` before
the first settles throws `recvfrom: RecvPending`. `recvfrom` does not check
the sender against `--allow-net` — see the permissions caveat above.

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

`send` reuses the grant made at `connect` time; there is no per-packet check.

### `getsockname()` / `getpeername()`

Both return an address object. `getpeername()` throws
`getpeername: socket is not connected` until `connect` is called:

```js
const addr = sock.getsockname();
// { address: "0.0.0.0", port: 0, family: "inet" } — before bind
```

### `close()`

Returns `undefined` immediately; safe to call twice. Pending
`sendto` / `recvfrom` promises reject with `...: socket closed`, further
method calls throw `...: socket is closed`, and the slot is recycled once
the kernel side drains. Closing is also what the GC finalizer does if you
leak a socket.

```js
const p = sock.recvfrom(new Uint8Array(1500));
sock.close();
await p; // rejects: recvfrom: socket closed
```

## Data and buffers

| Direction | Accepted types | Result |
|-----------|----------------|--------|
| `send` / `sendto` data | `ArrayBuffer`, `Uint8Array`, any TypedArray view | bytes sent (number) |
| `recv` / `recvfrom` buffer | `Uint8Array` or `ArrayBuffer` | zero-copy view of the received bytes |

`recvfrom` is **zero-copy**: the resolved view aliases your buffer.

- `Uint8Array` input → `buf.subarray(0, n)` (same backing `ArrayBuffer`,
  same `byteOffset`).
- `ArrayBuffer` input → `new Uint8Array(buf, 0, n)`.

If the datagram is larger than your buffer, it is truncated to
`buf.length` and the rest is discarded (standard UDP behavior — size your
buffer to 65507 if that matters).

## Addresses

Address objects always have this shape:

```js
{ address: "2001:db8::1", port: 9000, family: "inet6" }
```

- `address` — IP literal. IPv6 uses the RFC 5952 compressed form
  (`::1`, `2001:db8::1`).
- `family` — `"inet"` or `"inet6"`.
- No DNS: `"example.com"` is rejected with `...: invalid address`.

## Errors

| Message | Thrown by |
|---------|-----------|
| `udp.socket: family must be "inet" or "inet6"` | `udp.socket(family)` |
| `udp.socket: no socket slots available` | `udp.socket()` — 64 in use |
| `udp.bind requires --allow-net for 'addr:port'` | `bind` outside the net scope |
| `udp.connect requires --allow-net for 'addr:port'` | `connect` outside the net scope |
| `udp.sendto requires --allow-net for 'addr:port'` | `sendto` outside the net scope |
| `bind: invalid address` / `bind: invalid port` | `bind` argument validation |
| `bind: failed (address in use?)` | `bind(2)` failed |
| `connect: address required` / `connect: port required` | `connect` without both fields |
| `sendto: address required` / `sendto: port required` | `sendto` destination validation |
| `send: socket is not connected` / `recv: socket is not connected` | connected-only methods |
| `send: MessageTooLong` | data > 65507 bytes |
| `recvfrom: NotABuffer` | buffer isn't `Uint8Array` / `ArrayBuffer` |
| `...: socket is closed` | any method after `close()` |
| `...: socket closed` | **rejection** of a promise pending at `close()` |

Permission errors are `Error` objects with `name: "PermissionDenied"` and
`code: "PERMISSION_DENIED"`; the rest are `TypeError`s with plain messages.

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
ff udp-echo.js --allow-net=127.0.0.1
# ping
```

One portless scope covers the ephemeral server port, the dynamic `sendto`
destination, and the connected client's peer.

## Limits

| Limit | Value |
|-------|-------|
| Concurrent sockets | 64 (shared pool) |
| In-flight `sendto` calls | 64 |
| Maximum datagram | 65507 bytes |
| Pending receives per socket | 1 |
| Addresses | IP literals only (no DNS) |
| Permission scope | `bind`, `connect`, `sendto`; incoming sources are not filtered |
| Missing features | no `setsockopt`, multicast, or broadcast helpers |

## See also

- [Permissions](/docs/concepts/permissions) — flags, scopes, denial contract
- [WebSocket](/docs/api/websocket) — message-framed transport over TCP
- [http](/docs/api/http) — TCP servers
- [API overview](/docs/api/overview) — every injected global
- [Limitations](/docs/reference/limitations) — every hard cap
