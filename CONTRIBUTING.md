# Contributing to Fairyfly

Thanks for your interest in contributing. Fairyfly is a backend JavaScript
runtime written in Zig on top of QuickJS — small, fast, and auditable. It is
maintained by one person right now, so the rules below exist to keep PRs
small, reviewable, and mergeable fast.

By opening a pull request you agree that your contribution is licensed under
the [Mozilla Public License 2.0](LICENSE) — the same license as the project.

## Table of contents

1. [Ground rules](#ground-rules)
2. [Prerequisites](#prerequisites)
3. [What's gitignored](#whats-gitignored-never-commit-these)
4. [Building](#building)
5. [Running tests](#running-tests)
6. [Code style](#code-style)
7. [Working on the runtime](#working-on-the-runtime)
8. [Documentation](#documentation)
9. [Pull request checklist](#pull-request-checklist)
10. [Reporting bugs](#reporting-bugs)
11. [Security issues](#security-issues)
12. [Governance](#governance)

## Ground rules

- **Be kind.** Constructive reviews only. Harassment, spam, and drive-by
  rewrites of unrelated code will be closed.
- **PRs are collaborators-only.** Only collaborators may open pull
  requests; PRs from anyone else will be closed. Not a collaborator?
  Open an issue describing the problem and your proposed fix instead —
  solid proposals are how collaborator access is earned.
- **One concern per PR.** A PR that fixes a bug should not also reformat
  files or rename things. Split it.
- **Small beats big.** A 50-line diff with tests merges in a day; a 900-line
  diff sits for a week.
- **Stay in scope.** Features that pull the project toward browser parity
  (DOM, `window`) or full npm compatibility (CommonJS, `node:` builtins) are
  out of scope — see [README](README.md#why-fairyfly).
- **No drive-by dependency additions.** The runtime vendors QuickJS,
  BearSSL, SQLite, and nghttp2 on purpose. Propose new vendored libraries in
  an issue first.

## Prerequisites

| Requirement | Notes |
|---|---|
| **Zig 0.16.0** | `zig version` must print `0.16.0` — the codebase uses 0.16 std APIs |
| **C compiler** | `clang` on macOS, `gcc` on Linux |
| **POSIX system** | macOS or Linux (Linux 5.1+ recommended for io_uring) |
| **curl, sh, tar** | used by the vendor fetch script and package tooling |
| **Directory names** | The test suite lives in `test/` (tracked). `tests/` and `examples/` are gitignored local dirs — PRs adding files there are rejected |

Vendor sources are **gitignored** and fetched separately — pinned versions
(SHA-256-checked where a hash is set), same script CI and the Dockerfile use:

    ./scripts/fetch-vendors.sh

This pulls quickjs-ng v0.16.2, BearSSL 0.6, SQLite 3.53.4, and nghttp2
1.70.0 into `vendor/`. Run it once per fresh clone.

## What's gitignored (never commit these)

Straight from `.gitignore`:

- Build artifacts: `zig-cache/`, `.zig-cache/`, `zig-out/`, `zig-pkg/`
- Vendored sources: `vendor/` (fetch with `./scripts/fetch-vendors.sh`)
- Built FFI fixture: `test/fixtures/libaddon_probe.so`
- Local playgrounds: `examples/`, `tests/` (the real suite is `test/`)
- Bench scratch: everything under `bench/` (harness, temp outputs, results,
  logs, and `node_modules` under bench dirs never ship)
- `.DS_Store`

`examples/`, `tests/`, and `bench/` are intentionally local-only — don't
open PRs that add files there.

## Building

    make build        # zig build -Doptimize=ReleaseFast → zig-out/bin/ff
    make install      # build + copy to ~/.local/bin/ff

Debug builds (slower runtime, better assertions):

    zig build

Useful build options:

    zig build -Dbearssl=false          # drop TLS (https/wss) support
    zig build -Dio_uring=false         # Linux: epoll backend instead of io_uring
    zig build -Dffi=false              # compile ffi.dlopen stubs instead of libffi
    zig build -Dversion=1.2.3          # version reported by `ff --version`

Quick smoke check after building:

    zig-out/bin/ff --version
    zig-out/bin/ff -e 'console.log("hello")'

## Running tests

Run the full suite before pushing — `make ci` runs the same steps as the
GitHub Actions workflow (per `.github/workflows/ci.yml`):

    make ci

`make ci` = `make build` + FFI C fixture + `zig build test` + `sh test/run.sh`.

Pieces, if you need only one:

    zig build test          # Zig unit tests
    make fixtures           # build the C addon used by test/ffi.test.js
    sh test/run.sh          # every test/*.test.js through the runtime

### JS test pattern

Tests live in `test/` and use a tiny `check`/`done` helper from
`test/lib.mjs` — there is no external test framework:

    // test/example.test.js
    import { check, done } from "./lib.mjs";

    check("math works", 1 + 1 === 2);
    check("url parses", new URL("https://example.com/x").pathname === "/x");

    done("example");

Three rules:

1. Files must end in `.test.js` (anything else in `test/` is ignored).
2. Every file ends with `done("<name>")` — it calls `process.exit()`, which
   is also what cleanly stops server fixtures.
3. Never print the word `FAIL` yourself. `test/run.sh` greps for it; only
   `check()` may emit it.

Server fixture pattern (serve, hit, exit):

    import { check, done } from "./lib.mjs";

    http.serve({ port: 3901 }, () => new Response("hi"));
    const res = await fetch("http://127.0.0.1:3901/");
    check("server replies", (await res.text()) === "hi");

    done("server-smoke");

Pick high test ports (3900+) to avoid colliding with a local dev server.

## Code style

### Zig (`src/`)

- Match the style of the file you are editing. Run `zig fmt` on every file
  you touch.
- Keep comments tight — the codebase explains hot-path tricks with one-line
  notes, not paragraphs.
- Prefer explicit `catch` handling over silent discards in new code; existing
  silent swallows (e.g. `fs` returning `undefined`) are documented behavior,
  don't "fix" them without an issue first.

### JavaScript (tests, examples, docs snippets)

- **ES Modules only.** `import`/`export` — no `require()`, no
  `module.exports`, no `node:` imports.
- No `Buffer`. Use `Uint8Array` / `ArrayBuffer` / `TextEncoder`.
- `console.log` writes to **stderr** — that is intended, don't fight it.
- Relative imports may omit the extension (`./x` probes `./x.js`, then
  `./x/index.js`); explicit `.mjs` targets must be written out.
- Respect runtime limits in anything you ship:

  | Resource | Cap |
  |---|---|
  | HTTP connections | 512 |
  | Concurrent fetch slots | 16 (methods are exact-case: `POST`, not `post`) |
  | Timers | 128 live |
  | Workers | 8 (4 MB/message) |
  | Request body | ~4 KB |
  | Response body | 10 MB |

## Working on the runtime

### Where things live

    src/
      engine/    QuickJS bridge + runtime init
      api/       globals: console, fs, process, crypto, url, fetch, websocket,
                 sqlite, sql, ffi
      net/       http_native (server), http2_server, pg_client, async_fetch, tls
      event/     loop, timers, microtasks (libxev underneath)
      types/     Headers, Request, Response, Blob, FormData
      worker/    worker threads, message_port, serialize
      commands/  CLI subcommands: init, imprint, sever, start, test, repl, ...

### Performance-sensitive changes

If you touch a hot path (HTTP server, fetch, SQLite binding, event loop):

1. Benchmark before and after on the same machine with your own load tool
   (`wrk`, `oha`, or `ab`) against the same hello-world handler, same flags.
   The maintainer's harness under `bench/` is local-only and not in the
   repo — any equivalent setup with identical before/after conditions is
   acceptable; state the tool and flags in the PR.
2. Paste both numbers in the PR description.
3. Note if RSS changes materially (peak RSS via `/usr/bin/time -l` on macOS
   or `maxrss` on Linux).

Unexplained large regressions will block review.

### Platform notes

- **Linux** defaults to **io_uring** (5.1+); epoll via `-Dio_uring=false`.
  Docker's default seccomp blocks io_uring — test with
  `--security-opt seccomp=unconfined` or an epoll build.
- **macOS** uses kqueue.
- CI is `.github/workflows/ci.yml`; Linux jobs build static musl binaries.

## Documentation

- User-visible behavior change ⇒ update the matching page under `docs/`
  (`docs/index.md` is the map).
- New hard limit or cap ⇒ also update `docs/reference/limitations.md` and
  the README limitations section.
- New global or API ⇒ add a row to `docs/api/overview.md`.

## Pull request checklist

Before requesting review (collaborators — push a branch, no forks needed):

- [ ] `make ci` passes locally (build + Zig tests + all JS tests)
- [ ] `zig fmt` run on touched Zig files
- [ ] Commit message follows the repo style
      (`fix(ffi): ...`, `perf(pg,sqlite,http): ...`, `docs: ...`, `ci: ...`)
- [ ] Docs updated if behavior or limits changed
- [ ] Bench numbers included if a hot path changed
- [ ] PR description says **what** changed, **why**, and **how tested**
- [ ] `git status` clean of artifacts — no `zig-out/`, `vendor/`, cache, or
      `examples/` files swept into the commit

## Reporting bugs

Not a collaborator? This is your contribution path — open an issue with:

1. `ff --version` (prints version + OS + arch)
2. OS, architecture, install method (binary / source / Docker)
3. Minimal `.js` repro — smallest file that reproduces it
4. Expected vs actual behavior
5. Whether it reproduces on a release binary, or only a local build

## Security issues

**Do not open a public issue or pull request for security bugs.**

Email the maintainer directly (contact is on the GitHub profile:
[@AbdElMajidOuhamane](https://github.com/AbdElMajidOuhamane)) with:

- the vulnerability and its impact
- a minimal reproduction
- affected versions (`ff --version`)

Expect an acknowledgment within 48 hours. Confirmed issues get a patch
release coordinated with the reporter, then a public advisory after the fix
ships.

## Governance

Fairyfly currently has a **single maintainer**:
[@AbdElMajidOuhamane](https://github.com/AbdElMajidOuhamane).

- Final merge decisions rest with the maintainer.
- Only collaborators open pull requests; everyone else contributes via
  issues (see Ground rules).
- Controversial changes (new vendored dependency, license/tooling swaps,
  breaking API changes) start as an issue for discussion, not a PR.
- This section will grow — reviewers, an org repository, and a written
  decision process — as contributors join.
