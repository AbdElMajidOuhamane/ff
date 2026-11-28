---
title: Testing
description: Write and run tests with ff test and test/run.sh — the check/done pattern end to end.
order: 8
---

# Testing

Put files ending in `.test.js` inside `test/` and run them either with `ff test` (single process; fails on uncaught exceptions) or `test/run.sh` (spawns one fresh `ff` process per file and uses Fairyfly's `check`/`done` pattern).

## Permissions

Test code runs under the same deny-by-default policy as any other script.
Pass the grants the tests need to the runner:

```sh
ff test --allow-net=example.com:443
ff test server-smoke --allow-net=0.0.0.0:3901,127.0.0.1:3901
ff test --allow-all
```

- Place permission and limit flags **after `test`** (before or after the filter). When using value flags alongside `ff test`, prefer `=` syntax (e.g. `ff test --max-heap=128MB url`) so the value is not mistaken for the filename filter.
- A flag applies to **every** test file in that `ff test` run. There is no
  per-file grant.
- The runner reads `test/*.test.js` as program files, so no `--allow-read` is
  needed just to load tests. Reads inside a test still need a scope.
- `test/run.sh` runs each file with `--allow-all` because the suite covers
  filesystem, network, env, subprocesses, FFI, and the denial matrix itself.
  Tests that assert a denial must spawn a child `ff` with narrower flags
  instead of relying on the parent's policy.
- Minimal grants are better than `--allow-all` for application tests: a
  missing scope is a real failure you want to see.

Common grants:

| Test uses | Flag |
|---|---|
| `fetch` / `WebSocket` client | `--allow-net=<host>:<port>` |
| `http.serve` / `udp.bind` | `--allow-net=0.0.0.0:<port>` (or the UDP address) |
| `fs` reads / writes | `--allow-read=<path>`, `--allow-write=<path>` |
| `Database.open` | `--allow-read=<db>` and `--allow-write=<dir>` |
| `process.env` | `--allow-env=<NAME>` |
| `child_process` | `--allow-run=<program>` |
| `ffi` | `--allow-ffi` |

For a server fixture that also fetches itself, grant both the listener and the
client URL:

```sh
ff test server-smoke --allow-net=0.0.0.0:3901,127.0.0.1:3901
```

`0.0.0.0:3901` is the `http.serve` bind check; `127.0.0.1:3901` is the
outbound `fetch` check. Full model: [Permissions](/docs/concepts/permissions).

## Quick look

Create `test/smoke.test.js`:

```js
// test/smoke.test.js
import { check, done } from "./lib.mjs";

check("math works", 1 + 1 === 2);
check("url parses", new URL("https://example.com/x").pathname === "/x");

const res = new Response("hello");
check("body reads", (await res.text()) === "hello");

done("smoke");
```

Run it:

```sh
ff test/smoke.test.js
# [smoke] pass:3 fail:0
```

For `ff test` directly (single-process runner without `done()` / `process.exit()`), throw an `Error` on failure instead of calling `done()` — otherwise `done()` calls `process.exit()` after the first file:

```sh
ff test smoke
# OK   test/smoke.test.js
#
# 1 passed, 0 failed
```

This test touches no native API, so it needs no permission flags.

## The `check` / `done` pattern (`test/run.sh`)

`test/lib.mjs` is designed for `test/run.sh` (which runs one fresh `ff` process per file) — read it once, then copy the pattern:

| Helper | Signature | What it does |
|--------|-----------|--------------|
| `check` | `check(name, cond)` | Counts a pass when `cond` is truthy, else prints `FAIL: <name>` |
| `done` | `done(name)` | Prints `[<name>] pass:<n> fail:<m>`, then `process.exit(failed > 0 ? 1 : 0)` |

Three rules for `test/run.sh` suites:

1. Every test file imports from `./lib.mjs` — relative import **with** the `.mjs` extension.
2. Every test file ends with `done("<name>")`. Without it the process may idle instead of exiting.
3. `done()` calls `process.exit()`, which also stops the event loop. Server-fixture tests (which keep a listener alive) terminate cleanly because of this.

> **Important:** Because `done()` calls `process.exit()`, running `ff test` on files that call `done()` exits the entire `ff test` process immediately after the first matching file (skipping remaining files and `ff test`'s `OK` / `N passed, M failed` summary). Use `test/run.sh` for suites using `done()`, or throw on assertion failure for single-process `ff test` runs.

Real example from the repo (`test/url.test.js`):

```js
import { check, done } from "./lib.mjs";

const u = new URL("https://example.com:8080/path?q=1#hash");
check("href", u.href === "https://example.com:8080/path?q=1#hash");
check("port", u.port === "8080");
check("parse invalid", URL.parse("not a url") === null);

done("url");
```

```sh
ff test/url.test.js
# [url] pass:21 fail:0
```

## Running tests: `ff test`

```sh
ff test          # every test/*.test.js in one process (for throw-on-failure tests)
ff test url      # substring filter — only files with "url" in the name
ff test formdata # only formdata.test.js
```

Behavior:

- Opens `test/` — a missing directory fails with `error: no test/ directory found` (exit `1`). Run from the project root.
- If a filter matches no files, prints `error: no tests match '<filter>'` and exits `1`.
- Runs only files ending in `.test.js`. Anything else is ignored (e.g. `test/url.test.ffbc` never runs under `ff test`).
- Each file is evaluated as a module, then microtasks and the event loop are pumped — top-level `await` works. A file fails only when evaluation or async microtasks/loop throw an uncaught error (and stops the whole runner if the file calls `process.exit()`).
- Prints `OK   test/<name>` or `FAIL test/<name>` per file (prefixed with `✓` / `✗` on a TTY), then a `{passed} passed, {failed} failed` summary. `ff test` does **not** scan stdout/stderr for `FAIL` lines.
- Exit code is `1` when any file fails.
- Files larger than 10MB or unreadable fail with `FAIL test/<name>`.
- Permission flags in the command line apply to all files in the run; `--allow-all` makes every test file unrestricted.

## Running tests: `test/run.sh`

Takes no CLI arguments or filters — runs every `test/*.test.js` in its own fresh process with `--allow-all` and a per-suite timeout (`FF_TEST_TIMEOUT`, default `60`s):

```sh
./test/run.sh
# OK   test/text.test.js
# OK   test/blob.test.js
# ...
# all tests passed
```

`run.sh` passes `--allow-all` to every file — the suite covers fs, net, env,
run, FFI, and the denial matrix. The permission tests spawn child `ff`
processes with narrower flags, so the parent's `--allow-all` does not hide a
missing check.

Green means every file exited `0` **and** printed no `FAIL` lines. `make test`
runs build + C fixtures, `zig build test`, then `test/run.sh`. `make ci` adds
`zig fmt --check` and a fuzz smoke run — the same gates as GitHub Actions.

> **Caution:** `run.sh` greps for the word `FAIL`, so any `console.log("FAIL…")` of your own marks the file failed. Only `check()` should ever print it.

## Fuzz runner

Run `zig build fuzz -Doptimize=ReleaseSafe -- <target|smoke> [seed] [--events-max=N]`. Missing or unknown targets and invalid arguments print usage and exit with status `2`.

## Async and server tests

Top-level `await` works, and the runner pumps the loop after each file:

```js
// test/fetch-smoke.test.js
import { check, done } from "./lib.mjs";

const res = await fetch("https://example.com/");
check("status ok", res.ok);
check("body text", typeof (await res.text()) === "string");

done("fetch-smoke");
```

```sh
ff test fetch-smoke --allow-net=example.com:443
```

For a server fixture, serve on a fixed test port, hit it, then `done()` (which exits and closes the listener):

```js
// test/server-smoke.test.js
import { check, done } from "./lib.mjs";

http.serve({ port: 3901 }, () => new Response("hi"));
const res = await fetch("http://127.0.0.1:3901/");
check("server replies", (await res.text()) === "hi");

done("server-smoke");
```

```sh
ff test/server-smoke.test.js --allow-net=0.0.0.0:3901,127.0.0.1:3901
# [server-smoke] pass:1 fail:0
```

Both grants are required: the listener binds `0.0.0.0:3901`, and the client
fetches `127.0.0.1:3901`.

## Practical example: testing a JSON endpoint

```js
// test/notes.test.js
import { check, done } from "./lib.mjs";

http.serve({ port: 3902 }, (url, method, body) => {
  if (url === "/notes" && method === "POST") {
    const data = JSON.parse(body || "{}");
    if (!data.text) return Response.json({ error: "text is required" }, { status: 400 });
    return Response.json({ id: 1, text: data.text }, { status: 201 });
  }
  return new Response("not found", { status: 404 });
});

const ok = await fetch("http://127.0.0.1:3902/notes", {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ text: "buy milk" }),
});
check("creates", ok.status === 201);
check("echoes", (await ok.json()).text === "buy milk");

const bad = await fetch("http://127.0.0.1:3902/notes", {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({}),
});
check("rejects empty", bad.status === 400);

done("notes");
```

```sh
ff test/notes.test.js --allow-net=0.0.0.0:3902,127.0.0.1:3902
```

## Testing denials

To assert that a missing grant fails closed, run a child process with a
narrower policy. The parent test runner can keep `--allow-all`; the child
starts clean:

```js
// test/permissions.test.js
import { check, done } from "./lib.mjs";
import { execSync } from "node:process"; // not available — use child_process instead
```

Use the real global:

```js
const BIN = "./zig-out/bin/ff";
const out = child_process.execSync(
  `${BIN} -e 'try { fs.readFile("nope.txt"); } catch (e) { console.log(e.code); }'`,
  { maxBuffer: 1024 * 1024 },
);
check("read denied", out.stderr.includes("PERMISSION_DENIED"));
```

Note that `execSync` itself needs `--allow-run=/bin/sh` in the parent. The
repo's `test/permissions.test.js` follows this pattern and builds the child
command lines with explicit scopes.

## Troubleshooting

**Tests fail with `PermissionDenied`** — add the matching flag to the
`ff test` command. Common pairs: `fetch` needs `--allow-net=<host>:<port>`;
`http.serve` needs `--allow-net=0.0.0.0:<port>`; SQLite needs both file read
and directory write scopes.

**A test passes under `--allow-all` but fails with narrow flags** — the test
is missing a real grant. Add the specific scope rather than widening the
whole run. For server fixtures, remember the listener and client checks use
different addresses.

**`error: no test/ directory found`** — run from the project root, not from inside `test/`.

**Hanging test run** — you forgot `done(name)` under `test/run.sh`, or a `setInterval` / listener keeps the loop alive with no exit path.

**`FAIL test/x.test.js`** — the file threw an uncaught error, failed `check()`/`FAIL` under `run.sh`, exceeds the 10MB per-file cap, or is unreadable.

**Passes under `ff test`, fails under `run.sh`** — something printed `FAIL` without failing `check()`, or an earlier file called `done()`/`process.exit()` before later files ran under `ff test`. Search the output for stray `FAIL` text, and run `done()` suites via `./test/run.sh`.

**Denial test passes unexpectedly under `run.sh`** — the parent has
`--allow-all`. Spawn a child `ff` with explicit flags and assert its
`PermissionDenied` output; don't rely on the parent's policy.

## See also

- [Permissions](/docs/concepts/permissions) — flags, scopes, denial contract
- [Errors and exit codes](/docs/concepts/errors) — denial shapes
- [child_process](/docs/api/child-process) — spawning child `ff` processes in tests
- [Limitations](/docs/reference/limitations) — every hard cap
