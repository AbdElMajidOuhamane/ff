---
title: Logging
description: console in practice — levels, timing, stderr redirection, and a structured-log pattern.
order: 9
---

# Logging

Fairyfly ships one logging primitive: [`console`](/docs/api/console). It is
deliberately small — no levels object, no transports, no JSON mode — so this
page is about turning that one primitive into the shape your app needs.

## Redirecting output

Every `console` line goes to **stderr**, which makes separation trivial:

```sh
ff server.js                          # logs (and app output) on the terminal
ff server.js 2> server.log            # logs to file, terminal stays clean
ff server.js 2> >(tee server.log)     # both (bash/zsh process substitution)
```

There is no in-runtime API that writes to fd 1 (`process.stdout.write`,
`console.log` to stdout, etc. all don't exist). For a shipper that insists on
stdout, merge at the shell:

```sh
ff server.js 2>&1 | collector
```

Otherwise treat `console` as your log sink and let the supervisor collect
**stderr** — Docker and systemd both capture it by default.

## Levels via colours

Use the built-in colours as severity levels. `warn`/`slops` and
`error`/`redbal` are aliases of each other.

| Level | Method | Colour |
|---|---|---|
| debug | `console.debug` | plain |
| info | `console.log` / `console.info` | plain |
| success | `console.detail` | green |
| warn | `console.warn` / `console.slops` | yellow |
| error | `console.error` / `console.redbal` | red |

```js
console.debug("cache miss for", "user:42");
console.log("listening on", 3000);
console.detail("migration complete");
console.warn("pool near capacity:", 9, "/", 10);
console.error("request failed:", "ECONNRESET");
```

There is **no level filtering**: every call prints. Gate noisy output
yourself (`if (debug) console.debug(...)`), where `debug` is your own flag.

## Structured, single-line JSON

For machines, serialize one object per line — collectors (Vector, Loki,
CloudWatch) ingest that shape directly:

```js
// jsonlog.js
function log(level, msg, fields = {}) {
  console.log(JSON.stringify({ ts: new Date().toISOString(), level, msg, ...fields }));
}

log("info", "server started", { port: 3000 });
log("error", "upstream failed", { url: "https://example.com/", status: 502 });
```

```
{"ts":"2026-10-07T11:20:31.412Z","level":"info","msg":"server started","port":3000}
{"ts":"2026-10-07T11:20:31.415Z","level":"error","msg":"upstream failed","url":"https://example.com/","status":502}
```

Because objects otherwise print as `[object Object]`, `JSON.stringify` is the
only way to get structure into a log line — see
[the console API](/docs/api/console#arguments-and-formatting).

## Timing requests

`console.time` prints a human-readable `label: Nms` line on the wall clock —
good for logs. Keep the label on the stack so the `finally` always closes it:

```js
http.serve({ port: 3000 }, (url, method) => {
  const label = `${method} ${url}`;
  console.time(label);
  try {
    const body = JSON.stringify({ ok: true, url });
    return new Response(body, { headers: { "content-type": "application/json" } });
  } finally {
    console.timeEnd(label);         // GET /todos: 0ms
  }
});
```

For anything tighter than ~1 ms, or when a wall-clock step would corrupt the
number, use [`performance.now()`](/docs/api/performance) — a monotonic clock:

```js
(async () => {
  const t0 = performance.now();
  await new Promise((resolve) => setTimeout(resolve, 5));
  console.detail(`took ${(performance.now() - t0).toFixed(2)}ms`);
})();
```

## Logging errors without losing the stack

```js
try {
  throw new Error("boom");
} catch (err) {
  console.error("risky failed:", err && err.stack ? err.stack : err);
  throw err;                        // rethrow so the HTTP handler returns 500
}
```

Inside an `http.serve` handler, an uncaught throw becomes a `500`; log first,
then rethrow. An uncaught throw at the top level of a script exits `1` and
prints the error to stderr for you (see
[Errors and exit codes](/docs/concepts/errors)).

## Correlating lines with a request id

`crypto.randomUUID()` gives every request a cheap, unique id you can staple
onto each line:

```js
// reqlog.js
function requestLogger() {
  const id = crypto.randomUUID();   // RFC 4122 v4
  return (level, msg, fields = {}) =>
    console.log(JSON.stringify({ id, level, msg, ...fields }));
}

http.serve({ port: 3000 }, (url) => {
  const log = requestLogger();      // one id per request
  log("info", "start", { url });
  log("debug", "done");
  return new Response("ok");
});
```

## In a Worker

A Worker has its own `console` writing to the **same stderr**, so logs from
every worker interleave on one stream. Give lines a worker tag so you can
tell them apart:

```js
// worker.js
console.detail("[worker]", "started", globalThis.workerData);
onmessage = (e) => {
  console.log("[worker] job:", e.data.id);
  postMessage({ ok: true });
};
```

See the [Workers guide](/docs/guides/workers) for the full worker API.

## Gotchas

- `console.log({ a: 1 })` prints `[object Object]` — use `JSON.stringify`.
- ANSI colour codes survive redirection into files; strip them at the
  collector if your format requires it (or use only plain `log`/`info`/
  `debug` for machine-facing lines).
- Each line is written straight to stderr as it is produced, so there is no
  application-level buffering to flush — but pipes and collectors may still
  batch. For durability, prefer a file sink over a pipe.
- There is no log-level filtering and no `console.table`/`trace`/`assert`/
  `count`; `console.time` is wall-clock (use `performance.now` to measure).

## See also

- [`console` API](/docs/api/console) — every method, argument, and quirk
- [HTTP server](/docs/guides/http-server)
- [Workers](/docs/guides/workers)
- [Deploy](/docs/guides/deploy)
- [Errors and exit codes](/docs/concepts/errors)
