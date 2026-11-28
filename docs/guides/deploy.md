---
title: Deploy
description: Ship Fairyfly — build, install, Docker, ff start, smoke-test, and TLS.
order: 7
---

# Deploy

A deploy is: get the binary — prebuilt with `curl -fsSL …/install.sh | sh`
(see [Installation](/docs/getting-started/installation)), pull
`ghcr.io/abdelmajidouhamane/ff:latest`, or build from source (below) — get your
code on the box, start it with `ff start` (or `ff server.js`), and verify with
`FF_ECHO` before opening traffic.

## Permissions

Production runs deny-by-default just like local runs. `ff start` does **not**
read permissions from `ff.json` or from environment variables — pass `--allow-*`,
`--deny-*`, `--env-file`, and production limit flags (`--max-heap`, `--max-stack`,
`--worker-heap`, `--cpu-budget`) on the command line:

```sh
ff start --allow-net=0.0.0.0:3000 --max-heap=128MB --cpu-budget=2000
```

Minimum for a normal web service:

| Need | Flag |
|---|---|
| The listener | `--allow-net=<hostname>:<port>` (default `0.0.0.0:<port>`) |
| `process.env.PORT` / other app vars | `--allow-env=PORT,...` |
| Reading files / `Response.file` / TLS paths in JS | `--allow-read=<path>` |
| Writing files / SQLite | `--allow-write=<path>` |
| Subprocesses | `--allow-run=<program>` |
| FFI | `--allow-ffi` |

