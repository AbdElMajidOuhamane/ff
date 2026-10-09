---
title: Documentation
hidden: "true"
---

# Documentation

Fairyfly is a fast backend JavaScript runtime — one `ff` binary, batteries
included (HTTP, fetch, WebSocket, SQLite, Postgres, workers). Scripts and
ES modules both work — the runtime auto-detects per file.

44 pages in five sections. If you're new: read the three getting-started
pages in order, then keep **Concepts** open while you build — it explains
*why* the runtime behaves the way it does.

## Start here

1. [Introduction](/docs/getting-started/introduction) — what it is and when to pick it
2. [Installation](/docs/getting-started/installation) — prebuilt, source, or Docker
3. [Quickstart](/docs/getting-started/quickstart) — first server in five minutes
4. [HTTP Server](/docs/guides/http-server) — hello-world to a JSON REST API

## Getting started

| Page | What it covers |
|------|----------------|
| [Introduction](/docs/getting-started/introduction) | What Fairyfly is, when to use it, how it compares |
| [Installation](/docs/getting-started/installation) | Prebuilt install, build with Zig 0.16, Docker, I/O backends |
| [Quickstart](/docs/getting-started/quickstart) | Your first script, server, and database in five minutes |

## Concepts

| Page | What it covers |
|------|----------------|
| [Event loop](/docs/concepts/event-loop) | One thread, one loop — ordering, microtasks, what keeps the process alive |
| [Concurrency](/docs/concepts/concurrency) | Loop vs I/O pool vs Workers — which primitive to reach for |
| [Errors and exit codes](/docs/concepts/errors) | What throws, what gets swallowed, how failures surface |
| [Architecture](/docs/concepts/architecture) | Layers, directories, threads, and the hot path |

## Guides

| Page | What it covers |
|------|----------------|
| [HTTP Server](/docs/guides/http-server) | `http.serve` from hello-world to a JSON REST API |
| [Fetch Client](/docs/guides/fetch-client) | GET, POST, JSON, redirects, HTTPS trust |
| [WebSocket](/docs/guides/websocket) | Server upgrade, broadcast rooms, client API |
| [TLS](/docs/guides/tls) | Serve HTTPS/WSS with cert + key |
| [HTTP/2](/docs/guides/http2) | HTTP/2 over TLS with ALPN — same handler, same port |
| [Workers](/docs/guides/workers) | CPU-bound work on up to 8 threads |
| [Timers](/docs/guides/timers) | `setTimeout`, `setInterval`, `unref`, microtasks |
| [Logging](/docs/guides/logging) | `console`, colored output, timers, stderr redirection |
| [Modules](/docs/guides/modules) | ESM resolution rules, extensions, `import.meta.url` |
| [Process](/docs/guides/process) | argv, env, cwd, exit, pid — and what's missing on purpose |
| [Environment variables](/docs/guides/env) | Every `FF_` variable and `process.env` |
| [Packages](/docs/guides/packages) | `ff imprint` / `ff sever` for ESM dependencies |
| [Bytecode](/docs/guides/bytecode) | Ship without source via `ff compile` |
| [Testing](/docs/guides/testing) | `ff test` + `test/run.sh` with the `check`/`done` pattern |
| [Deploy](/docs/guides/deploy) | Build, Docker, `ff start`, smoke-test, production TLS |

## API reference

