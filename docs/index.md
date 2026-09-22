---
title: Documentation
hidden: "true"
---

# Documentation

Fairyfly is a fast backend JavaScript runtime — one `ff` binary, ESM only, batteries included (HTTP, fetch, WebSocket, SQLite, workers).

## Getting started

| Page | What it covers |
|------|----------------|
| [Introduction](/docs/getting-started/introduction) | What Fairyfly is and how it compares |
| [Installation](/docs/getting-started/installation) | Build with Zig 0.16, install to `~/.local/bin`, or Docker |
| [Quickstart](/docs/getting-started/quickstart) | First server in five minutes |

## Guides

| Page | What it covers |
|------|----------------|
| [HTTP Server](/docs/guides/http-server) | `http.serve` from hello-world to a JSON REST API |
| [Fetch Client](/docs/guides/fetch-client) | Call other APIs — GET, POST, JSON, redirects, HTTPS trust |
| [WebSocket](/docs/guides/websocket) | Upgrade handling, broadcast rooms, clients |
| [TLS](/docs/guides/tls) | Serve HTTPS/WSS with cert + key |
| [Environment Variables](/docs/guides/env) | Every `FF_` variable and `process.env` |
| [Deploy](/docs/guides/deploy) | Build, Docker, `ff start`, smoke-test, production TLS |
| [Testing](/docs/guides/testing) | `ff test` + `test/run.sh` with the `check`/`done` pattern |
| [Bytecode](/docs/guides/bytecode) | Ship without source via `ff compile` |
| [Packages](/docs/guides/packages) | `ff imprint` / `ff sever` for ESM dependencies |
| [Workers](/docs/guides/workers) | CPU-bound work on up to 8 threads |
| [Timers](/docs/guides/timers) | `setTimeout`, `setInterval`, and friends |

## API reference

| Page | What it covers |
|------|----------------|
| [Overview](/docs/api/overview) | Every global and module on one page |
| [`http`](/docs/api/http) | `http.serve` signatures, options, handler contract |
| [`fetch`](/docs/api/fetch) | `fetch`, `Request`, `Response`, `Headers` |
| [`fs`](/docs/api/fs) | Sync filesystem calls |

## Reference

| Page | What it covers |
|------|----------------|
| [CLI](/docs/reference/cli) | Every `ff` subcommand with flags and examples |
| [Limitations](/docs/reference/limitations) | Every hard cap in one place |
