---
title: Limitations
description: Every hard limit in one place — know the caps before you design around them.
order: 2
---

# Limitations

Fairyfly trades breadth for speed and auditability. This page lists every hard cap; each guide links back here from its own summary table.

## Permissions

Native APIs are deny-by-default. The full model lives in
[Permissions](/docs/concepts/permissions); the constraints that matter when
designing are:

| Constraint | Detail |
|---|---|
| Policy lifetime | Parsed once before the runtime starts; immutable for the process; workers inherit it |
| Scope roots | Resolved against the launch cwd and fixed; `process.chdir()` does not move them |
| Path scopes | Canonicalized and symlink-resolved; 4096-byte limit; no globs or extensions |
| Network scopes | Literal host match with no DNS; `localhost` ≠ `127.0.0.1`; bind is always `0.0.0.0` |
| Environment scopes | Exact, case-sensitive names; disallowed keys are absent from `process.env` |
| Run scopes | Basename or absolute path; `exec` / `execSync` also need `/bin/sh` |
| FFI | Bare `--allow-ffi` only; gates every `ffi` entry point except `ffi.allowed`; trust-equivalent to full access |
| Module loading | `import` and `new Worker(path)` do not need `read`; loaded code runs with the process policy |
| Isolation | In-process policy, not an OS sandbox; a symlink swapped between check and syscall can escape a path scope |
| Granularity | Process-global; no per-request or per-user scopes |
| Deny flags | None; the default is deny, and only `--allow-*` changes it |

`run` and `ffi` execute arbitrary code with the process's authority. Use
permissions to reduce mistakes in code you mostly trust, not as the only
boundary for hostile code.

## HTTP server

| Area | Limit | When hit |
|------|-------|----------|
| Concurrent connections | 512 | The 513th waits for a free slot |
| Request body | ~4 KB (shares the 4 KB read buffer) | Beyond → `413 Payload Too Large` |
| Response body | 10 MB hard cap (64 KB stage buffer spills to the heap) | Beyond 10 MB → `500` |
| Response headers | 2048 bytes | Headers beyond the cap are dropped |
| Hung handler | 30s | Connection fails with `504` |
| Bind address | Always `0.0.0.0` | No host option, no `FF_PORT`; the net scope must be `0.0.0.0:<port>` |
| Plain listener protocol | HTTP/1.1 | No HTTP/2 framing without TLS |
| HTTP/2 | TLS + ALPN only (nghttp2) | Plain sockets stay HTTP/1.1 |
| `FF_ECHO` | Any value set (even empty — only *unsetting* disables) | Every request gets canned `200 {"message":"ok"}` |

## Fetch (client)

| Area | Limit | When hit |
|------|-------|----------|
| Concurrent fetches | 16 | The 17th waits for a free slot |
| Body stage per slot | 64KB | Larger bodies spill to chunks/heap |
| I/O timeout | 30s | Slow servers fail |
| Redirects | Followed, max 5 hops | Throws `Too many redirects`; every hop is re-checked against `--allow-net` |
| Abort / `signal` | Not supported | `signal` / `timeout` / `redirect` init keys are ignored |
| Protocol | HTTP/1.1 | No HTTP/2 client |
| Proxy | HTTP proxies via env vars (`HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY`); `NO_PROXY` bypass | No SOCKS support; no `https://` proxy URLs (TLS to the proxy); env is read once at launch |

## WebSocket

| Area | Limit | When hit |
|------|-------|----------|
| Client sockets | 64 per process | Extra connects fail |
| Message size | 16384 bytes | Larger frames truncate |
| Handshake URL path | 512 bytes | Longer paths fail |
| Server socket API | `send` / `sendBinary` only | No `id`, `readyState`, or `close` on server sockets |
| Proxy | Same env vars as `fetch` | `ws://` needs a CONNECT-capable proxy |

## UDP

