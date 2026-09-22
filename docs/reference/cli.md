---
title: CLI
description: Every ff subcommand — syntax, flags, examples, and expected output.
order: 1
---

# CLI

`ff` is a single binary. Run it with no arguments to print the built-in usage summary.

## Quick look

```sh
ff --version
ff init -y demo && cd demo && ff start
```

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

## Evaluate inline code

```sh
ff -e 'console.log("hello from fairyfly")'
# hello from fairyfly
```

Runs the string as a script. Accepts `--ca` like `ff <file>`. Handy for smoke tests:

```sh
ff -e 'const r = await fetch("https://example.com/"); console.log(r.status)'
```

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
FF_CERT=cert.pem FF_KEY=key.pem ff start
```

Reads `main` from `ff.json` and runs it as a module (max 10MB). Missing or invalid manifest prints an error and exits.

| Flag / env | Description |
|------------|-------------|
| `--cert <path>` | PEM certificate (max 512KB) |
| `--key <path>` | PEM private key (max 256KB) |
| `FF_CERT` / `FF_KEY` | Fallback when flags are absent; flags win |

Both must be given together. On success the same port serves HTTPS/WSS too, and the cert path is trusted by the runtime's own outbound `fetch` / `WebSocket` — convenient for self-signed dev setups.

The port comes only from `http.serve({ port })` (default `3000`). There is no `--port` and no `FF_PORT`.

## Install packages

```sh
ff imprint marked@18.0.11
ff imprint marked
ff imprint
```

| Form | Effect |
|------|--------|
| `ff imprint pkg@ver ...` | Pin pure-JS ESM packages into `ff.json` + `ff.lock` (v2 lock with integrity hashes), materialize `node_modules/` |
| `ff imprint pkg ...` | Same, resolving latest from the registry |
| `ff imprint` (no args, v2 lock present) | Exact rebuild from the lock (CI-like) |
| `ff imprint` (no args, no lock) | Resolve from `ff.json`, write the lock |

Only ESM-compatible packages pass the pure-ESM gate.

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
```

Runs every `test/*.test.js` through the runtime (same convention as `test/run.sh` — see the Testing guide). The optional filter is a substring match on the filename. Each file evaluates to success with no `FAIL` lines; exits `1` if any test fails. Files larger than 10MB are not loaded.

## Interactive REPL

```sh
ff repl
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

Line buffer is 8192 bytes. Async work runs after each line via microtasks + event loop.

## Compile to bytecode

```sh
ff compile app.js
ff compile app.js -o app.ffbc
ff compile app.js --output dist/app.ffbc
```

Compiles an ES module to QuickJS bytecode with **source and debug info stripped**. Default output replaces the extension with `.ffbc`. Input cap: 20MB.

```sh
ff compile app.js
# Compiled app.js -> app.ffbc (12345 bytes)
ff app.ffbc
```

## Format code

```sh
ff fmt --write "src/**/*.js"
ff fmt -w app.js
ff fmt --check app.js
```

Delegates to `npx --yes prettier` (needs network, or a global prettier). Without files it prints usage; exit code is non-zero when prettier fails.

## Benchmarks

```sh
ff bench
```

Runs built-in microbenchmarks from the **current working directory** — it expects these paths relative to cwd:

```text
bench/fib.js  bench/sort.js  bench/string.js  bench/object.js
bench/json.js bench/loop.js  bench/closure.js bench/array.js
```

Missing files print `read error` and are skipped. Prints per-file elapsed ms plus a total.

## Self-update

```sh
ff upgrade
ff upgrade --check
```

Queries GitHub Releases for `AbdElMajidOuhamane/ff` (needs `curl`), compares semver against `ff --version`:

| Situation | Effect |
|-----------|--------|
| Already latest | Prints up-to-date, exits |
| `--check` | Prints the newer version, exits without downloading |
| Update available | Downloads `ff-<os>-<arch>`, `chmod 755`, replaces the running binary (default `~/.local/bin/ff` unless argv0 is absolute) |

## Print the version

```sh
ff --version
# ff 0.1.0 (macos-aarch64)
```

## Summary

| Command | Purpose |
|---------|---------|
| `ff <file.js\|.ffbc>` | Run a file (`--ca` optional) |
| `ff -e <code>` | Run inline JS (`--ca` optional) |
| `ff init [-y] [<dir>]` | Scaffold `ff.json` + entry file |
| `ff start [--cert --key]` | Run `main` from `ff.json` |
| `ff imprint [pkg[@ver] …]` | Install pure-JS ESM deps |
| `ff sever [pkg …] [--force]` | Remove deps / wipe install |
| `ff test [filter]` | Run `test/*.test.js` |
| `ff repl` | Interactive REPL |
| `ff compile <f.js> [-o out.ffbc]` | Bytecode, source stripped |
| `ff fmt [--write\|--check] <files …>` | Prettier via npx |
| `ff bench` | Run `bench/*.js` microbenchmarks |
| `ff upgrade [--check]` | Self-update from GitHub Releases |
| `ff --version` | Print version |
