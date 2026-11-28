---
title: tcp API
description: Direct TCP client sockets via tcp.connect(hostname, port) — IP literals only, 16 KB buffers, --allow-net gated.
order: 19
---

# `tcp` API

Non-blocking outbound TCP client sockets exposed on the global `tcp` object. Client-only (`tcp.connect` only — no listening servers, no TLS upgrade, no half-close, and **IPv4/IPv6 literals only** with no DNS lookup).

## Permissions

`tcp.connect` requires `--allow-net` for the target `<hostname>:<port>`:

```sh
ff client.js --allow-net=127.0.0.1:9000
```

- Denial is synchronous before any socket or Promise is created:
  - `e.name === "PermissionDenied"`, `e.code === "PERMISSION_DENIED"`
  - `e.message`: `tcp.connect requires --allow-net for '<hostname>:<port>'`
- IPv6 ports require brackets in the CLI flag (`--allow-net=[::1]:9000`).
- Full model: [Permissions](/docs/concepts/permissions).

## Quick look

```js
const sock = await tcp.connect("127.0.0.1", 9000);
const sent = await sock.write("HELLO\n");
const chunk = await sock.read();
if (chunk !== null) {
  console.log(sent, new TextDecoder().decode(chunk));
}
sock.close();
```

## `tcp.connect(hostname, port)`

```js
tcp.connect(hostname: string, port: number) → Promise<Socket>
```

| Detail | Behavior |
|---|---|
| `hostname` | IPv4 or IPv6 literal string (e.g. `"127.0.0.1"`, `"::1"`). Hostnames like `"localhost"` throw `TypeError: invalid IPv4/IPv6 address for tcp.connect`. |
| `port` | Integer `1..65535`. Out of range throws `TypeError: port out of range (1..65535)`. |
| Invalid arguments | Missing or wrong-type arguments throw `TypeError: tcp.connect requires (hostname, port)`. |
| Pool exhaustion | Exceeding `128` concurrent sockets throws `TypeError: max TCP connections exceeded (128)` synchronously. |
| Connection failure | Rejects the returned Promise with a plain string `"connect failed: <ErrorName>"` (and releases the slot). |

## `Socket` methods

| Method | Signature | Description |
|---|---|---|
| `sock.read()` | `() → Promise<Uint8Array \| null>` | Reads up to `16384` bytes (`16 KB`), returning a `Uint8Array` copy or `null` on EOF. Only 1 concurrent `read()` may be in flight; a second throws `TypeError: concurrent read already in progress`. Rejects with `"read failed: <ErrorName>"` or `"socket closed"`. |
| `sock.write(data)` | `(Uint8Array \| string) → Promise<number>` | Writes up to `16384` bytes (`16 KB`) and resolves with bytes written. Larger payloads throw `TypeError: write payload exceeds buffer size (16KB)`. Only 1 concurrent `write()` may be in flight (`TypeError: concurrent write already in progress`). Rejects with `"write failed: <ErrorName>"` or `"socket closed"`. |
| `sock.close()` | `() → undefined` | Synchronous and idempotent. Cancels pending loop operations, rejects any in-flight `read()` / `write()` Promises with `"socket closed"`, closes the fd, and frees the slot. |

- **Pass `Uint8Array` or `string` to `sock.write()`:** raw `ArrayBuffer` arguments are coerced as objects (`"[object ArrayBuffer]"`). Calling `sock.write()` with no arguments returns `undefined` instead of a Promise.
- Calling `read()` or `write()` on a closed or invalid socket throws `TypeError: socket not connected or invalid` (or `TypeError: socket not connected`).
- Pending `connect()`, `read()`, and `write()` calls keep the event loop alive while in flight. Leaked sockets are also closed when garbage collected.

## Limits

| Area | Cap | When hit |
|---|---|---|
| Concurrent TCP sockets | `128` | `TypeError: max TCP connections exceeded (128)` |
| Read chunk size | `16384` bytes (`16 KB`) | Larger incoming streams arrive across multiple `read()` calls |
| Write payload size | `16384` bytes (`16 KB`) | `TypeError: write payload exceeds buffer size (16KB)` |
| Concurrent ops per socket | `1` read + `1` write | `TypeError: concurrent read already in progress` / `concurrent write already in progress` |
| Addresses | IPv4 / IPv6 literals only | No DNS resolution (`TypeError`) |

## Related

- [`udp` API](/docs/api/udp)
- [`http` API](/docs/api/http)
- [Permissions](/docs/concepts/permissions)
