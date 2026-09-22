---
title: Timers
description: Run code later — setTimeout, setInterval, unref, microtasks, and limits.
order: 5
---

# Timers

Timers run a function after a delay or on repeat — debouncing, polling, timeouts, sleeping inside handlers. While a timer waits, the event loop serves other requests; no thread is blocked.

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

`setTimeout(fn, ms)` runs `fn` after *at least* `ms` milliseconds. Both timers schedule before either fires, so the 50ms one wins despite registering second. `console.log("end")` runs first because timers never block.

## Cancel a timer

```js
const t = setTimeout(() => console.log("never prints"), 20);
clearTimeout(t);
console.log("cancelled");
# cancelled
```

`setTimeout` returns a numeric id; `clearTimeout(id)` cancels it. Clearing an unknown or expired id is a safe no-op — it never throws. Same pair for intervals: `setInterval` / `clearInterval`.

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

> **Caution:** Always clear intervals you no longer need — a live interval keeps the event loop alive and the process never exits.

## Delay inside async code

```js
await new Promise((resolve) => setTimeout(resolve, 10));
console.log("10ms later");
```

The standard sleep pattern. It yields to the event loop, so other connections are served during the wait — use it freely inside async HTTP handlers.

Extra arguments pass through (up to 8 after `ms`):

```js
setTimeout((a, b) => console.log(a, b), 10, "hello", 42);
# hello 42
```

## Zero-delay yield

```js
setTimeout(() => console.log("next tick"), 0);
console.log("now");
# now
# next tick
```

`setTimeout(fn, 0)` yields to the event loop's next iteration (the `setImmediate` role in Node). Negative delays behave the same as 0.

## Microtasks vs timers

```js
queueMicrotask(() => console.log("microtask"));
setTimeout(() => console.log("timer"), 0);
console.log("sync");
# sync
# microtask
# timer
```

Microtasks drain before timers. Use `queueMicrotask` for work that must run before the next timer or I/O event — it is also the replacement for the missing `process.nextTick`.

## Unref: let the process exit

```js
const t = setTimeout(() => console.log("late"), 5000);
t.unref();
console.log("exits immediately");
# exits immediately
```

`setTimeout`/`setInterval` return a `Timeout` object (usable as a numeric id too). `t.unref()` keeps the timer armed but lets the process exit without waiting; `t.ref()` re-arms the hold; `t.hasRef()` reports the state; `t.refresh()` restarts the countdown. Use `unref` for background housekeeping that must not keep a CLI alive.

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

Unhealthy stretches back off to 5s; the `.unref()` means `Ctrl-C`… actually `process.exit` aside, the process can still end when nothing else holds the loop.

## Reference

| API | Description |
|-----|-------------|
| `setTimeout(fn, ms, ...args≤8)` | Run once; returns `Timeout` (numeric-compatible) |
| `clearTimeout(id)` | Cancel; unknown/expired ids are no-ops |
| `setInterval(fn, ms, ...args≤8)` | Repeat; returns `Timeout` |
| `clearInterval(id)` | Stop repeating |
| `t.unref()` / `t.ref()` / `t.hasRef()` / `t.refresh()` | Exit-hold control on the handle |
| `queueMicrotask(fn)` | Run before next timer/I/O; the `nextTick` replacement |

Limits: max 128 live timers (the 129th throws `TypeError: too many timers`), max 8 extra args, negative delay → 0. When no server, work, or referenced timers remain, the loop exits on its own.

## Troubleshooting

**Process never exits** — a live interval or referenced timer holds the loop. `clearInterval` what you own, or `unref` housekeeping timers.

**`too many timers`** — over 128 live. You leak `setInterval`s or schedule per-request timers without clearing; reuse or debounce.

**Timer fires late under load** — delays are *minimums*. A blocked loop (CPU-heavy handler, 512 full connections) delays everything; move work to `Worker`s.
