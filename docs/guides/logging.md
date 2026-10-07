---
title: Logging
description: console in practice — levels, timing, stderr redirection, and a structured-log pattern.
order: 9
---

# Logging

Fairyfly ships one logging primitive: [`console`](/docs/api/console). This
page is about using it well.

## Redirecting output

All `console` output is **stderr**, which makes separation trivial:

```sh
ff server.js                 # logs on the terminal, app output too
ff server.js 2> server.log    # logs to file, terminal stays clean
ff server.js 2> >(tee server.log)   # both
```

There is no `process.stdout.write` and no other API that touches fd 1 —
**every log line lands on stderr**. For a shipper that insists on stdout,
merge at the shell:

```sh
ff server.js 2>&1 | collector
```

Otherwise treat `console` as your log sink and let the supervisor collect
**stderr** (Docker and systemd both capture it by default).

## Levels

Use the built-in colours as levels:

| Level | Method | Colour |
|---|---|---|
| debug | `console.debug` | plain |
| info | `console.log` / `console.info` | plain |
| success | `console.detail` | green |
| warn | `console.warn` / `console.slops` | yellow |
| error | `console.error` / `console.redbal` | red |

```js
console.debug("cache miss for", key);
console.log("listening on", port);
console.detail("migration complete");
console.warn("pool near capacity:", active, "/", max);
console.error("request failed:", err);
```

## Structured, single-line JSON

For machines, serialize one object per line — collectors (Vector,
Loki, CloudWatch) ingest that shape directly:

```js
function log(level, msg, fields = {}) {
  console.log(JSON.stringify({ ts: new Date().toISOString(), level, msg, ...fields }));
}

log("info", "server started", { port: 3000 });
log("error", "upstream failed", { url, status: 502 });
```

```
{"ts":"2026-10-07T11:20:31.412Z","level":"info","msg":"server started","port":3000}
```

## Timing requests

```js
http.serve({ port: 3000 }, async (url, method, body) => {
  const label = `${method} ${url}`;
  console.time(label);
  try {
    const rows = await sql`SELECT * FROM todos`;
    return Response.json(rows);
  } finally {
    console.timeEnd(label);     // GET /todos: 3ms
  }
});
```

For anything tighter than ~1 ms, use `performance.now()`:

```js
const t0 = performance.now();
await doWork();
console.detail(`took ${(performance.now() - t0).toFixed(2)}ms`);
```

## Logging errors without losing the stack

```js
try {
  await risky();
} catch (err) {
  console.error("risky failed:", err && err.stack ? err.stack : err);
  throw err;                       // rethrow so the handler returns 500
}
```

Inside an `http.serve` handler, an uncaught throw becomes a `500` — log
first, then rethrow.

## In a Worker

Workers have their own `console`, writing to the same stderr:

```js
// worker.js
console.detail("worker started", globalThis.workerData);
onmessage = (e) => {
  console.log("job:", e.data.id);
  postMessage({ ok: true });
};
```

## Gotchas

- `console.log({ a: 1 })` prints `[object Object]` — use `JSON.stringify`.
- ANSI colour codes survive redirection into files; strip them at the
  collector if your format requires it.
- Nothing flushes aggressively — if the process is killed, the last line
  in a pipe may be lost. For crash-only diagnostics, prefer writing to a
  file with `fs.writeFile`.
- There is no log-level filtering: every call prints. Gate noisy output
  yourself (`if (debug) console.debug(...)`).

## See also

- [`console` API](/docs/api/console)
- [HTTP Server](/docs/guides/http-server)
- [Deploy](/docs/guides/deploy)
- [Errors and exit codes](/docs/concepts/errors)
