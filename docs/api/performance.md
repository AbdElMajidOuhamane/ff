---
title: performance
description: performance.now() — monotonic milliseconds, and nothing else.
order: 9
---

# `performance`

One method:

```js
const t0 = performance.now();
await doWork();
console.log(`took ${(performance.now() - t0).toFixed(2)}ms`);
```

## `performance.now()`

| | |
|---|---|
| Signature | `() → number` |
| Returns | Milliseconds (fractional) |
| Clock | **Monotonic** — never jumps backwards |
| Origin | The **first call in the process** |
| First call | Exactly `0` |

```js
console.log(performance.now());   // 0        (origin latched here)
console.log(performance.now());   // 0.041…
```

It reads the monotonic clock (`.awake` — `CLOCK_MONOTONIC` /
`UPTIME_RAW`), latches the origin on first use, and divides nanoseconds by
`1e6`. Only `performance.now` exists — there are no `mark`, `measure`,
`timeOrigin`, or `navigation` members.

## Timing patterns

### Measure a block

```js
const t0 = performance.now();
const rows = db.rows("SELECT * FROM todos");
const ms = performance.now() - t0;
console.detail(`query: ${ms.toFixed(1)}ms (${rows.length} rows)`);
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
| Resolution | sub-microsecond float | integer ms |
| Output | none — you compute the delta | prints `label: Nms` |
| Label tracking | none | named timers, warnings on unknown labels |

Use `performance.now()` for measurements; use `console.time` for
human-visible timings in logs.

## Gotchas

- The origin is the **first call**, not process start — anything before
  your first `performance.now()` is invisible. Call it once at boot if you
  need a stable baseline.
- It's a float: compare and print with rounding (`toFixed`) to avoid
  `0.041000000000000002` noise.
- Sub-millisecond values are real but coarse — single samples are noise;
  average over iterations.
- In Workers each runtime has its **own** origin.

## See also

- [Logging](/docs/guides/logging) — timing in logs
- [Timers](/docs/guides/timers) — scheduling, not measuring
- [Event loop](/docs/concepts/event-loop)
