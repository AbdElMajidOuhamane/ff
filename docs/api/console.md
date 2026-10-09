---
title: console
description: Output, colored aliases, and time/timeLog/timeEnd — every method and its quirks.
order: 8
---

# `console`

All output goes to **stderr**, every argument is printed (joined with a
space), and every method returns `undefined`.

```js
console.log("plain");
console.info("same as log");
console.debug("same as log");
console.warn("yellow");
console.error("red");
console.log("multiple", 1, true, null);   // multiple 1 true null
```

## Methods

| Method | Output | Notes |
|---|---|---|
| `console.log(...)` | plain | writes to stderr |
| `console.info(...)` | plain | alias of `log` |
| `console.debug(...)` | plain | alias of `log` |
| `console.warn(...)` | **yellow** | non-standard colouring |
| `console.error(...)` | **red** | non-standard colouring |
| `console.slops(...)` | **yellow** | alias of `warn` |
| `console.detail(...)` | **green** | success / detail line |
| `console.redbal(...)` | **red** | alias of `error` |
| `console.time(label)` | — | start or restart a named timer |
| `console.timeLog(label)` | `label: Nms` | read elapsed without stopping |
| `console.timeEnd(label)` | `label: Nms` | read elapsed and remove the label |

## Timers

```js
// timing.js — ff timing.js
console.time("db-query");
// ... work ...
console.timeLog("db-query");   // db-query: 1ms

// ... more work ...
console.timeEnd("db-query");   // db-query: 12ms (timer removed)
```

Output is **integer milliseconds** measured on the wall clock
(`CLOCK_REALTIME`), printed as `label: 12ms`.

Unknown labels warn instead of throwing:

```js
console.timeEnd("never-started");
// warning: unknown timer 'never-started'
```

Calling `timeEnd` twice warns — the label is removed once ended.
`timeLog` may be called repeatedly while the timer runs.

## Everything goes to stderr

```sh
$ ff app.js            # logs appear on the terminal
$ ff app.js 2>/dev/null # nothing — that's stderr being discarded
$ ff app.js > out.txt   # out.txt is empty
$ ff app.js 2> out.txt  # out.txt has the logs
```

That's deliberate: stdout stays clean for program output (JSON you pipe to
`jq`, a generated file listing), while diagnostics stay visible in a
terminal.

## Arguments

Every argument is printed, converted with standard `toString` semantics:

```js
console.log("count:", 3, { ok: true });
// count: 3 [object Object]

console.log({ ok: true });     // objects do NOT pretty-print
console.log(JSON.stringify({ ok: true }, null, 2));  // use this instead
```

- Objects print as `[object Object]` — serialize explicitly if you want
  structure.
- A single line is buffered up to **4096 bytes**; longer lines flush in
  chunks, so a huge argument still prints in full.
- `console.log.length` is `2` and `console.time.length` is `1` — the arity
  QuickJS reports. Don't rely on it.

## Gotchas

- **stderr, not stdout.** `console.log > file` captures nothing.
- No `console.table`, `console.trace`, `console.assert`, `console.count` —
  they're not defined; calling them throws `TypeError`.
- Colours are raw ANSI escapes; piping to a file keeps the escape codes.
- Timers use wall-clock time, so an NTP step can make a duration look
  negative or huge. For measurements, prefer
  [`performance.now()`](/docs/api/performance).

## See also

- [Logging](/docs/guides/logging) — patterns for real applications
- [Errors and exit codes](/docs/concepts/errors)
- [Limitations](/docs/reference/limitations)
