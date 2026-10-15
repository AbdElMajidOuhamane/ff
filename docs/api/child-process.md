---
title: child_process
description: Subprocesses — spawn, exec, and execSync with captured output, exit codes, and signals.
order: 14
---

# child_process

`child_process` runs OS subprocesses. POSIX only (macOS and Linux), max **8
concurrent children**. Everything is evented on the main loop — no extra
threads — and it is safe to use alongside `http.serve`, `fetch`, or `Worker`.

## Quick look

```js
const r = await child_process.exec("git rev-parse HEAD");
console.log(r.stdout.trim(), r.code);

const child = child_process.spawn("ffmpeg", ["-i", "in.mp4", "out.mp4"]);
const { code, signal } = await child.wait();
```

## Reference

| Member | Description |
|---|---|
| `child_process.spawn(command, args?, options?)` | Starts a child; returns a `Child` object. Throws `TypeError` on bad arguments, `Error` when the command cannot start, and when 8 children are already running |
| `child_process.exec(command, options?)` | Runs `command` through `/bin/sh -c`; resolves `{ stdout, stderr, code, signal }` with `stdout`/`stderr` as strings. A non-zero exit still resolves — it rejects only on launch failure or `maxBuffer` overflow |
| `child_process.execSync(command, options?)` | Blocking variant of `exec`; same result shape, returns directly instead of a Promise |
| `child.kill(signal?)` | Sends a signal — default `"SIGTERM"`; accepts a name (`"SIGKILL"`) or a number. Returns `false` when the child already exited |
| `child.wait()` | `Promise<{ code, signal }>` that resolves once the child exited **and** its pipes closed. Safe to call repeatedly (the same promise is returned) |

Options (all functions): `cwd` (string), `env` (object — **replaces** the
environment), `maxBuffer` (bytes per stream, default `1 MB`, `Infinity`
allowed). `spawn` additionally takes `stdio: "pipe" | "inherit"` (default
`"pipe"`; `"inherit"` passes ff's stdio through and captures nothing).

### The `Child` object

For `spawn`, the returned object exposes the captured results:

| Member | Description |
|---|---|
| `child.pid` | Child process id |
| `child.stdout` / `child.stderr` | Captured bytes as a `Uint8Array` once exited (`stdio: "pipe"` only) |
| `child.exitCode` | `0–255` after a normal exit, `null` when signal-killed |
| `child.signalCode` | `"SIGTERM"`… when signal-killed, else `null` |
| `child.truncated` | `true` when `maxBuffer` overflowed — the child was sent `SIGTERM` and capturing stopped |

`spawn` results land on the object at the same moment `wait()` resolves:

```js
const child = child_process.spawn("/bin/echo", ["hi"]);
await child.wait();
console.log(new TextDecoder().decode(child.stdout)); // "hi\n"
```

## Examples

Capture output and check the exit code:

```js
const r = await child_process.exec("git status --porcelain");
if (r.code !== 0) console.error(r.stderr);
```

Run without a shell (no quoting worries):

```js
const child = child_process.spawn("tar", ["-czf", "out.tgz", "src"]);
const { code } = await child.wait();
```

Stop a long-running child:

```js
const child = child_process.spawn("sleep", ["60"]);
child.kill();                    // SIGTERM
await child.wait();              // resolves, signal === "SIGTERM"
```

Synchronous use in scripts:

```js
const { stdout } = child_process.execSync("uname -s");
console.log(stdout.trim());
```

## Caveats

- **No streams or events.** There is no `child.stdin`, no `on("data")`, and no
  `spawnSync` in this version — output is captured and delivered through
  `wait()` / the returned promise. Writing to stdin is not supported yet.
- **A running child keeps ff alive** — the process won't exit until its
  children are reaped (let them finish, or `kill()` them). `process.exit()`
  bypasses this.
- **Children are not killed when ff exits** — same as Node. Call `kill()`
  yourself for anything that must not outlive the runtime.
- `wait()` waits for the pipes to close, so a grandchild that inherits
  `stdout`/`stderr` delays resolution (Node's `close` event behaves the same).
- `exec` output is decoded as UTF-8; binary output may not round-trip.
- `process.stats().child` exposes `spawned` / `truncated` / `outHeap`
  counters for watching subprocess activity.
