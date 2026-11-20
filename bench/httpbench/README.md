# HTTP benchmark — ff vs Deno vs Bun

A reproducible hello-JSON HTTP benchmark driven by [oha](https://github.com/hatoo/oha)
and [hyperfine](https://github.com/sharkdp/hyperfine), with a self-contained
HTML report (no plotting dependencies).

The same handler runs on every runtime — 27-byte JSON body, `content-type:
application/json`, HTTP/1.1 keep-alive, loopback only:

```js
const body = '{"message":"Hello, World!"}';
const headers = { "content-type": "application/json" };
// ff:    http.serve({ port, hostname: "127.0.0.1" }, () => new Response(body, { headers }));
// deno:  Deno.serve({ port, hostname: "127.0.0.1" }, () => new Response(body, { headers }));
// bun:   Bun.serve({ port, hostname: "127.0.0.1", fetch: () => new Response(body, { headers }) });
```

## Quick start

```sh
# ff must be built first (ReleaseFast is what ships)
zig build -Doptimize=ReleaseFast

./bench/httpbench/run.sh
open bench/httpbench/results/report.html
```

`run.sh` is a thin wrapper around `bench.py`; both accept the same flags.

Smoke test (≈15 s, one short run per runtime):

```sh
./bench/httpbench/run.sh --quick
```

Pick runtimes and load:

```sh
./bench/httpbench/run.sh --runtimes ff,bun --connections 256 --duration 10 --runs 5
```

## Requirements

| Tool | Tested version | Install |
|---|---|---|
| `ff` | built from this repo (`zig-out/bin/ff`) | `zig build -Doptimize=ReleaseFast` |
| `oha` | 1.16.0 | `brew install oha` / `cargo install oha` |
| `hyperfine` | 1.20.0 | `brew install hyperfine` |
| `deno` | 2.9.x | `brew install deno` |
| `bun` | 1.4.x | `brew install bun` |
| Python | 3.10+ (stdlib only) | system |

Only the runtimes you select are required. `oha` and `hyperfine` are checked
before anything starts.

## What it does

For each runtime, sequentially (never concurrently, so they do not steal CPU):

1. starts the server alone on `127.0.0.1:8787` (override with `--port`);
2. polls the port until a correct `200`, body, and content type arrive;
3. warms up with `oha -z {warmup}s`;
4. runs `oha -c {connections} -z {duration}s` **N times**, JSON output;
5. samples the server process RSS every 100 ms and keeps the peak;
6. runs `hyperfine` over `oha -n {hf-requests}` as an independent,
   client-inclusive wall-clock check;
7. stops the server, then repeats for the next runtime.

The table reports the **median of the per-run metrics** plus the min–max range,
so single-run noise is visible rather than hidden.

## Options

| Flag | Default | Meaning |
|---|---|---|
| `--runtimes` | `ff,deno,bun` | comma-separated subset |
| `--connections` | `100` | oha `-c` keep-alive connections |
| `--duration` | `5` | seconds per oha run |
| `--requests` | `0` | fixed requests per oha run (`-n`), overrides `--duration` |
| `--runs` | `3` | oha runs per runtime (median reported) |
| `--warmup` | `2` | warmup seconds per runtime |
| `--hf-runs` | `3` | hyperfine timed runs |
| `--hf-warmup` | `1` | hyperfine warmup runs |
| `--hf-requests` | `200000` | fixed request count for hyperfine |
| `--oha-threads` | `min(8, CPUs)` | oha worker threads |
| `--port` | `8787` | loopback port (must be free) |
| `--path` | `/` | request path |
| `--ff-bin` | `zig-out/bin/ff` | ff binary |
| `--ff-args` | none | extra ff flags, e.g. `--ff-args='--max-heap=256MB'` |
| `--build` | off | run `zig build -Doptimize=ReleaseFast` first |
| `--skip-hyperfine` | off | oha only |
| `--quick` | off | `1s × 1 run`, 20k hyperfine requests |

## Output

```
bench/httpbench/results/
├── report.html            ← the deliverable: charts + table + method
├── summary.csv            ← one row per runtime
├── summary.md             ← same table as Markdown
├── raw.json               ← everything the report is rendered from
├── charts/
│   ├── throughput.svg     ← median req/s, whiskers = min–max
│   ├── percentiles.svg    ← p50 / p90 / p95 / p99 / p99.9 curve
│   ├── histogram.svg      ← response-time distribution per runtime
│   ├── scatter.svg        ← throughput vs p99
│   └── rss.svg            ← peak RSS
└── <runtime>/
    ├── oha_runN.json      ← raw oha output per run
    ├── hyperfine.json     ← hyperfine --export-json
    ├── hyperfine.log
    ├── metrics.json       ← aggregated row
    └── server.log
```

Regenerate the report from existing data without re-running anything:

```sh
python3 bench/httpbench/report.py bench/httpbench/results
```

## ff CLI flags: what actually helps

The harness passes only the permissions ff needs (`--allow-net`, `--allow-env`);
no performance flag is set, because none measured faster. On this host
(8 CPUs, 100 keep-alive connections, 5 s runs), an interleaved ABBA A/B of the
two most plausible knobs gave:

| ff flags | median req/s |
|---|---:|
| default (`--max-heap=64MB`, `--cpu-budget=0`) | 89.8k |
| `--max-heap=1GB` | 89.7k |

Across a second interleaved block, default / `--max-heap=8MB` /
`--max-heap=1GB` / `--cpu-budget=3600000` all landed between 86.5k and 92.1k —
the spread between repeated runs is larger than any flag effect. Defaults are
already the fast path:

- `--cpu-budget=0` (default) leaves the interrupt monitor thread and the
  QuickJS interrupt handler **off**. Enabling a budget adds work; it is a
  safety valve for runaway scripts, not a throughput knob.
- `--max-heap` only caps the JS heap (and the GC trigger ceiling). Hello-world
  does not need more than the 64 MB default, and raising it did not help.
- The real levers are **build-time**: `-Doptimize=ReleaseFast` (what `make
  build` and this harness expect) and, on Linux, the io_uring backend
  (`-Dio_uring`, default true; `-Dio_uring=false` selects epoll). macOS only
  has kqueue.

Use `--ff-args` to reproduce an A/B yourself:

```sh
./bench/httpbench/run.sh --runtimes ff --skip-hyperfine --runs 5 \
    --ff-args='--max-heap=256MB'
```

Flag effects smaller than ~5% are not resolvable on a laptop; alternate the
variants between rounds (as the A/B above did) instead of running one block.

## Reading the numbers

- **Loopback benchmarks measure CPU efficiency and HTTP-stack overhead**, not
  network throughput. A JIT can win hello-world and lose a real workload; keep
  the handler identical and compare only rows from the same run/machine.
- **The client can be the bottleneck.** At 100 connections `oha` itself is
  busy; if all three runtimes plateau together, raise `--oha-threads` or lower
  `--connections` and re-check.
- **`oha` runs** use `-z {duration}s`: in-flight requests at the deadline are
  counted in `errorDistribution` as "aborted due to deadline", not as failed
  responses. `success` is the completed 2xx share.
- **`hyperfine` runs** time the *whole client invocation*, including oha
  startup and connection ramp. Its absolute req/s is lower than oha's for
  short runs; use its mean ± σ as a variance/consistency check, not as the
  headline throughput.
- **Warmup matters for JIT runtimes.** Deno and Bun compile on first requests;
  the warmup phase and the first oha run absorb that. Increase `--warmup` for
  more conservative numbers.
- **Only `content-type` is set by the handler.** Everything else on the wire
  (`Date`, `Connection`, header casing) is the runtime's own default, which is
  part of the HTTP stack being compared.
- **RSS** is sampled from the server process: `proc_pidinfo` on macOS,
  `/proc/<pid>/status` on Linux, `ps` as a last resort. If the host blocks all
  three, the report prints `—` and omits the RSS chart.
- Numbers are **machine-local**. Compare rows within one report, never across
  machines or adversarially against published benchmarks.

## Adding a runtime

1. Add `servers/<name>.js` with the same body/headers/port contract
   (`PORT` env var, bind `127.0.0.1`).
2. Add `<name>` to `RUNTIME_ORDER` and a command branch in `server_command()`
   in `bench.py`.
3. Colors live in `COLORS` in `report.py`.

## Implementation notes

- `bench.py` is stdlib-only orchestration; `report.py` renders CSV, Markdown,
  and hand-written SVG, so the HTML has no CDN or font dependency and works
  offline.
- Server stdout/stderr go to `results/<runtime>/server.log`; a bind failure or
  crash is reported with that path.
- `SIGTERM` is sent to the server's process group, then `SIGKILL` after 4 s.
  An interrupted run leaves no listener behind.