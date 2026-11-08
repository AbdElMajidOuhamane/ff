---
title: child_process
description: Subprocesses — spawn, exec, and execSync with captured output, exit codes, and signals.
order: 14
---

# child_process

`child_process` runs OS subprocesses. POSIX only (macOS and Linux), max **8
concurrent children**. Everything is evented on the main loop — no extra
threads — and it is safe to use alongside `http.serve`, `fetch`, or `Worker`.

## Permissions

Starting any child needs `--allow-run` for the executable:

```sh
ff script.js --allow-run=git
```

Scopes come in two forms:

| Scope | Matches |
|---|---|
| `--allow-run=git` (bare name) | Any invocation whose **basename** is `git` — `git`, `/usr/bin/git`, `/tmp/x/git` |
| `--allow-run=/usr/bin/git` (contains `/`) | Only that canonical path, or paths beneath it when it names a directory |
| `--allow-run=/bin` | Any executable under `/bin` |

```sh
ff tool.js --allow-run=git,node
ff tool.js --allow-run=/usr/bin/git,/opt/tools
```

- Matching is exact and case-sensitive. There are no globs.
- A bare-name scope ignores the path entirely: `--allow-run=git` also permits
  `/tmp/evil/git`. If you need path confinement, use an absolute scope **and**
  invoke the program by path.
- An absolute scope only matches an explicit path. `spawn("git", ...)` never
  matches `--allow-run=/usr/bin/git`; use `spawn("/usr/bin/git", ...)` (or a
  bare-name scope).
- Absolute scopes are canonicalized at launch; symlinks are resolved, and the
  program is canonicalized again when spawned. A symlink that resolves outside
  the scope is denied.
- `--allow-run` does **not** need `--allow-read` for the executable. The OS
  loader opens it; the run grant is what controls the launch.

Denial is synchronous and uses the standard shape:

```js
try {
  child_process.spawn("git", ["status"]);
} catch (e) {
  console.error(e.name, e.code); // PermissionDenied PERMISSION_DENIED
  console.error(e.message);      // child_process requires --allow-run for 'git'
}
```

`execSync` reports its own API name:

```text
child_process.execSync requires --allow-run for '/bin/sh'
```

### `exec` always needs `/bin/sh`

`exec` and `execSync` run `/bin/sh -c "<your command>"`. The only program
checked is the shell, so **every** `exec` call needs a run scope for
`/bin/sh` (or the bare name `sh`):

```sh
ff tool.js --allow-run=/bin/sh
```

Permitting `/bin/sh` permits **any command string** — the shell interprets
whatever you pass, including redirections and pipelines. If you want to
restrict which programs run, use `spawn` with an explicit executable and
arguments instead of `exec`.

> **Security caveat:** a child is a separate OS process. It is **not** bound by
> the parent's `--allow-read` / `--allow-write` / `--allow-net` scopes and can
> access anything the OS user can. Its `cwd` and `env` options are likewise not
> permission-gated. `run` and `ffi` are trust-equivalent to full access; use
> them only for code and programs you would trust with the whole process.

Full model: [Permissions](/docs/concepts/permissions).

## Quick look

```js
const r = await child_process.exec("git rev-parse HEAD");
console.log(r.stdout.trim(), r.code);

const child = child_process.spawn("ffmpeg", ["-i", "in.mp4", "out.mp4"]);
const { code, signal } = await child.wait();
```

```sh
ff quick.js --allow-run=/bin/sh,ffmpeg
```

`exec` needs the shell grant; `spawn` needs the program's name or path.

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

`cwd` and `env` affect only the child. They do not widen or narrow ff's
permission scopes.

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

```sh
ff echo.js --allow-run=/bin/echo
```

or, with a bare-name scope, `--allow-run=echo`.

## Examples

Capture output and check the exit code:

```js
const r = await child_process.exec("git status --porcelain");
if (r.code !== 0) console.error(r.stderr);
```

```sh
ff status.js --allow-run=/bin/sh
```

Run without a shell (no quoting worries):

```js
const child = child_process.spawn("tar", ["-czf", "out.tgz", "src"]);
const { code } = await child.wait();
```

```sh
ff pack.js --allow-run=tar
```

Stop a long-running child:

```js
const child = child_process.spawn("sleep", ["60"]);
child.kill();                    // SIGTERM
await child.wait();              // resolves, signal === "SIGTERM"
```

```sh
ff stop.js --allow-run=sleep
```

Synchronous use in scripts:

```js
const { stdout } = child_process.execSync("uname -s");
console.log(stdout.trim());
```

```sh
ff uname.js --allow-run=/bin/sh
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
- **Child permissions are the OS user's.** `--allow-run` is a launch gate, not
  a sandbox. Once started, the child can open any file, socket, or environment
  the OS allows, regardless of the parent's scopes.

## See also

- [Permissions](/docs/concepts/permissions) — flags, scopes, denial contract
- [Process](/docs/api/process) — argv, env, cwd, exit
- [API overview](/docs/api/overview) — every injected global
- [Limitations](/docs/reference/limitations) — every hard cap
