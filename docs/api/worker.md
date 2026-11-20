---
title: Worker
description: The Worker API — postMessage, terminate, workerData, events, and the message contract.
order: 15
---

# `Worker`

CPU-bound JavaScript on up to **8** OS threads. Each Worker has its own
JS runtime, event loop, and isolated heap (**32 MB** default, configurable via `--worker-heap`) — no shared state, only messages.

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
| `path` | Path to a JS file, resolved from `process.cwd()` (auto-probes `<path>.js` if omitted) |
| `options.data` | Any **structured-cloneable** value → `workerData` in the worker |

Throws `TypeError: Worker requires a module path` with no argument.
`options.data` that cannot be cloned throws `value could not be cloned`.

> The parameter is *named* "module path", but the file is evaluated as a
> **classic script** (`EVAL_TYPE_GLOBAL`) — `import` / `export` inside a
> worker file is a `SyntaxError`. Wrap shared code by copying it, or load
> it in the main thread.

## Parent side

### Methods

| Method | Signature | Notes |
|---|---|---|
| `postMessage(value)` | `(any) → void` | Structured clone; max **4 MB** per message |
| `terminate()` | `() → void` | Kills the thread; no further events fire |

### Handlers

```js
w.onmessage = (ev) => { /* ev.data — cloned value from the worker */ };
w.onerror   = (ev) => { /* ev.message — uncaught error inside the worker */ };
```

Both are single-valued properties — assigning twice replaces the first.

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
| `workerData` | Structured clone of the `options.data` you passed |
| `postMessage(value)` | Send to the parent |
| `onmessage` | `(ev) => void` — `ev.data` from the parent |
| `self` | The worker global object |
| `console` | Same `console` as the parent, same stderr |
| `setTimeout` / `setInterval` / clear\* | Timers return numeric IDs (`0..127`; no `.ref()`/`.unref()`/`AbortSignal`) |
| `queueMicrotask` | |
| `structuredClone` | Deep binary structured clone (max 4 MB) |
| `crypto`, `btoa`, `atob` | `randomUUID`, `getRandomValues`, `subtle` (`digest`, HMAC `importKey`/`sign`/`verify`/`exportKey`), and Base64 helpers (`crypto.bcrypt` throws) |
| `performance` | `performance.now()` — **own** origin |

Not available: `fetch`, `fs`, `http`, `Database`, `sql`, `process`, `crypto.bcrypt`, `import`, `TextEncoder`/`TextDecoder`, `URL`/`URLSearchParams`, `Headers`/`Request`/`Response`, `Blob`/`FormData`, `ReadableStream`, `AbortController`/`AbortSignal`, `WebSocket`, `tcp`, `udp`, `ff`, `child_process`, `ffi`, `permissions`, `Worker`.

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

Values are **structured-cloned** across the boundary:

| Cloneable | Not cloneable (throws `TypeError: value could not be cloned`) |
|---|---|
| primitives, `null`, `undefined`, `BigInt`, boxed primitives | functions, `Promise` |
| `Date`, `RegExp`, `Error` (subclasses + stack preserved) | `WeakMap` / `WeakSet`, non-registered `Symbol` |
| `Array`, plain objects (incl. class instances as plain objects, methods lost) | objects with getter/setter accessors, `SharedArrayBuffer` |
| cyclic object graphs, `Map`, `Set`, `ArrayBuffer`, `TypedArray`, `DataView` | native objects (`Blob`, `Headers`, `Request`, `Response`, `URL`, `FormData`, `ReadableStream`, `AbortSignal`, `CryptoKey`, `FfiPtr`, etc.) |

Cloning copies: the receiver gets a snapshot, not a reference. Mutations
after `postMessage` do not propagate.

## Limits

| Resource | Cap |
|---|---|
| Concurrent workers | 8 |
| Script file cap | 10 MiB |
| Per-message size | 4 MB |
| Worker heap | `min(32 MB, max-heap)` default, configurable via `--worker-heap` (`1 MB`–`max-heap`) |
| Worker JS stack / native stack | JS stack inherits `--max-stack` (`1 MB` default, `128 KB`–`native/2`); OS thread stack auto-scales `>= max(8 MB, 2 * JS stack)` |
| CPU budget | Inherits `--cpu-budget=<ms>` (enforced on top-level eval and `onmessage`) |
| Worker threads | Dedicated OS threads, not the main loop's I/O pool |

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

- A worker with an idle loop (timers/handlers) or a live slot **does not auto-release** — call `w.terminate()` when finished so the main process exits and the slot frees.
- `terminate()` is immediate; pending `postMessage`s in flight are lost.
- An uncaught throw during **top-level script evaluation** fires `onerror` on the parent and terminates the worker thread immediately (the parent still holds the worker slot open until `w.terminate()` is called). Uncaught errors inside `onmessage`, timer callbacks, or microtasks also fire `onerror` on the parent, while leaving the worker thread running until `terminate()`.

## Gotchas

- Worker files are **classic scripts** — no `import`/`export`, no
  top-level `await`.
- No shared memory: `SharedArrayBuffer` exists as a global but Workers
  don't share one — messages are the contract.
- `structuredClone(value)` uses the same binary serializer (max 4 MB) on both
  the main thread and inside Workers.
- 4 MB messages are expensive — send indices, not payloads.
- `console` in a worker writes to the **same stderr** — prefix it
  (`console.log("[w" + workerData.id + "]")`).

## See also

- [Workers guide](/docs/guides/workers)
- [Concurrency](/docs/concepts/concurrency) — when a Worker is the wrong tool
- [Event loop](/docs/concepts/event-loop) — main-thread liveness
- [Limitations](/docs/reference/limitations)
