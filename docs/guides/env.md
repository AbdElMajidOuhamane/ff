---
title: Environment Variables
description: Every FF_ variable — what it does, when to set it, and how to read env in code.
order: 6
---

# Environment Variables

Fairyfly reads a small set of `FF_` variables. There is no `FF_PORT` — the port comes only from `http.serve({ port })` in your JS.

## Quick look

```sh
FF_ECHO=1 ff server.js        # smoke mode: every request -> 200 {"message":"ok"}
FF_CA_FILE=./ca.pem ff start  # trust a private CA (client fetch/WSS)
FF_CERT=cert.pem FF_KEY=key.pem ff start  # serve TLS without flags
```

## Reference

| Variable | Used by | Effect |
|----------|---------|--------|
| `FF_ECHO` | `ff <file>`, `ff start` | Any value (even empty string counts as set? no — must be non-empty… see below) enables canned `200 {"message":"ok"}` for every request |
| `FF_CERT` | `ff start` | Fallback for `--cert`: PEM certificate path |
| `FF_KEY` | `ff start` | Fallback for `--key`: PEM private key path |
| `FF_CA_FILE` | runtime `fetch` / `WebSocket` client | Extra CA bundle trusted for outbound HTTPS/WSS |

### `FF_ECHO` — smoke mode

Any non-empty value enables it. Every request gets `200 {"message":"ok"}` without running your handler:

```sh
FF_ECHO=1 ff server.js
curl http://127.0.0.1:3000/anything
# {"message":"ok"}
```

Unset it to restore your handler:

```sh
unset FF_ECHO
ff server.js
```

> **Note:** `FF_ECHO` is checked with "is set and non-empty". `FF_ECHO= ff server.js` (empty) does **not** enable it.

### `FF_CERT` / `FF_KEY` — TLS without flags

`ff start` accepts `--cert`/`--key`; when the flags are absent, these env vars fill in:

```sh
FF_CERT=cert.pem FF_KEY=key.pem ff start
```

Both must be present together — one without the other fails to start TLS. Explicit flags win over env when both are given. Same file caps as flags: cert ≤ 512KB, key ≤ 256KB. See the TLS guide for generating and verifying.

### `FF_CA_FILE` — trust a private CA

Points `fetch` and `WSS` clients at an extra CA bundle (PEM path):

```sh
FF_CA_FILE=./ca.pem ff client.js
FF_CA_FILE=./ca.pem ff start
```

Unlike `--ca` (which `ff start` rejects), `FF_CA_FILE` works everywhere, including `ff start`. When TLS is started with `--cert`/`FF_CERT`, that cert path is additionally trusted by the runtime's own outbound clients — handy for self-signed dev loops.

## Reading env in code

`process.env` is a plain object snapshot of the environment:

```js
// config.js
const port = Number(process.env.PORT ?? 3000);
const token = process.env.API_TOKEN;
if (!token) throw new Error("API_TOKEN is required");

http.serve({ port }, () => new Response("ok"));
```

```sh
PORT=4242 API_TOKEN=secret ff config.js
curl http://127.0.0.1:4242/
# ok
```

> **Note:** `process.env` reflects the environment at startup. There is no `.env` file loader — export variables in your shell (or prefix the command, as above) before starting `ff`.

## Practical example: dev vs prod startup

```sh
# dev — smoke-test the deploy first
FF_ECHO=1 ff start
curl http://127.0.0.1:3000/health   # {"message":"ok"}

# dev TLS with self-signed cert, trusting it outbound too
FF_CERT=cert.pem FF_KEY=key.pem ff start

# prod — real handler, private upstream CA
FF_CA_FILE=/etc/ssl/upstream-ca.pem ff start
```

## Troubleshooting

**Port env var does nothing** — by design. `PORT`, `FF_PORT`, and friends are ignored; set the port in `http.serve({ port })`.

**`--ca` rejected by `ff start`** — expected. Use `FF_CA_FILE` with `ff start`; `--ca` works only with `ff <file>` and `ff -e`.

**TLS didn't start with env set** — both `FF_CERT` and `FF_KEY` must be set, files must exist and be within size caps, and explicit `--cert`/`--key` flags override env.
