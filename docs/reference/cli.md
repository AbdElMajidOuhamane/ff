---
title: CLI
description: Every ff subcommand — syntax, flags, examples, and expected output.
order: 1
---

# CLI

`ff` is a single binary. Run it with no arguments to print the built-in usage summary; `ff -h`, `ff --help`, and `ff help` print the same.

## Errors & exit codes

ff renders its own diagnostics in a fixed shape:

```text
error: <message>
hint: <what to try next>
```

- `error` is printed in red and `hint` in dim when stderr is a TTY. Color is
  auto-disabled when output is piped or redirected, or when `NO_COLOR` is set (to
  any value).
- Progress, success, and detail lines use a small glyph vocabulary: `→` for a
  step in progress, `✓` for a completed step, and `•` for secondary detail. The
  glyphs are plain UTF-8; only color is TTY-gated.
- Every command exits `0` on success and `1` on failure. This includes usage
  errors (missing arguments, unknown options), a missing or invalid `ff.json`,
  network/registry failures, integrity mismatches, and failed tests. Several
  failure paths that used to print a message but exit `0` — `ff upgrade` on a
  network error, `ff start`/`--watch start` with no `ff.json`, `ff imprint` or
  `ff sever` with a malformed manifest, TLS setup errors in `ff start` — now exit
  `1`.
- An unknown option prints `error: unknown option '--x'` and a hint to run
  `ff --help`; a missing argument prints the same `error:` plus the command's
  one-line `Usage:`.
- JavaScript exceptions are **not** part of this shape: they keep their own
  `Error: …` output from the runtime and REPL. A permission denial is one of
  these — an `Error` named `PermissionDenied` with
  `code: "PERMISSION_DENIED"` — so it does not use the `error:`/`hint:` CLI
  shape.

## Quick look

```sh
ff --version
ff init -y demo && cd demo && ff start
```

## Permissions

Native APIs are **deny-by-default**. A script can only read files, open
sockets, inspect the environment, spawn children, or load native code when the
launch command grants it with a `--allow-*` flag.

| Flag | Grants / Limits |
|------|-----------------|
| `--allow-read` | Filesystem reads, `process.chdir`, `Response.file`, `Database.open`, TLS file paths in `http.serve`, Postgres `sslrootcert` |
| `--allow-write` | Filesystem writes, SQLite database files and their parent directory |
| `--allow-net` | `fetch`, `WebSocket`, `http.serve`, TCP (`tcp.connect`), UDP, Postgres |
| `--allow-env` | `process.env`, Postgres DSN and TLS environment variables (`PG*`, `DATABASE_URL`, `PGSSL*`) |
| `--allow-run` | `child_process.spawn` / `exec` / `execSync`, `process.kill` (external PIDs; `pid === process.pid` requires no grant) |
| `--allow-ffi` | All `ffi` entry points except `ffi.allowed` |
| `--allow-all` | All of the above, including FFI |
| `--deny-read=<paths>` | Explicitly deny file paths even when covered by `--allow-read`; scope `=<paths>` is required (e.g. `--deny-read=/etc/passwd`) |
| `--deny-write=<paths>` | Explicitly deny file paths even when covered by `--allow-write`; scope `=<paths>` is required (e.g. `--deny-write=./secrets`) |
| `--deny-net=<hosts>` | Explicitly block hosts/ports even when `--allow-net` is active; scope `=<hosts>` is required (e.g. `--deny-net=169.254.169.254`) |
| `--env-file[=]<path>` | Load `.env` variables into `process.env` (max 2 MB, missing/unreadable files ignored, OS env wins, still gated by `--allow-env`) |
| `--max-heap[=]<size>` | Set max JavaScript main heap size (`64MB` default, range `8MB`–`4GB`; overrides `FF_MAX_HEAP`) |
| `--worker-heap[=]<size>` | Set per-worker JS heap size (`min(32MB, max-heap)` default, range `1MB`–`max-heap`) |
| `--max-stack[=]<size>` | Set max JS execution stack size (`1MB` default, range `128KB`–`native/2`; requires native stack >= 256 KB) |
| `--cpu-budget[=]<ms>` | Set consecutive JS execution budget in ms before interrupt (`0` disabled by default, range `0`–`3600000`; overrides `FF_CPU_BUDGET`) |

