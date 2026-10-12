---
title: HTTP/2
description: Serve HTTP/2 over TLS with ALPN — same handler, same port, no code changes.
order: 14
---

# HTTP/2

HTTP/2 works the moment TLS is on: pass `tls: { cert, key }` and the same port negotiates HTTP/1.1 or HTTP/2 per connection via ALPN (nghttp2). Plain (non-TLS) listeners stay HTTP/1.1 — there is no cleartext HTTP/2. Your handler doesn't change at all.

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
ff server.js
curl -k https://127.0.0.1:8443/
# {"proto":"either — handler can't tell"}

curl -k --http2 https://127.0.0.1:8443/
# same body, HTTP/2 frames on the wire
```

Generate a dev cert if you don't have one (see the [TLS guide](/docs/guides/tls) for the full walkthrough):

```sh
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout key.pem -out cert.pem \
  -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost"
```

## How negotiation works

The TLS server advertises the ALPN list `h2`, then `http/1.1`. Once the handshake completes, Fairyfly reads the negotiated protocol from the first decrypted bytes: `h2` routes that connection to nghttp2, anything else stays HTTP/1.1.

| Client offers (ALPN) | Gets |
|----------------------|------|
| `h2` (browsers and their `fetch`, `curl --http2`) | HTTP/2 |
| `http/1.1` only (old clients, `curl` default) | HTTP/1.1 |
| No ALPN extension / no match | HTTP/1.1 |
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
- `url` is the h2 `:path` (path + query), `method` is the exact-case h2 `:method`, `body` is the reassembled request body as a string.
- `Response.json` / `redirect` / statics, `Headers`, status codes — all identical.
- The 30s handler watchdog still applies; a parked handler can be multiplexed with other streams on the same connection.

What you get from the protocol (handled by nghttp2, not your code):

- Multiplexed streams — up to **100 concurrent streams per connection** (advertised as `SETTINGS_MAX_CONCURRENT_STREAMS`).
- Header compression (HPACK) — smaller repeated headers.
- Server framing (Content-Length) computed for you, as with HTTP/1.1.

What you don't get:

- No server push API — there is no push handle on the socket.
- No trailers — request trailers are ignored, and all response headers are set up front in the `Response`.
- No access to request headers — like HTTP/1.1, only `:method` and `:path` reach the handler; every other h2 header is dropped.
- No `fetch` upgrade — the **client is HTTP/1.1 only**. Outbound `fetch("https://h2-only.example")` fails; call HTTP/1.1-capable endpoints.

## WebSocket and HTTP/2 on one port

WebSocket still rides the HTTP/1.1 connections: a request on a TLS connection that negotiated `http/1.1` and carries a `Sec-WebSocket-Key` header is upgraded exactly as on a plain port. Connections that negotiated `h2` serve normal multiplexed requests and never see the WebSocket path. Both live on the same `tls`-enabled port with no extra configuration.

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
TLS_CERT=./cert.pem TLS_KEY=./key.pem ff api.js
curl -k https://127.0.0.1:8443/health
# {"ok":true}
curl -k --http2 -X POST https://127.0.0.1:8443/echo \
  -H "content-type: application/json" -d '{"a":1}'
# {"youSent":{"a":1}}
```

Behind a platform load balancer that terminates TLS, skip `tls` entirely and serve plain HTTP — the balancer speaks HTTP/2 to the internet for you.

## Reference: HTTP/2 limits

| Area | Limit | When hit |
|------|-------|----------|
| Concurrent streams | 100 per connection | nghttp2 enforces the advertised cap |
| Request body | 10 MB | Bytes past the cap are dropped for that stream |
| `:method` | 16 bytes | Longer methods are truncated |
| `:path` | 2048 bytes | Longer paths are truncated |
| Response headers | 128 header pairs; name ≤ 64 bytes, value ≤ 4096 bytes | Pairs past any cap are skipped |
| Response body | 10 MB | Beyond → `500` |
| Protocol | TLS + ALPN `h2` only | Plain sockets stay HTTP/1.1 |

## Troubleshooting

**`curl` reports version 1.1** — the client didn't offer `h2`, or TLS isn't on. Confirm the `tls` block is present and retest with `curl --http2`.

**Handshake failure** — cert/key unreadable, over the size caps (cert ≤ 512 KB; key ≤ 512 KB through the JS option, 256 KB through `--key`), or not a matching pair. Start plain-HTTP first to isolate app bugs, then add TLS.

**Outbound fetch to an h2-only host fails** — expected: no HTTP/2 client. Proxy through an HTTP/1.1 endpoint or pick a host that still negotiates 1.1.

**WebSocket over the TLS port broke after enabling `tls`** — nothing about WS changed; upgrades still happen on HTTP/1.1 connections to the same port. Check the `websocket` block is present (the upgrade is automatic — no handler branch) and the client uses `wss://`.

## See also

- [TLS guide](/docs/guides/tls) — `tls: { cert, key }`, cert/key sources, and CA trust
- [HTTP Server guide](/docs/guides/http-server) — handler contract and limits
- [http API](/docs/api/http) — options reference
- [Limitations](/docs/reference/limitations) — every hard cap
