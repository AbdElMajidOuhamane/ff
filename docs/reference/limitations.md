---
title: Limitations
description: Every hard limit in one place — know the caps before you design around them.
order: 2
---

# Limitations

Fairyfly trades breadth for speed and auditability. This page lists every hard cap; each guide links back here from its own summary table.

## HTTP server

| Area | Limit | When hit |
|------|-------|----------|
| Concurrent connections | 512 | The 513th waits for a free slot |
| Response body | 64KB per response | Larger bodies are rejected |
| Hung handler | 30s | Connection fails with `504` |
| Bind address | Always `0.0.0.0` | No host option, no `FF_PORT` |
| Plain listener protocol | HTTP/1.1 | No HTTP/2 framing without TLS |
| HTTP/2 | TLS + ALPN only (nghttp2) | Plain sockets stay HTTP/1.1 |
| `FF_ECHO` | Any non-empty value set | Every request gets canned `200 {"message":"ok"}` |

## Fetch (client)

| Area | Limit | When hit |
|------|-------|----------|
| Concurrent fetches | 16 | The 17th waits for a free slot |
| Body stage per slot | 64KB | Larger bodies spill to chunks/heap |
| I/O timeout | 30s | Slow servers fail |
| Redirects | Followed, max 5 hops | Throws `Too many redirects` |
| Abort / `signal` | Not supported | `signal` / `timeout` / `redirect` init keys are ignored |
| Protocol | HTTP/1.1 | No HTTP/2 client |

## WebSocket

| Area | Limit | When hit |
|------|-------|----------|
| Client sockets | 64 per process | Extra connects fail |
| Message size | 16384 bytes | Larger frames truncate |
| Handshake URL path | 512 bytes | Longer paths fail |
| Server socket API | `send` / `sendBinary` only | No `id`, `readyState`, or `close` on server sockets |

## Timers and workers

| Area | Limit | When hit |
|------|-------|----------|
| Live timers | 128 | `TypeError: too many timers (max 128)` |
| Extra timer args | 8 after `ms` | Extras ignored |
| Workers | 8 | `too many workers (max 8)` |
| Worker stack | 8MB | — |
| `process.nextTick` | Missing | Use `queueMicrotask` |

```js
// instead of process.nextTick(fn):
queueMicrotask(fn);
```

## Filesystem

| Area | Limit | When hit |
|------|-------|----------|
| Path length | 4096 bytes | Longer paths fail |
| Read per call | 10MB, sync | Larger reads fail |
| API style | Sync only | No `fs.watch` — poll with timers |

## Modules and language

| Area | Limit | When hit |
|------|-------|----------|
| Module system | ESM only | No `require()`, no CommonJS |
| Relative extensions | Use `"./x.js"` | Extensionless relative imports may fail |
| Bare specifiers | Resolved via `node_modules` | Needs `ff imprint` install first |
| `Buffer` | Missing | Use `Uint8Array` |
| DOM / `window` | Missing | Backend only |
| `process.spawn` / `exec` | Missing | `process` has exit/cwd/chdir/pid/platform/arch/env/argv only |

## TLS and bytecode

| Area | Limit | When hit |
|------|-------|----------|
| TLS versions | TLS 1.2 (BearSSL build) | No TLS 1.3 in the default build |
| `ff compile` input | 20MB source | Larger inputs fail |
| `ff test` file | 10MB | Larger test files are not loaded |
| REPL line | 8192 bytes | Longer lines truncate |
| `ff init` | Always overwrites | Back up `ff.json` if you customized it |

## What is *not* limited (common misconceptions)

- `res.blob()` and `res.formData()` **work** on `Request` and `Response`.
- HTTP redirects **are followed** (up to 5 hops) by `fetch`.
- Port shorthand `http.serve(3000, handler)` **works**; the default port is `3000`.
- `make install` targets **`~/.local/bin/ff`**, not `/usr/local/bin`.
