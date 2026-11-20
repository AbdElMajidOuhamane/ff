---
title: Cron (ff.cron)
description: In-process UTC job scheduler via ff.cron(name, schedule, callback) supporting @every intervals and 5-field cron expressions.
order: 20
---

# Cron (`ff.cron`)

In-process cron and interval scheduler exposed as `ff.cron` (currently the only property on the global `ff` object). Requires **no imports** and **no permission flags**.

## Quick look

```js
// Interval schedule
ff.cron("heartbeat", "@every 5s", () => {
  console.log("tick");
});

// 5-field UTC cron expression (every 15 minutes)
ff.cron("cleanup", "*/15 * * * *", () => {
  console.log("cleanup pass");
});
```

## Signature

```js
ff.cron(name: string, schedule: string, callback: () => void) → undefined
```

| Parameter | Type | Notes |
|---|---|---|
| `name` | `string` | Job identifier used in diagnostic messages. |
| `schedule` | `string` | `@every <N><unit>` interval or 5-field UTC cron expression. |
| `callback` | `() => void` | Function invoked on each trigger (`this` is `undefined`, 0 args). |

Invalid argument types throw `TypeError: ff.cron requires (name, schedule, callback)`.

## Schedule syntax

### Interval syntax: `@every <N><unit>`

- Supported integer units only: **`ms`** (milliseconds), **`s`** (seconds), **`m`** (minutes).
- Examples: `"@every 500ms"`, `"@every 10s"`, `"@every 5m"`.
- Unsupported: hours (`h`), days (`d`), decimals (`1.5s`), or aliases (`@hourly`, `@daily`). Backed by `setInterval`.

### 5-field UTC cron syntax

```text
minute  hour  day-of-month  month  day-of-week
(0-59) (0-23)    (1-31)     (1-12)   (0-7, 0 & 7 = Sunday)
```

- **Strictly UTC** — evaluated against system wall clock (`CLOCK_REALTIME`) in UTC, with no timezone option.
- Numeric fields only (no month/weekday names like `JAN` or `MON`).
- Operators supported per field: wildcard `*`, lists (`,`), ranges (`-`), and steps (`/`), e.g. `10-20/3 * * * *` or `0 9-17 * * 1-5`.
- **Vixie OR semantics:** when *both* day-of-month (`dom`) and day-of-week (`dow`) are non-`*`, the job runs when **either** matches.
- **366-day validation:** expressions that match no UTC date in the next 366 days (for example `"0 0 31 2 *"`) throw synchronously at registration:
  `TypeError: cron schedule will never match in the next 366 days`.
- 5-field jobs re-arm using `setTimeout` after each callback execution.

## Error handling & lifecycle

- Malformed schedules throw synchronously: `TypeError: invalid cron schedule expression`.
- Uncaught errors thrown by a 5-field callback are logged (`Uncaught (in cron)`) and the next run is still scheduled.
- Registered cron jobs **keep the event loop alive** until the process exits (no `cancel`, `remove`, `list`, or `unref` API is exposed).

## Limits

| Area | Cap | When hit |
|---|---|---|
| Registered cron jobs | `32` | Throws `TypeError: Max cron jobs (32) exceeded` |
| Shared timer table | `128` live slots | Shares slots with `setTimeout` / `setInterval` / `AbortSignal.timeout`; throws `TypeError: failed to schedule cron timer (timer table full)` |
| Future match window | `366` days | Throws `TypeError: cron schedule will never match in the next 366 days` |
| Cancellation | None | Jobs remain active for the process lifetime |

## Related

- [Timers](/docs/guides/timers)
- [Event loop](/docs/concepts/event-loop)
- [API overview](/docs/api/overview)