`--deny-*` exists only for `read`, `write`, and `net` (there are no `--deny-env`, `--deny-run`, or `--deny-ffi` flags, and bare `--deny-read`/`--deny-write`/`--deny-net` without `=<scope>` fail at startup). Byte sizes accept integer values with optional case-insensitive `K`/`KB`, `M`/`MB`, or `G`/`GB` suffixes (or raw bytes); runtime limit flags and `--env-file` accept both `--flag=val` and `--flag val` forms.

### Stack limit safety (`--max-stack`)

QuickJS evaluates JavaScript call stack depth against the `--max-stack` limit, but each JS frame also consumes native C stack frames on the host thread. Setting a JS stack limit equal to or near the OS native stack reservation is pathological (quickjs-ng PR #1700): deep recursion hits OS guard pages (SIGSEGV `139` / SIGBUS `138`) before QuickJS can detect exhaustion and raise a `RangeError`.

Fairyfly enforces that thread native stack >= 2 * JS stack:
- **Startup threshold**: `--max-stack` is capped at half of the detected main thread native stack (e.g. at most 8 MB on macOS with a 16 MB native stack; 4 MB on Linux with an 8 MB `rlimit`). Values above this threshold fail at startup with an explanatory hint.
- **Worker stack auto-scaling**: Worker threads automatically scale their native OS stack reservation to `max(8 MB, alignForward(2 * JS stack, pageSize))`. At an 8 MB JS limit, worker thread stacks grow to 16 MB.
- **Memory trade-off**: Thread stack pages are committed on demand by the OS kernel. Under deep recursion, with 8 worker threads all recursing to an 8 MB limit, maximum committed stack RSS is ~74 MB.

Flags are repeatable and comma-split. A bare `--allow-*` flag grants the whole category:

```sh
ff server.js --allow-net=0.0.0.0:3000 --allow-read=./public
ff job.js --allow-run=git --allow-env=HOME,PATH
ff client.js --allow-net=api.example.com:443
ff test --allow-all
```

Scope rules:

- Paths resolve against the launch cwd and stay fixed. `--allow-read=.` is the
  launch directory; symlink targets must remain inside a scope.
- Network scopes are `host`, `host:port`, or `*.domain`. `localhost` and
  `127.0.0.1` are distinct. `http.serve` checks `<hostname>:<port>` (default `0.0.0.0:<port>`).
- Environment scopes are exact, case-sensitive names.
- Run scopes are basenames (`git`) or absolute paths. `exec` / `execSync` also
  need `/bin/sh` in scope.
- `--allow-ffi` is bare only. `--allow-all` is trust-equivalent to full access;
  `run` and `ffi` can execute arbitrary code.

Permission and runtime limit flags are parsed globally before command dispatch, so invalid flags abort every command. They are accepted by every runtime entrypoint — `ff <file>`, `ff -e`, `ff start`, `ff test`, `ff repl`, standalone binaries compiled with `--standalone`, and `ff --watch` (provided the flags follow `--watch` so the supervisor forwards them to the child). `ff compile` initializes QuickJS compile-only without executing user JS (so permissions do not gate compilation), while `ff imprint`, `ff fmt`, and `ff upgrade` do not start a JS runtime.

A denied call throws before any I/O, job, promise, child, or socket is created:

```js
try {
  fs.readFile("/etc/passwd");
} catch (e) {
  e.name;    // "PermissionDenied"
  e.code;    // "PERMISSION_DENIED"
  e.message; // "fs.readFile requires --allow-read for '/etc/passwd'"
}
```

Full flag and scope reference: [Permissions](/docs/concepts/permissions).

## Run a file

```sh
ff server.js
ff app.ffbc
```

Runs the given JS file — or `.ffbc` bytecode (detected by the `.ffbc` filename extension; standalone executables compiled with `--standalone` detect their `FFSTANDA` trailer magic). The process exits when the event loop drains.

```sh
ff server.js --ca ./ca.pem
```

`--ca` trusts an extra CA bundle for that run's outbound `fetch` / `WSS`. It works with `ff <file>`, `ff -e`, and `ff --watch <file>`, and is silently ignored by `ff start` (use `FF_CA_FILE` there).

```sh
ff server.js --allow-net=0.0.0.0:3000 --allow-read=./public
```

Native APIs are denied unless the matching flag is present. A denied call throws before it reaches the OS; see [Permissions](/docs/concepts/permissions).

```sh
ff server.js --allow-ffi
```

`--allow-ffi` unlocks the `ffi` global. Native code and raw pointer/memory
helpers bypass every other permission and sandbox guarantee; without the flag
every `ffi` entry point except `ffi.allowed` denies, and `ffi.allowed` is
`false`. See [FFI](/docs/api/ffi) for the full API and security contract.

## Evaluate inline code

```sh
ff -e 'console.log("hello from fairyfly")'
# hello from fairyfly
```

Runs the string as a **classic script** — no top-level `await` (it's a
`SyntaxError`; wrap in an async IIFE when you need `await`). Accepts
`--ca` like `ff <file>`. Handy for smoke tests:

```sh
ff -e 'fetch("https://example.com/").then((r) => console.log(r.status))' --allow-net=example.com:443
ff -e '(async () => { const r = await fetch("https://example.com/"); console.log(r.status); })()' --allow-net=example.com:443
```

Permission flags apply exactly as they do for a file.

## Scaffold a project

```sh
ff init
ff init -y
ff init --yes my-app
ff init -y sub/dir
```

Prompts (Enter accepts each default), skipped entirely with `-y` / `--yes`:

| Prompt | Default |
|--------|---------|
| package name | current- or target-dir basename, sanitized |
| version | `1.0.0` |
| description | empty |
| entry point | `main.js` |
| author | empty |
| license | `ISC` |

Writes `ff.json` plus the entry file (`console.log("Hello from fairyfly!")`). Optional `[<dir>]` scaffolds inside a new directory.

> **Caution:** `ff init` **always overwrites** `ff.json` and the entry file. Back them up first if you customized them.

## Serve a project

```sh
ff start
ff start --cert cert.pem --key key.pem
ff start --allow-net=0.0.0.0:3000 --allow-read=./public
FF_CERT=cert.pem FF_KEY=key.pem ff start
```

Reads `main` from `ff.json` and runs it as a module (max 10MB). Missing or invalid manifest prints an error and exits.

Permission and limit flags are parsed before command dispatch so they work anywhere in argv, while `--cert` and `--key` must follow `start` (e.g. `ff start --cert ... --key ...`).

When the entry starts an HTTP server, ff prints the step and the bound URL:

```text
→ starting main.js
✓ server listening on http://localhost:3000
  • websocket support enabled
```

With TLS (`--cert`/`--key` or `http.serve({ tls })`) the URL uses `https://`.

| Flag / env | Description |
|------------|-------------|
| `--cert <path>` | PEM certificate (max 512KB) |
| `--key <path>` | PEM private key (max 256KB) |
| `FF_CERT` / `FF_KEY` | Fallback when flags are absent; flags win |

Both must be given together. On success the port serves HTTPS/WSS/HTTP/2 **only** (replacing plain HTTP/WS on that listener), and the cert path is trusted by the runtime's own outbound `fetch` / `WebSocket` — convenient for self-signed dev setups. *(Known issue: calling `http.serve({ port }, handler)` without an `opts.tls` object currently disables CLI `--cert`/`--key`; pass `tls: { cert, key }` in `http.serve` instead.)*

The CLI reads `--cert` / `--key` before the runtime starts, so those two files do not need `--allow-read`. File paths passed to `http.serve({ tls: { cert, key } })` are runtime reads and do.

The port comes only from `http.serve({ port })` (default `3000`). There is no `--port` and no `FF_PORT`.

## Install packages

```sh
ff imprint marked@18.0.11
ff imprint marked
ff imprint github:owner/repo#v1.2.3
ff imprint codeberg:owner/repo
ff imprint https://example.com/pkg.tar.gz
ff imprint
```

| Form | Effect |
|------|--------|
| `ff imprint pkg@ver ...` | Pin pure-JS ESM packages into `ff.json` + `ff.lock` (reported as v2 by CLI, `"lockfileVersion": 1` in JSON, with integrity hashes), materialize `node_modules/` |
| `ff imprint pkg ...` | Same, resolving latest from the registry |
| `ff imprint github:owner/repo[#ref] ...` | Resolve a GitHub archive; name/version come from its root `package.json` |
| `ff imprint codeberg:owner/repo[#ref] ...` | Same for Codeberg |
| `ff imprint https://…/pkg.tar.gz` | Install an explicit `.tar.gz` / `.tgz` URL |
| `ff imprint` (no args, lock present) | Exact rebuild from the lock (CI-like) |
| `ff imprint` (no args, no lock) | Resolve from `ff.json` (npm and direct sources), write the lock |

Only ESM-compatible packages pass the pure-ESM gate.

`ff imprint` is an install command: its registry and archive downloads are not
runtime `fetch` calls and do not require `--allow-net`.

Direct sources also accept `[git+]https://github.com/owner/repo[.git][#ref]` and
`[git+]https://codeberg.org/owner/repo[.git][#ref]`; omit `#ref` to use `HEAD`. The archive
root must contain `package.json`. Private repositories, authentication,
monorepo subdirectories, and build scripts are not supported. The lock pins the
archive URL and a computed SHA-512 integrity hash; a moved branch fails the
integrity check instead of installing different code.

## Remove packages

```sh
ff sever marked
ff sever marked@18.0.11
ff sever
ff sever --force
```

| Form | Effect |
|------|--------|
| `ff sever pkg ...` | Remove those deps from `ff.json`, prune now-unreachable packages from `node_modules` |
| `ff sever` (no names) | Confirm, then wipe `node_modules`, empty `dependencies`, clear the lock |
| `--force` | Skip the confirmation (for the no-names wipe) |

Names are scope-aware: `ff sever @scope/pkg@1.0` strips to `@scope/pkg`.

## Run the test suite

```sh
ff test
ff test url
ff test formdata
ff test --allow-all
```

Runs every matching `test/*.test.js` in a single process. The optional filter is a substring match on the filename (flags must follow `test`, using `=` for value flags such as `ff test --max-heap=128MB` so values are not mistaken for the filter). A file fails when module evaluation or async microtasks/loop throw an uncaught error (`ff test` does **not** scan stdout/stderr for `FAIL` lines); exits `1` if any file fails. Files larger than 10MB are skipped with `FAIL test/<name>`. Note that calling `process.exit()` (such as `done()` from `test/lib.mjs`) terminates `ff test` immediately before later files or the summary — run the repo's `done()` suites via `./test/run.sh` (one process per file) or directly with `ff test/<name>.test.js`.

The runner executes the files in-process, so the permission flags apply to the code under test. With no flags, any test that touches a native API fails with `PermissionDenied`. The repository's `test/run.sh` passes `--allow-all` because the suite exercises every gated API; a project suite should use only the flags its tests need. Pass `--allow-ffi` to run the FFI contract (`test/ffi.test.js`); without it the FFI tests skip.

## Interactive REPL

```sh
ff repl
ff repl --allow-all
```

```text
ff> 1 + 1
2
ff> .exit
```

| Input | Effect |
|-------|--------|
| JS expression | Evaluated; non-`undefined` results print, exceptions print as `Error: …` |
| `.exit` / `.quit` | Quit |
| `.clear` | Clear the screen |

Line buffer is 8192 bytes. Async work runs after each line via microtasks + event loop. Permission flags apply to every expression evaluated in the session.

## Compile to bytecode or standalone

```sh
ff compile app.js
ff compile app.js -o app.ffbc
ff compile app.js --output dist/app.ffbc
ff compile app.js --standalone
ff compile app.js --standalone -o app
```

Compiles an ES module to QuickJS bytecode with **source and debug info stripped**. Input cap: 20MB.

- Without `--standalone`: writes `.ffbc` bytecode (default replaces the extension with `.ffbc`; prints `✓ Compiled <in> → <out> (<N> bytes)`).
- With `--standalone`: copies the `ff` executable, appends bytecode plus a 24-byte `FFSTANDA` + Wyhash integrity trailer, sets `chmod 0755`, and strips the input extension by default (`app.js` → `app`; prints `✓ Compiled standalone binary <in> → <out> (<N> bytes)`). Standalone compilation currently supports single-file scripts only (files containing `"import "` or `"import("` are rejected).

```sh
ff compile app.js
# ✓ Compiled app.js → app.ffbc (12345 bytes)
ff app.ffbc
```

Compiling initializes QuickJS in compile-only mode without executing user code, so permission flags have no effect during compilation. They apply when running `.ffbc` bytecode or the `--standalone` executable (which remains deny-by-default and accepts `--allow-*`, `--deny-*`, `--env-file`, and runtime limit flags).

## Format code

```sh
ff fmt --write "src/**/*.js"
ff fmt -w app.js
ff fmt --check app.js
ff fmt app.js                  # same as --check (default)
```

Delegates to `npx --yes prettier` (requires Node.js and network access or a cached/global `prettier`). Defaults to `--check` when neither `-w`/`--write` nor `--check` is passed. Without files it prints usage; exit code is non-zero when prettier fails or check finds unformatted files. This is a CLI operation and is not gated by `--allow-net` or `--allow-run`.

## Self-update

```sh
ff upgrade
ff upgrade --check
```

Queries GitHub Releases for `AbdElMajidOuhamane/ff` (needs `curl`), compares semver against `ff --version`:

| Situation | Effect |
|-----------|--------|
| No releases published or network failure | Prints `error: <reason>` (with a hint where useful), exits `1` |
| Already latest | Prints up-to-date, exits |
| `--check` | Prints the newer version, exits without downloading |
| Update available | Downloads `ff-<os>-<arch>`, fetches `sha256sums.txt`, verifies the SHA-256 checksum (refusing install on mismatch or missing hash), `chmod 755`, replaces the running binary (default `~/.local/bin/ff` unless argv0 is absolute) |

> **Note:** Releases are published at [github.com/AbdElMajidOuhamane/ff/releases](https://github.com/AbdElMajidOuhamane/ff/releases) — `v0.2.0-beta` is the first. With a release available, `ff upgrade` reports up-to-date for current builds, downloads when you're behind, and only takes the failure row on network errors or a missing release asset.

## Watch mode: ff --watch

```sh
ff --watch server.js --allow-net=0.0.0.0:3000
ff --watch start --allow-all
ff --watch app.js --ca custom-ca.pem --allow-net
```

Runs as a lightweight supervisor process that watches `dirname(target)` (or `.` when `target` has no directory, or `.` in `start` mode) and automatically restarts the child whenever files change (POSIX-only):

- **Target**: Accepts either a JavaScript entry file (`ff --watch <file>`) or `start` (`ff --watch start` to run `main` from `ff.json`).
- **Flags**: Forwards custom CA (`--ca <path>`), all permission flags (`--allow-*` and `--deny-*`), and any trailing arguments placed after `<target>` (such as `--max-heap`, `--env-file`, `--cert`/`--key`, or script arguments) directly to the child. Flags placed *before* `--watch` are not forwarded.
- **Polling & Debounce**: Recursively monitors file modification times (`mtime`) and file sizes with a 200 ms polling interval and 100 ms debounce window.
- **Ignored paths**: Automatically ignores `.git`, `node_modules`, `zig-out`, `.zig-cache`, and `zig-cache`.
- **Clean restart**: Reaps the previous child process by sending `SIGTERM`, waits up to 500 ms grace period, escalates to `SIGKILL` if the child hangs, then spawns a fresh runtime.
- **Signal forwarding**: `SIGINT` and `SIGTERM` on the supervisor cleanly terminate the child. Sets `FF_WATCH_PARENT` so the child automatically exits if the parent supervisor terminates.

## Print the version

```sh
ff --version
# ff 0.4.0 (macos-aarch64)
```

## Runtime & proxy environment

Runtime limit environment variables are read once at process start (CLI flags override env):

- `FF_MAX_HEAP`: JS main heap size (`8MB`–`4GB`, default `64MB`; overridden by `--max-heap`)
- `FF_CPU_BUDGET`: consecutive JS CPU budget in ms (`0`–`3600000`, default `0`; overridden by `--cpu-budget`)

Outbound `fetch` / `WebSocket` requests in every command honor the standard
proxy environment variables. They are read once at process start:

| Variable | Applies to |
|----------|------------|
| `HTTP_PROXY` / `http_proxy` | `http://` and `ws://` requests |
| `HTTPS_PROXY` / `https_proxy` | `https://` and `wss://` requests |
| `ALL_PROXY` / `all_proxy` | both, when the protocol-specific variable is unset |
| `NO_PROXY` / `no_proxy` | comma-separated bypass list (`*` bypasses all; `host`, `.host`, `host:port` accepted) |

Proxy URLs may carry credentials (`http://user:pass@proxy:8080`). SOCKS is
not supported. See [fetch Proxies](/docs/api/fetch#proxies) for matching
details and examples.

## Summary

| Command | Purpose |
|---------|---------|
| `ff <file.js\|.ffbc> [--allow-*] [--deny-*]` | Run a file (`--ca`, `--env-file`, limit and permission flags optional) |
| `ff -e <code> [--allow-*] [--deny-*]` | Run inline JS as a classic script (`--ca`, `--env-file`, limit and permission flags optional) |
| `ff init [-y\|--yes] [<dir>]` | Scaffold `ff.json` + entry file |
| `ff start [--cert --key] [--allow-*] [--deny-*]` | Run `main` from `ff.json` |
| `ff --watch <file\|start> [--ca <path>] [--allow-*] [--deny-*]` | File watcher supervisor (200ms poll, auto-restart, POSIX-only) |
| `ff imprint [pkg\|source …]` | Install pure-JS ESM deps from npm, GitHub, Codeberg, or a tarball |
| `ff sever [pkg …] [--force]` | Remove deps / wipe install |
| `ff test [filter] [--allow-*] [--deny-*]` | Run `test/*.test.js` in one process (use `test/run.sh` for process-per-file `done()` suites) |
| `ff repl [--allow-*] [--deny-*]` | Interactive REPL |
| `ff compile <f.js> [--standalone] [-o\|--output <out>]` | Bytecode (`.ffbc`, source stripped) or self-executable binary (`--standalone`) |
| `ff fmt [-w\|--write\|--check] <files …>` | Prettier via npx (`--check` default, requires Node.js) |
| `ff upgrade [--check]` | Self-update from GitHub Releases |
| `ff --version` | Print version |
| `ff -h\|--help\|help` | Print usage |
