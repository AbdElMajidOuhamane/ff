---
title: Process
description: argv, env, cwd, exit, pid — what process gives you, and what's missing on purpose.
order: 13
---

# Process

`process` is a small global for inspecting and controlling the running
program: arguments, environment, working directory, identity, resource
counters, and exit. There is no `spawn`/`exec` — shelling out doesn't exist
in Fairyfly.

## Quick look

```js
// info.js
console.log("args:", process.argv);
console.log("pid:", process.pid, "on", process.platform, process.arch);
console.log("cwd:", process.cwd());
console.log("home:", process.env.HOME ?? "(unset)");
console.log("rss bytes:", process.memoryUsage().rss);
```

```sh
ff info.js hello
# args: ["ff","info.js","hello"]
# pid: 12345 on darwin arm64
# cwd: /Users/ada/demo
# home: /Users/ada
# rss bytes: 4177920
```

## Reference

Every member, with its exact return shape:

| Member | Type | Returns / value |
|---|---|---|
| `process.argv` | `string[]` | Full argv **including** the runtime and script name |
| `process.env` | `object` | Boot snapshot of the environment; string values only |
| `process.pid` | `number` | OS process id |
| `process.platform` | `string` | `"darwin"`, `"linux"`, `"win32"`, `"freebsd"`, or `"unknown"` |
| `process.arch` | `string` | `"arm64"`, `"x64"`, `"ia32"`, `"riscv64"`, or `"unknown"` |
| `process.cwd()` | `() => string` | Absolute current working directory |
| `process.chdir(path)` | `(path) => undefined` | Change directory; **silent no-op** on any failure |
| `process.exit(code?)` | `(code?) => never` | Exit now; code clamped to `0`–`255`, default `0` |
| `process.memoryUsage()` | `() => { rss: number }` | Peak resident set size, normalized to bytes |
| `process.stats()` | `() => object` | Internal allocation/spill counters |

Arity (what QuickJS reports as `.length`): `exit` 1, `chdir` 1, `cwd` 0,
`memoryUsage` 0, `stats` 0.

## Arguments: `argv`

`argv[0]` is the runtime **as it was invoked**, `argv[1]` is your script, and
user arguments start at index 2:

```js
// greet.js
const name = process.argv[2] ?? "world";
console.log(`hello, ${name}`);
```

```sh
ff greet.js ada
# hello, ada
ff greet.js
# hello, world
```

Under `ff -e "<code>"` the "script" slot is the `-e` flag and the code string
takes the next slot:

```js
// argv for: ff -e 'console.log(process.argv.length)'
// ["ff", "-e", "console.log(process.argv.length)"]  → length 3
```

A tiny flag parser needs nothing else:

```js
// serve.js
const args = process.argv.slice(2);
const port = Number(args[args.indexOf("--port") + 1] ?? 3000);

http.serve({ port }, () => new Response("ok"));
```

```sh
ff serve.js --port 4242
curl http://127.0.0.1:4242/
# ok
```

## Environment: `env`

A plain object of string key/value pairs, captured **once at startup**.
Missing keys read as `undefined`:

```js
// config.js
const token = process.env.API_TOKEN;
if (!token) throw new Error("API_TOKEN is required");

const port = Number(process.env.PORT ?? 3000);
http.serve({ port }, () => new Response("ok"));
```

```sh
PORT=4242 API_TOKEN=secret ff config.js
```

> **Note:** `process.env` is a snapshot — there is no `.env` loader and no
> live re-read. Because it's an ordinary object, assigning
> `process.env.X = "y"` only changes the JS object; it does **not** reach the
> OS environment. Export variables (or prefix the command, as above) before
> starting `ff`. The `FF_` variables (`FF_ECHO`, `FF_CERT`, `FF_KEY`,
> `FF_CA_FILE`) are read the same way — see the env guide.

## Working directory: `cwd` / `chdir`

```js
console.log(process.cwd()); // where ff was launched
process.chdir("/tmp");      // move — verify with cwd(), failures are silent
console.log(process.cwd()); // /tmp
```

`chdir` **never throws**. On a missing/unreachable path — or a non-string
argument — it returns `undefined` and the cwd stays put. Check
`process.cwd()` afterwards when the path is user-supplied.

Relative file paths in `fs` and module-adjacent lookups resolve against the
cwd, so `chdir` before serving from a data dir is legitimate. Prefer absolute
paths in long-lived servers.

## Exiting: `exit`

```js
if (!process.env.API_TOKEN) {
  console.error("missing API_TOKEN, quitting");
  process.exit(1);
}
```

