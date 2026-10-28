---
title: TLS
description: Serve HTTPS and WSS with the built-in BearSSL stack.
order: 4
---

# TLS

Fairyfly ships its own TLS stack (BearSSL) — no OpenSSL dependency, no system libraries. The same `http.serve` code serves plain HTTP and HTTPS. TLS is enabled per server, and WebSocket (`wss://`) rides on it for free. For HTTP/2 over the same port, see the [HTTP/2 guide](/docs/guides/http2).

TLS here means two things: encrypting your server so browsers see `https://`, and trusting other servers when you call `fetch` or `new WebSocket` against `https://` URLs.

## Permissions

A TLS server is still an `http.serve` listener, and its certificate files are
still files:

| Item | Needs |
|---|---|
| Listener | `--allow-net=0.0.0.0:<port>` |
| `tls.cert` / `tls.key` **paths** | `--allow-read` on each file |
| `tls.cert` / `tls.key` **inline PEM** | No file grant |
| `ff start --cert/--key`, `FF_CERT` / `FF_KEY` | No runtime `--allow-read` — the CLI reads them before the engine starts |
| `--ca` / `FF_CA_FILE` | No `--allow-read` and no `--allow-env` — CLI/runtime trust config |
| Outbound `fetch` / `wss://` | `--allow-net` on the target host and port |

```sh
ff tls-server.js \
  --allow-net=0.0.0.0:8443 \
  --allow-read=cert.pem,key.pem
```

A denied TLS path throws synchronously from `http.serve`:

```js
try {
  http.serve({ port: 8443, tls: { cert: "cert.pem", key: "key.pem" } }, handler);
} catch (e) {
  console.error(e.name, e.code); // PermissionDenied PERMISSION_DENIED
  console.error(e.message);      // http.serve tls.cert requires --allow-read for 'cert.pem'
}
```

The listener check runs first; if both the port and a cert path are denied, the
net error wins.

Trust and access are separate: `--ca` / `FF_CA_FILE` makes a private CA trusted
but never grants network access, and `--allow-net` never makes an untrusted
certificate valid. Full model: [Permissions](/docs/concepts/permissions).

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
ff tls-server.js \
  --allow-net=0.0.0.0:8443 \
  --allow-read=cert.pem,key.pem
curl -k https://127.0.0.1:8443/
# hello over tls
```

What happens:

- `tls.cert` and `tls.key` accept a file path **or** inline PEM text. A string starting with `-----BEGIN ` is treated as PEM content; anything else is a path.
- Path inputs are permission-checked before reading. Grant `--allow-read` for each path (and any symlink target).
- Cert files are capped at 512KB, key files at 256KB. Larger files fail to load.
- A bad cert or key throws a `TypeError` and the server never starts half-configured — you see the error, never a silent plain-HTTP fallback. A denied path throws `PermissionDenied` instead.

Inline PEM needs no file grant:

```js
const cert = fs.readFile("cert.pem"); // needs --allow-read
const key = fs.readFile("key.pem");   // needs --allow-read

http.serve(
  { port: 8443, tls: { cert, key } }, // strings, passed inline
  handler,
);
```

Here the reads happen in JS, so `--allow-read` is still required for the
`fs.readFile` calls — it just is not required again by `http.serve`.

## Enable TLS from the CLI

If your entrypoint is `ff.json`, skip the `tls` object and pass paths at startup:

```sh
ff start --cert cert.pem --key key.pem --allow-net=0.0.0.0:8443
```

Environment fallback:

```sh
FF_CERT=cert.pem FF_KEY=key.pem \
ff start --allow-net=0.0.0.0:8443
```

Rules:

- `--cert` and `--key` must be given together. One without the other prints an error and exits.
- When both CLI flags and the JS `tls` object are set, the JS object wins at listener start.
- The CLI reads `--cert` / `--key` / `FF_CERT` / `FF_KEY` itself, so those paths do **not** need `--allow-read`. A `tls` object inside the app is a runtime read and does.
- A binary built with `-Dbearssl=false` has no TLS: starting with cert/key prints `built without TLS` and exits.
- The app's listener still needs its port scope: `--allow-net=0.0.0.0:<port>` after `start`.

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
ff wss-server.js \
  --allow-net=0.0.0.0:8443 \
  --allow-read=cert.pem,key.pem
# in another terminal:
ff wss-client.js --allow-net=localhost:8443 --ca cert.pem
# text: welcome over wss
# text: hello over tls
```

The server needs the cert/key read scopes; the client needs the `wss` host and
port plus `--ca` for the self-signed certificate. Binary frames arrive as
`Uint8Array`; send them with `socket.sendBinary`.

## Trusting your own certificate

Browsers and `fetch` reject self-signed certs by default. Three cases:

**1. Same process serves and fetches.** Starting with `--cert cert.pem` (or `FF_CERT`) auto-trusts that cert for the process's own `fetch` and `WebSocket` clients — no extra CA flag:

```js
http.serve(
  { port: 8443, tls: { cert: "cert.pem", key: "key.pem" } },
  (url, method, body) => new Response("hi"),
);

const res = await fetch("https://localhost:8443/");
console.log(await res.text()); // hi
```

```sh
ff self.js \
  --allow-net=0.0.0.0:8443,localhost:8443 \
  --allow-read=cert.pem,key.pem
```

Both scopes are needed: `0.0.0.0:8443` for the listener and
`localhost:8443` for the outbound `fetch`. The certificate is trusted
automatically, but trust does not replace `--allow-net`.

**2. Separate client script.** Pass the cert as a CA:

```sh
ff client.js --ca cert.pem --allow-net=localhost:8443
# or via env (the only option under ff start):
FF_CA_FILE=cert.pem ff client.js --allow-net=localhost:8443
```

`--ca` and `FF_CA_FILE` are trust inputs, not app reads: they need no
`--allow-read` and no `--allow-env`.

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
ff tls-server.js \
  --allow-net=0.0.0.0:8443 \
  --allow-read=cert.pem,key.pem
curl -k https://localhost:8443/
# hello over tls
```

## Limits you will hit

- One listener is TLS-or-plain per `tls` block. No client-certificate auth.
- Cert ≤ 512KB, key ≤ 256KB.
- RSA or EC keys; RSA is the well-trodden path.
- Outbound `fetch` stays HTTP/1.1 even against HTTPS hosts.
- Server bind is always `0.0.0.0`; the net scope must name `0.0.0.0:<port>`.
- `tls.cert` / `tls.key` paths need `--allow-read`; inline PEM and CLI
  `--cert` / `FF_CERT` do not.

## Try it

- Generate a cert with the openssl command above.
- Start `tls-server.js` with the net and read flags, then `curl -k https://localhost:8443/`.
- Connect `wss-client.js` with `--allow-net=localhost:8443 --ca cert.pem` and confirm echo works over TLS.
- Start a second script with `--ca cert.pem` and fetch your own server without `-k`.

## See also

- [Permissions](/docs/concepts/permissions) — flags, scopes, denial contract
- [HTTP Server guide](/docs/guides/http-server) — listener basics
- [HTTP/2 guide](/docs/guides/http2) — ALPN over TLS
- [Limitations](/docs/reference/limitations) — every hard cap
