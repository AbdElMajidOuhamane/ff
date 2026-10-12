---
title: Timers
description: Run code later — setTimeout, setInterval, unref, microtasks, and limits.
order: 5
---

# Timers

Timers run a function after a delay or on repeat — debouncing, polling,
timeouts, sleeping inside handlers. While a timer waits, the event loop
serves other requests; no thread is blocked.

## Quick look

```js
// timer.js
console.log("start");

setTimeout(() => console.log("after 100ms"), 100);
setTimeout(() => console.log("after 50ms"), 50);

console.log("end (synchronous)");
```

```sh
ff timer.js
# start
# end (synchronous)
# after 50ms
# after 100ms
```

`setTimeout(fn, ms)` runs `fn` after *at least* `ms` milliseconds. Both
timers schedule before either fires, so the 50 ms one wins despite
registering second. `console.log("end")` runs first because timers never
block.

## The `Timeout` handle

`setTimeout` / `setInterval` return a **`Timeout` object**. It can be
passed straight to `clearTimeout` / `clearInterval`:

```js
const t = setTimeout(() => console.log("never prints"), 20);
clearTimeout(t);
console.log("cancelled");
```

```
cancelled
```

`clearTimeout` and `clearInterval` also accept a **bare numeric id**
(which is all a worker runtime ever returns — worker timers have no
`Timeout` class). Clearing an unknown, expired, or out-of-range id is a
safe no-op — it never throws.

| Method | Returns | Effect |
|---|---|---|
| `t.unref()` | `t` | Stop holding the process open (timer still fires if the loop outlives it) |
| `t.ref()` | `t` | Undo `unref()` — hold the process open again |
| `t.hasRef()` | `boolean` | Current hold state |
| `t.refresh()` | `t` | Restart the countdown from the original delay |

`unref`/`ref`/`refresh` are chainable (they return the same handle).

## Repeat on an interval

```js
// tick.js
let count = 0;

const iv = setInterval(() => {
  count += 1;
  console.log("tick", count);
}, 20);

setTimeout(() => {
  clearInterval(iv);
  console.log("stopped after", count, "ticks");
}, 90);
```

```sh
ff tick.js
# tick 1 … tick 4, then: stopped after 4 ticks
```

> **Caution:** Always clear intervals you no longer need — a live interval
> is *referenced* and keeps the event loop alive, so the process never
> exits.

## Delay inside async code

```js
// sleep.mjs — top-level await needs a module (or use the IIFE below)
await new Promise((resolve) => setTimeout(resolve, 10));
console.log("10ms later");
```

In a plain `.js` classic script (no `import`/`export`) top-level `await`
is a syntax error — wrap it:

```js
// sleep.js
(async () => {
  await new Promise((resolve) => setTimeout(resolve, 10));
  console.log("10ms later");
})();
```

The standard sleep pattern. It yields to the event loop, so other
connections are served during the wait — use it freely inside async HTTP
handlers.

Extra arguments pass through (up to 8 after `ms`):

```js
setTimeout((a, b) => console.log(a, b), 10, "hello", 42);
```

```
hello 42
```

A **9th** extra argument throws
`TypeError: setTimeout accepts at most 8 callback arguments` (the same
limit and message apply to `setInterval`).

## Delay handling

- The delay is `ToInt64(argv[1])`, so fractional delays truncate:
  `setTimeout(fn, 1.9)` waits 1 ms.
- A **negative** delay is clamped to `0` — it defers, it never drops.
- Only the first argument must be a function: a non-function (for either
  `setTimeout` or `setInterval`) throws
  `TypeError: setTimeout requires a function as first argument`.

## Zero-delay yield

```js
setTimeout(() => console.log("next tick"), 0);
console.log("now");
```

```
now
next tick
```

`setTimeout(fn, 0)` yields to the event loop's next iteration (the
`setImmediate` role in Node). Negative delays behave the same as `0`.

## Microtasks vs timers

```js
queueMicrotask(() => console.log("microtask"));
setTimeout(() => console.log("timer"), 0);
console.log("sync");
```

```
sync
microtask
timer
```

Microtasks drain before timers. `queueMicrotask(fn)` requires a function
(`TypeError: queueMicrotask requires a function argument`); a throw inside
the callback is reported as `queueMicrotask error: <message>`. It is also
the replacement for the missing `process.nextTick`.

## Unref: let the process exit

```js
const t = setTimeout(() => console.log("late"), 5000);
t.unref();
console.log("exits immediately");
```

```
exits immediately
```

`unref()` keeps the timer **armed and scheduled** but subtracts it from
the loop's liveness check, so the process can exit without waiting. If the
loop happens to outlive the timer (another referenced timer, a server, an
in-flight request), the unref'd timer still **fires normally**:

```js
const u = setTimeout(() => console.log("unref fired"), 30);
u.unref();
setTimeout(() => console.log("ref fired"), 60);   // holds the loop open
```

```
unref fired
ref fired
```

Use `unref` for background housekeeping that must not keep a CLI alive.

## Practical example: polling with backoff

```js
// poll.js
let delay = 100;

function poll() {
  fetch("https://api.example.com/health")
    .then((r) => {
      console.log("up:", r.ok);
      delay = 100;
    })
    .catch(() => {
      delay = Math.min(delay * 2, 5000);
      console.log("down, retry in", delay);
    })
    .finally(() => {
      setTimeout(poll, delay).unref();
    });
}

poll();
```

Unhealthy stretches back off to 5 s; the `.unref()` keeps the reschedule
timer from holding the process open, so once the in-flight fetch settles
and nothing else holds the loop, the process ends on its own instead of
waiting out the delay.

## Reference

| API | Description |
|-----|-------------|
| `setTimeout(fn, ms, ...args≤8)` | Run once; returns a `Timeout` |
| `setInterval(fn, ms, ...args≤8)` | Repeat; returns a `Timeout` |
| `clearTimeout(t)` / `clearInterval(t)` | Cancel; accepts a `Timeout` or a numeric id; unknown/expired ids are no-ops |
| `t.unref()` / `t.ref()` / `t.refresh()` | `t` (chainable) |
| `t.hasRef()` | `boolean` |
| `queueMicrotask(fn)` | Run before next timer/I/O; the `nextTick` replacement |

Limits:

- Max **128 live timers** (shared across `setTimeout` and `setInterval`);
  the 129th throws `TypeError: too many timers (max 128)`.
- Max **8 extra callback arguments**; a 9th throws `TypeError`.
- Negative delay → `0`; fractional delay → truncated ms.

When no server, in-flight work, or referenced timers remain, the loop
exits on its own. See [Event loop](/docs/concepts/event-loop).

## Troubleshooting

**Process never exits** — a live interval or referenced timer holds the
loop. `clearInterval` what you own, or `unref` housekeeping timers.

**`too many timers`** — over 128 live. You leak `setInterval`s or schedule
per-request timers without clearing; reuse or debounce.

**Timer fires late under load** — delays are *minimums*. A blocked loop
(CPU-heavy handler, 512 full connections) delays everything; move work to
`Worker`s.

## See also

- [Event loop](/docs/concepts/event-loop) — ordering and liveness
- [Concurrency](/docs/concepts/concurrency) — Workers for CPU-bound work
- [Errors and exit codes](/docs/concepts/errors)
