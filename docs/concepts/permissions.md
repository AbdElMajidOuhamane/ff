---
title: Permissions
description: Deny-by-default native API access — flags, scopes, enforcement points, and the error contract.
order: 5
---

# Permissions

Fairyfly is **deny-by-default** for native capabilities. A script cannot read
files, open sockets, inspect the environment, spawn processes, or load native
libraries unless the launch command grants it.

There is no `ff.json` section, no environment variable, and no runtime toggle.
The only input is `--allow-*` on the command line.

## Quick look

```sh
ff server.js --allow-net=0.0.0.0:3000 --allow-read=./public
ff -e 'console.log(fs.readFile("config.json"))' --allow-read=.
ff test --allow-all
```

Every command that starts a JS runtime accepts the flags: `ff <file>`,
`ff -e`, `ff start`, `ff test`, `ff repl`, and `ff --watch`.

## Flags

| Flag | Grants | Scope |
|---|---|---|
| `--allow-read` | `fs` reads, `process.chdir`, TLS file paths in `http.serve` | paths |
| `--allow-write` | `fs` writes, SQLite database files and their parent directory | paths |
| `--allow-net` | `fetch`, `WebSocket`, `http.serve`, UDP, Postgres | `host`, `host:port`, `*.domain` |
| `--allow-env` | `process.env`, Postgres DSN variables for the global `sql` | exact names |
| `--allow-run` | `child_process.spawn` / `exec` / `execSync` | basenames or absolute paths |
| `--allow-ffi` | `ffi.dlopen` / `ffi.callback` | none — bare only |
| `--allow-all` | every category above, **including FFI** | none |

Rules:

- Flags are repeatable and comma-split: `--allow-read=src,test`.
- A bare flag grants the whole category: `--allow-net` means any host, any port.
- An empty scope is invalid: `--allow-read=` fails at startup.
- There are no `--deny-*` flags. Unknown permission flags fail startup.
- Scopes are parsed once, before the JS runtime exists, and are immutable for
  the process lifetime.
- Flags are scanned across the whole argv. A script argument that begins with
  `--allow-` is interpreted as a permission flag, not passed to the script.

## Path scopes

```sh
--allow-read=.                  # launch directory and everything below
--allow-read=./public,./views   # two roots
--allow-read=/etc/hosts         # one file
--allow-write=/tmp/build
```

- Relative scopes resolve against the **launch** cwd, then stay fixed.
- Matching is component-exact: `--allow-read=/srv/app` covers
  `/srv/app/data.json`, not `/srv/app2/data.json`.
- Symlinks are resolved before matching. The resolved target must be inside a
  scope. A symlink inside an allowed directory that points outside is denied.
- Writes through a dangling symlink are denied.
- `..` traversal, NUL bytes, and paths at or beyond 4096 bytes are denied.
- `process.chdir()` does **not** move the scope roots. After a `chdir`, a
  relative API path resolves against the new cwd and must still land inside a
  scope captured at startup.
- Bare `--allow-read` / `--allow-write` grant every path.

## Network scopes

```sh
--allow-net=api.example.com        # any port
--allow-net=api.example.com:443
--allow-net=*.internal:8080        # subdomains only
--allow-net=127.0.0.1:5432
--allow-net=[::1]:3000
--allow-net                        # every host and port
```

- Hostnames are matched case-insensitively and exactly. There is no DNS
  resolution: `localhost` and `127.0.0.1` are different scopes.
- `*.example.com` matches one or more subdomain labels, but **not** the apex
  `example.com`.
- `*` matches every host and every port. A port suffix on `*` does not narrow
  it; use `*.example.com` for a scoped wildcard.
- When the port is omitted, any port is allowed. `fetch` and `WebSocket`
  default to 80/443 when the URL has no explicit port.
- `http.serve()` always binds `0.0.0.0`, so its scope must be
  `--allow-net=0.0.0.0:<port>` — not `127.0.0.1:<port>`.
- IPv6 literals use brackets: `[::1]:3000`.

## Environment scopes

```sh
--allow-env=HOME,PATH
--allow-env=PG_TEST_DSN,DATABASE_URL,PGHOST,PGPORT,PGUSER,PGPASSWORD,PGDATABASE
--allow-env                       # every variable
```

- Names are exact and case-sensitive. There is no wildcard.
- `process.env` is built once at startup with disallowed keys omitted. Reading
  a disallowed name returns `undefined`; it does not throw.
- The runtime still reads its own `FF_*` configuration (`FF_ECHO`, `FF_CERT`,
  `FF_KEY`, `FF_CA_FILE`). That is CLI/runtime configuration, not application
  access to `process.env`.

## Run scopes

```sh
--allow-run=git
--allow-run=/usr/bin/git
--allow-run=/bin/sh
--allow-run                       # every program
```

- A bare name matches the **basename** of `argv[0]`. `--allow-run=git` also
  permits `./git` and `/tmp/git`; use an absolute scope when that matters.
- An absolute scope matches that path or a directory subtree.
- `exec` and `execSync` always run `/bin/sh -c`. They need `/bin/sh` in scope,
  and granting `/bin/sh` permits any command string. `spawn` checks only
  `argv[0]`, so spawning a shell has the same effect.
- `run` is trust-equivalent to full process access. Treat it like `--allow-all`.

## FFI

```sh
--allow-ffi
```

- Bare only: `--allow-ffi=.` is invalid.
- `--allow-all` includes FFI.
- `ffi.allowed` reports the current state.
- Native code runs with the full privileges of the `ff` process. FFI bypasses
  every other permission, so `--allow-ffi` is trust-equivalent to full access.

## Where checks happen

