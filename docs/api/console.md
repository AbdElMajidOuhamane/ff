---
title: console
description: Output, colored aliases, and time/timeLog/timeEnd — every method and its quirks.
order: 8
---

# `console`

`console` is Fairyfly's only output primitive. It writes to **stderr** —
never stdout — converts each argument with `String(...)` semantics, joins
them with a single space, and returns `undefined` from every method.

```js
console.log("plain");
console.info("same as log");
console.debug("same as log");
console.warn("yellow");                    // ANSI yellow
console.error("red");                      // ANSI red
console.detail("green");                   // ANSI green
console.log("multiple", 1, true, null, undefined, { a: 1 });
// multiple 1 true null undefined [object Object]
```

Calling a plain method (`log`/`info`/`debug`) with no arguments prints a
single blank line (just the trailing newline); a coloured method prints an
empty coloured line:

```js
console.log();   // (blank line)
```

## Methods

Exactly these members exist. The aliases share the same C callback, so
`log`/`info`/`debug` accept the same arguments, and `warn` is `slops` while
`error` is `redbal`.

| Method | Style | Alias of | `length` |
|---|---|---|---|
| `console.log(...args)` | plain | — | 2 |
| `console.info(...args)` | plain | `log` | 2 |
| `console.debug(...args)` | plain | `log` | 2 |
| `console.warn(...args)` | **yellow** | — | 2 |
| `console.slops(...args)` | **yellow** | `warn` | 2 |
| `console.error(...args)` | **red** | — | 2 |
| `console.redbal(...args)` | **red** | `error` | 2 |
| `console.detail(...args)` | **green** | — | 2 |
| `console.time(label?)` | — | — | 1 |
| `console.timeLog(label?)` | — | — | 1 |
| `console.timeEnd(label?)` | — | — | 1 |

The `length` column is the arity QuickJS reports (the value passed to
`JS_NewCFunction`). It is not enforced — every method accepts any number of
arguments — so don't branch on it.

`console.table`, `console.trace`, `console.assert`, and `console.count` do
**not** exist. They read as `undefined`, so calling one throws
`TypeError: not a function`.

## Colours are raw ANSI

The coloured methods wrap the whole line in an escape sequence and reset
before the newline:

```js
console.warn("watch out");
// emits: ESC[33mwatch out ESC[0m\n   (yellow, then reset)
```

The codes are written unconditionally — piping to a file keeps them, as does
`2> log.txt`. Strip them downstream if your collector needs plain text.

## Timers

Timers are keyed by a **label string**. The label is the first argument and
the only argument that matters; extra arguments are ignored. With no
argument the label defaults to `"default"`.

```js
// timing.js — ff timing.js
console.time("db-query");
// ... work ...
console.timeLog("db-query");   // db-query: 1ms   (timer keeps running)
// ... more work ...
console.timeEnd("db-query");   // db-query: 12ms  (timer is removed)
```

- Durations are **integer milliseconds** from the **wall clock**
  (`CLOCK_REALTIME`), printed as `label: Nms`.
- `timeLog` prints without stopping; call it as often as you like.
- `timeEnd` prints and **removes** the label.
- Calling `time(label)` again with the same label **restarts** it (the
  start time is overwritten).
- An unknown label warns instead of throwing:

```js
console.timeEnd("never-started");
// warning: unknown timer 'never-started'
```

Because `timeEnd` removes the label, ending twice warns too:

```js
console.time("x");
console.timeEnd("x");   // x: 3ms
console.timeEnd("x");   // warning: unknown timer 'x'
```

The default label works the same way:

```js
console.time();
// ... work ...
console.timeEnd();      // default: 0ms
```

Wall-clock timing means an NTP step can make a duration look negative or
huge. For measurements prefer [`performance.now()`](/docs/api/performance).

## Everything goes to stderr

```sh
$ ff app.js             # logs appear on the terminal
$ ff app.js 2>/dev/null # nothing — stderr is discarded
$ ff app.js > out.txt   # out.txt is empty
$ ff app.js 2> out.txt  # out.txt has the logs
```

That's deliberate: stdout stays clean for program output (JSON you pipe to
`jq`, a generated file listing), while diagnostics stay visible in a
terminal.

## Arguments and formatting

Every argument is converted with the same coercion `String(value)` uses:

```js
console.log("count:", 3, { ok: true });
// count: 3 [object Object]

console.log({ ok: true });                          // objects do NOT pretty-print
console.log(JSON.stringify({ ok: true }, null, 2)); // use this instead
```

- Numbers, booleans, `null`, and `undefined` print as their string forms
  (`null`, `undefined`).
- Objects print as `[object Object]` — serialize explicitly if you want
  structure.
- A single line is buffered in **4096-byte** chunks and flushed as it fills,
  so an argument larger than 4096 bytes still prints in full (in several
  writes, with no injected newlines).

## Gotchas

- **stderr, not stdout.** `console.log > file` captures nothing.
- No `console.table` / `trace` / `assert` / `count` — they're undefined, so
  calling them throws `TypeError`.
- Colours are raw ANSI escapes; redirection into a file keeps the codes.
- `time`/`timeLog`/`timeEnd` use `CLOCK_REALTIME`; use `performance.now()` for
  anything where a clock step would matter.
- Unknown timer labels never throw — they print
  `warning: unknown timer '<label>'`.
- Every method returns `undefined`; `console.log` is not chainable.

## See also

- [Logging](/docs/guides/logging) — patterns for real applications
- [Errors and exit codes](/docs/concepts/errors)
- [Limitations](/docs/reference/limitations)
