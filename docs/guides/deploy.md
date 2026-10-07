---
title: Deploy
description: Ship Fairyfly — build, install, Docker, ff start, smoke-test, and TLS.
order: 7
---

# Deploy

A deploy is: get the binary — prebuilt with `curl -fsSL …/install.sh | sh`
(see [Installation](/docs/getting-started/installation)), pull
`ghcr.io/abdelmjidouhamane/ff:latest`, or build from source (below) — get your
code on the box, start it with `ff start` (or `ff server.js`), and verify with
`FF_ECHO` before opening traffic.

## Quick look

```sh
./scripts/fetch-vendors.sh   # first run only — vendors are gitignored
make build
./zig-out/bin/ff start
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
| `make test` | Build + `zig build test` + `test/run.sh` |

> **Note:** Installs land in `~/.local/bin/ff`, not `/usr/local/bin`. If `ff` isn't found after install, add the dir to `PATH`:
>
> ```sh
> export PATH="$HOME/.local/bin:$PATH"
> ```

There is no `make build-native` target.

On Linux the I/O backend is io_uring by default; build with
`zig build -Dio_uring=false` for an epoll binary that runs anywhere. See the
README's "I/O backend on Linux" for the kernel and seccomp requirements.

## Run with `ff start`

`ff start` reads `main` from `ff.json` and runs it — this is the production entrypoint:

```sh
ff init -y my-app
cd my-app
ff start
```

```sh
curl http://127.0.0.1:3000/
```

The listen port comes from `http.serve({ port })` in your code (default `3000`, binds `0.0.0.0`). Match whatever your platform expects:

```js
// server.js — port from the environment, default 3000
const port = Number(process.env.PORT ?? 3000);
http.serve({ port }, (url, method, body) => new Response("ok"));
```

```sh
PORT=8080 ff start
curl http://127.0.0.1:8080/
# ok
```

> **Caution:** No `FF_PORT`, no `--port` flag. If deploys get connection-refused, the port in code and the platform's expected port disagree — that's the first thing to check.

## Docker

```dockerfile
# Dockerfile
FROM alpine:3 AS build
# ... build steps produce /ff ...
FROM alpine:3
COPY --from=build /ff /usr/local/bin/ff
COPY ff.json server.js ./
EXPOSE 3000
CMD ["ff", "start"]
```

```sh
docker build -t fairyfly .
docker run -p 3000:3000 fairyfly
curl http://127.0.0.1:3000/
```

The `-p` mapping must match the port in `http.serve({ port })` — the container binds `0.0.0.0` already, so only the mapping can be wrong.

> **io_uring images need a permissive seccomp profile.** The published image
> is built with io_uring; Docker's default profile blocks it and the process
> exits at startup with `ff: I/O backend unavailable…`. Run with
> `--security-opt seccomp=unconfined`, or build your image with
> `zig build -Dio_uring=false` for a run-anywhere epoll binary.

## Smoke-test before traffic

Start with `FF_ECHO=1` so every request returns canned `200 {"message":"ok"}` without running app logic. This separates "is the deploy reachable" from "does my code work":

```sh
FF_ECHO=1 ff start &
curl -i http://127.0.0.1:3000/health
# HTTP/1.1 200 OK
# {"message":"ok"}
kill %1
ff start   # real handler
```

## TLS in production

Terminate TLS in Fairyfly with a real certificate (see the TLS guide for the full walkthrough):

```sh
ff start --cert /etc/ssl/cert.pem --key /etc/ssl/key.pem
# or via env:
FF_CERT=/etc/ssl/cert.pem FF_KEY=/etc/ssl/key.pem ff start
```

Both must be given together; on success the same port serves HTTPS and WSS alongside plain HTTP/WS. Behind a platform load balancer that terminates TLS for you, skip these and serve plain HTTP.

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
ff start
curl http://127.0.0.1:3000/health
# {"ok":true,"uptimeMs":123}
```

Point your platform's health check at `/health` and assert on `ok: true`.

## Troubleshooting

**Connection refused after deploy** — port mismatch: compare `http.serve({ port })`, `PORT`, and the Docker `-p` / platform port. Nothing overrides the code port.

**`ff: command not found`** — `~/.local/bin` isn't on `PATH`. Export it and open a new shell.

**TLS didn't start** — both cert and key required, within size caps (cert ≤ 512KB, key ≤ 256KB), paths readable by the process user.

**App boots but handlers 504** — the 30s watchdog is firing under load. Move heavy work to `Worker` threads (max 8) and reply early.

**`ff: I/O backend unavailable`** — this binary uses io_uring (Linux 5.1+,
seccomp must allow `io_uring_setup`/`io_uring_enter`/`io_uring_register`).
On Docker and most managed platforms the default seccomp profile blocks it:
run with `--security-opt seccomp=unconfined`, or rebuild with
`-Dio_uring=false` (epoll). The published image is an io_uring image.
