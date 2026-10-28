---
title: Environment Variables
description: Every FF_ variable — what it does, when to set it, and how to read env in code.
order: 6
---

# Environment Variables

Fairyfly reads a small set of `FF_` variables. There is no `FF_PORT` — the port comes only from `http.serve({ port })` in your JS.

These are **runtime configuration**, read directly by the CLI/runtime. They are
separate from application env access: `--allow-env` controls what
`process.env` exposes to JS, not whether `FF_*` works.

## Quick look

```sh
FF_ECHO=1 ff server.js --allow-net=0.0.0.0:3000
FF_CA_FILE=./ca.pem ff start --allow-net=0.0.0.0:3000
FF_CERT=cert.pem FF_KEY=key.pem ff start --allow-net=0.0.0.0:3000
```

The `--allow-net` flag is for the app's server, not for the `FF_*` variable.
Add the app's other flags as needed.

## Reference

| Variable | Used by | Effect |
|----------|---------|--------|
| `FF_ECHO` | `ff <file>`, `ff start` | Presence enables canned `200 {"message":"ok"}` for every request — any value, **including empty** |
| `FF_CERT` | `ff start` | Fallback for `--cert`: PEM certificate path |
| `FF_KEY` | `ff start` | Fallback for `--key`: PEM private key path |
| `FF_CA_FILE` | runtime `fetch` / `WebSocket` client | Extra CA bundle trusted for outbound HTTPS/WSS |

### `FF_ECHO` — smoke mode

Any value enables it — the check is *"is the variable set?"*, so even
`FF_ECHO=` (empty) counts. Every request gets `200 {"message":"ok"}`
without running your handler:

```sh
FF_ECHO=1 ff server.js --allow-net=0.0.0.0:3000
curl http://127.0.0.1:3000/anything
# {"message":"ok"}
```

Unset it to restore your handler:

```sh
unset FF_ECHO
ff server.js --allow-net=0.0.0.0:3000
```

> **Note:** Only *unsetting* disables echo mode. `FF_ECHO= ff server.js`
> (empty value) **does** enable it; `FF_ECHO=0` also enables it (the
> value is never inspected).

### `FF_CERT` / `FF_KEY` — TLS without flags

`ff start` accepts `--cert`/`--key`; when the flags are absent, these env vars fill in:

```sh
FF_CERT=cert.pem FF_KEY=key.pem ff start --allow-net=0.0.0.0:3000
```

Both must be present together — one without the other fails to start TLS. Explicit flags win over env when both are given. Same file caps as flags: cert ≤ 512KB, key ≤ 256KB.

The CLI reads these files before the runtime starts, so they do not require
`--allow-read`. File paths passed to `http.serve({ tls })` are runtime reads
and do. See the [TLS guide](/docs/guides/tls) for generating and verifying.

### `FF_CA_FILE` — trust a private CA

Points `fetch` and `WSS` clients at an extra CA bundle (PEM path):

```sh
FF_CA_FILE=./ca.pem ff client.js --allow-net=api.example.com:443
FF_CA_FILE=./ca.pem ff start --allow-net=0.0.0.0:3000
```

`FF_CA_FILE` only changes trust. It does **not** grant network access:
outbound `fetch` / `WebSocket` calls still need `--allow-net` for their
host and port.

Unlike `--ca` (which `ff start` rejects), `FF_CA_FILE` works everywhere, including `ff start`. When TLS is started with `--cert`/`FF_CERT`, that cert path is additionally trusted by the runtime's own outbound clients — handy for self-signed dev loops.

## Reading env in code

`process.env` is a plain object snapshot of the environment, filtered by
`--allow-env`. Only granted names appear; everything else is `undefined`:

```js
// config.js
const port = Number(process.env.PORT ?? 3000);
const token = process.env.API_TOKEN;
if (!token) throw new Error("API_TOKEN is required");

http.serve({ port }, () => new Response("ok"));
```

```sh
PORT=4242 API_TOKEN=secret ff config.js \
  --allow-env=PORT,API_TOKEN \
  --allow-net=0.0.0.0:3000
curl http://127.0.0.1:4242/
# ok
```

> **Note:** `process.env` reflects the environment at startup. There is no
> `.env` file loader — export variables in your shell (or prefix the command,
> as above) before starting `ff`. Bare `--allow-env` grants every name;
> `--allow-env=PORT,API_TOKEN` grants just those two.

### Runtime config vs application env

The runtime reads `FF_*` directly, outside `process.env`. `--allow-env` only
controls what JavaScript can see:

```sh
FF_ECHO=1 ff server.js --allow-net=0.0.0.0:3000
# echo mode works without --allow-env

FF_ECHO=1 ff app.js --allow-env=FF_ECHO
# process.env.FF_ECHO is now visible too
```

Without the grant, `process.env.FF_ECHO` is `undefined` even though echo mode
is active. The same applies to `FF_CERT`, `FF_KEY`, and `FF_CA_FILE`.

## Practical example: dev vs prod startup

```sh
# dev — smoke-test the deploy first
FF_ECHO=1 ff start --allow-net=0.0.0.0:3000
curl http://127.0.0.1:3000/health   # {"message":"ok"}

# dev TLS with self-signed cert, trusting it outbound too
FF_CERT=cert.pem FF_KEY=key.pem ff start --allow-net=0.0.0.0:3000

# prod — real handler, private upstream CA, app reads PORT
FF_CA_FILE=/etc/ssl/upstream-ca.pem ff start \
  --allow-net=0.0.0.0:3000 \
  --allow-env=PORT
```

## Troubleshooting

**Port env var does nothing** — the runtime does not read `PORT` or `FF_PORT`; set the port in `http.serve({ port })`. Your app may read `PORT` itself, but only with `--allow-env=PORT`.

**`process.env.X` is undefined** — either the variable was not exported, or
`--allow-env` does not include it. Check both: `X=1 ff app.js --allow-env=X`.
No `.env` file is read.

**`FF_ECHO` works but `process.env.FF_ECHO` is undefined** — expected.
`FF_*` variables are runtime config; JS sees them only with a matching
`--allow-env` grant.

**`--ca` rejected by `ff start`** — expected. Use `FF_CA_FILE` with `ff start`; `--ca` works only with `ff <file>` and `ff -e`.

**`FF_CA_FILE` set but fetch still denied** — trust and permission are
separate. Add `--allow-net=<host>:<port>` for the request.

**TLS didn't start with env set** — both `FF_CERT` and `FF_KEY` must be set, files must exist and be within size caps, and explicit `--cert`/`--key` flags override env.

**Echo mode won't turn off** — `FF_ECHO=` (empty) and `FF_ECHO=0` both keep it on. `unset FF_ECHO` is the only way off.
