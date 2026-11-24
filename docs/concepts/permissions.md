---
title: Permissions
description: Deny-by-default native API access — flags, scopes, enforcement points, and the error contract.
order: 5
---

# Permissions

Fairyfly is **deny-by-default** for native capabilities. A script cannot read
files, open sockets, inspect the environment, spawn processes, or load native
libraries unless the launch command grants it.

There is no `ff.json` section and no permission environment variable. Initial policy comes solely from `--allow-*` and `--deny-*` CLI flags; permissions can never be *granted* at runtime, only *narrowed/revoked* via `permissions.revoke()`.

## Quick look

```sh
ff server.js --allow-net=0.0.0.0:3000 --allow-read=./public
ff -e 'console.log(fs.readFile("config.json"))' --allow-read=.
ff test --allow-all
```

Every command that starts a JS runtime accepts the flags: `ff <file>`,
`ff -e`, `ff start`, `ff test`, `ff repl`, and `ff --watch`.

## Flags

| Flag | Grants / Restrictions | Scope |
|---|---|---|
| `--allow-read` | `fs` reads, `process.chdir`, `Response.file`, `Database.open`, TLS file paths in `http.serve`, Postgres `sslrootcert` | paths |
| `--allow-write` | `fs` writes, SQLite database files and their parent directory | paths |
| `--allow-net` | `fetch`, `WebSocket`, `http.serve`, TCP (`tcp.connect`), UDP, Postgres | `host`, `host:port`, `*.domain` |
| `--allow-env` | `process.env`, Postgres DSN and TLS variables (`PG*`, `DATABASE_URL`, `PGSSL*`) for the global `sql` | exact names |
| `--allow-run` | `child_process.spawn` / `exec` / `execSync`, `process.kill` (external PIDs) | basenames or absolute paths (`kill` for `process.kill`) |
| `--allow-ffi` | every `ffi` entry point except `ffi.allowed` | none — bare only |
| `--allow-all` | every category above, **including FFI** | none |
| `--deny-read=<paths>` | explicitly deny file paths even when covered by `--allow-read` (`=<paths>` required) | paths |
| `--deny-write=<paths>` | explicitly deny file paths even when covered by `--allow-write` (`=<paths>` required) | paths |
| `--deny-net=<hosts>` | explicitly block hosts/ports even when `--allow-net` is active (`=<hosts>` required) | `host`, `host:port`, `*.domain` |
| `--deny-private-net` | deny loopback, RFC1918, CGNAT, link-local/cloud-metadata (`169.254.169.254`), and private IPv6 after DNS resolution across `fetch`, `WebSocket`, `tcp.connect`, outbound `udp`, and Postgres `sql` | none — bare only |
| `--simple-sandbox` | enable Linux OS sandbox (`PR_SET_NO_NEW_PRIVS` + Landlock LSM v1 + seccomp-bpf keeping `io_uring_enter` allowed); fails closed on non-Linux OSes | none — bare only |

Rules:

- Flags are repeatable and comma-split: `--allow-read=src,test`.
- A bare `--allow-*` flag grants the whole category: `--allow-net` means any host, any port. `--deny-*` flags require `=<scope>` (bare `--deny-read` or unknown `--deny-*` categories such as `--deny-env`/`--deny-run`/`--deny-ffi` fail at startup).
- An empty scope is invalid: `--allow-read=` or `--deny-read=` fails at startup.
- `--deny-*` flags take precedence over `--allow-*` grants (e.g. `--allow-read=. --deny-read=./secrets`).
- Initial scopes are parsed before the JS runtime starts, and permissions can be dropped/narrowed at runtime via `permissions.revoke()`.
- Any argument starting with `--allow-` or `--deny-` is parsed as a permission flag (unknown ones abort startup), though raw arguments still appear in `process.argv`.

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
- `..` traversal, NUL bytes, and paths at or beyond `PATH_MAX` (`4096` bytes on Linux, `1024` bytes on macOS) are denied.
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
- `http.serve()` binds `0.0.0.0` by default (configurable via `{ hostname }`),
  so match `--allow-net` to the bound `<hostname>:<port>` (default
  `--allow-net=0.0.0.0:<port>`, not `127.0.0.1:<port>`).