- The code is clamped to `0`–`255` (clamped, not wrapped): `exit(300)` → `255`,
  `exit(-5)` → `0`, `exit()` → `0`, `exit(7)` → `7`.
- `exit()` terminates the process immediately (`std.process.exit`) — pending
  timers, connections, and workers **do not drain**.
- Non-zero codes fail CI.
- An **uncaught throw** — at the top level of your script or of an imported
  module — prints the error with its stack to stderr and exits `1` on its
  own; no catch-all needed.

> **Note:** There is no signal-handling API. Stop servers with `Ctrl-C` from
> the terminal, or `process.exit(0)` for programmatic shutdown.

## Identity: `pid` / `platform` / `arch`

```js
console.log(process.pid);       // 12345
console.log(process.platform);  // "darwin"
console.log(process.arch);      // "arm64"
```

`platform` maps the build OS to a Node-style name; `arch` maps the CPU. Both
fall back to `"unknown"` for targets outside the listed sets.

## Memory: `memoryUsage()`

```js
const { rss } = process.memoryUsage();
console.log(`peak rss: ${(rss / 1024 / 1024).toFixed(1)} MiB`);
// peak rss: 4.0 MiB
```

Returns an object with a **single** field, `rss`:

| Field | Meaning |
|---|---|
| `rss` | Peak resident set size in **bytes** |

It reads the process high-water mark from `getrusage(RUSAGE_SELF).maxrss` and
normalizes to bytes: Linux reports KiB (multiplied by 1024), macOS reports
bytes directly. Because it is a **peak**, it never decreases within a run.

There is no `heapTotal`, `heapUsed`, `external`, or `arrayBuffers` — only
`rss`.

## Introspection: `stats()`

`stats()` returns monotonic, per-process counters that expose how much the
network subsystems spilled to the heap (internal tuning telemetry). Every
value is a number; all are `0` until the relevant subsystem runs.

```js
// stats.js
console.log(JSON.stringify(process.stats(), null, 2));
```

```text
{
  "fetch": { "bodyHeap": 0, "hdrSpill": 0, "decompressHeap": 0 },
  "http":  { "bodySpill": 0, "bodySpillReuse": 0 },
  "pg":    { "submit": 0, "jobReuse": 0, "jobFresh": 0, "wqueueGrow": 0,
             "wqueueShrink": 0, "waitEnqueue": 0, "arenaResetFail": 0,
             "freelistDestroy": 0 }
}
```

| Counter | Counts |
|---|---|
| `fetch.bodyHeap` | Fetch bodies that spilled to the heap (> 64 KiB stage buffer) |
| `fetch.hdrSpill` | Responses whose header count exceeded the stack buffer (> 64 headers) |
| `fetch.decompressHeap` | Decompression window buffers allocated on the heap |
| `http.bodySpill` | Server response bodies > 64 KiB spilled to a per-connection heap buffer |
| `http.bodySpillReuse` | Spills that reused a retained buffer instead of reallocating |
| `pg.submit` | Queries submitted to the Postgres pool |
| `pg.jobReuse` | Job objects taken from the pool freelist |
| `pg.jobFresh` | Job objects freshly allocated (freelist empty) |
| `pg.wqueueGrow` | Connection write-queue array growths |
| `pg.wqueueShrink` | Connection write-queue array shrinks |
| `pg.waitEnqueue` | Queries enqueued waiting for a free connection (pool saturated) |
| `pg.arenaResetFail` | Job arena `reset` failures (retain limit hit) |
| `pg.freelistDestroy` | Released jobs destroyed instead of pooled (freelist at capacity) |

These are diagnostic counters, not a public contract — treat the values as
opaque and stable only for a given build.

## What `process` does *not* have

| Missing (vs Node) | Use instead |
|---|---|
| `spawn` / `exec` / `execFile` | Nothing in-runtime — call other services over HTTP, or `fetch` a sidecar |
| `nextTick` | `queueMicrotask(fn)` |
| `uptime()` / `cpuUsage()` | [`performance.now()`](/docs/api/performance) for elapsed time |
| `on('SIGINT')` / signal handlers | `Ctrl-C` in the terminal; `process.exit()` in code |
| `stdin` / `stdout` streams | [console](/docs/api/console) writes **stderr**; no readable stdin |
| `memoryUsage().heapUsed` and friends | Only `rss` is exposed |
| `env` mutation | Export variables before launching `ff` |

Need Postgres? Use the built-in [`SQL` client](/docs/api/postgres) — no driver
to install.

## See also

- [Process guide](/docs/guides/process) — CLI, config, and shutdown patterns
- [`performance`](/docs/api/performance) — monotonic timing
- [Errors and exit codes](/docs/concepts/errors)