| Page | What it covers |
|------|----------------|
| [Overview](/docs/api/overview) | Every global on one page, each linking to its reference |
| [`http`](/docs/api/http) | `http.serve` signatures, options, handler contract |
| [`fetch`](/docs/api/fetch) | `fetch()` — init keys, redirects, limits |
| [Request / Response / Headers](/docs/api/request-response) | Constructors, statics, body readers, `Headers` |
| [`WebSocket`](/docs/api/websocket) | Client API and server socket API |
| [`fs`](/docs/api/fs) | Sync and Promise-based filesystem calls |
| [`console`](/docs/api/console) | Every method, aliases, `time`/`timeLog`/`timeEnd` |
| [`process`](/docs/api/process) | `argv`, `env`, `pid`, `memoryUsage`, `stats` |
| [`URL`](/docs/api/url) | `URL`, `URLSearchParams`, `URL.parse`, `URL.canParse` |
| [`crypto`](/docs/api/crypto) | `randomUUID`, `getRandomValues`, `subtle.digest`, `btoa`/`atob` |
| [Text encoding](/docs/api/text-encoding) | `TextEncoder` / `TextDecoder` |
| [`performance`](/docs/api/performance) | `performance.now()` |
| [`Worker`](/docs/api/worker) | `postMessage`, `terminate`, worker-side globals |
| [Blob and FormData](/docs/api/blobs-formdata) | Binary payloads and HTML forms |
| [SQLite](/docs/api/sqlite) | `Database` — open, query, write, transactions |
| [Postgres](/docs/api/postgres) | `SQL`/`sql` — queries, types, errors, transactions |
| [FFI](/docs/api/ffi) | Load C-ABI shared libraries and call them from JS |

## Reference

| Page | What it covers |
|------|----------------|
| [CLI](/docs/reference/cli) | Every `ff` subcommand with flags and examples |
| [Limitations](/docs/reference/limitations) | Every hard cap in one place |
| [Compatibility](/docs/reference/compatibility) | What's missing vs Node/browser, and what to use instead |
| [Examples](/docs/reference/examples) | Runnable examples with run commands and expected output |

## Every feature, one table

| Feature | Page |
|---------|------|
| `console` (11 methods, colored aliases, timers) | [API: console](/docs/api/console) · [Logging](/docs/guides/logging) |
| `setTimeout` / `setInterval` / `queueMicrotask` | [Timers](/docs/guides/timers) · [Event loop](/docs/concepts/event-loop) |
| `performance.now()` | [API: performance](/docs/api/performance) |
| `http.serve` (HTTP, TLS, HTTP/2, WebSocket) | [API: http](/docs/api/http) · [HTTP Server](/docs/guides/http-server) |
| `fetch`, `Request`, `Response`, `Headers` | [API: fetch](/docs/api/fetch) · [API: Request/Response](/docs/api/request-response) |
| `WebSocket` client | [API: WebSocket](/docs/api/websocket) · [WebSocket](/docs/guides/websocket) |
| `fs` sync + `*Async` | [API: fs](/docs/api/fs) |
| `Database` (SQLite) | [API: SQLite](/docs/api/sqlite) |
| `sql` / `SQL` / `Tx` (Postgres) | [API: Postgres](/docs/api/postgres) |
| `Worker` | [API: Worker](/docs/api/worker) · [Workers](/docs/guides/workers) |
| `URL` / `URLSearchParams` | [API: URL](/docs/api/url) |
| `crypto`, `btoa`, `atob` | [API: crypto](/docs/api/crypto) |
| `TextEncoder` / `TextDecoder` | [API: Text encoding](/docs/api/text-encoding) |
| `Blob` / `FormData` | [Blob and FormData](/docs/api/blobs-formdata) |
| `process` | [API: process](/docs/api/process) · [Process](/docs/guides/process) |
| `ffi` (needs `--allow-ffi`) | [API: FFI](/docs/api/ffi) |
| ESM resolution, `import.meta.url` | [Modules](/docs/guides/modules) |
| Packages: `ff imprint` / `ff sever` | [Packages](/docs/guides/packages) |
| Bytecode: `ff compile` | [Bytecode](/docs/guides/bytecode) |
| Environment variables | [Environment](/docs/guides/env) |
| CLI commands | [CLI](/docs/reference/cli) |
| Hard limits | [Limitations](/docs/reference/limitations) |
| Node/browser gaps | [Compatibility](/docs/reference/compatibility) |
