---
title: Event loop
description: One thread, one loop — how timers, microtasks and I/O completions are ordered, and what keeps the process alive.
order: 1
---

# Event loop

Every Fairyfly script runs on **one OS thread**. Concurrency does not come
from threads — it comes from the loop: when your synchronous JS finishes,
the runtime dispatches pending timers, I/O completions, and microtasks, and
repeats until there is nothing left to do.

The loop is built on [libxev](https://github.com/mitchellh/libxev): kqueue
on macOS, io_uring or epoll on Linux (see
[Installation](/docs/getting-started/installation)).

## One turn of the loop

From `src/event/loop.zig` (`runWithMicrotasks`), in order:

1. **Block for completions** if referenced work is armed (a timer, socket,
   fetch, query…). If only queued submissions remain, drain them *without*
   blocking — that's what lets an `unref()`'d timer stop holding the process.
2. **Drain subsystems** in a fixed order: fetch → WebSocket client → FFI →
   async `fs` → workers. Each drain settles Promises on the JS thread.
3. **Pump microtasks** — every `queueMicrotask` callback queued this turn.
4. **GC check** every 8192 turns, and only when the heap exceeds 8 MB.
5. **Exit or sleep**: if nothing relevant is pending, the loop stops and the
   process exits. If it's idle, it sleeps 100 µs doubling up to 8 ms.

## Ordering guarantees

Timers and microtasks are ordered, and you can rely on it:

```js
// order.js — ff order.js
console.log("1: sync");

queueMicrotask(() => console.log("3: microtask"));

setTimeout(() => console.log("4: timer 0ms"), 0);
setTimeout(() => console.log("5: timer 20ms"), 20);

console.log("2: sync");
```

```
1: sync
2: sync
3: microtask
4: timer 0ms
5: timer 20ms
```

Rules that fall out of this:

- All synchronous code runs first — always.
- Microtasks run before the next timer or I/O callback.
- `setTimeout(fn, 0)` runs on the **next loop turn**, which makes it the
  equivalent of Node's `setImmediate`.
- Negative delays are clamped to `0`; they defer, they never drop.

## What keeps the process alive

Each turn, the loop asks whether any *relevant* work remains
(`hasRelevantWork`). It keeps running while any of these is true:

| Pending work | Where it comes from |
|---|---|
| Armed work in the loop | referenced timers, TCP/UDP sockets, and other armed completions |
| A **referenced** timer armed | `setTimeout` / `setInterval` |
| An `http.serve` listener running | any active server |
| A `fetch` in flight | outbound HTTP (16-slot pool) |
| A WebSocket client connection in flight | `new WebSocket(...)` |
| A Postgres query in flight | `sql` / `SQL` |
| An FFI job in flight | `ffi` `nonblocking` calls **and** foreign-thread callbacks waiting on the bridge |
| An async `fs` job in flight | `fs.readFileAsync()` etc. — and Known issue: a *completed* job still pins the process, which then never exits (see [fs](/docs/api/fs)) |
| A live `Worker` | until `terminate()` |

Two subtleties from the source:

- The armed-work check is `loop.active − unref'd-timer-completions > 0`, so an
  unref'd timer's own submission cannot, by itself, hold the process open.
  Queued submissions/pending completions only count while **nothing** is
  unref'd — every other producer is already covered by a counter above.
- `unref()` never unschedules the timer. It only removes it from the
  liveness set. So an unref'd timer **still fires** if the loop outlives it
  (see below).

An **`unref()`'d timer does not hold the process**:

```js
// unref.js — exits immediately; "never runs" is never printed
const t = setTimeout(() => console.log("never runs"), 100);
t.unref();
```

```
$ ff unref.js
$ echo $?
0
```

That is the whole pattern for background housekeeping (polling, flushing)
in a CLI: arm it, `unref()` it, and let the script end. But if something
else keeps the loop alive past the timer's delay, the unref'd timer runs
anyway:

```js
// fires, because the 60 ms referenced timer holds the loop open
const u = setTimeout(() => console.log("unref fired"), 30);
u.unref();
setTimeout(() => console.log("ref fired"), 60);
// unref fired
// ref fired
```

## Async handlers park connections

Inside `http.serve`, an `async` handler is suspended — not blocking the
thread — until its Promise settles:

```js
http.serve({ port: 3000 }, async (url, method, body) => {
  const res = await fetch("https://example.com/api");
  return Response.json({ proxy: await res.json() });
});
```

While the Promise is pending, other connections keep flowing. If it never
settles, the watchdog reaps the request with **`504` after 30 s**. A thrown
error or rejected Promise becomes a **`500`**.

## When the process exits

| Situation | Result |
|---|---|
| Nothing relevant pending | exit `0` |
| Uncaught throw / uncaught script error | stack to **stderr**, exit `1` |
| Unhandled promise rejection | silent, exit `0` — unless the throw is a top-level module throw, which is reported |
| `process.exit(n)` | exit code clamped to `0–255` |
| Event-loop backend failure | `ff: event loop error: <name>`, exit `1` |
| io_uring selected but unavailable | `ff: I/O backend unavailable (…)`, exit `1` |

Details and more examples: [Errors and exit codes](/docs/concepts/errors).

## Gotchas

- There is **no `process.nextTick`** — use `queueMicrotask`.
- Sync `fs` calls block this thread. In a server, prefer
  [`fs.*Async`](/docs/api/fs) so a slow disk never stalls connections —
  but note the Known issue above: a successful `*Async` call still pins
  the process afterwards.
- An infinite JS loop hangs the process — there is no watchdog that can
  interrupt running JavaScript. See [Limitations](/docs/reference/limitations).
- `console` writes to **stderr**, so `ff app.js > out.txt` captures nothing.
- The loop wakes at most every 100 µs while idle; don't expect sub-100 µs
  timer precision.
- A top-level `await` rejection inside a module is *not* reported (the
  module promise settles after the synchronous check); only a top-level
  *throw* before any `await` is. Attach a `.catch`/`try` there.

## See also

- [Concurrency](/docs/concepts/concurrency) — loop vs Workers vs the I/O pool
- [Timers](/docs/guides/timers) — `unref`, `refresh`, limits
- [Errors and exit codes](/docs/concepts/errors)
- [Limitations](/docs/reference/limitations)
