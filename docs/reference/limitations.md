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
| Policy lifetime | Initial policy parsed at startup; can be narrowed one-way at runtime via `permissions.revoke(...)`, never expanded; read atomically by workers |
| Scope roots | Resolved against the launch cwd and fixed; `process.chdir()` does not move them |
| Path scopes | Canonicalized and symlink-resolved; OS `PATH_MAX` (4096 B Linux, 1024 B macOS); no globs or extensions |
| Network scopes | Host/port match with no DNS (supports `*` and `*.domain` wildcards; `localhost` ≠ `127.0.0.1`); `http.serve` defaults to `0.0.0.0` unless `hostname` is passed |
| Environment scopes | Exact, case-sensitive names; disallowed keys are absent from `process.env` |
| Run scopes | Basename or absolute path; `exec` / `execSync` also need `/bin/sh` |
| FFI | Bare `--allow-ffi` only; gates every `ffi` entry point except startup snapshot `ffi.allowed`; trust-equivalent to full access |
| Module loading | `import` and `new Worker(path)` do not need `read`; loaded code runs with the process policy |
| Isolation | Permission flags alone are an in-process policy layer (a symlink swapped between check and syscall can escape a path scope); on Linux, `--simple-sandbox` adds kernel-level Landlock LSM v1 + seccomp-bpf confinement (`io_uring_setup`/`io_uring_register`/`execve`/`ptrace`/`mount`/`bpf`/module syscalls blocked while `io_uring_enter` stays allowed), failing closed on non-Linux OSes |
| Granularity | Process-global (dynamically updatable via `permissions.revoke`); no per-request or per-user scopes |
| Deny flags | `--deny-read=<paths>`, `--deny-write=<paths>`, `--deny-net=<hosts>` override matching `--allow-*` / `--allow-all` grants (scope required; no `--deny-env` / `--deny-run` / `--deny-ffi`) |
| SSRF guard | `--deny-private-net` enforces post-DNS blocking of loopback, RFC1918, CGNAT, link-local/cloud-metadata (`169.254.169.254`), and private IPv6 across `fetch`, `WebSocket`, `tcp.connect`, outbound `udp`, and Postgres `sql` |

`run` and `ffi` execute arbitrary code with the process's authority. Use
permissions to reduce mistakes in code you mostly trust, not as the only
boundary for hostile code.

## Runtime limits

| Flag / env | Default | Valid range |
|---|---|---|
| `--max-heap` (`FF_MAX_HEAP`) | `64MB` | `8MB`–`4GB` |
| `--worker-heap` | `min(32MB, max-heap)` | `1MB`–`max-heap` |
| `--max-stack` | `1MB` | `128KB`–`native/2` (requires native stack >= 256 KB) |
| `--cpu-budget` (`FF_CPU_BUDGET`) | `0` (disabled) | `0`–`3600000` ms |
| `--wall-timeout` (`FF_WALL_TIMEOUT`) | `0` (disabled) | `0`–`3600000` ms (exits `124` on expiry) |
| `--max-log-bytes` | `0` (unlimited) | `0`–`100MB` (prints suppression notice once exceeded) |

## HTTP server

