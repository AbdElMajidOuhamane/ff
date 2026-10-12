---
title: Environment Variables
description: Every FF_ variable — what it does, when to set it, and how to read env in code.
order: 6
---

# Environment Variables

Fairyfly reads a small, fixed set of `FF_` variables. There is no `FF_PORT` — the listen port comes only from `http.serve({ port })` in your JS.

## Quick look

```sh
FF_ECHO=1 ff server.js        # smoke mode: every request -> 200 {"message":"ok"}
FF_CA_FILE=./ca.pem ff start  # trust a private CA in the runtime's own client
FF_CERT=cert.pem FF_KEY=key.pem ff start  # serve TLS without flags
```

## Reference

| Variable | Read by | Effect |
|----------|---------|--------|
| `FF_ECHO` | the HTTP server (`http.serve`) | Presence enables echo mode: every request returns `200 {"message":"ok"}` — any value, **including empty** |
| `FF_CERT` | `ff start` | Fallback for `--cert`: PEM certificate path. Also a fallback CA file for the runtime's own TLS client |
| `FF_KEY` | `ff start` | Fallback for `--key`: PEM private key path |
| `FF_CA_FILE` | runtime TLS client (`fetch`, `WebSocket`) | Extra CA bundle (PEM path) trusted for outbound HTTPS/WSS |
| `FF_WATCH_PARENT` | `ff` child under `ff --watch` | Internal: the supervisor's PID; a watchdog exits the child if the supervisor dies |

### `FF_ECHO` — smoke mode

Any value enables it — the check is *"is the variable set?"* (`getenv(...) != null`), so even `FF_ECHO=` (empty) counts. The HTTP server then answers every request with `200 {"message":"ok"}` **without invoking your handler**, which is ideal for separating "is the deploy reachable" from "does my code work".

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

> **Note:** Only *unsetting* disables echo mode. `FF_ECHO= ff server.js`
> (empty value) **does** enable it; `FF_ECHO=0` also enables it — the value
> is never inspected.

Echo mode is a property of the HTTP server, so it only matters for a run that calls `http.serve` (`ff start` or `ff your-file.js`).

### `FF_CERT` / `FF_KEY` — TLS without flags

`ff start` accepts `--cert`/`--key`; when a flag is absent, these env vars fill in:

```sh
FF_CERT=cert.pem FF_KEY=key.pem ff start
```

Both must be present together — one without the other stops startup with:

```text
[https] --cert and --key must be provided together
```

Explicit flags win over env when both are given. Size caps match the flags: cert ≤ 512 KB, key ≤ 256 KB. On success: `[https] TLS enabled (cert=… key=…) — https/wss on the same port`, and the provided cert is also trusted by the runtime's own outbound `fetch`/`WebSocket` client. See the [TLS guide](/docs/guides/tls) for generating and verifying certificates.

### `FF_CA_FILE` — trust a private CA

Points the runtime's TLS client (used by `fetch` and the WebSocket **client**) at an extra CA bundle, as a PEM file path:

```sh
FF_CA_FILE=./ca.pem ff client.js
FF_CA_FILE=./ca.pem ff start
```

The bundle is loaded lazily, the first time the client is used. `FF_CA_FILE` works with any command that builds a runtime (including `ff start`). This is distinct from the CLI's `--ca` flag, which is only honored by `ff <file>` and `ff -e` — `ff start` ignores `--ca` (see the TLS guide). When TLS is served with `--cert`/`FF_CERT`, that certificate is additionally trusted by the client, which is handy for self-signed dev loops. If `FF_CA_FILE` is unset but `FF_CERT` is set, the cert path is used as the client CA.

### `FF_WATCH_PARENT` — orphan watchdog

This one is set by the runtime, not by you. `ff --watch` spawns a child `ff` and exports `FF_WATCH_PARENT` with the supervisor's PID. The child starts a watchdog thread that checks its parent every 500 ms and exits if the parent is gone — so a killed supervisor (even `SIGKILL`) doesn't leave an orphaned server behind. Setting it by hand to a value that isn't the current parent's PID makes the process exit within ~500 ms.

## Reading env in code

`process.env` is a plain object snapshot of the environment, built once at startup:

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

> **Note:** `process.env` reflects the environment at boot, and assigning to it
> does not change the OS environment. There is no `.env` file loader — export
> variables in your shell (or prefix the command, as above) before starting `ff`.

## Practical example: dev vs prod startup

```sh
# dev — smoke-test the deploy first
FF_ECHO=1 ff start
curl http://127.0.0.1:3000/health   # {"message":"ok"}

# dev TLS with self-signed cert; the cert is trusted outbound too
FF_CERT=cert.pem FF_KEY=key.pem ff start

# prod — real handler, private upstream CA for outbound fetch/wss
FF_CA_FILE=/etc/ssl/upstream-ca.pem ff start
```

## Troubleshooting

**Port env var does nothing** — by design. `PORT`, `FF_PORT`, and friends are ignored; set the port in `http.serve({ port })`.

**`--ca` has no effect with `ff start`** — expected. `--ca` is only parsed for `ff <file>` and `ff -e`; `ff start` ignores it. Use `FF_CA_FILE` to point the runtime's client at a CA bundle.

**TLS didn't start with env set** — both `FF_CERT` and `FF_KEY` must be set, both files must exist and be within the size caps (cert ≤ 512 KB, key ≤ 256 KB), and explicit `--cert`/`--key` flags override env.

**Echo mode won't turn off** — `FF_ECHO=` (empty) and `FF_ECHO=0` both keep it on. `unset FF_ECHO` is the only way off.
