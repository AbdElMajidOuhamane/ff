---
title: TLS
description: Serve HTTPS and WSS with the built-in BearSSL stack.
order: 4
---

# TLS

Fairyfly ships its own TLS stack (BearSSL) — no OpenSSL dependency, no system libraries. The same `http.serve` code serves plain HTTP and HTTPS. TLS is enabled per server, WebSocket (`wss://`) rides on it for free, and so does HTTP/2. For HTTP/2 over the same port, see the [HTTP/2 guide](/docs/guides/http2).

TLS here means two things: encrypting your server so browsers see `https://`, and trusting other servers when you call `fetch` or `new WebSocket` against `https://` URLs.

## Enable TLS from JavaScript

Create `tls-server.js`:

```js
// tls-server.js
http.serve(
  {
    port: 8443,
    tls: {
      cert: "cert.pem",
      key: "key.pem",
    },
  },
  (url, method, body) => new Response("hello over tls"),
);
```

Run it:

```sh
ff tls-server.js
curl -k https://127.0.0.1:8443/
# hello over tls
```

What happens:

- `tls.cert` and `tls.key` accept inline PEM text **or** a file path. Anything starting with `-----BEGIN ` is treated as PEM content; anything else is read from the current working directory as a path.
- When they are paths, both files are read with a **512 KB** cap through this option. Larger files fail to load.
- A bad cert or key throws a `TypeError` and the server never starts half-configured — you see the error, never a silent plain-HTTP fallback.
- The listener speaks HTTPS and WSS (and negotiates HTTP/2 via ALPN). It is not also plain HTTP — a port is TLS **or** plain, decided by whether you passed `tls`.

## Enable TLS from the CLI

If your entrypoint is `ff.json`, you can skip the `tls` object and pass paths at startup:

```sh
ff start --cert cert.pem --key key.pem
```

Environment fallback:

```sh
FF_CERT=cert.pem FF_KEY=key.pem ff start
```

Rules:

- `--cert` and `--key` must be given together. One without the other prints `[https] --cert and --key must be provided together` and exits without running.
- CLI flags win over `FF_CERT` / `FF_KEY`.
- The cert file is capped at 512 KB and the key file at 256 KB on this path. The cert path is also registered as the run's client CA (see [Trusting your own certificate](#trusting-your-own-certificate)).
- When both the CLI flags and a JS `tls` object are set, the JS object re-arms TLS at listener start (it wins).
- A binary built with `-Dbearssl=false` has no TLS: starting with cert/key prints `[https] built without TLS (rebuild without -Dbearssl=false)` and exits.

### Where the cert and key can come from

| Source | Cert / key | Notes |
|--------|-----------|-------|
| `http.serve` `tls: { cert, key }` | inline PEM or file path | both read with a 512 KB cap; the JS object wins if the CLI also set TLS |
| `ff start --cert`, `--key` | file paths | 512 KB cert / 256 KB key; must be given together |
| `FF_CERT`, `FF_KEY` | file paths | fallback when the flags are absent |

Inline PEM is detected purely by the leading `-----BEGIN `; everything else is treated as a path relative to the cwd.

## WebSocket over TLS

Nothing extra — same port, `wss://` scheme, and the upgrade happens automatically exactly like plain WS (no `{ status: 101 }` branch in the handler):

```js
// wss-server.js
http.serve(
  {
    port: 8443,
    tls: { cert: "cert.pem", key: "key.pem" },
    websocket: {
      open: (socket) => socket.send("welcome over wss"),
      message: (socket, data) => socket.send(data),
      close: (socket) => console.log("bye"),
    },
  },
  (url, method, body) => new Response("http here, wss upgrades on this port"),
);
```

Create `wss-client.js`:

```js
// wss-client.js
const ws = new WebSocket("wss://localhost:8443/ws");
ws.onopen = () => ws.send("hello over tls");
ws.onmessage = (e) => {
  if (e.data instanceof Uint8Array) console.log("binary:", e.data);
  else console.log("text:", e.data);
};
```

```sh
ff wss-server.js
# in another terminal:
ff wss-client.js --ca cert.pem
# text: welcome over wss
# text: hello over tls
```

Binary frames arrive as `Uint8Array`; send them with `socket.sendBinary`. The `--ca` flag works for `ff <file>` and `ff -e` (and is forwarded by `ff --watch`), but not `ff start`.

## Trusting your own certificate

Browsers and `fetch` reject self-signed certs by default. The runtime's outbound client is created **once at startup**, before your script runs, so a CA is only trusted when it is registered at startup — through the CLI or environment — not by the `tls` object inside `http.serve`. Three cases:

**1. Same process serves (with CLI TLS) and fetches.** `ff start --cert cert.pem --key key.pem` (or `FF_CERT`) registers that cert as the client CA *before* the client is created, so the process's own `fetch` and `WebSocket` trust it:

```js
// main.js — run with: ff start --cert cert.pem --key key.pem
http.serve({ port: 8443 }, () => new Response("hi")); // TLS already armed by --cert/--key

(async () => {
  const res = await fetch("https://localhost:8443/");
  console.log(await res.text()); // hi
})();
```

**2. Separate client script.** Pass the cert as a CA:

```sh
ff client.js --ca cert.pem
# or via env (works for both ff <file> and ff start):
FF_CA_FILE=cert.pem ff client.js
```

`FF_CERT` is also read as a client-CA fallback at startup, but prefer `FF_CA_FILE` for clarity.

**3. External tools.** `curl -k https://localhost:8443/` skips verification (`-k` = local testing only). For Node: `NODE_EXTRA_CA_CERTS=cert.pem node client.mjs`.

> **Caution:** Arming TLS with the JS `tls: { cert, key }` option does not retroactively make the *already-created* outbound client trust that cert. If a script both serves with a JS `tls` object and calls back into itself over HTTPS, also pass `--ca cert.pem` (or set `FF_CA_FILE`).

## Generate a dev certificate

SubjectAltNames matter — the client verifies the hostname, so mint for `localhost` (and the IP when you dial it numerically):

```sh
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout key.pem -out cert.pem -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
```

This creates `cert.pem` and `key.pem` in the current directory. Then:

```sh
ff tls-server.js
curl -k https://localhost:8443/
# hello over tls
```

## Limits you will hit

- The TLS version is capped at **TLS 1.2** (BearSSL); there is no TLS 1.3.
- One listener is TLS-or-plain per `tls` block. No client-certificate auth.
- Cert read cap ≤ 512 KB (CLI) / ≤ 512 KB per file through the JS option; CLI key ≤ 256 KB.
- On top of the read caps, the decoded certificate chain must fit a 32 KB pool (across at most 4 `CERTIFICATE` PEM blocks) and the decoded private key must fit 8 KB.
- RSA or EC keys; Ed25519/X25519 are not supported and fail to load.
- ALPN advertises `h2` then `http/1.1`, so the same port serves HTTP/2 or HTTP/1.1.
- Outbound `fetch` stays HTTP/1.1 even against HTTPS hosts.
- A port added by `tls` is TLS-only; it does not also answer plain HTTP.

## Try it

- Generate a cert with the openssl command above.
- Start `tls-server.js`, then `curl -k https://localhost:8443/`.
- Connect `wss-client.js` and confirm echo works over TLS.
- Start a second script with `--ca cert.pem` and fetch your own server without `-k`.
