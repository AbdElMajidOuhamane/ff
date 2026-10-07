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
| Request body | ~4 KB (shares the 4 KB read buffer) | Beyond → `413 Payload Too Large` |
| Response body | 10 MB hard cap (64 KB stage buffer spills to the heap) | Beyond 10 MB → `500` |
| Response headers | 2048 bytes | Headers beyond the cap are dropped |
| Hung handler | 30s | Connection fails with `504` |
| Bind address | Always `0.0.0.0` | No host option, no `FF_PORT` |
| Plain listener protocol | HTTP/1.1 | No HTTP/2 framing without TLS |
| HTTP/2 | TLS + ALPN only (nghttp2) | Plain sockets stay HTTP/1.1 |
| `FF_ECHO` | Any value set (even empty — only *unsetting* disables) | Every request gets canned `200 {"message":"ok"}` |

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
| Worker heap | 32 MB + 1 MB JS stack (8 MB thread stack) | — |
| Worker message | 4 MB per message | Larger `postMessage` payloads are rejected |
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
| API style | Sync + six `*Async` Promise variants (`readFileAsync`, `writeFileAsync`, `existsAsync`, `mkdirAsync`, `rmAsync`, `readdirAsync`) | No `fs.watch` — poll with timers |

## Console

| Area | Type | Description |
|------|------|-------------|
| Arguments printed | All per call | Every argument prints, joined with spaces |
| Destination | stderr | `console.log > out.txt` captures nothing |

## Modules and language

| Area | Limit | When hit |
|------|-------|----------|
| Module system | ESM only | No `require()`, no CommonJS |
| Relative extensions | Optional for `.js` | `./x` probes `./x.js`, then `./x/index.js`; other extensions must be written out |
| Bare specifiers | Resolved via `node_modules` | Needs `ff imprint` install first |
| `Buffer` | Missing | Use `Uint8Array` |
| DOM / `window` | Missing | Backend only |
| `process.spawn` / `exec` | Missing | `process` has exit/cwd/chdir/pid/platform/arch/env/argv only |

## SQLite

| Area | Limit | When hit |
|------|-------|----------|
| `db.exec` | First statement only | Multi-statement SQL needs `db.execNoArgs` |
| Parameters | Positional `?` only | Named `:x` / `$x` are not supported |
| Integer precision | ±2⁵³ | Beyond → precision loss in JS |

## Postgres

| Area | Limit | When hit |
|------|-------|----------|
| Pool | 10 connections | Extra queries queue |
| TLS (`sslmode`) | Not supported | — |
| Connection/socket timeouts | None | Slow queries wait indefinitely |
| `rowCount` | Returned rows only | INSERT/UPDATE row counts are not reported |
| COPY | Not supported | — |

## Process

| Area | Limit | When hit |
|------|-------|----------|
| `process.env` | Snapshot at boot | Assigning to it does not affect the OS environment |
| stdout/stdin streams | Missing | No `process.stdout.write` or stdin reads |
| `hrtime`, `kill` | Missing | — |
| Runaway JS watchdog | None | An infinite loop hangs the process |

## TLS and bytecode

| Area | Limit | When hit |
|------|-------|----------|
| TLS versions | TLS 1.2 (BearSSL build) | No TLS 1.3 in the default build |
| `ff compile` input | 20MB source | Larger inputs fail |
| `ff test` file | 10MB | Larger test files are not loaded |
| REPL line | 8192 bytes | Longer lines truncate |
| `ff init` | Always overwrites | Back up `ff.json` if you customized it |

## Packages

| Area | Limit | When hit |
|------|-------|----------|
| Package type | Pure-JS ESM only | `require(`, `module.exports`, or `node:` imports are rejected |
| Version graph | One flat `node_modules` | A conflicting transitive version is a hard error |

## What is *not* limited (common misconceptions)

- `res.blob()` and `res.formData()` **work** on `Request` and `Response`.
- HTTP redirects **are followed** (up to 5 hops) by `fetch`.
- Port shorthand `http.serve(3000, handler)` **works**; the default port is `3000`.
- `make install` targets **`~/.local/bin/ff`**, not `/usr/local/bin`.