| Area | Limit | When hit |
|------|-------|----------|
| Concurrent connections | 512 | The 513th connection is accepted and immediately closed (no internal wait queue beyond the OS `listen(128)` backlog) |
| Request head (HTTP/1.1) | 4 KB (request line + header block) | Beyond → `431 Request Header Fields Too Large` |
| Request body (HTTP/1.1) | 1 MB hard cap (4 KB static buffer spills to heap; 64 MB global spill budget) | Beyond 1 MB → `413 Payload Too Large`; global budget exhausted → `503 Service Unavailable` |
| Response body | 10 MB hard cap (64 KB HTTP/1.1 stage buffer spills to the heap; 64 MB process-wide spill budget; up to 256 KB retained per slot) | Beyond 10 MB → `500`; spill budget exhausted → `503` for `Response`/`ArrayBuffer` bodies and `500` for plain `{status, body}` objects; `Response.file(path)` reads up to 50 MB (still subject to the 10 MB cap when sent over `http.serve`) |
| Response headers | 2048 bytes (HTTP/1.1 status line + user headers); HTTP/2: 128 total Nv slots per response including `:status` and `content-length` (so <= 126 user headers; name <= 64 B, value <= 4096 B) | Extra headers beyond the cap, and HTTP/2 pairs over 64 B name / 4096 B value, are dropped silently |
| Read/idle deadline | 30s without progress | A connection that receives no bytes for 30s while waiting for headers/body is closed; the deadline restarts on every read, so a trickling client is never expired. The same 30s is the keep-alive idle timeout. Sockets stalled mid-write are not timed out. |
| Hung handler | 30s | Connection fails with `504` |
| Graceful drain | `SHUTDOWN_DRAIN_MS = 5000` ms | Remaining active sockets force-closed after 5s on `server.close()` |
| Framing strictness | Duplicate/ambiguous Content-Length, Transfer-Encoding, obs-fold, or BWS | Terminated with `400 Bad Request` |
| Response status | 100..999 | Values outside 100..999 fall back to default (`200`, or `302` in `Response.redirect`) |
| Bind address | Defaults to `0.0.0.0`; `hostname` accepts IPv4/IPv6 literals (optional `reusePort`); `port` must be an integer `0..65535` | No DNS hostnames, no `FF_PORT`; out-of-range ports throw `TypeError`; `--allow-net` must match `<hostname>:<port>` |
| Plain listener protocol | HTTP/1.1 | No HTTP/2 framing without TLS |
| Routes object | Up to 16 `:param` captures/route; route key `< 512` B | Oversized URLs never reach routing: the request head is bounded first (`431` on HTTP/1.1, `400` on HTTP/2) |
| HTTP/2 | TLS + ALPN (nghttp2); `MAX_STREAMS = 100`/conn — a 101st concurrent stream is refused with `RST_STREAM(REFUSED_STREAM)`; req headers `<= 64 KB` (`431`); `:path <= 512 B`, `:method <= 16 B`, `:authority <= 255 B` (`400`); req body `<= 10 MB/stream` (`413`), `16 MB/session` (session failed, connection closed); staged response bytes `<= 16 MiB/session` (connection closed on overflow) | Plain sockets stay HTTP/1.1; `ReadableStream` response body returns `501` |
| `FF_ECHO` | Any value set (even empty — only *unsetting* disables) | Every **HTTP/1.1** request gets canned `200 {"message":"ok"}`; HTTP/2 requests still run the handler |

## Fetch (client)

| Area | Limit | When hit |
|------|-------|----------|
| Concurrent fetches | 16 | The 17th rejects immediately with `"Failed to start fetch"` |
| Body stage per slot | 64KB | Larger bodies spill to chunks/heap |
| Response body cap | 16 MB (decompressed output; the declared `Content-Length` is only pre-checked for identity responses) | Responses beyond 16 MB reject with `"ResponseTooLarge: body exceeds limit"` |
| I/O timeout | 30s | Slow servers fail |
| Redirects | Followed, max 5 hops | Rejects with `"Too many redirects"`; every hop is re-checked against `--allow-net` |
| Cross-origin credentials | Stripped on cross-origin redirect | `authorization`, `cookie`, `proxy-authorization`, `www-authenticate`, `x-api-key`, `x-auth-token` dropped when changing origin |
| Header validation | RFC 7230 character validation | Invalid header names or values containing CR/LF/NUL/CTLs throw `TypeError` |
| Abort / `signal` | `AbortSignal` supported (`init.signal` / `req.signal`) | `timeout` and `redirect` init keys are ignored (`AbortSignal.timeout(ms)` uses 1 slot in the 128-timer table) |
| TLS hostnames | DNS SAN verification only | IP-literal TLS hosts (`https://127.0.0.1:...`) fail closed; connect using DNS hostnames |
| Protocol | HTTP/1.1 | No HTTP/2 client |
| Proxy | HTTP proxies via env vars (`HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY`); `NO_PROXY` bypass | No SOCKS support; `https://` targets do not support `https://` proxy URLs (TLS-to-proxy; plain `http://` targets do); env is read once at launch |

## WebSocket

| Area | Limit | When hit |
|------|-------|----------|
| Client sockets | 64 per process | Extra connects fail |
| Message size | `16384` bytes (`16 KB`) per message | Server and client RX close with `1009` when a frame or assembled message exceeds `16384` bytes (client frames over the 64 KiB `RDBUF` die with `1006` first). On the server a single frame is additionally bounded by the 4 KiB `READ_BUF_SIZE` staging buffer, so a 4 KB-16 KB frame kills the connection without a Close frame. Server TX fits at most 16,370 B of payload (16 KiB write buffer minus the frame header); larger sends close `1009`. Client TX silently truncates at `16384` bytes |
| Handshake URL path (client) | 512 bytes | Longer paths fail; CRLF/control characters rejected. The server has no 512-byte path limit — the whole request head must fit 4 KiB |
| Frame masking | Required from clients per RFC 6455 | Server rejects unmasked client frames and closes socket |
| Control frames | Max 125 bytes payload (`123` B close reason), no reserved opcodes | Malformed control frames close connection |
| Text encoding | Strict UTF-8 validation | Invalid UTF-8 text message closes connection |
| Socket handles | Generation-tagged `{slot, gen}` | Retained JS handles cannot address recycled slots (post-close `send` is a silent no-op) |
| Server socket API | `send` (string) / `sendBinary` only | No `id`, `readyState`, or `close` on server sockets |
| Send buffer | Client: 32 KB (`TX_BUF_SIZE = 32768`); Server: 16 KB | Client throws `TypeError: WebSocket: send buffer full`; server drops outbound frames silently when full |
| Proxy | Same env vars as `fetch` | `ws://` needs a CONNECT-capable proxy |

