---
title: Deploy
description: Ship Fairyfly — build, install, Docker, ff start, smoke-test, and TLS.
order: 7
---

# Deploy

A deploy is: get the binary — prebuilt with `curl -fsSL …/install.sh | sh`
(see [Installation](/docs/getting-started/installation)), pull
`ghcr.io/abdelmjidouhamane/ff:latest`, or build from source (below) — get your
code on the box, start it with `ff start` (or `ff server.js`), then verify with
`FF_ECHO` before opening traffic.

## Quick look

```sh
./scripts/fetch-vendors.sh   # first run only — vendors are gitignored
make install                 # build + copy to ~/.local/bin/ff
ff init -y demo && cd demo
ff start
```

```sh
curl http://127.0.0.1:3000/
```

## Get the binary

Three options, all producing the same `ff`:

**Prebuilt binary.** The installer detects your OS/arch, downloads the matching
asset from the latest GitHub release, verifies its SHA-256 against
`sha256sums.txt`, and installs to `~/.local/bin/ff`:

```sh
curl -fsSL https://raw.githubusercontent.com/AbdElMajidOuhamane/ff/main/install.sh | sh
```

It honors a preset `FF_INSTALL_DIR` if you want a different destination
(`curl -fsSL …/install.sh | FF_INSTALL_DIR=/usr/local/bin sh`). Published assets:

| Platform | Asset |
|----------|-------|
| macOS (Apple silicon) | `ff-macos-aarch64` |
| macOS (Intel) | `ff-macos-x86_64` |
| Linux (x86_64) | `ff-linux-x86_64` |
| Linux (ARM64) | `ff-linux-aarch64` |

Release binaries are built with `-Dffi=false` and `-Dversion=<tag>`; update in
place with `ff upgrade` (add `--check` to only compare versions).

