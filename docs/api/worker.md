---
title: Worker
description: The Worker API — postMessage, terminate, workerData, events, and the message contract.
order: 15
---

# `Worker`

CPU-bound JavaScript on up to **8** OS threads. Each Worker gets its own
JS runtime, event loop, and heap (**32 MB**) — no shared state, only
messages.

```js
const w = new Worker("./hash-worker.js", { data: { rounds: 1e6 } });
w.onmessage = (ev) => console.log("hash:", ev.data.hex);
w.onerror = (ev) => console.error("failed:", ev.message);
w.postMessage({ password: "hunter2" });
```

## Constructor

| | |
|---|---|
| Signature | `new Worker(path, options?)` |
| `path` | Path to a JS file, resolved from the process **cwd**; `.js` is appended when the literal path doesn't exist |
| `options.data` | Any structured-cloneable value → `workerData` in the worker |

`options` has exactly one meaningful key, `data`. There is no `type` option:
a worker file is always evaluated as a **classic script**.

Throws a `TypeError` for:

| Situation | Message |
|---|---|
| No argument | `Worker requires a module path` |
| File not found | `Worker module not found` |
| All 8 slots busy | `too many workers (max 8)` |
| `data` can't be cloned | `value could not be cloned` |

> The parameter is *named* "module path", but the file is evaluated as a
> **classic script** (`EVAL_TYPE_GLOBAL`) — `import` / `export` inside a
> worker file is a `SyntaxError`. Wrap shared code by copying it, or load
> it in the main thread.
>
> Path resolution: `"./w.js"` and `"./w"` both work (the `.js` is appended
> if the given path doesn't exist). Paths are relative to the **cwd**, not
> the spawning script. The file itself is capped at **10 MB**.

## Parent side

### Methods

| Method | Signature | Notes |
|---|---|---|
| `postMessage(value)` | `(any) → void` | Structured clone; max **4 MB** per message |
| `terminate()` | `() → void` | Kills the thread; idempotent |

`postMessage` throws a `TypeError` (`value could not be cloned`) if the
value can't be cloned, and a `TypeError: postMessage requires an argument`
when called with no value. On a **terminated** worker it throws an
`InternalError` (`postMessage on terminated Worker`).

### Handlers

```js
w.onmessage = (ev) => { /* ev.data   — cloned value from the worker */ };
w.onerror   = (ev) => { /* ev.message — uncaught error inside the worker */ };
```

Both are plain properties on the Worker object — assigning twice replaces
the first, and neither is defined until you assign it. Messages/errors
received with no handler installed are dropped (errors are also printed to
stderr as `[worker] unhandled error: …`).

```js
w.onerror = (ev) => {
  console.error("worker crashed:", ev.message);
  w.terminate();
};
```

## Worker side

Globals available inside the worker file:

| Global | Description |
|---|---|
| `workerData` | Structured clone of `options.data`, or `undefined` |
| `postMessage(value)` | Send to the parent (max 4 MB) |
| `onmessage` | `(ev) => void` — `ev.data` from the parent |
| `self` | The worker global object |
| `console` | Same `console`, same stderr |
| `setTimeout(fn, ms?, ...args)` / `setInterval` | Timers; numeric IDs |
| `clearTimeout(id)` / `clearInterval(id)` | Cancel by numeric ID |
| `queueMicrotask(fn)` | Standard microtask scheduling |
| `performance.now()` | Milliseconds; **own** origin |

Timer rules: at most **128** timers per worker (beyond that
`setTimeout`/`setInterval` throw `too many timers (max 128)`), and at most
**8** extra callback arguments (`setTimeout accepts at most 8 callback
arguments`). A negative delay is treated as `0`.

Not available: `fetch`, `fs`, `http`, `Database`, `sql`, `process`,
`Worker` (no nested workers), `import`. There is **no** worker-side
`close()` — the parent owns the lifecycle via `terminate()`.

Also absent: **`MessageChannel` / `MessagePort`** and
**`SharedArrayBuffer`**. The only channel is `postMessage`/`onmessage`.

```js
// hash-worker.js
const rounds = workerData.rounds;

onmessage = (ev) => {
  const t0 = performance.now();
  let h = 0;
  for (let i = 0; i < rounds; i++) h = (h * 31 + ev.data.password.charCodeAt(i % ev.data.password.length)) | 0;
  postMessage({ hex: (h >>> 0).toString(16), ms: performance.now() - t0 });
};
```

## Message contract

Values are **structured-cloned** across the boundary (the engine's binary
object format, with reference support so cyclic graphs survive).

| Cloneable | Not cloneable (`value could not be cloned`) |
|---|---|
| `null`, `undefined`, numbers, strings, booleans, `bigint` | functions |
| `Array`, plain objects | `WeakMap` / `WeakSet` |
| `Date`, `RegExp`, boxed primitives | `Promise` |
| `Map`, `Set` | symbols (outside the registry) |
| `ArrayBuffer`, typed arrays | properties with getters/setters |
| `Error` (revived as a real `Error`, subclass and `message`/`stack` kept) | runtime-specific objects (e.g. `Blob`) |
| cyclic graphs (cycles are fine) | |

Class instances are cloned as **plain objects** (methods and prototype are
lost) — the same as browser `structuredClone`. Cloning **copies**: the
receiver gets a snapshot, not a reference, so mutations after
`postMessage` do not propagate. `ArrayBuffer`s are copied, not transferred.

## Limits

| Resource | Cap |
|---|---|
| Concurrent workers | 8 (the 9th throws) |
| Per-message size | 4 MB |
| Worker JS heap | 32 MB |
| Worker JS stack | 1 MB |
| Worker OS thread stack | 8 MB |
| Worker module file | 10 MB |
| Timers per worker | 128 |

```js
try {
  w.postMessage(() => {});            // TypeError: value could not be cloned
} catch (e) {
  console.error(e.message);
}
```

## Pattern: worker pool

```js
const pool = Array.from({ length: 4 }, (_, i) => {
  const w = new Worker("./job-worker.js", { data: { id: i } });
  w.onmessage = (ev) => dispatch(ev.data);
  return w;
});

let next = 0;
function submit(job) {
  pool[next % pool.length].postMessage(job);
  next++;
}
```

Eight is the ceiling — beyond that, queue in JS and keep 8 warm.

## Lifecycle

```js
const w = new Worker("./job.js");
w.postMessage("go");
// … when the job queue drains:
w.terminate();
```

- A healthy worker **never exits on its own** — even an empty script keeps
  its thread parked in the event loop. The main process stays alive while
  any worker is unterminated (`liveCount() > 0` keeps the loop running).
- `terminate()` is immediate and idempotent; pending `postMessage`s in
  flight are lost. It closes the channel and reaps (joins) the thread.
- An error thrown inside the worker's `onmessage` handler is caught, sent
  to the parent's `onerror`, and the worker keeps running.
- An **uncaught top-level error** (the worker file itself throws, or the
  file can't be read) is sent to the parent's `onerror` and **ends that
  worker's evaluation** — it stops processing further messages but still
  occupies its slot until you `terminate()` it.

## Gotchas

- Worker files are **classic scripts** — no `import`/`export`, no
  top-level `await`.
- No shared memory: there is no `SharedArrayBuffer`, and no
  `MessageChannel`/`MessagePort` — messages are the only contract.
- `structuredClone` is not a global; message passing *is* your clone.
- 4 MB messages are expensive — send indices, not payloads.
- `console` in a worker writes to the **same stderr** — prefix it
  (`console.log("[w" + workerData.id + "]")`).
- Worker paths resolve from the **cwd**, not the spawning script — use an
  absolute path or a path relative to where you launch `ff`.

## See also

- [Workers guide](/docs/guides/workers)
- [Concurrency](/docs/concepts/concurrency) — when a Worker is the wrong tool
- [Event loop](/docs/concepts/event-loop) — main-thread liveness
- [Limitations](/docs/reference/limitations)
