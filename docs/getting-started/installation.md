---
title: Installation
description: Install the prebuilt binary with curl, build from source with Zig, or use Docker.
order: 2
---

# Installation

Install the prebuilt binary in one line, build from source with Zig, or run it in Docker.

## Quick install

macOS (Apple silicon / Intel) and Linux (x86_64 / ARM64):

```sh
curl -fsSL https://raw.githubusercontent.com/AbdElMajidOuhamane/ff/main/install.sh | sh
```

The installer detects your OS and architecture, downloads the matching binary
from the latest GitHub release, verifies its SHA-256 checksum, and installs to
`~/.local/bin/ff`. If `~/.local/bin` isn't on your `PATH`, it prints the
`export` line to add. Update anytime with:

```sh
ff upgrade
```

| Platform | Asset |
|---|---|
| macOS (Apple silicon) | `ff-macos-aarch64` |
| macOS (Intel) | `ff-macos-x86_64` |
| Linux (x86_64) | `ff-linux-x86_64` |
| Linux (ARM64) | `ff-linux-aarch64` |

Prefer containers? `docker pull ghcr.io/abdelmajidouhamane/ff:latest`.

The rest of this page covers Docker and building from source.

## Prerequisites

| Tool | Why | Where |
|------|-----|-------|
| **Zig 0.16** | Compiler — the only hard requirement for source builds | [ziglang.org/download](https://ziglang.org/download/) |
| **Make** | `build` / `install` / `test` shortcuts | macOS: Xcode CLT (`xcode-select --install`); Linux: `build-essential` |
| **Git** | Clone the repo | any package manager |
| **curl** | Quick install and `ff upgrade` | any package manager |

Check Zig first — Fairyfly requires 0.16:

```sh
zig version
# 0.16.0
```

## Build from source

The vendors (QuickJS, BearSSL, SQLite, nghttp2) are gitignored — fetch them
first (pinned versions, SHA-256 verified), then build:

```sh
git clone <repo-url>
cd fairyfly
./scripts/fetch-vendors.sh
make build
```

`make build` runs:

```sh
zig build -Doptimize=ReleaseFast
```

This compiles everything: QuickJS, BearSSL, SQLite, nghttp2, libxev, and the runtime itself. The first build takes 1–2 minutes. The binary lands at:

```text
./zig-out/bin/ff
```

> **Note:** There is no `make build-native` target. `make build` is the only build.

## Run it

```sh
./zig-out/bin/ff --version
./zig-out/bin/ff -e 'console.log("hello from fairyfly")'
# hello from fairyfly
```

Or scaffold a project and start it:

```sh
./zig-out/bin/ff init -y demo
cd demo
../zig-out/bin/ff start
```

The generated `main.js` only logs, so it needs no grants. Program loading is a
carve-out: `ff start` reads `ff.json` and its `main` without `--allow-read`.
Once `main.js` calls `http.serve`, start it with the listener scope:

```sh
../zig-out/bin/ff start --allow-net=0.0.0.0:3000
```

## Permissions

The binary is deny-by-default. A loaded script cannot read files, open
sockets, inspect `process.env`, spawn processes, or load native libraries
until the launch command grants it.

```sh
ff server.js --allow-net=0.0.0.0:3000
ff notes.js --allow-read=notes.db --allow-write=.
ff tool.js --allow-run=git
ff addon.js --allow-ffi
ff test --allow-all
```

- Flags are CLI-only. There is no `ff.json` field and no environment variable
  that grants access.
- Scopes are comma-split and repeatable: `--allow-read=src,views`.
- A bare flag grants the whole category: `--allow-net` means any host and port.
- `ff start` takes the flags after `start`; `ff --watch` forwards them to the
  child it restarts.
- `ff test` applies the flags to every test file in that run. The repo's
  `test/run.sh` uses `--allow-all` because the suite exercises every category.
- A missing grant fails before I/O with `PermissionDenied` /
  `PERMISSION_DENIED`. FFI is the exception: `ffi.dlopen` / `ffi.callback`
  throw `TypeError` without a `code`.
- `--allow-run` and `--allow-ffi` are trust-equivalent to full access.
  Permissions catch mistakes; they are not an OS sandbox.

`globalThis.permissions` reports the six enabled categories as booleans:

```sh
ff -e 'console.log(JSON.stringify(permissions))' --allow-read=.
# {"read":true,"write":false,"net":false,"env":false,"run":false,"ffi":false}
```

It does not expose the scopes, and reassigning its properties does not change
enforcement. Full model: [Permissions](/docs/concepts/permissions).

## Install on PATH

```sh
make install
```

This copies the binary to:

```text
~/.local/bin/ff
```

If `~/.local/bin` isn't on your `PATH`, Make tells you; add it (e.g. in `~/.zshrc`):

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Then from anywhere:

```sh
ff server.js --allow-net=0.0.0.0:3000
ff --version
```

A server that also reads static files needs the matching read scope, for
example `--allow-read=./public`.

> **Note:** Installs go to `~/.local/bin/ff`, never `/usr/local/bin`. This project has no `sudo make install` path — if you need a system-wide binary, copy it there yourself.

### Uninstall

```sh
make uninstall
```

Removes `~/.local/bin/ff` only. Zig caches are untouched.

## Docker

The image contains the `ff` binary, not your app. Mount the app or bake it into
a derived image:

```sh
docker build -t fairyfly .

# terminal 1 — mount the current directory as /app
docker run --rm -p 3000:3000 -v "$PWD":/app \
  fairyfly ff server.js --allow-net=0.0.0.0:3000

# terminal 2
curl http://127.0.0.1:3000/
```

`ff.json` inside the image does **not** carry the permission policy. Put the
`--allow-*` flags in the container command (or the image `CMD`). A listener on
port 3000 needs `--allow-net=0.0.0.0:3000`; static files read with `fs` need
`--allow-read=/app/public` (or whichever path the app uses).

The listen port comes from `http.serve({ port })` (default `3000`). The
runtime has no `FF_PORT` or `--port` override. If the app reads `PORT`, add
`--allow-env=PORT` and `-e PORT=3000`, then make the net scope match that port.

> **io_uring images need a permissive seccomp profile.** Docker's default
> profile blocks io_uring; run with `--security-opt seccomp=unconfined`, or
> build an image with `zig build -Dio_uring=false` for an epoll binary.

## Other Make targets

| Target | What it does |
|--------|--------------|
| `make build` | `zig build -Doptimize=ReleaseFast` |
| `make install` | Build + copy to `~/.local/bin/ff` |
| `make uninstall` | Delete `~/.local/bin/ff` |
| `make fixtures` | Rebuild the C fixture for `test/ffi.test.js` with `zig cc` |
| `make fmt` | `zig fmt --check build.zig src/` (the CI `tidy` job) |
| `make test` | Build + fixtures + `zig build test` + `test/run.sh` |
| `make ci` | `fmt` + build + fixtures + `zig build test` + `test/run.sh` + fuzz smoke |
| `make cov` | kcov line coverage into `kcov-output/` (requires `kcov`) |
| `make doctor` | Print Xcode/SDK/DEVELOPER_DIR/zig state and probe Zig's libc++ build |

## Troubleshooting

**Zig version mismatch** — `zig version` must print `0.16.x`. With 0.15 or earlier, download 0.16 from the link above and retry.

**Make not found** — macOS: `xcode-select --install`. Debian/Ubuntu: `sudo apt install build-essential`.

**macOS: `error: sub-compilation of libcxx failed` / `INFINITY`** — the selected SDK is the macOS 26/27 one from CommandLineTools, which Zig 0.16.0's bundled libc++ cannot compile against. Run `make doctor`; it reports the state. Fix with `sudo xcode-select -s /Applications/Xcode.app` (the Makefile also selects Xcode automatically when CLT is active).

**macOS: `ld: unknown architecture arm64e.x1`** — an older Xcode linker paired with a newer CLT SDK. The test fixture now builds with `zig cc`, so `make test` is unaffected; for other C projects either align `xcode-select` or set `SDKROOT` to the Xcode SDK.

**`ff: command not found` after `make install`** — `~/.local/bin` isn't on `PATH`. Add the export shown by Make, then open a new shell.

**`Permission denied` while installing** — prefer `make install` (user-local). Don't `sudo` anything; this project has no system-install path.

**Runtime `PermissionDenied`** — the script hit an ungranted API. The message names the flag and scope, for example
`http.serve requires --allow-net for '0.0.0.0:3000'`. Add the flag to the
same command; `ff.json` and environment variables cannot grant it.

**Docker: `PermissionDenied` in the logs** — add the runtime flags to the
container command (or image `CMD`). A listener on port 3000 needs
`--allow-net=0.0.0.0:3000`.

**Docker: connection refused** — confirm `http.serve({ port })` matches the `-p` mapping and the handler is actually registered (try `FF_ECHO=1` smoke mode first). If the logs show `PermissionDenied`, fix the missing grant before debugging the port.

## See also

- [Quickstart](/docs/getting-started/quickstart) — first script and server
- [Permissions](/docs/concepts/permissions) — flags, scopes, denial contract
- [Deploy](/docs/guides/deploy) — production start commands and Docker
- [CLI](/docs/reference/cli) — every command and flag