## Raw TCP (`tcp`)

| Area | Limit | When hit |
|------|-------|----------|
| Concurrent sockets | 128 (`MAX_TCP`) | `TypeError: max TCP connections exceeded (128)` |
| Read / write buffers | `16384` bytes (`16 KB`) each | Larger `write()` throws `TypeError: write payload exceeds buffer size (16KB)` |
| Pending I/O | 1 concurrent `read()` + 1 concurrent `write()` per socket | Throws `TypeError: concurrent read/write already in progress` |
| Addresses / scope | IPv4/IPv6 literals only (no DNS); client-only; `--allow-net` | Hostnames rejected with `TypeError`; no server/listen or TLS upgrade |

## UDP

| Area | Limit | When hit |
|------|-------|----------|
| Concurrent sockets | 64 (shared pool) | `udp.socket: no socket slots available` |
| In-flight `sendto` calls | 64 | `send: SendQueueFull` |
| Maximum datagram | 65507 bytes | `send: MessageTooLong` |
| Pending receives per socket | 1 | `recvfrom: RecvPending` |
| Addresses | IP literals only | Hostnames rejected (`...: invalid address`) |
| `setsockopt` / multicast | Missing | No socket options |

## Timers, cron, and workers

| Area | Limit | When hit |
|------|-------|----------|
| Live timers | 128 (shared across `setTimeout`, `setInterval`, `AbortSignal.timeout`, and `ff.cron`) | `TypeError: too many timers (max 128)` |
| Extra timer args | 8 after `ms` | Beyond 8 throws `TypeError: setTimeout accepts at most 8 callback arguments` (also accepts `{ signal }` or `AbortSignal` as 3rd arg) |
| Cron jobs (`ff.cron`) | 32 jobs (`MAX_CRON`), no cancel/unref | `TypeError: Max cron jobs (32) exceeded`; `@every` supports `ms`/`s`/`m`; 5-field cron rejects expressions with no match in 366 days |
| Workers | 8 | `too many workers (max 8)` |
| Worker scope | `console`, numeric timers, `queueMicrotask`, `postMessage`, `structuredClone`, `crypto` (`randomUUID`, `getRandomValues`, `subtle`; `crypto.bcrypt` throws), `btoa`, `atob`, `performance` (`performance.now()`), `workerData`, `self` | No `fs`, `fetch`, `http.serve`, `crypto.bcrypt`, `TextEncoder`, `URL`, `Blob`, `process`, `ffi`, `tcp`, `udp`, `ff`, or nested workers; 10 MiB script cap |
| Worker heap / stack | `min(32 MB, --max-heap)` default (configurable via `--worker-heap`), `--max-stack` JS stack (`>= max(8 MB, 2 * --max-stack)` OS thread stack) | — |
| Worker message | 4 MB per message | Larger `postMessage` payloads are rejected |
| `process.nextTick` | Missing | Use `queueMicrotask` |

