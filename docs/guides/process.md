---
title: Process
description: argv, env, cwd, exit, pid — what process gives you, and what's missing on purpose.
order: 13
---

# Process

`process` is a small global for inspecting and controlling the running program: arguments, environment, working directory, identity, and exit. It has no `spawn`/`exec` — shelling out doesn't exist in Fairyfly.

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
| `process.chdir(path)` | `(path) => void` | Change directory — throws when the path is missing or unreachable |
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
process.chdir("/tmp");      // move — throws on failure
console.log(process.cwd()); // /tmp
```

Relative file paths in `fs` and module-adjacent lookups resolve against the cwd, so `chdir` before serving from a data dir is a legitimate pattern. Prefer absolute paths in long-lived servers to avoid surprises.

## Exiting: `exit`

```js
if (badConfig) {
  console.error("bad config, quitting");
  process.exit(1);
}
```

- Code is clamped to 0–255 (`exit(300)` → 44? no — clamped into range, negatives become 0).
- `exit()` stops the event loop immediately — pending timers, connections, and workers do not drain. The test helper `done()` relies on this to end server-fixture tests cleanly.
- Non-zero codes fail CI (`make test`, `test/run.sh` treat them as failure).

Graceful shutdown instead of a hard cut:

```js
process.onSIGINT = undefined; // no signal API — Ctrl-C stops ff from the terminal
```

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
| `spawn` / `exec` / `execFile` | Nothing in-runtime — call other services over HTTP, or use `fetch` against a sidecar |
| `nextTick` | `queueMicrotask(fn)` |
| `uptime()` / `memoryUsage()` / `cpuUsage()` | `performance.now()` for elapsed time; nothing for RSS |
| `on('SIGINT')` / signal handlers | `Ctrl-C` in the terminal; `process.exit()` in code |
| `stdin` / `stdout` streams | `console.log` writes stdout; no readable stdin |

Need Postgres? Use the built-in [`SQL` client](/docs/api/postgres) — no driver to install.

## Troubleshooting

**`process.env.X` is undefined** — the variable wasn't exported in the launching shell. `X=1 ff app.js` (prefix) or `export X=1` first. No `.env` file is read.

**`chdir` throws** — path missing or no permission. It throws rather than returning false — wrap in `try/catch` when the dir is user-supplied.

**Exit code surprises** — codes clamp to 0–255 and `exit()` skips all draining. For "finish work then quit", drain first, then exit.

**`spawn is not a function`** — by design. There is no subprocess API; use HTTP sidecars.
