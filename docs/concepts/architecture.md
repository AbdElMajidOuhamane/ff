---
title: Architecture
description: Layers from QuickJS down to libxev, where each subsystem lives, and how the hot path stays allocation-free.
order: 4
---

# Architecture

One binary, four layers, no plugins. Understanding the shape of the
codebase makes the rest of the documentation predictable.

## The layers

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

## Where things live

| Directory | Contents | Read when |
|---|---|---|
| `src/api/` | Every JS global | Looking up a global's behaviour |
| `src/net/` | HTTP server, HTTP/2, fetch, Postgres, TLS, WebSocket | Networking limits or protocol details |
| `src/event/` | Loop, timers, microtasks | Ordering or liveness questions |
| `src/types/` | `Headers`, `Request`, `Response`, `Blob`, `FormData` | Fetch API semantics |
| `src/worker/` | Workers + structured clone | Worker limits |
| `src/commands/` | CLI subcommands | CLI flags |
| `src/modules/` | ESM resolver | Import resolution rules |
| `vendor/` | QuickJS, BearSSL, SQLite, nghttp2 (gitignored) | Build problems |

## Threads

| Thread | Count | Work |
|---|---|---|
| JS thread | 1 | All JavaScript, all Promise settlements |
| Event-loop pool (`libxev`) | 4 | General loop work |
| `fs.*Async` pool | 4 + 16 job slots | File I/O; a 17th concurrent job waits |
| `ffi` pool | 4 | Each native call parks a pool thread |
| `fetch` workers | 16 (1 MB stack each) | One thread per slot; outbound connections |
| Postgres / TLS | none | Event-driven on the loop thread |
| `Worker` | up to 8 | Your CPU-bound JS, each with its own runtime |

There is no single shared pool — loop, `fs`, and `ffi` each own a
separate 4-thread pool. See [Concurrency](/docs/concepts/concurrency) for
the full inventory.

## Hot-path design

- **SoA connection table** — 512 slots stored as parallel arrays with packed
  2-byte flags (`ConnFlags` is a `packed struct(u16)`), so the hot loop
  touches cache lines, not objects.
- **Static per-slot buffers** — 64 KB response staging per connection;
  bodies above that spill to the heap (capped at 10 MB), and spills up to
  256 KB are retained for reuse instead of re-allocated.
- **`HeadersData` refcount** — one heap object with an atomic refcount,
  shared by `Request` / `Response` / `Headers` across thread boundaries.
- **Zero-copy URLs** — one allocation per URL; components are pooled slices.
- **Worker messages** — one small allocation plus a `memcpy` per message.
- **Postgres arenas** — per-job arena with a 32 KB retain cap plus a job
  freelist, so a warm query path allocates nothing.

## Build options

```sh
zig build -Doptimize=ReleaseFast   # what `make build` uses
zig build -Dbearssl=false          # drop TLS (HTTPS/WSS unavailable)
zig build -Dffi=false              # keep the `ffi` global, but `dlopen`/`callback` throw (needs `--allow-ffi` at runtime regardless)
zig build -Dio_uring=false         # Linux: use epoll instead of io_uring
zig build -Dversion=1.2.3          # version reported by `ff --version`
```

| Vendor | Version | Role |
|---|---|---|
| quickjs-ng | 0.16.2 | JS engine |
| BearSSL | 0.6 | TLS 1.2 for HTTPS/WSS |
| SQLite | 3.53.4 | `Database` |
| nghttp2 | 1.70.0 | HTTP/2 framing + HPACK |

All four are fetched by `./scripts/fetch-vendors.sh` — they are not
committed. See [Installation](/docs/getting-started/installation).

## I/O backends

| Platform | Backend |
|---|---|
| macOS | kqueue |
| Linux | io_uring by default; `-Dio_uring=false` → epoll |
| Docker's default seccomp profile | blocks io_uring — use `--security-opt seccomp=unconfined` or an epoll build |

## See also

- [Event loop](/docs/concepts/event-loop)
- [Concurrency](/docs/concepts/concurrency)
- [HTTP Server](/docs/guides/http-server)
- [Installation](/docs/getting-started/installation)
