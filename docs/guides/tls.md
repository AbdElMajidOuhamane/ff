---
title: TLS
description: Serve HTTPS and WSS with the built-in BearSSL stack.
order: 4
---

# TLS

Fairyfly ships its own TLS stack (BearSSL) — no OpenSSL dependency, no system libraries. The same `http.serve` code serves plain HTTP and HTTPS. TLS is enabled per server, and WebSocket (`wss://`) rides on it for free. For HTTP/2 over the same port, see the [HTTP/2 guide](/docs/guides/http2).

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

- `tls.cert` and `tls.key` accept a file path **or** inline PEM text. Anything starting with `-----BEGIN` is treated as PEM content, otherwise as a path.
- Cert files are capped at 512KB, key files at 256KB. Larger files fail to load.
- A bad cert or key throws a `TypeError` and the server never starts half-configured — you see the error, never a silent plain-HTTP fallback.

## Enable TLS from the CLI

If your entrypoint is `ff.json`, skip the `tls` object and pass paths at startup:

```sh
ff start --cert cert.pem --key key.pem
```

Environment fallback:

```sh
FF_CERT=cert.pem FF_KEY=key.pem ff start
```

Rules:

- `--cert` and `--key` must be given together. One without the other prints an error and exits.
- When both CLI flags and the JS `tls` object are set, the JS object wins at listener start.
- A binary built with `-Dbearssl=false` has no TLS: starting with cert/key prints `built without TLS` and exits.

## WebSocket over TLS

Nothing extra — same port, `wss://` scheme. The upgrade path still returns `{ status: 101 }`:

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
  (url, method, body) => {
    if (url === "/ws") return { status: 101 };
    return new Response("http here, wss on /ws");
  },
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

Binary frames arrive as `Uint8Array`; send them with `socket.sendBinary`.

## Trusting your own certificate

Browsers and `fetch` reject self-signed certs by default. Three cases:

**1. Same process serves and fetches.** Starting with `--cert cert.pem` (or `FF_CERT`) auto-trusts that cert for the process's own `fetch` and `WebSocket` clients — no extra flags:

```js
http.serve(
  { port: 8443, tls: { cert: "cert.pem", key: "key.pem" } },
  (url, method, body) => new Response("hi"),
);

const res = await fetch("https://localhost:8443/");
console.log(await res.text()); // hi
```

**2. Separate client script.** Pass the cert as a CA:

```sh
ff client.js --ca cert.pem
# or via env (the only option under ff start):
FF_CA_FILE=cert.pem ff client.js
```

**3. External tools.** `curl -k https://localhost:8443/` skips verification (`-k` = local testing only). For Node: `NODE_EXTRA_CA_CERTS=cert.pem node client.mjs`.

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

- One listener is TLS-or-plain per `tls` block. No client-certificate auth.
- Cert ≤ 512KB, key ≤ 256KB.
- RSA or EC keys; RSA is the well-trodden path.
- Outbound `fetch` stays HTTP/1.1 even against HTTPS hosts.

## Try it

- Generate a cert with the openssl command above.
- Start `tls-server.js`, then `curl -k https://localhost:8443/`.
- Connect `wss-client.js` and confirm echo works over TLS.
- Start a second script with `--ca cert.pem` and fetch your own server without `-k`.
