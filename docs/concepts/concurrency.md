---
title: Concurrency
description: One JS thread, a shared I/O pool, and up to 8 Workers — which primitive to reach for.
order: 2
---

# Concurrency

Fairyfly gives you three layers. Picking the wrong one is the usual cause
of a server that "gets stuck".

| Layer | Runs on | Use for | Limit |
|---|---|---|---|
| **JS event loop** | one thread | everything you write | see [Event loop](/docs/concepts/event-loop) |
| **Background I/O** | internal threads | `fetch`, Postgres, TLS, `fs.*Async`, `ffi` calls | per-subsystem pools below — not one shared pool |
| **Workers** | up to 8 OS threads | CPU-bound JS | **8** workers, 32 MB heap each, 4 MB per message |

There is no single "4-thread pool" doing everything. Each subsystem owns its threads:

| Subsystem | Threads | Cap / notes |
|---|---|---|
| Event-loop pool (`libxev`) | 4 | general loop work |
| `fs.*Async` | own 4-thread pool + 16 job slots | a 17th concurrent job waits |
| `ffi` | own 4-thread pool | each native call parks a pool thread while it runs |
| `fetch` | 16 dedicated threads (1 MB stack each) | one thread per slot — a 16-way fan-out truly runs in parallel |
| Postgres / TLS | none | event-driven on the loop thread; no helper threads |
| `Worker` | 8 OS threads (8 MB stack each) | one JS runtime + 32 MB heap each; 4 MB per message |

JavaScript itself never runs in parallel with other JavaScript. Two JS
sections execute one after the other, always.

## Decision table

| You need to… | Do this | Not this |
|---|---|---|
| Call other APIs | `await fetch(...)` | blocking the loop |
| Query Postgres / SQLite | `await sql\`…\`` / `db.row()` | spinning up a thread |
| Read/write files in a server | `await fs.readFileAsync(...)` | `fs.readFile(...)` |
| Hash, compress, parse a huge payload | `new Worker(...)` | a tight loop in the handler |
| Run 5 requests at once | `Promise.all([...])` | sequential `await`s |

## Example: parallel fan-out

```js
// fanout.js — ff fanout.js
const urls = [
  "https://example.com/",
  "https://example.org/",
  "https://example.net/",
];

const started = performance.now();
const results = await Promise.all(urls.map((u) => fetch(u)));
console.log(`${results.length} responses in ${(performance.now() - started).toFixed(1)}ms`);
console.log(results.map((r) => r.status).join(", "));
```

All three requests are in flight at once — each `fetch` slot has its **own
thread**, so a fan-out like this costs one loop, not three.

> Top-level `await` works in files (modules). It does **not** work in
> `ff -e '...'`, which is evaluated as a script — wrap it in an async IIFE
> there, or put the code in a file.

## Example: non-blocking file I/O in a handler

```js
// The async variants return Promises and run on the background pool.
http.serve({ port: 3000 }, async (url) => {
  const body = await fs.readFileAsync("index.html", "utf8");
  return new Response(body, { headers: { "content-type": "text/html" } });
});
```

Sync calls block the loop thread — fine for a CLI, wrong inside a server:

```js
// Blocks every other connection while it runs:
const body = fs.readFile("index.html");
```

## Example: CPU-bound work → Worker

```js
// main.js
const w = new Worker("./hash-worker.js", { data: { rounds: 1e6 } });
w.onmessage = (e) => console.log("hash:", e.data.hex);
w.onerror = (e) => console.error("failed:", e.message);
w.postMessage({ password: "hunter2" });
```

Workers have their **own** JS runtime and event loop. They share no state
and talk only by messages (structured clone). The worker scope has
`console`, timers, `postMessage`, `workerData`, and `performance` — no
`fs`, no `fetch`, no `http.serve`.

## Limits worth memorising

| Resource | Cap |
|---|---|
| Concurrent `fetch` | 16 slots, one thread each |
| Concurrent HTTP connections | 512 |
| Loop / fs / ffi pools | 4 threads each (separate pools) |
| Concurrent `fs.*Async` jobs | 16 |
| Workers | 8 |
| Worker message | 4 MB |
| Live timers | 128 |

## Gotchas

- `Promise.all` fails fast — one rejection rejects the whole batch. Use
  `Promise.allSettled` when every result matters.
- Sync `fs`, a long `while` loop, or a big synchronous parse delays every
  pending timer and connection.
- Workers never exit on their own; the process waits for `terminate()`.
- Worker files are **classic scripts** — `import`/`export` inside a worker
  throws.

## See also

- [Event loop](/docs/concepts/event-loop)
- [Workers](/docs/guides/workers) · [API: Worker](/docs/api/worker)
- [API: fs](/docs/api/fs) — sync vs `*Async`
- [Limitations](/docs/reference/limitations)
