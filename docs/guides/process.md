---
title: Process
description: argv, env, cwd, exit, pid — what process gives you, and what's missing on purpose.
order: 13
---

# Process

`process` is a small global for inspecting and controlling the running program: arguments, environment, working directory, identity, and exit. Subprocesses live on the separate [child_process](/docs/api/child-process) global.

## Quick look

```js
// info.js
console.log("args:", process.argv);
console.log("pid:", process.pid, "on", process.platform, process.arch);
console.log("cwd:", process.cwd());
console.log("home:", process.env.HOME);
```

```sh
ff info.js hello --allow-env=HOME
# args: ["ff", "info.js", "hello", "--allow-env=HOME"]
# pid: 12345 on darwin arm64
# cwd: /Users/ada/demo
# home: /Users/ada
```

## Reference

| Member | Type | Description |
|--------|------|-------------|
| `process.argv` | `string[]` | Full argv **including** the runtime, script name, and `--allow-*` flags (`["ff", "main.js", …]`) |
| `process.env` | `object` | Filtered environment snapshot — only names granted by `--allow-env` appear |
| `process.cwd()` | `() => string` | Current working directory |
| `process.chdir(path)` | `(path) => void` | Change directory — throws `PermissionDenied` outside `--allow-read`; a missing/unreachable path is a silent no-op |
| `process.exit(code?)` | `(code?) => never` | Exit now; code clamped to 0–255, default 0. Also stops the event loop |
| `process.pid` | `number` | OS process id |
| `process.platform` | `string` | `"darwin"`, `"linux"`, `"win32"`, `"freebsd"`, or `"unknown"` |
| `process.arch` | `string` | `"arm64"`, `"x64"`, `"ia32"`, `"riscv64"`, or `"unknown"` |

> **Permissions:** `process.env` needs `--allow-env`; `process.chdir` needs
> `--allow-read` on the target. Everything else in this table is ungated. See
> [Permissions](/docs/concepts/permissions).

## Arguments: `argv`

`argv[0]` is the runtime, `argv[1]` is your script — user args start at index 2:

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

Permission flags are **not stripped** from `argv`: `ff app.js --allow-read=.`
leaves `--allow-read=.` in `process.argv`. They are also interpreted as policy,
so do not use a `--allow-*`-shaped value as an application argument.

A tiny flag parser needs nothing else:

```js
// serve.js
const args = process.argv.slice(2);
const port = Number(args[args.indexOf("--port") + 1] ?? 3000);

http.serve({ port }, () => new Response("ok"));
```

```sh
ff serve.js --port 4242 --allow-net=0.0.0.0:4242
curl http://127.0.0.1:4242/
# ok
```

## Environment: `env`

A plain object with string values, built at startup from the OS environment and
filtered by `--allow-env`. A name outside the grant is absent, so it reads as
`undefined` — fail fast on required ones:

```js
// config.js
const token = process.env.API_TOKEN;
if (!token) throw new Error("API_TOKEN is required");

const port = Number(process.env.PORT ?? 3000);
http.serve({ port }, () => new Response("ok"));
```

```sh
PORT=4242 API_TOKEN=secret ff config.js \
  --allow-env=PORT,API_TOKEN \
  --allow-net=0.0.0.0:3000
```

> **Note:** `process.env` is a startup snapshot and there is no `.env` loader.
> Export variables (or prefix the command, as above) before starting `ff`.
> Only granted names are copied into the object; bare `--allow-env` grants all
> of them. The `FF_*` variables (`FF_ECHO`, `FF_CERT`, `FF_KEY`, `FF_CA_FILE`)
> are read by the runtime itself, but the application sees them only if
> `--allow-env` includes them. See the [env guide](/docs/guides/env).

## Working directory: `cwd` / `chdir`

```js
console.log(process.cwd()); // where ff was launched
process.chdir("/tmp");      // needs --allow-read=/tmp
console.log(process.cwd()); // /private/tmp on macOS, /tmp on Linux
```

```sh
ff move.js --allow-read=/tmp
```

