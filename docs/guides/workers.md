---
title: Workers
description: Offload CPU-bound work to threads — spawn, message, handle errors, terminate.
order: 11
---

# Workers

The main thread runs a single event loop — perfect for I/O, bad for hashing, parsing, or number-crunching that blocks every request. `Worker` moves that work to OS threads, each with its own JS runtime and event loop. Max 8 workers per process.

## Quick look

Main (`main.js`) — spawn with data, send a job, print the reply:

```js
// main.js
const w = new Worker("./hash-worker.js", {
  data: { rounds: 100000 },
});

w.onmessage = (e) => console.log("result:", e.data);
w.onerror = (e) => console.error("worker failed:", e.message);

w.postMessage({ password: "hunter2", salt: "pepper" });
```

Worker (`hash-worker.js`) — read `workerData`, listen, reply:

```js
// hash-worker.js
const cfg = globalThis.workerData; // { rounds: 100000 }

onmessage = (e) => {
  const { password, salt } = e.data;
  let acc = password + salt;
  for (let i = 0; i < cfg.rounds; i++) acc = acc.split("").reverse().join("");
  postMessage({ ok: true, rounds: cfg.rounds });
};
```

```sh
ff main.js
# result: { ok: true, rounds: 100000 }
```

## Spawning: `new Worker(path, { data }?)`

```js
const w = new Worker("./worker.js");
const w2 = new Worker("./worker.js", { data: { id: 1 } });
```

| Argument | Description |
|----------|-------------|
| `path` | Worker module path, relative to the current script. Missing file throws `Worker module not found` |
| `options.data` | Initial payload, structured-cloned once, visible in the worker as `globalThis.workerData` |

> **Caution:** The option key is `data`, not `workerData`. `new Worker("./w.js", { workerData: … })` silently passes nothing — the worker must read `globalThis.workerData`, but the parent sends `{ data: … }`.

Parent-side API:

| Member | Description |
|--------|-------------|
| `w.postMessage(value)` | Send a structured-cloned value to the worker; throws on a terminated worker |
| `w.onmessage` | `(e) => …` — receives worker replies via `e.data` |
| `w.onerror` | `(e) => …` — receives worker errors via `e.message` |
| `w.terminate()` | Stop the worker, close the channel, reap the thread |

## Messaging both directions

Parent → worker via `w.postMessage`, worker → parent via global `postMessage`. Both sides receive via `onmessage` with the payload on `e.data`:

```js
// main.js
const w = new Worker("./echo-worker.js", { data: { tag: "A" } });
w.onmessage = (e) => console.log("parent got:", e.data);
w.postMessage("first");
w.postMessage("second");
```

```js
// echo-worker.js
console.log("worker tag:", globalThis.workerData.tag); // A
onmessage = (e) => postMessage(`echo: ${e.data}`);
```

```sh
ff main.js
# worker tag: A
# parent got: echo: first
# parent got: echo: second
```

Values cross the boundary by structured clone — each message is copied, never shared. Keep messages small and self-contained.

## Errors and shutdown

```js
// main.js
const w = new Worker("./risky-worker.js");
w.onerror = (e) => console.error("worker failed:", e.message);
w.onmessage = (e) => {
  console.log("done:", e.data);
  w.terminate(); // done — release the thread
};
w.postMessage("go");
```

Rules:

- Workers live until `terminate()`. There is no idle-exit — the process stays alive while any worker is unterminated.
- The process exits once all workers are terminated (and the main loop drains).
- Worker-side uncaught errors surface via the parent's `onerror` and print `[worker] unhandled error: …` diagnostics.
- `postMessage` after `terminate()` throws — guard or null out the handle.

## Practical example: non-blocking hash endpoint

Keep the HTTP loop free by hashing in a worker pool of one:

```js
// server.js
const w = new Worker("./hasher.js", { data: { rounds: 50000 } });
let pending = null;
w.onmessage = (e) => {
  const cb = pending;
  pending = null;
  if (cb) cb(e.data);
};
w.onerror = (e) => {
  const cb = pending;
  pending = null;
  if (cb) cb({ error: e.message });
};

http.serve({ port: 3000 }, (url, method, body) => {
  if (url === "/hash" && method === "POST") {
    const { password = "" } = JSON.parse(body || "{}");
    return new Promise((resolve) => {
      pending = (out) => resolve(Response.json(out));
      w.postMessage({ password });
    });
  }
  return new Response("POST /hash");
});
```

```js
// hasher.js
const cfg = globalThis.workerData;
onmessage = (e) => {
  let acc = e.data.password;
  for (let i = 0; i < cfg.rounds; i++) acc = acc.split("").reverse().join("");
  postMessage({ hex: acc.slice(0, 32), rounds: cfg.rounds });
};
```

```sh
ff server.js
curl -X POST http://127.0.0.1:3000/hash \
  -H "content-type: application/json" -d '{"password":"hunter2"}'
# {"hex":"...","rounds":50000}
```

The handler returns a `Promise`, so the connection parks while the worker crunches — other requests keep flowing.

## Reference

| Area | Limit / rule |
|------|--------------|
| Max workers | 8 — the 9th throws `too many workers (max 8)` |
| Worker scope | `console` + timers + `postMessage`/`onmessage`/`workerData` — no `http.serve` in workers, keep servers on the main thread |
| Nested workers | Not supported — spawning from inside a worker fails |
| Shutdown | Only via `terminate()`; process exits once all workers terminate |
| Module size | Worker file capped at 10MB on load |

## Troubleshooting

**`Worker module not found`** — the path is relative to the spawning script, and needs the extension (`"./hasher.js"`, not `"./hasher"`).

**`workerData` is undefined** — parent used the wrong key. Send `{ data: … }`, read `globalThis.workerData`.

**Process won't exit** — an unterminated worker is alive. Call `w.terminate()` for every spawned worker (or `process.exit()` to force it).

**`too many workers (max 8)`** — pool exhausted. Reuse workers across requests instead of spawning per request.

**UI still stalls with workers** — the job isn't actually offloaded (handler computes inline), or all 8 slots are busy and new spawns throw. Move the loop body into the worker file.
