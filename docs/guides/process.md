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
ff info.js hello
# args: ["ff", "info.js", "hello"]
# pid: 12345 on darwin arm64
# cwd: /Users/ada/demo
# home: /Users/ada
```

## Reference

| Member | Type | Description |
|--------|------|-------------|
| `process.argv` | `string[]` | Full argv **including** the runtime and script name (`["ff", "main.js", …]`) |
| `process.env` | `object` | Environment snapshot as plain key/value strings |
| `process.cwd()` | `() => string` | Current working directory |
| `process.chdir(path)` | `(path) => void` | Change directory — silently does nothing when the path is missing or unreachable (never throws; verify with `cwd()`) |
| `process.exit(code?)` | `(code?) => never` | Exit now; code clamped to 0–255, default 0. Also stops the event loop |
| `process.pid` | `number` | OS process id |
| `process.platform` | `string` | `"darwin"`, `"linux"`, `"win32"`, `"freebsd"`, or `"unknown"` |
| `process.arch` | `string` | `"arm64"`, `"x64"`, `"ia32"`, `"riscv64"`, or `"unknown"` |

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

Plain object, string values only. Missing keys read as `undefined` — fail fast on required ones:

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

> **Note:** `process.env` is a startup snapshot and there is no `.env` loader. Export variables (or prefix the command, as above) before starting `ff`. The `FF_` variables (`FF_ECHO`, `FF_CERT`, `FF_KEY`, `FF_CA_FILE`) are read the same way — see the env guide.

## Working directory: `cwd` / `chdir`

```js
console.log(process.cwd()); // where ff was launched
process.chdir("/tmp");      // move — verify with cwd(), failures are silent
console.log(process.cwd()); // /tmp
```

> **Caution:** `chdir` never throws — a missing or unreachable path is a silent no-op and the cwd stays put. Check `process.cwd()` afterwards when the directory is user-supplied.

Relative file paths in `fs` and module-adjacent lookups resolve against the cwd, so `chdir` before serving from a data dir is a legitimate pattern. Prefer absolute paths in long-lived servers to avoid surprises.

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

Graceful shutdown instead of a hard cut: there is no signal-handling API — stop servers with `Ctrl-C` from the terminal, or call `process.exit(0)` for programmatic shutdown.

> **Note:** There is no signal-handling API. Stop servers with `Ctrl-C` from the terminal, or `process.exit(0)` for programmatic shutdown.

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
ff tool.js serve       # serves on 3000 (or $PORT)
ff tool.js bogus       # usage… (exit 1)
```

## What `process` does *not* have

| Missing (vs Node) | Use instead |
|-------------------|-------------|
| `spawn` / `exec` / `execFile` | Separate global: [child_process](/docs/api/child-process) — `spawn`, `exec`, `execSync` |
| `nextTick` | `queueMicrotask(fn)` |
| `uptime()` / `memoryUsage()` / `cpuUsage()` | `performance.now()` for elapsed time; nothing for RSS |
| `on('SIGINT')` / signal handlers | `Ctrl-C` in the terminal; `process.exit()` in code |
| `stdin` / `stdout` streams | `console.log` writes **stderr**; no readable stdin |

Need Postgres? Use the built-in [`SQL` client](/docs/api/postgres) — no driver to install.

## Troubleshooting

**`process.env.X` is undefined** — the variable wasn't exported in the launching shell. `X=1 ff app.js` (prefix) or `export X=1` first. No `.env` file is read.

**`chdir` didn't move me** — it never throws; a bad path is a silent no-op. Log `process.cwd()` after the call to confirm.

**Exit code surprises** — codes clamp to 0–255 and `exit()` skips all draining. For "finish work then quit", drain first, then exit. An uncaught top-level or module throw already exits `1` by itself; errors thrown *inside* an HTTP handler become a `500` response instead.

**`process.spawn is not a function`** — subprocesses live on the separate [child_process](/docs/api/child-process) global: `child_process.exec("…")` or `child_process.spawn(cmd, args)`.