**Docker.** `ghcr.io/abdelmjidouhamane/ff:latest` (multi-arch, plus
`:vX.Y.Z` tags). See [Docker](#docker).

**From source.**

```sh
git clone <repo-url>
cd fairyfly
./scripts/fetch-vendors.sh   # pinned vendors, SHA-256 verified
make build                   # zig build -Doptimize=ReleaseFast (writes the ff binary)
make install                 # build, then copy the binary to ~/.local/bin/ff
```

| Target | Effect |
|--------|--------|
| `make build` | `zig build -Doptimize=ReleaseFast` — compiles QuickJS, BearSSL, SQLite, nghttp2, libxev, and the runtime |
| `make install` | `make build`, then copy to `~/.local/bin/ff` |
| `make uninstall` | Delete `~/.local/bin/ff` |
| `make fixtures` | Build the C fixture for `test/ffi.test.js` |
| `make test` / `make ci` | Build + fixtures + `zig build test` + `test/run.sh` |

Build options:

```sh
zig build -Doptimize=ReleaseFast   # make build's invocation
zig build -Dbearssl=false          # drop TLS support entirely
zig build -Dio_uring=false         # Linux: epoll backend instead of io_uring
zig build -Dffi=false              # keep `ffi` global, but dlopen/callback throw
zig build -Dversion=1.2.3          # version reported by `ff --version`
```

> **Note:** Installs land in `~/.local/bin/ff`, never `/usr/local/bin`. If `ff`
> isn't found after install, add that directory to `PATH`:
>
> ```sh
> export PATH="$HOME/.local/bin:$PATH"
> ```

There is no `make build-native` target.

### I/O backend on Linux

On Linux the default build uses **io_uring**; `-Dio_uring=false` selects the
**epoll** backend. io_uring needs Linux 5.1+ and a seccomp policy that permits
`io_uring_setup` / `io_uring_enter` / `io_uring_register`. When the selected
backend is unavailable the process fails fast:

```text
ff: I/O backend unavailable (io_uring requires Linux 5.1+ and must not be blocked by seccomp; rebuild with -Dio_uring=false for epoll)
```

macOS always uses kqueue.

## Run with `ff start`

`ff start` reads `main` from `ff.json` and runs that file — this is the
production entrypoint. It requires an `ff.json` whose `main` field names an
existing file (read up to 10 MB), plus `node_modules/` if that file imports bare
packages.

```sh
ff init -y my-app
cd my-app
ff start
```

```sh
curl http://127.0.0.1:3000/
```

The listen port comes from `http.serve({ port })` in your code (default `3000`,
which binds `0.0.0.0`). Match whatever your platform expects:

```js
// main.js — port from the environment, default 3000
const port = Number(process.env.PORT ?? 3000);
http.serve({ port }, (url, method, body) => new Response("ok"));
```

```sh
PORT=8080 ff start
curl http://127.0.0.1:8080/
# ok
```

> **Caution:** There is no `FF_PORT` and no `--port` flag — nothing overrides the
> port in code. If a deploy gets connection-refused, compare that port with the
> platform/Docker mapping first.

`ff start` also accepts `--cert`/`--key` (see TLS below). Other than that it
takes no options; to run a specific file, use `ff server.js` directly. During
development, `ff --watch start` restarts the child on file changes.

## Docker

The repo's `Dockerfile` is a two-stage build that produces a small runtime image
containing only the binary — **no `EXPOSE`, no `CMD`, and no app code**. You
supply the code and the command.

```dockerfile
# syntax=docker/dockerfile:1
FROM debian:bookworm AS build
# ...install Zig 0.16.0, copy the repo...
RUN sh scripts/fetch-vendors.sh
RUN zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl -Dffi=false -Dio_uring=true

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
RUN adduser -D -u 1000 app
WORKDIR /app
COPY --from=build <built ff binary> /usr/local/bin/ff
USER app
```

Build the image, then mount your project at `/app` and run it:

```sh
docker build -t fairyfly .
docker run --rm -p 3000:3000 -v "$PWD:/app" -w /app fairyfly ff start
curl http://127.0.0.1:3000/
```

The image runs as the non-root user `app` (uid 1000), so mounted files must be
readable by that user, and `node_modules/` must already be present (run
`ff imprint` on the host or in a build step). The `-p` mapping must match the
port in `http.serve({ port })`; the container already binds `0.0.0.0`.

> **io_uring images need a permissive seccomp profile.** The published image is
> built with `-Dio_uring=true`, and Docker's default seccomp profile blocks the
> io_uring syscalls, so the process exits at startup with
> `ff: I/O backend unavailable…`. Run with
> `--security-opt seccomp=unconfined`, or build your own image with
> `-Dio_uring=false` for a run-anywhere epoll binary.

### Docker Compose (Postgres)

`docker-compose.yml` in the repo starts only a **Postgres 16** service for local
development of the `sql` API — it is not an app definition:

```sh
docker compose up -d          # postgres:fairyfly on localhost:5432
DATABASE_URL=postgres://fairyfly:fairyfly@localhost:5432/fairyfly ff server.js
```

## Smoke-test before traffic

Start with `FF_ECHO=1` so every request returns canned `200 {"message":"ok"}`
without running app logic. This separates "is the deploy reachable" from "does
my code work":

```sh
FF_ECHO=1 ff start &
curl -i http://127.0.0.1:3000/health
# HTTP/1.1 200 OK
# {"message":"ok"}
kill %1
ff start   # real handler
```

## TLS in production

Terminate TLS inside Fairyfly with a real certificate (the TLS guide has the
full walkthrough):

```sh
ff start --cert /etc/ssl/cert.pem --key /etc/ssl/key.pem
# or via env:
FF_CERT=/etc/ssl/cert.pem FF_KEY=/etc/ssl/key.pem ff start
```

Both must be given together; on success the same port serves HTTPS and WSS
alongside plain HTTP/WS (`[https] TLS enabled (cert=… key=…) — https/wss on the
same port`). Size caps: cert ≤ 512 KB, key ≤ 256 KB. The served certificate is
also trusted by the runtime's own outbound `fetch`/`WebSocket` client. Behind a
platform load balancer that terminates TLS for you, skip these and serve plain
HTTP.

## Practical example: health-checked service

```js
// main.js
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
ff start
curl http://127.0.0.1:3000/health
# {"ok":true,"uptimeMs":123}
```

Point your platform's health check at `/health` and assert on `ok: true`.

## Troubleshooting

**Connection refused after deploy** — port mismatch: compare `http.serve({ port })`, `PORT`, and the Docker `-p` / platform port. Nothing overrides the code port.

**`ff: command not found`** — `~/.local/bin` isn't on `PATH`. Export it and open a new shell.

**TLS didn't start** — both cert and key are required (together), within the size caps (cert ≤ 512 KB, key ≤ 256 KB), and readable by the process user.

**App boots but handlers 504** — the server's 30 s watchdog reaps hung handlers. Move heavy work to `Worker` threads (max 8) and reply early.

**`ff: I/O backend unavailable`** — this binary uses io_uring (Linux 5.1+, seccomp must allow `io_uring_setup`/`io_uring_enter`/`io_uring_register`). On Docker and most managed platforms the default seccomp profile blocks it: run with `--security-opt seccomp=unconfined`, or rebuild with `-Dio_uring=false` (epoll). The published image is an io_uring image.
