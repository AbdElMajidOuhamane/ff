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

**Permission denied** — prefer `make install` (user-local). Don't `sudo` anything; this project has no system-install path.

**Docker: connection refused** — confirm `http.serve({ port })` matches the `-p` mapping and the handler is actually registered (try `FF_ECHO=1` smoke mode first).
