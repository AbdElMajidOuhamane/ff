---
title: Process
description: argv, env, cwd, exit, pid — what process gives you, and what's missing on purpose.
order: 13
---

# Process

This guide is about *using* `process` in real programs — parsing a CLI,
reading config, shutting down cleanly, and keeping an eye on memory. For the
exhaustive member list and exact return shapes, see the
[`process` API reference](/docs/api/process).

`process` is Fairyfly's window onto the running program. It has no
`spawn`/`exec`; the only way to talk to another process is over the network.

## A first look

```js
// info.js
console.log("args:", process.argv);
console.log("pid:", process.pid, "on", process.platform, process.arch);
console.log("cwd:", process.cwd());
```

```sh
ff info.js hello
# args: ["ff","info.js","hello"]
# pid: 12345 on darwin arm64
# cwd: /Users/ada/demo
```

## Parsing arguments

`argv[0]` is the runtime and `argv[1]` is the script, so your arguments start
at index 2. Slice them off and mirror the common subcommand shape:

```js
// tool.js
const [cmd, ...rest] = process.argv.slice(2);

switch (cmd) {
  case "greet":
    console.log(`hello, ${rest[0] ?? "world"}`);
    break;
  case "serve":
    http.serve({ port: 3000 }, () => new Response("serving"));
    break;
  default:
    console.error("usage: tool.js <greet [name] | serve>");
    process.exit(1);
}
```

```sh
ff tool.js greet ada   # hello, ada
ff tool.js serve       # serves on 3000
ff tool.js bogus       # usage… (exit 1)
```

> `ff -e "<code>"` shifts the layout: `argv` becomes
> `["ff", "-e", "<code>"]`, so the code string occupies index 2.

Because there's a runtime and a script ahead of your args, `slice(2)` is the
idiom to remember. A tiny flag parser needs nothing fancier:

```js
// serve.js
const args = process.argv.slice(2);
const port = Number(args[args.indexOf("--port") + 1] ?? 3000);
http.serve({ port }, () => new Response("ok"));
```

## Configuring from the environment

`process.env` is a plain object of string values, captured **once at boot**.
Read required values eagerly and fail fast; give optional ones a default:

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

```sh
export API_TOKEN=secret
ff config.js
```

There is no `.env` loader and no live re-read — export variables (or prefix
the command) before launching `ff`. `process.env` is a snapshot, and since it
is an ordinary object, writing to it only changes JS state, never the OS
environment.

## Keeping the working directory honest

`process.cwd()` reports where `ff` was launched. `process.chdir(path)` moves
you — but it **never throws**: a bad path, or even a non-string argument,
leaves the cwd unchanged and returns `undefined`. That makes it safe to call
without a `try/catch`, but it also means failures are invisible unless you
check:

```js
// movedir.js
process.chdir("/tmp/data");       // a missing path is a silent no-op
console.log("now in", process.cwd());   // confirm where you actually are
```

Prefer absolute paths in long-lived servers so a stray `chdir` elsewhere can't
move your file reads out from under you.

## Shutting down

`process.exit(code)` ends the process *now* — the code is clamped to
`0`–`255` (so `exit(300)` is `255`, `exit(-5)` is `0`), and defaulting to `0`.
Nothing is drained: pending timers, in-flight requests, and workers are all
cut off.

```js
// validate.js
if (process.env.STRICT !== "1") {
  console.error("STRICT=1 is required; aborting");
  process.exit(1);
}
```

For "finish the work, *then* quit", drain first and exit last:

```js
(async () => {
  await Promise.all([Promise.resolve("a"), Promise.resolve("b")]);   // let work settle
  process.exit(0);
})().catch((err) => {
  console.error(err);
  process.exit(1);
});
```

There is **no signal API** — no `process.on("SIGINT")`. In development, stop a
server with `Ctrl-C`; for programmatic shutdown, call `process.exit(0)`. An
uncaught throw at the top level of a script already prints its stack and exits
`1` for you (see [Errors and exit codes](/docs/concepts/errors)).

## Watching memory

Unlike Node, Fairyfly exposes a single, cheap memory figure: `rss`, the
process **peak** resident set size in bytes. It's a high-water mark from
`getrusage`, so it only ever goes up — good for spotting growth, not for
precise current usage:

```js
// memwatch.js
function logRss() {
  const { rss } = process.memoryUsage();
  console.detail(`peak rss: ${(rss / 1048576).toFixed(1)} MiB`);
}

logRss();
setInterval(logRss, 5000).unref();   // background: never holds the loop open
```

Emitting one `rss` sample per request is also handy in structured logs:

```js
http.serve({ port: 3000 }, (url) => {
  const { rss } = process.memoryUsage();
  console.log(JSON.stringify({ level: "info", url, rss }));
  return new Response("ok");
});
```

For internal allocation/spill tuning, `process.stats()` returns a bag of
monotonic counters for the fetch, HTTP, and Postgres subsystems — mostly `0`
until you actually do work:

```js
// stats.js
setTimeout(() => {
  const s = process.stats();
  console.log("fetch spills:", s.fetch.bodyHeap, "| pg waiters:", s.pg.waitEnqueue);
}, 50);
```

See the [API reference](/docs/api/process#introspection-stats) for the full
field list. Treat these as diagnostic telemetry, not a stable contract.

## Troubleshooting

**`process.env.X` is undefined** — the variable wasn't exported in the
launching shell. `X=1 ff app.js` (prefix) or `export X=1` first; no `.env`
file is read.

**`chdir` didn't move me** — it never throws; a bad path or non-string
argument is a silent no-op. Log `process.cwd()` after the call to confirm.

**Exit code surprises** — codes clamp to `0`–`255`, and `exit()` skips all
draining. To "finish work then quit", drain first, then exit. Uncaught
top-level or module throws already exit `1`; errors thrown *inside* an HTTP
handler become a `500` instead.

**`spawn is not a function`** — by design. There is no subprocess API; use
HTTP sidecars.

## What `process` does *not* have

| Missing (vs Node) | Use instead |
|---|---|
| `spawn` / `exec` / `execFile` | Nothing in-runtime — talk to services over HTTP |
| `nextTick` | `queueMicrotask(fn)` (see [Timers](/docs/guides/timers)) |
| `uptime()` / `cpuUsage()` | [`performance.now()`](/docs/api/performance) for elapsed time |
| `on('SIGINT')` / signal handlers | `Ctrl-C` in the terminal; `process.exit()` in code |
| `stdin` / `stdout` streams | [`console`](/docs/api/console) writes **stderr**; no readable stdin |
| `memoryUsage()` beyond `rss` | Only `rss` (peak) is exposed |

Need Postgres? Use the built-in [`SQL` client](/docs/api/postgres) — no driver
to install.

## See also

- [`process` API reference](/docs/api/process) — every member and return shape
- [Environment variables](/docs/guides/env)
- [Logging](/docs/guides/logging)
- [Errors and exit codes](/docs/concepts/errors)
