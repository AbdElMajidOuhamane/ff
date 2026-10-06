---
title: Installation
description: Build Fairyfly from source with Zig, install it on PATH, or use Docker.
order: 2
---

# Installation

Build from source with Zig, or run the prebuilt binary in Docker.

## Prerequisites

| Tool | Why | Where |
|------|-----|-------|
| **Zig 0.16** | Compiler — the only hard requirement | [ziglang.org/download](https://ziglang.org/download/) |
| **Make** | `build` / `install` / `test` shortcuts | macOS: Xcode CLT (`xcode-select --install`); Linux: `build-essential` |
| **Git** | Clone the repo | any package manager |
| **curl** | Only for `ff upgrade` | any package manager |

Check Zig first — Fairyfly requires 0.16:

```sh
zig version
# 0.16.0
```

## Build from source

```sh
git clone <repo-url>
cd fairyfly
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
ff server.js
ff --version
```

> **Note:** Installs go to `~/.local/bin/ff`, never `/usr/local/bin`. This project has no `sudo make install` path — if you need a system-wide binary, copy it there yourself.

### Uninstall

```sh
make uninstall
```

Removes `~/.local/bin/ff` only. Zig caches are untouched.

## Docker

```sh
docker build -t fairyfly .
docker run -p 3000:3000 fairyfly ff server.js
curl http://127.0.0.1:3000/
```

The listen port is set in code via `http.serve({ port })` (default `3000`), not by an env var — map the host port to the same port your code listens on.

## Other Make targets

| Target | What it does |
|--------|--------------|
| `make build` | `zig build -Doptimize=ReleaseFast` |
| `make install` | Build + copy to `~/.local/bin/ff` |
| `make uninstall` | Delete `~/.local/bin/ff` |
| `make test` | Build + `zig build test` + `test/run.sh` |
| `make ci` | Build + `test/run.sh` |

## Troubleshooting

**Zig version mismatch** — `zig version` must print `0.16.x`. With 0.15 or earlier, download 0.16 from the link above and retry.

**Make not found** — macOS: `xcode-select --install`. Debian/Ubuntu: `sudo apt install build-essential`.

**`ff: command not found` after `make install`** — `~/.local/bin` isn't on `PATH`. Add the export shown by Make, then open a new shell.

**Permission denied** — prefer `make install` (user-local). Don't `sudo` anything; this project doesn't ship a system-install path.

**Docker: connection refused** — confirm `http.serve({ port })` matches the `-p` mapping and the handler is actually registered (try `FF_ECHO=1` smoke mode first).