- The listener binds `0.0.0.0` by default unless `{ hostname }` is set in
  `http.serve`; match `--allow-net` to that `<hostname>:<port>` (not the
  platform's public hostname or `127.0.0.1` unless you explicitly bound `127.0.0.1`).
- Initial grants come only from CLI flags (nothing can add scopes at runtime),
  though applications can drop/narrow privileges after initialization via
  `permissions.revoke()`, and `--deny-read=` / `--deny-write=` / `--deny-net=`
  block specific paths or hosts even inside broader allows.
- `--allow-all` exists for fully trusted apps but gives up every boundary; do
  not use it as a deploy default.
- `FF_ECHO`, `FF_MAX_HEAP`, and `FF_CPU_BUDGET` are runtime configuration, not
  app env: they need no `--allow-env`, and `FF_ECHO` does not bypass `--allow-net`.

A missing grant usually fails at startup with `PermissionDenied` and a
non-zero exit; check the process logs before debugging the platform.

Full model: [Permissions](/docs/concepts/permissions).

## Quick look

```sh
./scripts/fetch-vendors.sh   # first run only — vendors are gitignored
make build
./zig-out/bin/ff start --allow-net=0.0.0.0:3000
```

```sh
curl http://127.0.0.1:3000/
```

## Build and install

```sh
git clone <repo-url>
cd fairyfly
./scripts/fetch-vendors.sh   # pinned vendors, SHA-256 verified
make build          # zig build -Doptimize=ReleaseFast -> ./zig-out/bin/ff
make install        # copy to ~/.local/bin/ff
```

| Target | Effect |
|--------|--------|
| `make build` | Compile everything (QuickJS, BearSSL, SQLite, nghttp2, xev, runtime) |
| `make install` | Build + copy the binary to `~/.local/bin/ff` |
| `make uninstall` | Delete `~/.local/bin/ff` |
| `make test` | Build + fixtures + `zig build test` + `test/run.sh` |

> **Note:** Installs land in `~/.local/bin/ff`, not `/usr/local/bin`. If `ff` isn't found after install, add the dir to `PATH`:
>
> ```sh
> export PATH="$HOME/.local/bin:$PATH"
> ```

There is no `make build-native` target.

On Linux the I/O backend is io_uring by default; build with
`zig build -Dio_uring=false` for an epoll binary that runs anywhere. See the
README's "Building from source" section for the kernel and seccomp requirements.

## Run with `ff start`

`ff start` reads `main` from `ff.json` and runs it — this is the production entrypoint:

```sh
ff init -y my-app
cd my-app
cat > main.js <<'EOF'
http.serve({ port: 3000 }, () => new Response("ok"));
EOF
ff start --allow-net=0.0.0.0:3000
```

```sh
curl http://127.0.0.1:3000/
# ok
```

The listen host and port come from `http.serve({ hostname, port })` in your code (defaults: `hostname` `"0.0.0.0"`, `port` `3000`). Match whatever your platform expects:

```js
// server.js — port from the environment, default 3000
const port = Number(process.env.PORT ?? 3000);
http.serve({ port }, (url, method, body) => new Response("ok"));
```

```sh
PORT=8080 ff start \
  --allow-env=PORT \
  --allow-net=0.0.0.0:8080
curl http://127.0.0.1:8080/
# ok
```

> **Caution:** No `FF_PORT`, no `--port` flag. If deploys get connection-refused, the port in code and the platform's expected port disagree — that's the first thing to check. The net scope must match the same port.

## Docker

```dockerfile
# Dockerfile
FROM alpine:3 AS build
# ... build steps produce /ff ...
FROM alpine:3
RUN apk add --no-cache ca-certificates
COPY --from=build /ff /usr/local/bin/ff
COPY ff.json server.js ./
EXPOSE 3000
CMD ["ff", "start", "--allow-net=0.0.0.0:3000"]
```

```sh
docker build -t fairyfly .
docker run --security-opt seccomp=unconfined -p 3000:3000 fairyfly
curl http://127.0.0.1:3000/
```

`ff.json` carries the entrypoint, not the permission policy. Keep the
`--allow-*` flags in `CMD` (or the platform's start command). If the app reads
`PORT`, add `--allow-env=PORT` and make the net scope match.

The `-p` mapping must match the port in `http.serve({ port })` — the container binds `0.0.0.0` by default unless `hostname` is set, so match `-p` and `--allow-net` to the bound address and port.

> **io_uring images need a permissive seccomp profile.** The published image
> is built with io_uring; Docker's default profile blocks it and the process
> exits at startup with `ff: I/O backend unavailable…`. Run with
> `--security-opt seccomp=unconfined`, or build your image with
> `zig build -Dio_uring=false` for a run-anywhere epoll binary.

## Smoke-test before traffic

Start with `FF_ECHO=1` so every request returns canned `200 {"message":"ok"}` without running app logic. This separates "is the deploy reachable" from "does my code work":

```sh
FF_ECHO=1 ff start --allow-net=0.0.0.0:3000 &
curl -i http://127.0.0.1:3000/health
# HTTP/1.1 200 OK
# {"message":"ok"}
kill %1
ff start --allow-net=0.0.0.0:3000   # real handler
```

Echo mode bypasses the handler, not the listener check — the `--allow-net`
grant is still required.

## TLS in production

Terminate TLS in Fairyfly with a real certificate (see the [TLS guide](/docs/guides/tls) for details and current caveats):

```js
// server.js — pass tls: { cert, key } directly to http.serve
http.serve(
  { port: 3000, tls: { cert: "/etc/ssl/cert.pem", key: "/etc/ssl/key.pem" } },
  () => new Response("ok"),
);
```

```sh
ff start --allow-net=0.0.0.0:3000 --allow-read=/etc/ssl/cert.pem,/etc/ssl/key.pem
```

> **Known issue:** `ff start` also accepts `--cert` / `--key` (and `FF_CERT` / `FF_KEY`) before JS runs without needing `--allow-read`, **but** calling `http.serve({ port }, handler)` without a `tls` option currently disables TLS on the listener (overriding CLI TLS). Pass `{ tls: { cert, key } }` in `http.serve` until that interaction is fixed. When TLS is active, the listener serves HTTPS/WSS/HTTP/2 **only** (replacing plain HTTP/WS on that port).

Behind a platform load balancer that terminates TLS for you, skip TLS in Fairyfly and serve plain HTTP. The listener still needs `--allow-net=<hostname>:<port>`.

## Practical example: health-checked service

```js
// server.js
const port = Number(process.env.PORT ?? 3000);
const started = Date.now();

http.serve({ port }, (url, method, body) => {
  const path = new URL(url, "http://localhost").pathname;
  if (path === "/health") {
    return Response.json({ ok: true, uptimeMs: Date.now() - started });
  }
  return new Response("ok");
});
```

```sh
ff start --allow-env=PORT --allow-net=0.0.0.0:3000
curl http://127.0.0.1:3000/health
# {"ok":true,"uptimeMs":123}
```

Point your platform's health check at `/health` and assert on `ok: true`.

## Troubleshooting

**`PermissionDenied` at startup** — the listener port/host is outside every
`--allow-net` scope. Add `--allow-net=<hostname>:<port>` (default `0.0.0.0:<port>`)
to the `ff start` command (or Docker `CMD`). `127.0.0.1` and the platform hostname
will not match the default `0.0.0.0` bind address unless `{ hostname }` is passed in `http.serve`.

**`process.env.PORT` is undefined in production** — add
`--allow-env=PORT`. The variable is filtered out of `process.env`, while the
platform may still have exported it. `ff.json` and env vars cannot grant this.

**TLS files denied or CLI `--cert` / `--key` inactive** — CLI `--cert` / `--key`
are read before the runtime and need no `--allow-read`, **but** calling
`http.serve({ port }, handler)` without an `opts.tls` object currently disables
TLS on the listener (known issue). Pass `{ tls: { cert, key } }` in `http.serve`
along with `--allow-read` for both paths.

**Connection refused after deploy** — port mismatch: compare `http.serve({ port })`, `PORT`, the `--allow-net` port, and the Docker `-p` / platform port. Nothing overrides the code port.

**`ff: command not found`** — `~/.local/bin` isn't on `PATH`. Export it and open a new shell.

**TLS didn't start** — both cert and key required, within size caps (cert ≤ 512KB, key ≤ 256KB), paths readable by the process user. A `PermissionDenied` message means a runtime `tls` path lacks `--allow-read`; a `TypeError` means a malformed or mismatched pair.

**App boots but handlers 504** — the 30s watchdog is firing under load. Move heavy work to `Worker` threads (max 8) and reply early.

**`ff: I/O backend unavailable`** — this binary uses io_uring (Linux 5.1+,
seccomp must allow `io_uring_setup`/`io_uring_enter`/`io_uring_register`).
On Docker and most managed platforms the default seccomp profile blocks it:
run with `--security-opt seccomp=unconfined`, or rebuild with
`-Dio_uring=false` (epoll). The published image is an io_uring image.

## See also

- [Permissions](/docs/concepts/permissions) — flags, scopes, denial contract
- [CLI reference](/docs/reference/cli) — `ff start` and permission flags
- [TLS guide](/docs/guides/tls) — certificate setup and trust
- [Limitations](/docs/reference/limitations) — every hard cap