| Area | Limit | When hit |
|------|-------|----------|
| Concurrent sockets | 64 (shared pool) | `udp.socket: no socket slots available` |
| In-flight `sendto` calls | 64 | `send: SendQueueFull` |
| Maximum datagram | 65507 bytes | `send: MessageTooLong` |
| Pending receives per socket | 1 | `recvfrom: RecvPending` |
| Addresses | IP literals only | Hostnames rejected (`...: invalid address`) |
| `setsockopt` / multicast | Missing | No socket options |

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
| Path length | 4096 bytes | Longer paths fail, including permission scopes |
| Read per call | 10MB, sync | Larger reads fail |
| Permission scopes | Canonicalized at launch | `chdir` does not move them; symlink targets must stay inside a scope |
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
| Program loading | Not a `read` operation | `import` and `new Worker(path)` work without `--allow-read` |
| `Buffer` | Missing | Use `Uint8Array` |
| DOM / `window` | Missing | Backend only |
| Subprocess API | Separate global | `child_process.spawn` / `exec` / `execSync` — see the child_process section below |

## SQLite

| Area | Limit | When hit |
|------|-------|----------|
| `db.exec` | First statement only | Multi-statement SQL needs `db.execNoArgs` |
| Parameters | Positional `?` only | Named `:x` / `$x` are not supported |
| Integer precision | ±2⁵³ | Beyond → precision loss in JS |
| Open permissions | `read` + `write` on the file, `write` on the parent | WAL/-shm siblings need the parent; `:memory:` is exempt |

## Postgres

| Area | Limit | When hit |
|------|-------|----------|
| Pool | 10 connections | Extra queries queue |
| TLS (`sslmode`) | Not supported | — |
| Connection/socket timeouts | None | Slow queries wait indefinitely |
| `rowCount` | Returned rows only | INSERT/UPDATE row counts are not reported |
| COPY | Not supported | — |
| Permission scope | `net` on the DSN host and port | Global `sql` also needs `env` to read `PG_*` / `DATABASE_URL`; otherwise it falls back to `127.0.0.1:5432` |

## Process

| Area | Limit | When hit |
|------|-------|----------|
| `process.env` | Filtered snapshot at boot | Only `--allow-env` names are present; assigning to it does not affect the OS environment |
| `process.chdir` | Needs `read` on the target | Outside the scope it throws `PermissionDenied`; an allowed missing path is still a silent no-op |
| stdout/stdin streams | Missing | No `process.stdout.write` or stdin reads |
| `hrtime`, `kill` | Missing | — |
| Runaway JS watchdog | None | An infinite loop hangs the process |

## child_process

| Area | Limit | When hit |
|------|-------|----------|
| Concurrent children | 8 | The 9th `spawn` throws / `exec` rejects |
| `maxBuffer` | 1 MB per stream (default) | Overflow SIGTERMs the child; `exec` rejects, `spawn` sets `truncated` |
| Platform | POSIX only (macOS/Linux) | Windows throws |
| stdin, streams, events | Missing | Use `wait()` + captured `stdout` / `stderr` |
| ff exit | Children are not killed | Call `kill()` yourself |
| `exec` shell | `exec` / `execSync` always run `/bin/sh -c` | `/bin/sh` must be in `--allow-run`; permitting it permits any command string |

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
| Direct sources | Public HTTPS only; single package at the archive root | Private repos, auth, monorepo subdirectories unsupported |
| Direct archive size | 128 MB download cap | Larger archives fail |
| Raw archive URLs | Must end in `.tar.gz` or `.tgz` | Other URL forms are rejected |
| Build scripts | Not run | The archive must already contain runnable JS |
| Direct refs | Default to `HEAD`; branch/tag names are mutable | The lock's integrity check fails closed if the archive changes |

## What is *not* limited (common misconceptions)

- `res.blob()` and `res.formData()` **work** on `Request` and `Response`.
- HTTP redirects **are followed** (up to 5 hops) by `fetch`.
- Port shorthand `http.serve(3000, handler)` **works**; the default port is `3000`.
- `make install` targets **`~/.local/bin/ff`**, not `/usr/local/bin`.
- `import` and `new Worker(path)` do **not** need `--allow-read`; program loading is a carve-out.
- `process.argv`, `cwd`, `exit`, `pid`, `platform`, `arch`, `memoryUsage`, and `stats` are **not** permission-gated.
- `ff imprint`, `ff fmt`, `ff upgrade`, and `ff compile` are CLI operations, not runtime APIs, and are **not** gated by `--allow-*`.
