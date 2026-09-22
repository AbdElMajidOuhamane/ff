---
title: Testing
description: Write and run tests with ff test and test/run.sh — the check/done pattern end to end.
order: 8
---

# Testing

Fairyfly has no external test framework. Put files ending in `.test.js` inside `test/` and run them with `ff test` (one process, all files) or `test/run.sh` (one process per file).

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
ff test smoke
# OK   test/smoke.test.js
#
# 1 passed, 0 failed
```

## The `check` / `done` pattern

`test/lib.mjs` is tiny on purpose — read it once, then copy the pattern:

| Helper | Signature | What it does |
|--------|-----------|--------------|
| `check` | `check(name, cond)` | Counts a pass when `cond` is truthy, else prints `FAIL: <name>` |
| `done` | `done(name)` | Prints `[<name>] pass:<n> fail:<m>`, then `process.exit(failed > 0 ? 1 : 0)` |

Three rules:

1. Every test file imports from `./lib.mjs` — relative import **with** the `.mjs` extension.
2. Every test file ends with `done("<name>")`. Without it the process may idle instead of exiting.
3. `done()` calls `process.exit()`, which also stops the event loop. Server-fixture tests (which keep a listener alive) terminate cleanly because of this.

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
ff test url
# OK   test/url.test.js
#
# 1 passed, 0 failed
```

## Running tests: `ff test`

```sh
ff test          # every test/*.test.js in one process
ff test url      # substring filter — only files with "url" in the name
ff test formdata # only formdata.test.js
```

Behavior:

- Opens `test/` — a missing directory prints `No test/ directory found.` and exits. Run from the project root.
- Runs only files ending in `.test.js`. Anything else is ignored (e.g. `test/url.test.ffbc` never runs under `ff test`).
- Each file is evaluated as a module, then microtasks and the event loop are pumped — top-level `await` works.
- Prints `OK   test/<name>` or `FAIL test/<name>` per file, then a `{passed} passed, {failed} failed` summary.
- Exit code is `1` when any file fails.
- Files larger than 10MB are not loaded (`FAIL … (read error)`).

## Running tests: `test/run.sh`

Same job, one process per file:

```sh
./test/run.sh
# OK   test/text.test.js
# OK   test/blob.test.js
# ...
# all tests passed
```

Green means every file exited `0` **and** printed no `FAIL` lines. `make test` runs `zig build test` plus `test/run.sh`; `make ci` runs the build plus `test/run.sh`.

> **Caution:** `run.sh` greps for the word `FAIL`, so any `console.log("FAIL…")` of your own marks the file failed. Only `check()` should ever print it.

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
ff test server-smoke
# OK   test/server-smoke.test.js
#
# 1 passed, 0 failed
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

**Hanging test run** — you forgot `done(name)`, or a `setInterval` / listener keeps the loop alive with no exit path. End every file with `done()`.

**`FAIL test/x.test.js (read error)`** — the file exceeds the 10MB per-file cap or is unreadable.

**Passes under `ff test`, fails under `run.sh`** — something printed `FAIL` without failing `check()`. Search the output for stray `FAIL` text.