- IPv6 literals use brackets: `[::1]:3000`.

## Environment scopes

```sh
--allow-env=HOME,PATH
--allow-env=PG_TEST_DSN,DATABASE_URL,PGHOST,PGPORT,PGUSER,PGPASSWORD,PGDATABASE,PGSSLMODE,PGSSLROOTCERT
--allow-env                       # every variable
```

- Names are exact and case-sensitive. There is no wildcard.
- `process.env` is built once at startup (from OS env plus any `--env-file`)
  with disallowed keys omitted. Reading a disallowed name returns `undefined`;
  it does not throw.
- The runtime still reads its own CLI/runtime configuration (`FF_ECHO`,
  `FF_CERT`, `FF_KEY`, `FF_CA_FILE`, `FF_MAX_HEAP`, `FF_CPU_BUDGET`,
  `FF_WALL_TIMEOUT`, `FF_WATCH_PARENT`, `NO_COLOR`, and proxy env vars) outside `--allow-env`.
  That does not expose those keys in JavaScript `process.env`.

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
- `ffi.allowed` reports the current state. Every other `ffi` entry point —
  `dlopen`, `callback`, `ptr`, `view`, `cstring`, `read`, `write`,
  `copyBytes`, `writeBytes`, `struct`, `union`, `isNull` — requires the flag.
- Native code runs with the full privileges of the `ff` process. FFI bypasses
  every other permission, so `--allow-ffi` is trust-equivalent to full access.

## Where checks happen

| API | Flag | Checked |
|---|---|---|
| `fs.readFile` / `exists` / `readdir` | `read` | before the syscall or fs job |
| `fs.writeFile` / `mkdir` / `rm` | `write` | before the syscall or fs job |
| `Response.file(path)` | `read` | before reading the file |
| `process.env` | `env` | when the global is built |
| `process.chdir` | `read` on the target | before `chdir` |
| `fetch` | `net` on `host:port` | before the request is submitted, and on every redirect hop |
| `new WebSocket` | `net` on `host:port` | before the socket is created |
| `http.serve` | `net` on `<hostname>:<port>` (default `0.0.0.0:port`) | before the listener starts |
| `http.serve({ tls })` | `read` for file paths | before the TLS files are loaded |
| `tcp.connect(host, port)` | `net` on `host:port` | before connecting |
| `udp.bind` / `connect` / `sendto` | `net` on the address | before the syscall |
| `Database.open` | `read` + `write` on the file, `write` on the parent | before `sqlite3_open` |
| `new SQL(dsn \| options)` | `net` on host/port, plus `read` on `sslrootcert` if TLS is enabled | before the pool is created |
| global `sql` | `net`, `read` on `sslrootcert` (if TLS enabled), plus `env` for `PG*` / `PG_TEST_DSN` / `DATABASE_URL` / `PGSSL*` | before the first query |
| `child_process.spawn` / `exec` / `execSync` | `run` on `argv[0]` | before the child is created |
| `process.kill(pid, sig?)` | `run` on `"kill"` (when `pid !== process.pid`) | before the signal is sent |
| `ffi.dlopen` / `ffi.callback` / `ffi.*` memory helpers | `ffi` | before `dlopen`, closure creation, pointer creation, or memory access |

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
- FFI uses the same error shape but has no scope suffix:
  `ffi.read requires --allow-ffi`. `ffi.allowed` is `false` without the flag.

## Lifetime and inheritance

