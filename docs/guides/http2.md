---
title: HTTP/2
description: Serve HTTP/2 over TLS with ALPN — same handler, same port, no code changes.
order: 14
---

# HTTP/2

HTTP/2 works the moment TLS is on: pass `tls: { cert, key }` and the same port negotiates HTTP/1.1 or HTTP/2 per connection via ALPN (nghttp2). Plain (non-TLS) listeners stay HTTP/1.1 — there is no cleartext HTTP/2. Your handler doesn't change at all.

## Permissions

HTTP/2 is still an `http.serve` listener with TLS, so it uses the same grants
as the [TLS guide](/docs/guides/tls#permissions):

| Item | Needs |
|---|---|
| Listener | `--allow-net=0.0.0.0:<port>` |
| `tls.cert` / `tls.key` paths | `--allow-read` on each file |
| Inline PEM | No file grant |
| `--allow-env` | Only if the app reads `PORT` / cert paths from `process.env` |

```sh
ff server.js \
  --allow-net=0.0.0.0:8443 \
  --allow-read=./cert.pem,./key.pem
```

Denial is synchronous:

```js
try {
  http.serve({ port: 8443, tls: { cert: "./cert.pem", key: "./key.pem" } }, handler);
} catch (e) {
  console.error(e.name, e.code); // PermissionDenied PERMISSION_DENIED
  console.error(e.message);      // http.serve tls.cert requires --allow-read for './cert.pem'
}
```

The listener check runs first; if the port is outside `--allow-net`, that error
wins before the cert/key read checks.

Full model: [Permissions](/docs/concepts/permissions).

## Quick look

```js
// server.js
http.serve(
  {
    port: 8443,
    tls: { cert: "./cert.pem", key: "./key.pem" },
  },
  (url, method, body) => Response.json({ proto: "either — handler can't tell" }),
);
```

```sh
ff server.js \
  --allow-net=0.0.0.0:8443 \
  --allow-read=./cert.pem,./key.pem
curl -k https://127.0.0.1:8443/
# {"proto":"either — handler can't tell"}

curl -k --http2 https://127.0.0.1:8443/
# same body, HTTP/2 frames on the wire
```

Generate a dev cert if you don't have one (see the TLS guide for the full walkthrough):

```sh
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout key.pem -out cert.pem \
  -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost"
```

## How negotiation works

| Client offers (ALPN) | Gets |
|----------------------|------|
| `h2` (browsers, `curl --http2`, modern `fetch`) | HTTP/2 |
| `http/1.1` only (old clients, `curl` default) | HTTP/1.1 |
| No TLS at all | HTTP/1.1, always |

One port serves both — no second listener, no `http2: true` flag, no separate handler. Verify what's negotiated:

```sh
curl -k -s -o /dev/null -w "%{http_version}\n" https://127.0.0.1:8443/
# 1.1
curl -k --http2 -s -o /dev/null -w "%{http_version}\n" https://127.0.0.1:8443/
# 2
```

> **Note:** The `-k` flag accepts the self-signed dev cert — local testing only. Production uses a real CA cert; the runtime code is identical.

## What changes with HTTP/2 (and what doesn't)

Unchanged — write handlers exactly like the HTTP Server guide:

- Handler signature `(url, method, body)` → `Response | { status, body } | Promise<…>`.
- `Response.json` / `redirect` / statics, `Headers`, status codes — all identical.
- Limits still apply: 512 connections, 10 MB response body (64 KB stage buffer spills to the heap), 30s watchdog.
- WebSocket upgrades ride the HTTP/1.1 connections on the same port; `h2` connections serve normal requests.
- Permissions are unchanged: the port grant covers HTTP/2 and HTTP/1.1, and TLS file reads are still `read` scopes.

What you get from the protocol (handled by nghttp2, not your code):

- Multiplexed streams — many in-flight requests per connection.
- Header compression (HPACK) — smaller repeated headers.
- Server framing (Content-Length / Transfer-Encoding) computed for you, as with HTTP/1.1.

What you don't get:

- No server push API — there is no push handle on the socket.
- No trailers API — set all headers up front in the `Response`.
- No `fetch` upgrade — the **client is HTTP/1.1 only**. Outbound `fetch("https://h2-only.example")` fails; call HTTP/1.1-capable endpoints.

## Practical example: dual-protocol JSON API

Same file serves both protocols — old clients keep working, new ones get multiplexing:

```js
// api.js
const port = Number(process.env.PORT ?? 8443);

http.serve(
  {
    port,
    tls: { cert: process.env.TLS_CERT ?? "./cert.pem", key: process.env.TLS_KEY ?? "./key.pem" },
  },
  (url, method, body) => {
    const path = new URL(url, "http://localhost").pathname;
    if (path === "/health") return Response.json({ ok: true });
    if (path === "/echo" && method === "POST") {
      return Response.json({ youSent: JSON.parse(body || "{}") });
    }
    return new Response("not found", { status: 404 });
  },
);
```

```sh
TLS_CERT=./cert.pem TLS_KEY=./key.pem ff api.js \
  --allow-env=TLS_CERT,TLS_KEY \
  --allow-net=0.0.0.0:8443 \
  --allow-read=./cert.pem,./key.pem
curl -k https://127.0.0.1:8443/health
# {"ok":true}
curl -k --http2 -X POST https://127.0.0.1:8443/echo \
  -H "content-type: application/json" -d '{"a":1}'
# {"youSent":{"a":1}}
```

`process.env.TLS_CERT` / `TLS_KEY` need `--allow-env`; without it the `??`
fallbacks to `./cert.pem` / `./key.pem` are used. The read scopes must cover
whichever paths are actually used. If the app reads `PORT`, add `PORT` to the
env grant.

Behind a platform load balancer that terminates TLS, skip `tls` entirely and serve plain HTTP — the balancer speaks HTTP/2 to the internet for you. The listener still needs `--allow-net=0.0.0.0:<port>`.

## Troubleshooting

**`http.serve` throws `PermissionDenied`** — check the message: a net denial
names `0.0.0.0:<port>`; a TLS denial names `tls.cert` or `tls.key` and the
path. Add the listener port to `--allow-net` and each path to `--allow-read`.

**`tls.cert` is denied even though the file exists** — the path is outside
`--allow-read`, or a symlink target is. Add the canonical target (or its
directory) to the scope. Inline PEM avoids the read check but needs the
content in memory first.

**`curl` reports version 1.1** — the client didn't offer `h2`, or TLS isn't on. Confirm the `tls` block is present and retest with `curl --http2`.

**Handshake failure** — cert/key unreadable, over size caps (cert ≤ 512KB, key ≤ 256KB), or not a matching pair. Permission denial is separate and reports `PermissionDenied`; a malformed pair throws `TypeError` after the files are read. Start plain-HTTP first to isolate app bugs, then add TLS.

**Outbound fetch to an h2-only host fails** — expected: no HTTP/2 client. Proxy through an HTTP/1.1 endpoint or pick a host that still negotiates 1.1.

**WebSocket over the TLS port broke after enabling `tls`** — nothing about WS changed; upgrades still happen on HTTP/1.1 connections to the same port. Check the `websocket` block is present (the upgrade is automatic — no handler branch) and the client uses `wss://` with `--allow-net` on the target.

## See also

- [Permissions](/docs/concepts/permissions) — flags, scopes, denial contract
- [TLS guide](/docs/guides/tls) — certificate setup and trust
- [HTTP Server guide](/docs/guides/http-server) — handler basics
- [Limitations](/docs/reference/limitations) — every hard cap
