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
| `FF_ECHO` | any command running `http.serve` | Presence enables canned `200 {"message":"ok"}` for every request — any value, **including empty** |
| `FF_CERT` | `ff start` (and outbound TLS fallback) | Fallback for `--cert`: PEM certificate path; also trusted by outbound TLS if `--ca` and `FF_CA_FILE` are unset |
| `FF_KEY` | `ff start` | Fallback for `--key`: PEM private key path |
| `FF_CA_FILE` | runtime `fetch` / `WebSocket` client | Extra CA bundle trusted for outbound HTTPS/WSS |
| `FF_MAX_HEAP` | runtime startup | JS main heap size (`8MB`–`4GB`, default `64MB`; overridden by `--max-heap`) |
| `FF_CPU_BUDGET` | runtime startup | Consecutive JS CPU interrupt budget in ms (`0`–`3600000`, default `0`; overridden by `--cpu-budget`) |
| `FF_WATCH_PARENT` | child spawned by `ff --watch` | Internal supervisor PID so the child exits if `--watch` dies |
| `NO_COLOR` | CLI output | Presence (any value) disables ANSI colors in CLI diagnostics |

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

### `FF_MAX_HEAP` — main heap limit

Sets the QuickJS main heap limit at startup (`8MB`–`4GB`, default `64MB`, integer sizes with optional `K`/`KB`, `M`/`MB`, `G`/`GB` suffixes):

```sh
FF_MAX_HEAP=256MB ff server.js --allow-net=0.0.0.0:3000
```

An explicit `--max-heap` flag on the command line overrides `FF_MAX_HEAP`.

### `FF_CPU_BUDGET` — JS CPU interrupt watchdog

Interrupts consecutive synchronous JS execution after `N` milliseconds (`0`–`3600000`, default `0` = disabled) on `ff <file.js>`, `ff -e`, HTTP handlers, timers, microtasks, streams, and worker eval/`onmessage` (top-level eval in `ff start`, `ff test`, `ff repl`, `.ffbc`, and `--standalone` is not guarded):

```sh
FF_CPU_BUDGET=1000 ff worker-heavy.js
```

An explicit `--cpu-budget` flag overrides `FF_CPU_BUDGET`. Requires no `--allow-env` grant.

`FF_CA_FILE` only changes trust. It does **not** grant network access:
outbound `fetch` / `WebSocket` calls still need `--allow-net` for their
host and port.

Unlike `--ca` (which `ff start` silently ignores; `--ca` works on `ff <file>`, `ff -e`, and `ff --watch <file>`), `FF_CA_FILE` works everywhere, including `ff start`. If neither `--ca` nor `FF_CA_FILE` is set, outbound TLS falls back to trusting `FF_CERT` when present — handy for self-signed dev loops.

## Reading env in code

`process.env` is a plain object snapshot of the environment at startup,
filtered by `--allow-env`. Only granted names appear; everything else is
`undefined`:

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
  --allow-net=0.0.0.0:4242
curl http://127.0.0.1:4242/
# ok
```

> **Note:** Bare `--allow-env` grants every name; `--allow-env=PORT,API_TOKEN`
> grants just those two. `process.env` is populated once at startup — see below
> for loading `.env` files explicitly with `--env-file`.

### Loading a `.env` file (`--env-file`)

No `.env` file is read automatically, but you can pass `--env-file <path>` (or `--env-file=<path>`) on the CLI:

```sh
ff config.js --env-file=.env.production --allow-env=PORT,API_TOKEN --allow-net=0.0.0.0:4242
```

- **Syntax**: `KEY=VALUE` per line; blank lines and `#` comments are skipped; surrounding spaces/tabs/`\r` are trimmed and matching `'...'` or `"..."` quotes around `VALUE` are stripped.
- **Size & missing files**: capped at 2 MB; if the file is missing or unreadable, startup continues silently without failing.
- **Precedence**: OS environment variables always take precedence over values in `--env-file`.
- **Permissions & scope**: entries from `--env-file` are still filtered by `--allow-env` and only populate JavaScript `process.env` (they do not alter OS env vars read by `FF_*` runtime flags or the global `sql` pool).

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
is active. The same applies to `FF_CERT`, `FF_KEY`, `FF_CA_FILE`, `FF_MAX_HEAP`,
`FF_CPU_BUDGET`, `FF_WATCH_PARENT`, and `NO_COLOR`.

### Database environment variables

The built-in Postgres client (`sql` global) inspects database configuration variables when granted by `--allow-env`:

| Variable | Description |
|---|---|
| `PG_TEST_DSN` or `DATABASE_URL` | Full connection DSN (e.g. `postgres://user:pass@host:5432/db?sslmode=verify-full&sslrootcert=ca.pem`) |
| `PGHOST` | Database server host (default `127.0.0.1`) |
| `PGPORT` | Database server port (default `5432`) |
| `PGUSER` | Database user (default `postgres`) |
| `PGPASSWORD` | Database password |
| `PGDATABASE` | Database name (default `postgres`) |
| `PGSSLMODE` | Postgres TLS mode (`disable` or `verify-full`) |
| `PGSSLROOTCERT` | Path to PEM root CA bundle (requires `--allow-read=<path>`) |

Like application variables, these are only read if explicitly permitted with `--allow-env`:

```sh
ff app.js \
  --allow-net=db.internal:5432 \
  --allow-env=PGHOST,PGPORT,PGUSER,PGPASSWORD,PGDATABASE,PGSSLMODE,PGSSLROOTCERT \
  --allow-read=/etc/ssl/pg-ca.pem
```

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

**`process.env.X` is undefined** — either the variable was not exported (or not in `--env-file`), or `--allow-env` does not include it. Check both: `X=1 ff app.js --allow-env=X`. Note that `.env` files are only read when explicitly passed via `--env-file <path>`.

**`FF_ECHO` works but `process.env.FF_ECHO` is undefined** — expected.
`FF_*` variables are runtime config; JS sees them only with a matching
`--allow-env` grant.

**`--ca` ignored by `ff start`** — expected. Use `FF_CA_FILE` with `ff start`; `--ca` works with `ff <file>`, `ff -e`, and `ff --watch <file>`.

**`FF_CA_FILE` set but fetch still denied** — trust and permission are
separate. Add `--allow-net=<host>:<port>` for the request.

**TLS didn't start with env set** — both `FF_CERT` and `FF_KEY` must be set, files must exist and be within size caps, and explicit `--cert`/`--key` flags override env.

**Echo mode won't turn off** — `FF_ECHO=` (empty) and `FF_ECHO=0` both keep it on. `unset FF_ECHO` is the only way off.
