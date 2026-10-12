---
title: Testing
description: Write and run tests with ff test and test/run.sh — the check/done pattern end to end.
order: 8
---

# Testing

Fairyfly has no external test framework. Put files ending in `.test.js` inside `test/` and run them through the runtime: `test/run.sh` runs **one process per file** (this is what `make test` uses), or `ff test` runs them in a single process with a summary.

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

Run it as a file:

```sh
ff test/smoke.test.js
# [smoke] pass:3 fail:0
```

## The `check` / `done` pattern

`test/lib.mjs` is a tiny assertion library that dogfoods the ESM loader:

| Helper | Signature | What it does |
|--------|-----------|--------------|
| `check` | `check(name, cond)` | Counts a pass when `cond` is truthy, else prints `FAIL: <name>` (via `console.log` → stderr) |
| `done` | `done(name)` | Prints `[<name>] pass:<n> fail:<m>`, then `process.exit(failed > 0 ? 1 : 0)` |

Three rules:

1. Every test file imports from `./lib.mjs` — a relative import **with** the `.mjs` extension.
2. Every test file should end with `done("<name>")`, which reports and exits.
3. `done()` calls `process.exit()`, which also stops the event loop — so tests that leave a server listener running terminate cleanly instead of hanging.

A minimal single-file test, using the same pattern as `test/url.test.js`:

```js
// test/url-mini.test.js
import { check, done } from "./lib.mjs";

const u = new URL("https://example.com:8080/path?q=1#hash");
check("href", u.href === "https://example.com:8080/path?q=1#hash");
check("port", u.port === "8080");
check("parse invalid", URL.parse("not a url") === null);

done("url-mini");
```

```sh
ff test/url-mini.test.js
# [url-mini] pass:3 fail:0
```

## Running tests: `test/run.sh`

The repo's suite runner. It runs each `test/*.test.js` in its own `ff` process and passes `--allow-ffi` to every file (so `test/ffi.test.js` runs its full contract instead of self-skipping):

```sh
./test/run.sh
# OK   test/text.test.js
# OK   test/blob.test.js
# ...
# all tests passed
```

Green means every file **exited `0`** and printed **no `FAIL` lines**. It requires an already-built `ff` binary (run `make build` first).

`make test` / `make ci` run the same steps — build, build the C fixture (`make fixtures`), `zig build test` (Zig unit tests), then `test/run.sh`.

> **Caution:** `run.sh` greps the captured output for the word `FAIL`, so any
> `console.log("FAIL…")` of your own marks the file failed. Only `check()`
> should ever print it.

## Running tests: `ff test`

The built-in runner scans `test/` and evaluates each `*.test.js` as a module in a shared runtime:

```sh
ff test          # every test/*.test.js
ff test url      # substring filter — only files whose name contains "url"
ff test formdata # only formdata.test.js
```

Behavior:

- Opens `test/`; if it's missing it prints `No test/ directory found.` and stops. Run from the project root.
- Runs only files ending in `.test.js`. Other entries (including `.ffbc` files) are ignored.
- Each file is evaluated as a module (so top-level `await` works) and then the event loop is pumped.
- Prints `OK   test/<name>` or `FAIL test/<name>` per file, then `{passed} passed, {failed} failed`.
- Exit code is `1` when any file failed.
- Each file is read with a **10 MB** cap; a larger or unreadable file prints `FAIL test/<name> (read error)` and counts as a failure.

> **Important:** `done()` calls `process.exit()`. Under `ff test` (a single
> process for all files), reaching a `done()` call ends the whole run right
> there — so the runner's `OK`/summary lines only print for files that finish
> without calling `process.exit`. This is exactly why the repo's own suite
> (`test/run.sh`) runs one process per file. When a file calls `done()`, the
> line you actually see is `[<name>] pass:<n> fail:<m>` from `done`, and the
> process exits with `done`'s code.

## Async and server tests

Top-level `await` works, because each file is evaluated as a module:

```js
// test/fetch-smoke.test.js
import { check, done } from "./lib.mjs";

const res = await fetch("https://example.com/");
check("status ok", res.ok);
check("body text", typeof (await res.text()) === "string");

done("fetch-smoke");
```

For a server fixture, serve on a fixed test port, hit it, then `done()` (which exits and closes the listener). Picking from a few candidate ports avoids flaking when one is busy:

```js
// test/server-smoke.test.js
import { check, done } from "./lib.mjs";

const PORTS = [39871, 39872, 39873];
let base = null;
for (const port of PORTS) {
  try {
    http.serve({ port }, () => new Response("hi"));
    base = "http://127.0.0.1:" + port;
    break;
  } catch (e) {}
}
if (base === null) throw new Error("could not bind any candidate port");

const res = await fetch(base + "/");
check("server replies", (await res.text()) === "hi");

done("server-smoke");
```

```sh
ff test/server-smoke.test.js
# [server-smoke] pass:1 fail:0
```

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

## Troubleshooting

**`No test/ directory found.`** — run from the project root, not from inside `test/`.

**Nothing runs under `ff test`** — remember the filter is a **substring** match on the filename, and only `*.test.js` files are considered.

**Hanging test run** — you forgot `done(name)`, or a `setInterval`/listener keeps the loop alive with no exit path. End every file with `done()`.

**`FAIL test/x.test.js (read error)`** — the file exceeds the 10 MB per-file cap or is unreadable.

**Fewer files ran under `ff test` than expected** — the first file that called `done()` exited the shared process. Use `test/run.sh` (one process per file) or run files individually.

**Passes under `ff test`, fails under `run.sh`** — something printed `FAIL` without failing `check()`. Search the output for stray `FAIL` text.
