---
title: performance
description: performance.now() — monotonic milliseconds, and nothing else.
order: 9
---

# `performance`

`performance` is a plain global object with **exactly one** property: `now`.
There is no `mark`, `measure`, `timeOrigin`, `getEntries`, or `navigation`.

```js
const t0 = performance.now();
// ... work ...
console.log(`took ${(performance.now() - t0).toFixed(2)}ms`);
```

## `performance.now()`

| | |
|---|---|
| Signature | `() → number` |
| Returns | Milliseconds since the origin (fractional) |
| Clock | **Monotonic** — never jumps backwards |
| Origin | Latched on the **first call in the current runtime** |
| First call | Exactly `0` |
| Arity | `performance.now.length === 0` |

```js
console.log(performance.now());   // 0        (origin latched here)
console.log(performance.now());   // 0.003584 (monotonic ms since then)
```

It reads the monotonic clock (`.awake` — `CLOCK_MONOTONIC` on Linux,
`UPTIME_RAW` on macOS), converts nanoseconds to milliseconds (divides by
`1e6`), and returns a `float64`. The origin is captured the first time the
function runs and reused forever after.

The origin is **per runtime**, and each runtime lives on one thread:

- The **main runtime** has a single origin: the first `performance.now()`
  call in your script latches it, and every later call on the main thread
  measures from there.
- A [Worker](/docs/guides/workers) runs on its **own thread with its own
  runtime**, so it has its **own** origin — the first `performance.now()`
  inside a worker returns `0`, independent of the main thread's clock.

## Timing patterns

### Measure a block

```js
const t0 = performance.now();
let sum = 0;
for (let i = 0; i < 1_000; i++) sum += i;
const ms = performance.now() - t0;
console.detail(`sum=${sum} in ${ms.toFixed(2)}ms`);
```

### Time a request end to end

```js
http.serve({ port: 3000 }, async (url) => {
  const t0 = performance.now();
  const res = await fetch("https://example.com/");
  console.log(`${url} → ${res.status} in ${(performance.now() - t0).toFixed(1)}ms`);
  return new Response(await res.text(), { headers: { "content-type": "text/html" } });
});
```

### Benchmark loop

```js
const N = 100_000;
const t0 = performance.now();
for (let i = 0; i < N; i++) JSON.stringify({ i });
const per = (performance.now() - t0) / N;
console.log(`${(per * 1e6).toFixed(0)}ns/op`);
```

## vs `console.time`

| | `performance.now()` | `console.time()` |
|---|---|---|
| Clock | monotonic | **wall clock** (NTP steps can skew it) |
| Resolution | sub-microsecond `float64` | integer ms |
| Output | none — you compute the delta | prints `label: Nms` |
| Label tracking | none | named timers, warnings on unknown labels |

Use `performance.now()` for measurements; use
[`console.time`](/docs/api/console#timers) for human-visible timings in logs.

## Gotchas

- The origin is the **first call in a runtime**, not process start —
  anything before that first call is invisible. Call it once at boot if you
  need a stable baseline.
- It's a float: round before printing (`toFixed`) to avoid
  `0.041000000000000002` noise.
- Sub-millisecond values are real but coarse — single samples are noise;
  average over iterations.
- Each [Worker](/docs/guides/workers) has its **own** origin (thread-local),
  so its first `performance.now()` returns `0` — you cannot compare a worker's
  timestamps against the main thread's.

## See also

- [Logging](/docs/guides/logging) — timing in logs
- [Timers](/docs/guides/timers) — scheduling, not measuring
- [Event loop](/docs/concepts/event-loop)