> **Caution:** `chdir` throws `PermissionDenied` when the target is outside the
> `read` scopes. Once allowed, a missing or unreachable path is a silent no-op
> and the cwd stays put. Check `process.cwd()` afterwards when the directory is
> user-supplied.

Scope roots are fixed at launch. A later `chdir` does **not** move them, so
`--allow-read=.` remains the launch directory. Relative `fs` paths resolve
against the new cwd and must still land inside a scope captured at startup.

Relative file paths in `fs` and module-adjacent lookups resolve against the cwd,
so `chdir` before serving from a data dir is a legitimate pattern. Prefer
absolute paths in long-lived servers to avoid surprises.

## Exiting: `exit`

```js
if (badConfig) {
  console.error("bad config, quitting");
  process.exit(1);
}
```

- Codes clamp to 0–255 (`exit(300)` → `255`, `exit(-5)` → `0`) — clamped, not wrapped mod 256.
- `exit()` stops the event loop immediately — pending timers, connections, and workers do not drain. The test helper `done()` relies on this to end server-fixture tests cleanly.
- Non-zero codes fail CI (`make test`, `test/run.sh` treat them as failure).
- An **uncaught throw** — at the top level of your script or of an imported module — prints `Error: …` with its stack to stderr and exits `1` on its own; no catch-all needed.

Graceful shutdown: there is no signal-handling API — stop servers with `Ctrl-C` from the terminal, or call `process.exit(0)` for programmatic shutdown.

## Practical example: CLI with subcommands

```js
// tool.js
const [cmd, ...rest] = process.argv.slice(2);

if (cmd === "greet") {
  console.log(`hello, ${rest[0] ?? "world"}`);
} else if (cmd === "serve") {
  const port = Number(process.env.PORT ?? 3000);
  http.serve({ port }, () => new Response("serving"));
} else {
  console.error("usage: tool.js <greet [name] | serve>");
  process.exit(1);
}
```

```sh
ff tool.js greet ada   # hello, ada
ff tool.js serve --allow-env=PORT --allow-net=0.0.0.0:3000
ff tool.js bogus       # usage… (exit 1)
```

`greet` is pure JS and needs no flags. `serve` needs `net`, plus `env` if it
should read `PORT`.

## What `process` does *not* have

| Missing (vs Node) | Use instead |
|-------------------|-------------|
| `spawn` / `exec` / `execFile` | Separate global: [child_process](/docs/api/child-process) — `spawn`, `exec`, `execSync` |
| `nextTick` | `queueMicrotask(fn)` |
| `uptime()` / `cpuUsage()` | `performance.now()` for elapsed time |
| `on('SIGINT')` / signal handlers | `Ctrl-C` in the terminal; `process.exit()` in code |
| `stdin` / `stdout` streams | `console.log` writes **stderr**; no readable stdin |

(`process.memoryUsage()` does exist — its `rss` is a peak counter from
`getrusage`, see the [API page](/docs/api/process).)

Need Postgres? Use the built-in [`SQL` client](/docs/api/postgres) — no driver to install.

## Troubleshooting

**`process.env.X` is undefined** — either the variable wasn't exported in the
launching shell, or `--allow-env` does not include it. Check both:
`X=1 ff app.js --allow-env=X`. No `.env` file is read.

**`chdir` threw `PermissionDenied`** — the target is outside every `read`
scope. Add `--allow-read=<target>` (or a parent directory). This is different
from a missing directory, which is still a silent no-op.

**`chdir` didn't move me** — the path is allowed but missing or unreachable. It
returns `undefined` and leaves the cwd unchanged; log `process.cwd()` after the
call to confirm.

**Exit code surprises** — codes clamp to 0–255 and `exit()` skips all draining. For "finish work then quit", drain first, then exit. An uncaught top-level or module throw already exits `1` by itself; errors thrown *inside* an HTTP handler become a `500` response instead.

**`process.spawn is not a function`** — subprocesses live on the separate [child_process](/docs/api/child-process) global: `child_process.exec("…")` or `child_process.spawn(cmd, args)`.