> [!NOTE]
> **Native vs JS stack safety**: QuickJS checks recursion depth against the configured JS limit, but each frame also occupies native stack frames. Setting a JS limit equal to the native reservation is pathological (quickjs-ng PR #1700), triggering SIGSEGV/SIGBUS before QuickJS can throw `RangeError`. Fairyfly enforces native stack >= 2 * JS limit on main and worker threads. Worker native stack automatically grows up to 16 MB when `--max-stack=8MB`. Committed RSS under deep recursion across 8 workers at an 8 MB limit is ~74 MB.

```js
// instead of process.nextTick(fn):
queueMicrotask(fn);
```

## Filesystem

| Area | Limit | When hit |
|------|-------|----------|
| Path length | 4096 bytes | Longer paths fail, including permission scopes |
| Read per call | 10MB, sync | Larger reads fail |
| Write per call | 10MB hard cap (sync and async) | Beyond 10MB throws/rejects instead of truncating |
| Permission scopes | Canonicalized at launch | `chdir` does not move them; symlink targets must stay inside a scope |
| API style | Sync + six `*Async` Promise variants (`readFileAsync`, `writeFileAsync`, `existsAsync`, `mkdirAsync`, `rmAsync`, `readdirAsync`) | No `fs.watch` — poll with timers |

## Console

| Area | Type | Description |
|------|------|-------------|
| Arguments printed | All per call | Every argument prints, joined with spaces |
| Destination | stderr | `console.log > out.txt` captures nothing |
| Output cap | Unlimited by default | `--max-log-bytes=<size>` (`0`–`100MB`) caps total bytes written across `console.*` and emits a suppression notice once reached |

## Modules and language

| Area | Limit | When hit |
|------|-------|----------|
| Module system | ESM only | No `require()`, no CommonJS |
| Relative extensions | Optional for `.js` | `./x` probes `./x.js`, then `./x/index.js`; other extensions must be written out |
| Bare specifiers | Resolved via `node_modules` | Needs `ff imprint` install first |
| Package containment | Strict directory boundary | Manifest targets (`main`, `module`, `exports`) and subpaths containing `..` or escaping package root are rejected |
| Program loading | Not a `read` operation | `import` and `new Worker(path)` work without `--allow-read` |
| `Buffer` | Missing | Use `Uint8Array` |
| DOM / `window` | Missing | Backend only |
| Subprocess API | Separate global | `child_process.spawn` / `exec` / `execSync` — see the child_process section below |

## SQLite

| Area | Limit | When hit |
|------|-------|----------|
| `db.exec` | First statement only | Multi-statement SQL needs `db.execNoArgs` |
| Statement cache | 64 prepared statements per `Database` handle (FIFO eviction; auto-evicts on `SQLITE_SCHEMA`) | Raw `Statement` objects are not exposed to JS |
| Parameters | Positional `?` only | Named `:x` / `$x` are not supported; 32-bit signed ints bind as `INTEGER`, larger JS numbers bind as `REAL` (`double`), `BigInt` binds as `NULL` |
| Integer precision | ±2⁵³ | Beyond → precision loss in JS |
| Open permissions | `read` + `write` on the file, `write` on the parent | WAL/-shm siblings need the parent; `:memory:` is exempt |

## Postgres

| Area | Limit | When hit |
|------|-------|----------|
| Pool | 10 connections | Extra queries queue |
| TLS (`sslmode`) | `verify-full` and `disable` supported via BearSSL | `sslmode=verify-full` requires `sslrootcert` pointing to valid PEM CA bundle; libpq modes (`require`, `prefer`, `verify-ca`) rejected |
| Connection/socket timeouts | None | Slow queries wait indefinitely |
| `rowCount` | Returned rows only | INSERT/UPDATE row counts are not reported |
| COPY | Not supported | — |
| Permission scope | `net` on the DSN host and port, plus `read` on `sslrootcert` when TLS is used | Global `sql` also needs `env` to read `PG_*` / `DATABASE_URL` / `PGSSL*`; otherwise it falls back to `127.0.0.1:5432` |

## Process

| Area | Limit | When hit |
|------|-------|----------|
| `process.env` | Filtered snapshot at boot | Only `--allow-env` names are present; assigning to it does not affect the OS environment |
| `process.chdir` | Needs `read` on the target | Outside the scope it throws `PermissionDenied`; an allowed missing path is still a silent no-op |
| Signals (`process.on` / `once` / `off`) | `SIGINT`, `SIGTERM`, `SIGHUP`, `SIGUSR1`, `SIGUSR2` (max 8 listeners per signal) | Unsupported signal names or > 8 listeners throw `TypeError` |
| `process.kill(pid, sig?)` | Needs `--allow-run=kill` when `pid !== process.pid` | Self-signaling `process.pid` is ungated |
| `stdout` / `stdin` | Minimal helpers only | `process.stdout.write` and `process.stdin.read` / `readSync` are supported; no Node EventEmitter streams |
| `hrtime` | Missing | Use `performance.now()` |
| Runaway JS / hang watchdogs | Opt-in (`--cpu-budget` / `--wall-timeout`) | Disabled (`0`) by default; `--cpu-budget=<ms>` interrupts runaway JS loops (`InternalError: interrupted`) and `--wall-timeout=<ms>` exits `124` |

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
| Server TLS versions | TLS 1.2 minimum (TLS 1.0 and 1.1 rejected) | No TLS 1.3 in the default BearSSL build |
| IP-literal TLS hosts | DNS SAN verification only | `std.crypto.tls.Client` matches DNS SANs, not IP SANs; IP-literal TLS fails closed |
| `ff upgrade` | Verifies SHA-256 digest from `sha256sums.txt` | Mismatched or missing hash refuses install |
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
- `process.argv`, `cwd`, `exit`, `pid`, `platform`, `arch`, `on`, `once`, `off`, `memoryUsage`, and `stats` are **not** permission-gated (`process.kill` is ungated for `process.pid`).
- `ff imprint`, `ff fmt`, `ff upgrade`, and `ff compile` are CLI operations, not runtime APIs, and are **not** gated by `--allow-*`.