| API | Flag | Checked |
|---|---|---|
| `fs.readFile` / `exists` / `readdir` | `read` | before the syscall or fs job |
| `fs.writeFile` / `mkdir` / `rm` | `write` | before the syscall or fs job |
| `process.env` | `env` | when the global is built |
| `process.chdir` | `read` on the target | before `chdir` |
| `fetch` | `net` on `host:port` | before the request is submitted, and on every redirect hop |
| `new WebSocket` | `net` on `host:port` | before the socket is created |
| `http.serve` | `net` on `0.0.0.0:port` | before the listener starts |
| `http.serve({ tls })` | `read` for file paths | before the TLS files are loaded |
| `udp.bind` / `connect` / `sendto` | `net` on the address | before the syscall |
| `Database.open` | `read` + `write` on the file, `write` on the parent | before `sqlite3_open` |
| `new SQL(dsn)` | `net` on the DSN host and port | before the pool is created |
| global `sql` | `net`, plus `env` for `PG_*` / `DATABASE_URL` | before the first query |
| `child_process.spawn` / `exec` / `execSync` | `run` on `argv[0]` | before the child is created |
| `ffi.dlopen` / `ffi.callback` | `ffi` | before `dlopen` / callback creation |

`Database.open(":memory:")` is exempt from all path checks. Inline PEM passed to
`http.serve({ tls: { cert, key } })` is exempt from `read`; a path is not.

## Errors

Most gates throw an `Error` with a stable name and code:

```js
try {
  fs.readFile("/etc/passwd");
} catch (e) {
  console.log(e.name);    // "PermissionDenied"
  console.log(e.code);    // "PERMISSION_DENIED"
  console.log(e.message); // "fs.readFile requires --allow-read for '/etc/passwd'"
}
```

The message shape is:

```text
<api> requires --allow-<kind> for '<detail>'
```

Details:

- `e instanceof Error` is true, but there is no global `PermissionDenied`
  constructor. Check `e.code` or `e.name`; `instanceof PermissionDenied`
  will not work.
- Denials are thrown **before** I/O, jobs, promises, children, or sockets are
  created. The `*Async` fs variants throw synchronously, before returning a
  promise. Inside an `async` function that becomes a rejected promise.
- Initial `fetch` denial throws synchronously. A denial on a **redirect hop**
  rejects the fetch promise with a plain string:
  `PermissionDenied: fetch requires --allow-net`. That string has no `.code`.
- FFI is the one exception to the error shape: `ffi.dlopen` and `ffi.callback`
  throw a `TypeError` whose message ends in `requires --allow-ffi`, and
  `ffi.allowed` is `false`. There is no `code` property.

## Lifetime and inheritance

- The policy is parsed before any runtime object exists and never changes.
- `globalThis.permissions` exposes booleans for the six categories:
  `read`, `write`, `net`, `env`, `run`, `ffi`. A category is `true` when it has
  any grant, bare or scoped.
- The object reports enabled categories only; it does not expose the scopes.
  Reassigning its properties does not change enforcement.
- Workers inherit the same policy. There is no per-worker grant or drop.
- `ff --watch` forwards permission flags to the child it restarts.
- `ff start` accepts the flags after `start`; `--cert` / `--key` are CLI
  configuration reads and are not gated by `--allow-read`.

## Program-loading carve-out

Loading code is not a `read` operation:

- `import` / `export` resolution and module file reads.
- `ff start` reading `ff.json` and its `main` file.
- `ff test` loading `test/*.test.js`.
- `new Worker("./worker.js")` loading the worker file.

These work without `--allow-read`. Permissions gate what the loaded code does
at runtime, not whether it can be loaded. A worker that calls `fs.readFile`
still needs its own `--allow-read` grant (inherited from the parent).

`ff imprint`, `ff fmt`, `ff upgrade`, and `ff compile` are CLI operations, not
runtime APIs. They are not gated by these flags.

## Security model

Permissions are an **in-process policy layer, not an OS sandbox**.

- A path is canonicalized and then passed to a normal filesystem syscall. A
  symlink swapped between the check and the syscall can escape the scope.
- `run` and `ffi` are trust-equivalent to full access; native code and child
  processes are not confined.
- Module loading is a carve-out. Importing untrusted code gives that code the
  permissions of the process.
- Scopes are process-global. There is no per-request or per-user narrowing.

Use permissions to catch mistakes and to run code you mostly trust with less
authority. Do not use them as the only boundary for hostile code.

## Migration

| Task | Command |
|---|---|
| Static server | `ff server.js --allow-net=0.0.0.0:3000 --allow-read=./public` |
| Fetch client | `ff client.js --allow-net=api.example.com:443` |
| SQLite app | `ff app.js --allow-read=. --allow-write=.` |
| Postgres app | `ff app.js --allow-net=127.0.0.1:5432 --allow-env=PG_TEST_DSN` |
| Child process | `ff tool.js --allow-run=git` |
| Native library | `ff app.js --allow-ffi` |
| Full test suite | `ff test --allow-all` |

Start with the narrowest scope that works and widen only when the runtime tells
you which flag and detail were denied.

## See also

- [CLI](/docs/reference/cli)
- [Errors and exit codes](/docs/concepts/errors)
- [`fs`](/docs/api/fs) · [`process`](/docs/api/process) · [`fetch`](/docs/api/fetch)
- [`http`](/docs/api/http) · [`WebSocket`](/docs/api/websocket) · [UDP](/docs/api/udp)
- [SQLite](/docs/api/sqlite) · [Postgres](/docs/api/postgres)
- [`child_process`](/docs/api/child-process) · [FFI](/docs/api/ffi)
- [Workers](/docs/guides/workers)
- [Limitations](/docs/reference/limitations)
