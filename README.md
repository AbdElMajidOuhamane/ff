<img src="assets/ff.webp" alt="Fairyfly logo" width="120" />

# Fairyfly Runtime

[![CI](https://github.com/AbdElMajidOuhamane/ff/actions/workflows/ci.yml/badge.svg)](https://github.com/AbdElMajidOuhamane/ff/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/AbdElMajidOuhamane/ff)](https://github.com/AbdElMajidOuhamane/ff/releases/latest)
[![License: MPL-2.0](https://img.shields.io/badge/license-MPL--2.0-blue.svg)](LICENSE)

A lightweight, backend-focused JavaScript runtime built with Zig and powered by
[QuickJS](https://bellard.org/quickjs/). Designed for fast startup, low memory,
and a small readable codebase.

> **138k req/sec · 0.66 ms p50 · 5 MB RSS** on Apple silicon (8-thread wrk, 100 conn).
> Outperforms Node 23, Bun 1.4, and Deno 2 — and uses ~10× less memory.
> Reproduce: `make build`, serve the hello-world handler, then
> `wrk -t8 -c100 -d10s http://127.0.0.1:3000/` (RSS sampled via `ps -o rss=`);
> see [Performance](#performance).

---

## Contents

1. [Documentation](#documentation)
2. [Installation](#installation)
3. [Why Fairyfly](#why-fairyfly)
4. [Quick start](#quick-start)
5. [Example tour](#example-tour)
6. [API at a glance](#api-at-a-glance)
7. [Performance](#performance)
8. [Architecture](#architecture)
9. [Building from source](#building-from-source)
10. [CLI reference](#cli-reference)
11. [Limitations vs Node / browser](#limitations-vs-node--browser)
12. [License](#license)

---

## Documentation

The full guide set lives in [`docs/`](docs/index.md) — 44 pages covering
everything this README summarizes.

| Section | Contents |
|---|---|
| [Getting started](docs/getting-started/introduction.md) | Introduction, installation, quickstart |
| [Guides](docs/index.md) | HTTP server, fetch, WebSocket, TLS, HTTP/2, Postgres packages, modules, workers, timers, testing, bytecode, environment, deploy |
| [API reference](docs/api/overview.md) | Every global and module on one page |
| [Reference](docs/reference/cli.md) | CLI, limitations, examples |

---

## Installation

### Prebuilt binary (macOS and Linux)

```sh
curl -fsSL https://raw.githubusercontent.com/AbdElMajidOuhamane/ff/main/install.sh | sh
```

One command works on every supported platform — it detects your OS and
architecture, downloads the matching binary from the latest GitHub release,
verifies its SHA-256 checksum, and installs to `~/.local/bin/ff`:

| Platform | Asset |
|---|---|
| macOS (Apple silicon) | `ff-macos-aarch64` |
| macOS (Intel) | `ff-macos-x86_64` |
| Linux (x86_64) | `ff-linux-x86_64` |
| Linux (ARM64) | `ff-linux-aarch64` |

If `~/.local/bin` isn't on your `PATH`, the installer prints the `export` line
to add to your shell profile. Update anytime with:

```sh
ff upgrade
```

### Docker

```sh
docker pull ghcr.io/abdelmjidouhamane/ff:latest
docker run --rm ghcr.io/abdelmjidouhamane/ff:latest ff --version
```

### From source

See [Building from source](#building-from-source).

---

## Why Fairyfly

Modern backend development doesn't need a 50 MB runtime to start. Fairyfly is
built for cases where:

- **Cold start matters** — CLI tools, edge functions, short-lived jobs
- **Memory is constrained** — containers with strict limits
- **The whole codebase should fit in your head** — ~24k lines of Zig across 54 files

It's *not* aimed at:

- Browser parity (no DOM, no `window`)
- Full npm ecosystem compatibility (pure-JS ESM packages only — see [Packages](docs/guides/packages.md))

If you need either of those, use Node, Bun, or Deno. If you need a backend
runtime that's small, fast, and auditable, Fairyfly fits.

---

## Quick start

```sh
# Install (see Installation)
curl -fsSL https://raw.githubusercontent.com/AbdElMajidOuhamane/ff/main/install.sh | sh

# Run inline code
ff -e 'console.log("hello from fairyfly")'

# Initialize a project (writes ff.json)
ff init -y demo
cd demo
ff start
```

---

## Example tour

Three copy-pasteable programs covering the core loop — serve, call, store.
Each links to the guide with the full story.

**Serve** ([HTTP Server guide](docs/guides/http-server.md)):

```js
// server.js
http.serve({ port: 3000 }, (url, method, body) => {
  if (url === "/json") return Response.json({ ok: true });
  if (url === "/echo" && method === "POST") return new Response(body);
  return new Response("not found", { status: 404 });
});
```

```sh
ff server.js
curl http://127.0.0.1:3000/json  # {"ok":true}
```

**Call** ([Fetch Client guide](docs/guides/fetch-client.md)):

```js
// client.js
const res = await fetch("https://api.example.com/notes", {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ text: "buy milk" }),
});
console.log(res.status, await res.text());
```

```sh
ff client.js
```

**Store** ([SQLite guide](docs/api/sqlite.md)):

```js
// notes.js
const db = Database.open("notes.db");
db.execNoArgs(`CREATE TABLE IF NOT EXISTS notes (
  id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL)`);

db.exec("INSERT INTO notes (text) VALUES (?)", ["buy milk"]);
console.log(db.rows("SELECT id, text FROM notes"));
// [ { id: 1, text: "buy milk" } ]
db.close();
```

```sh
ff notes.js
```

---

## API at a glance

Every global, one line each — full signatures live in the [API overview](docs/api/overview.md):

| Global | What to know |
|---|---|
| `console` | Prints **every** argument, joined with spaces — to **stderr** |
| `fetch` | 16 slots, HTTP/1.1; `string` / `URLSearchParams` bodies survive, `FormData` / `Blob` / binary do not; exact-case methods; rejections are plain strings |
| `http.serve` | `(url, method, body)` handler, all strings; return a `Response`; WebSocket upgrades are automatic |
| `Response` / `Request` | Bodies re-read freely (`bodyUsed` stays `false`); `bytes()` returns `ArrayBuffer`; `Response.redirect()` sets no `Location` header |
| `Database` | `Database.open(path)`; synchronous; failures throw plain strings, not `Error`s |
| `sql` / `SQL` | Postgres tagged templates; failures reject with real `Error`s (`code` / `severity` / `message`) |
| `fs` | Sync calls return `undefined` on failure (never throw); six `*Async` Promise variants |
| `Worker` | Max 8 OS threads; structured-clone messaging, 4 MB per message |
| `crypto` | `randomUUID`, `getRandomValues`, `subtle.digest` (SHA-1/256/384/512); `btoa`/`atob` round-trip Unicode via UTF-8 |
| `URL` / `URLSearchParams` | `URL.parse` (null-safe); param edits don't flow back to the URL; no percent-encoding — encode yourself |
| `Blob` / `FormData` | `blob()` / `formData()` readers work; `form.size()` is a method |
| `process` | `argv` mirrors the OS argv; `env` is a boot snapshot; `chdir` never throws; exit codes clamp to 0–255 |
| `TextEncoder` / `TextDecoder` | UTF-8 string ↔ bytes |
| `WebSocket` | Client with `send` / `sendBinary` / `close`; sync mistakes throw `TypeError: WebSocket: …` |
| `ffi` | Native libraries; needs `--allow-ffi` at runtime |

---

## Performance

### macOS (Apple silicon, kqueue)

`wrk -t 8 -c 100 -d 10s`, all runtimes serving the same hello-world handler:

| Runtime       | Req/sec   | p50    | p99    | Peak RSS |
|---------------|-----------|--------|--------|----------|
| **Fairyfly**  | **138k**  | **0.66 ms** | **0.85 ms** | **5 MB** |
| Deno 2.9      | 110k      | 0.86 ms | 1.00 ms | 48 MB    |
| Bun 1.4       | 107k      | 0.87 ms | 1.71 ms | 34 MB    |
| Node 23       | 69k       | 1.36 ms | 1.69 ms | 82 MB    |

### Linux (io_uring vs epoll)

hyperfine × wrk `-t4 -c100 -d 10s`, 3-run medians across two campaigns,
Linux aarch64 VM, musl `ReleaseFast` builds, same hello-world handler:

| Runtime | req/s (io_uring) | req/s (epoll) | Peak RSS (io_uring / epoll) |
|---|---|---|---|
| **Fairyfly** | **309k** | 171k | **10 MB / 16 MB** |
| Deno 2.9.7 | 248k | 247k | 44 MB / 44 MB |
| Bun 1.4.2 | 187k | 184k | 34 MB / 35 MB |
| Node 18 | 55k | 57k | 88 MB / 88 MB |

Fairyfly with io_uring is **~1.8× its own epoll backend** (≈2× on the
`wrk.sh` harness), **+25% throughput over Deno** with **~4× lower peak
RSS** on this workload.

> These are VM-relative numbers: compare rows within a table, not across
> tables or against other machines. Hello-JSON keep-alive is one workload;
> TLS/WebSocket/Postgres paths are not represented here.

**Reproducing:** `wrk -t8 -c100 -d10s` against the hello-world handler
(8 threads, 100 keep-alive connections, RSS sampled via `ps`), 3-run
medians per runtime. Server-side numbers use `ReleaseFast` builds
(`make build`). Broader interpreter and I/O comparisons live in
[`bench/run-bench.sh`](bench); memory comparisons use `bench/mem-bench.sh`
(maintainer-local, not in the repo).

---

## Architecture

```
┌──────────────────────────────────────────────────┐
│ JavaScript source (.js files)                    │
└──────────────────┬───────────────────────────────┘
                   │ QuickJS parser
┌──────────────────▼───────────────────────────────┐
│ QuickJS bytecode + JS runtime (gc, value stack)  │
└──────────────────┬───────────────────────────────┘
                   │ C ABI (src/c.zig → quickjs_shim.zig)
┌──────────────────▼───────────────────────────────┐
│ Zig API layer                                    │
│   api/     console, fs, process, crypto, url,    │
│            fetch, websocket, sqlite, sql, ffi    │
│   net/     http_native (512-slot server),        │
│            http2_server, pg_client, async_fetch  │
│   event/   loop, timers, microtasks              │
│   types/   Headers, Request, Response, Blob,     │
│            FormData, PoolSlice                   │
│   worker/  worker, message_port, serialize       │
│   commands/ init, imprint, sever, start, test,   │
│            repl, compile, fmt, upgrade, watch    │
└──────────────────┬───────────────────────────────┘
                   │
┌──────────────────▼───────────────────────────────┐
│ libxev event loop (io_uring / epoll, kqueue)     │
└──────────────────────────────────────────────────┘
```

**Hot-path design:** 512-slot SoA connection table with packed 2-byte
`ConnFlags`; static per-slot 64 KB response staging (spills to the heap,
capped at 10 MB); refcounted `HeadersData` shared across threads; zero-copy
URL slices; per-job Postgres arenas. Details: [Architecture](docs/concepts/architecture.md).

---

## Building from source

Requirements:

- **Zig 0.16** (uses 0.16.0 std APIs)
- C compiler (clang on macOS, gcc on Linux)
- A POSIX system (macOS or Linux)

Vendors (`quickjs-ng` 0.16.2, BearSSL 0.6, SQLite 3.53.4, nghttp2 1.70.0)
are **gitignored** — fetch them first:

```sh
./scripts/fetch-vendors.sh   # pinned, SHA-256 verified (same script CI uses)
make install                 # build + install to ~/.local/bin/ff
ff -e 'console.log("hello")'
```

Or via Docker (fetches vendors, generates bridge headers, cross-compiles static musl):

```sh
docker build -t fairyfly .
```

Build options:

```sh
zig build -Doptimize=ReleaseFast   # default for `make build`
zig build -Dbearssl=false          # drop TLS support entirely
zig build -Dio_uring=false         # Linux: epoll backend instead of io_uring
zig build -Dffi=false              # keep the `ffi` global, but `dlopen`/`callback` throw (needs `--allow-ffi` at runtime regardless)
zig build -Dversion=1.2.3          # version reported by `ff --version`
zig build test                     # Zig unit tests
make test                          # Zig unit tests + test/run.sh
```

Linux uses **io_uring** by default, **epoll** via `-Dio_uring=false`
(needs Linux 5.1+; Docker's default seccomp blocks io_uring — use
`--security-opt seccomp=unconfined` or ship an epoll build).

---

## CLI reference

```
ff init [-y|--yes] [<dir>]
                         Initialize a new project (writes ff.json)
ff imprint [pkg[@ver] ...]
                         Add exact dep(s) to ff.json + ff.lock, fetch pure-JS ESM
ff sever [pkg ...] [--force]
                         Remove dep(s), prune orphans
ff start [--cert cert.pem --key key.pem]
                         Run ff.json's "main" (TLS enabled with cert+key)
ff --watch <file|start> [args...]
                         Restart the child when files change (200ms poll)

ff test [filter]         Run test/*.test.js
ff repl                  Interactive REPL
ff upgrade [--check]     Self-update from GitHub Releases
ff compile <f.js> [-o out.ffbc]
                         Compile to bytecode (run back with ff <file.ffbc>)
ff fmt [--write|--check] <files...>
                         Format via prettier (needs npx/network)
ff -e <code>             Run inline JavaScript code
ff <file.js>             Run a JavaScript file
ff <file.js> --allow-ffi Allow ffi.dlopen (native libraries)
ff --version             Print runtime version
```

**`ff --watch`** never runs a runtime itself — it polls the project tree
(mtime + size, 200 ms, 100 ms debounce), then SIGTERMs the child, waits up to
500 ms, SIGKILLs, and respawns. `--watch` must be the **first** argument.
Forward everything after the target (e.g. `ff --watch app.js --ca cert.pem`).

Environment variables:

- `FF_ECHO` (any value, even empty — only unsetting disables) — run the server in echo mode (returns canned response)
- `FF_CERT` / `FF_KEY` — TLS cert/key paths (same as `--cert/--key`)
- `FF_CA_FILE` — CA file for the runtime's own TLS client (fetch/WebSocket)
- `FF_WATCH_PARENT` — set internally by `--watch` (orphan watchdog)

Database:

- `DATABASE_URL`, `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE` —
  configure the global `sql`
- `PG_TEST_DSN` — used by the Postgres test files (they self-skip if unset)

---

## Limitations vs Node / browser

**Modules & language**

- No `require()`, no CommonJS
- ES Modules only; worker files are classic scripts (no `import`/`export`)
- Extensionless relative imports probe `./x.js`, then `./x/index.js`
- No `Buffer` (use `ArrayBuffer` / `Uint8Array`)
- No browser DOM
- TypeScript is not supported — compile to `.js` first

**HTTP**

- HTTP/2 accepted by the server (TLS + ALPN); outbound clients are HTTP/1.1 only
- Max **512** concurrent HTTP connections
- Request bodies: ~4 KB (headers + body share a 4 KB buffer; beyond → `413`)
- Response bodies: buffered, hard cap **10 MB** (64 KB static stage buffer,
  larger bodies spill to the heap; beyond 10 MB → `500`)
- Response headers capped at 2048 bytes; server-computed
  `Content-Length` / `Transfer-Encoding` / `Connection` are not overridable
- No `Expect: 100-continue`, no chunked **request** bodies
- No idle/keep-alive timeout — only hung handlers are reaped (504 after 30 s)

**Outbound**

- `fetch`: **16** concurrent slots, HTTP/1.1, 30 s I/O timeout, max 5 redirects
- No `AbortController` / `signal` / `timeout` / `redirect` init keys
- WebSocket client: **64** sockets, 16384-byte messages (larger sends truncate)
- Outbound TLS connection pool: **64**

**Timers & loop**

- Max **128** concurrent timers; the 129th throws `TypeError`
- Max **8** extra timer arguments
- No `process.nextTick` — use `queueMicrotask`

**Console**

- Prints **every argument** of each call, joined with spaces
- Writes to **stderr**, not stdout

**Workers**

- Max **8**; 32 MB heap, 1 MB JS stack, 8 MB thread stack each
- 4 MB per message; no `ArrayBuffer` transfer (always copied)
- Worker scope is `console` + timers + `postMessage` — no `fs`, `fetch`, or `http.serve`
- No nested workers; exit only via `terminate()`

**SQLite**

- `db.exec()` runs the **first** statement only — use `db.execNoArgs()` for
  multi-statement SQL
- Positional `?` parameters only (no named `:x` / `$x`)
- Integer columns beyond 2⁵³ lose precision in JS
- Failures throw plain strings, not `Error`s — log `String(e)`

**Postgres**

- No TLS (`sslmode`), no connection/socket timeouts, no keepalive
- Pool caps at 10 connections
- `rowCount` reflects returned rows only (INSERT/UPDATE row counts are not reported)
- No COPY support

**Process**

- `process.env` is a snapshot taken at boot — assigning to it does not affect
  the OS environment
- No `stdout`/`stdin` streams, no `hrtime`, no `kill`
- `chdir` never throws — a bad path is a silent no-op; check `cwd()`
- Exit codes clamp to 0–255 (no mod-256 wrap)
- No interrupt/watchdog for runaway JS — an infinite loop hangs the process

**Packages**

- `ff imprint` installs **pure-JS ESM** packages only; anything using
  `require(`, `module.exports`, or `node:` imports is rejected
- One flat `node_modules` — a conflicting transitive version is a hard error

---

## License

MPL-2.0 (Mozilla Public License Version 2.0). See [LICENSE](LICENSE).

---

## Acknowledgments

- QuickJS — Fabrice Bellard
- [BearSSL](https://www.bearssl.org) — Thomas Pornin
- libxev — [mitchellh](https://github.com/mitchellh/libxev)
- [nghttp2](https://nghttp2.org) — HTTP/2
- Inspired by Node.js, Bun, and Deno — none of their code is included; this is
  a from-scratch implementation in Zig