- The initial policy is parsed before any runtime object exists; grants can never be added at runtime, only dropped or narrowed one-way via `permissions.revoke()`.
- `globalThis.permissions` exposes dynamic booleans for the six categories:
  `read`, `write`, `net`, `env`, `run`, `ffi`. A category is `true` when it has
  any active grant.
- `permissions.revoke(descriptor)` synchronously returns `undefined` and updates the process-global atomic policy (shared with workers):
  ```js
  permissions.revoke({ name: "read" }); // drops all read permissions
  permissions.revoke({ name: "write", path: "/tmp/init" }); // revokes specific path scope
  permissions.revoke({ name: "net", host: "169.254.169.254" }); // revokes specific network scope
  permissions.revoke({ name: "env", variable: "SECRET_KEY" }); // revokes env scope (see caveats)
  permissions.revoke({ name: "run" }); // revokes all run permissions (category-only)
  permissions.revoke({ name: "ffi" }); // revokes all FFI permissions (category-only)
  ```
  Revocation caveats:
  - Scoped revocation works for `read`/`write` (`path`), `net` (`host`), and `env` (`variable`); `run` and `ffi` revoke whole-category only.
  - Under bare `--allow-env`, revoking `{ name: "env", variable: "X" }` drops **all** `env` permissions (per-variable removal only applies when `--allow-env=A,B` was scoped).
  - Because `process.env` is built once at startup, revoking `env` does not delete keys already on `process.env` — it affects `permissions.env` and subsequent runtime `checkEnv` calls (such as lazy global `sql` init).
  - `ffi.allowed` is a startup snapshot boolean and stays `true` after `permissions.revoke({ name: "ffi" })`, whereas `permissions.ffi` flips to `false` and `ffi.*` calls throw `PermissionDenied`.
- Workers share the process-global policy dynamically.
- `ff --watch` forwards permission flags (placed after `--watch`) to the child it restarts.
- `ff start` accepts permission flags anywhere in argv; `--cert` / `--key` are CLI
  configuration reads and are not gated by `--allow-read`.

## Program-loading carve-out

Loading code is not a `read` operation:

- `import` / `export` resolution and module file reads.
- `ff start` reading `ff.json` and its `main` file.
- `ff test` loading `test/*.test.js`.
- `new Worker("./worker.js")` loading the worker file.

These work without `--allow-read`. Permissions gate what loaded code does at runtime, not whether it can be loaded. (Workers expose a restricted CPU/crypto/timers/console global set without `fs` or native I/O APIs; `permissions.*` is not exposed in workers, though shared policy state applies across the runtime.)

`ff imprint`, `ff fmt`, `ff upgrade`, and `ff compile` are CLI operations, not
runtime APIs. They are not gated by these flags.

## Security model

Permission flags alone are an **in-process policy layer, not an OS sandbox**.

- A path is canonicalized and then passed to a normal filesystem syscall. A
  symlink swapped between the check and the syscall can escape the scope.
- `run` and `ffi` are trust-equivalent to full access; native code and child
  processes are not confined unless OS sandboxing is enabled.
- Module loading is a carve-out. Importing untrusted code gives that code the
  permissions of the process.
- Scopes are process-global. There is no per-request or per-user narrowing.

For OS-level isolation on Linux and SSRF hardening:

- **`--simple-sandbox`** enables kernel-level confinement (`PR_SET_NO_NEW_PRIVS` +
  Landlock LSM ABI v1 matching your `--allow-read`/`--allow-write` scopes +
  seccomp-bpf blocking `io_uring_setup`, `io_uring_register`, `execve`,
  `execveat`, `ptrace`, `mount`, `bpf`, and module syscalls while keeping
  `io_uring_enter` fast); it fails closed on non-Linux OSes.
- **`--deny-private-net`** performs post-DNS IP checks to block loopback,
  RFC1918, CGNAT, link-local/cloud-metadata (`169.254.169.254`), and private
  IPv6 addresses even when DNS resolves an external hostname to an internal IP.

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
