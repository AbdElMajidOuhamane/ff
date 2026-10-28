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

| Flag | Grants |
|------|--------|
| `--allow-read` | Filesystem reads, `process.chdir`, TLS file paths in `http.serve` |
| `--allow-write` | Filesystem writes, SQLite database files and their parent directory |
| `--allow-net` | `fetch`, `WebSocket`, `http.serve`, UDP, Postgres |
| `--allow-env` | `process.env`, Postgres DSN environment variables |
| `--allow-run` | `child_process.spawn` / `exec` / `execSync` |
| `--allow-ffi` | `ffi.dlopen` / `ffi.callback` |
| `--allow-all` | All of the above, including FFI |

Flags are repeatable and comma-split. A bare flag grants the whole category:

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
  `127.0.0.1` are distinct. `http.serve` always checks `0.0.0.0:<port>`.
- Environment scopes are exact, case-sensitive names.
- Run scopes are basenames (`git`) or absolute paths. `exec` / `execSync` also
  need `/bin/sh` in scope.
- `--allow-ffi` is bare only. `--allow-all` is trust-equivalent to full access;
  `run` and `ffi` can execute arbitrary code.

The flags are accepted by every command that starts the runtime — `ff <file>`,
`ff -e`, `ff start`, `ff test`, `ff repl`, and `ff --watch` (which forwards them
to the restarted child). They are scanned from the full argv, so
`ff start --allow-net=0.0.0.0:3000` works. CLI-only commands (`ff imprint`,
`ff fmt`, `ff upgrade`, `ff compile`) do not start a runtime and are not gated.

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

Runs the given JS file — or `.ffbc` bytecode (the loader detects the magic). The process exits when the event loop drains.

```sh
ff server.js --ca ./ca.pem
```

`--ca` trusts an extra CA bundle for that run's outbound `fetch` / `WSS`. It is accepted **only** by `ff <file>` and `ff -e` — not by `ff start` (use `FF_CA_FILE` there).

```sh
ff server.js --allow-net=0.0.0.0:3000 --allow-read=./public
```

Native APIs are denied unless the matching flag is present. A denied call throws before it reaches the OS; see [Permissions](/docs/concepts/permissions).

```sh
ff server.js --allow-ffi
```

`--allow-ffi` unlocks the `ffi` global (`ffi.dlopen`). Native code bypasses every permission and sandbox guarantee, so without the flag `ffi.dlopen` throws and `ffi.allowed` is `false`. See [FFI](/docs/api/ffi) for the full API and security contract.

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

Permission flags are accepted after `start`, alongside the TLS flags. They are scanned from the full argv, so position does not matter.

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

Both must be given together. On success the same port serves HTTPS/WSS too, and the cert path is trusted by the runtime's own outbound `fetch` / `WebSocket` — convenient for self-signed dev setups.

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
| `ff imprint pkg@ver ...` | Pin pure-JS ESM packages into `ff.json` + `ff.lock` (v2 lock with integrity hashes), materialize `node_modules/` |
| `ff imprint pkg ...` | Same, resolving latest from the registry |
| `ff imprint github:owner/repo[#ref] ...` | Resolve a GitHub archive; name/version come from its root `package.json` |
| `ff imprint codeberg:owner/repo[#ref] ...` | Same for Codeberg |
| `ff imprint https://…/pkg.tar.gz` | Install an explicit `.tar.gz` / `.tgz` URL |
| `ff imprint` (no args, v2 lock present) | Exact rebuild from the lock (CI-like) |
| `ff imprint` (no args, no lock) | Resolve from `ff.json` (npm and direct sources), write the lock |

Only ESM-compatible packages pass the pure-ESM gate.

`ff imprint` is an install command: its registry and archive downloads are not
runtime `fetch` calls and do not require `--allow-net`.

Direct sources also accept `https://github.com/owner/repo[#ref]` and
`https://codeberg.org/owner/repo[#ref]`; omit `#ref` to use `HEAD`. The archive
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

Runs every `test/*.test.js` through the runtime (same convention as `test/run.sh` — see the Testing guide). The optional filter is a substring match on the filename. Each file evaluates to success with no `FAIL` lines; exits `1` if any test fails. Files larger than 10MB are not loaded.

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

## Compile to bytecode

```sh
ff compile app.js
ff compile app.js -o app.ffbc
ff compile app.js --output dist/app.ffbc
```

Compiles an ES module to QuickJS bytecode with **source and debug info stripped**. Default output replaces the extension with `.ffbc`. Input cap: 20MB.

```sh
ff compile app.js
# ✓ Compiled app.js → app.ffbc (12345 bytes)
ff app.ffbc
```

Compiling does not execute the module, so permission flags have no effect here. They apply when the bytecode is run.

## Format code

```sh
ff fmt --write "src/**/*.js"
ff fmt -w app.js
ff fmt --check app.js
```

Delegates to `npx --yes prettier` (needs network, or a global prettier). Without files it prints usage; exit code is non-zero when prettier fails. This is a CLI operation and is not gated by `--allow-net` or `--allow-run`.

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
| Update available | Downloads `ff-<os>-<arch>`, `chmod 755`, replaces the running binary (default `~/.local/bin/ff` unless argv0 is absolute) |

> **Note:** Releases are published at [github.com/AbdElMajidOuhamane/ff/releases](https://github.com/AbdElMajidOuhamane/ff/releases) — `v0.2.0-beta` is the first. With a release available, `ff upgrade` reports up-to-date for current builds, downloads when you're behind, and only takes the failure row on network errors or a missing release asset.

## Print the version

```sh
ff --version
# ff 0.2.0-beta (macos-aarch64)
```

## Proxy environment

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
| `ff <file.js\|.ffbc> [--allow-*]` | Run a file (`--ca`, permission flags optional) |
| `ff -e <code> [--allow-*]` | Run inline JS as a classic script (`--ca`, permission flags optional) |
| `ff init [-y] [<dir>]` | Scaffold `ff.json` + entry file |
| `ff start [--cert --key] [--allow-*]` | Run `main` from `ff.json` |
| `ff imprint [pkg\|source …]` | Install pure-JS ESM deps from npm, GitHub, Codeberg, or a tarball |
| `ff sever [pkg …] [--force]` | Remove deps / wipe install |
| `ff test [filter] [--allow-*]` | Run `test/*.test.js` (repository suite uses `--allow-all`) |
| `ff repl [--allow-*]` | Interactive REPL |
| `ff compile <f.js> [-o out.ffbc]` | Bytecode, source stripped |
| `ff fmt [--write\|--check] <files …>` | Prettier via npx |
| `ff upgrade [--check]` | Self-update from GitHub Releases |
| `ff --version` | Print version |
| `ff -h\|--help\|help` | Print usage |
