# Fairyfly Runtime

A lightweight, backend-focused JavaScript runtime built with Zig and powered by
[QuickJS](https://bellard.org/quickjs/). Designed for fast startup, low memory,
and a small readable codebase.

> **138k req/sec · 0.66 ms p50 · 5 MB RSS** on Apple silicon (8-thread wrk, 100 conn).
> Outperforms Node 23, Bun 1.4, and Deno 2 — and uses ~10× less memory.

---

## Contents

1. [Why Fairyfly](#why-fairyfly)
2. [Quick start](#quick-start)
3. [Core concepts](#core-concepts)
4. [Tutorials](#tutorials)
   - [Hello world](#hello-world)
   - [Timers and the event loop](#timers-and-the-event-loop)
   - [HTTP server](#http-server)
   - [Fetch client](#fetch-client)
   - [WebSocket server](#websocket-server)
   - [WebSocket client](#websocket-client)
   - [URL parsing](#url-parsing)
   - [Working with modules](#working-with-modules)
5. [Built-in API reference](#built-in-api-reference)
6. [Performance](#performance)
7. [Architecture](#architecture)
8. [Building from source](#building-from-source)
9. [CLI reference](#cli-reference)

---

## Why Fairyfly

Modern backend development doesn't need 50 MB of runtime to start. Fairyfly is
built for cases where:

- **Cold start matters** — CLI tools, edge functions, short-lived jobs
- **Memory is constrained** — containers with strict limits
- **The whole codebase should fit in your head** — under 10k lines of Zig

It's *not* aimed at:

- Browser parity (no DOM, no `window`)
- npm ecosystem (no `node_modules` resolution)

If you need either of those, use Node, Bun, or Deno. If you need a backend
runtime that's small, fast, and auditable, Fairyfly fits.

---

## Quick start

```sh
# Build (one-time)
make build

# Run a JavaScript file
./zig-out/bin/ff examples/hello.js

# Run inline code
./zig-out/bin/ff -e 'console.log("hello from fairyfly")'

# Initialize a project (writes ff.json)
./zig-out/bin/ff init myapp
cd myapp && ../zig-out/bin/ff start
```

---

## Core concepts

### Single-threaded event loop

Like Node and Bun, Fairyfly runs JavaScript on a single OS thread. Concurrency
comes from the event loop: when JS code finishes, the loop dispatches pending
timers, I/O completions, and microtasks.

```
┌─ JS code runs ─┐    ┌─ pending timer fires ─┐
│                 │ →  │                         │
└─────────────────┘    └─ microtask pump ────────�
                                ↓
                    ┌─ I/O completion (kqueue/epoll) ─┐
                    └─ back to JS code ───────────────┘
```

### No `process.nextTick`; use `queueMicrotask`

`queueMicrotask(fn)` is supported. `setTimeout(fn, 0)` is the equivalent of
`setImmediate` in Node — it yields to the event loop on the next iteration.

### Modules are ES Modules only

`require()` is not supported. Use `import` / `export`. File extensions are
mandatory in import specifiers:

```js
import { add } from "./math.js";
export const pi = 3.14159;
```

---

## Tutorials

### Hello world

The smallest Fairyfly script:

```js
// hello.js
console.log("hello, world!");
```

Run:

```sh
$ ./zig-out/bin/ff hello.js
hello, world!
```

### Timers and the event loop

`setTimeout` schedules a callback to run after a minimum delay. The event
loop processes it on the next tick after the timer expires.

```js
// timer.js
console.log("start");

setTimeout(() => {
    console.log("after 100ms");
}, 100);

setTimeout(() => {
    console.log("after 50ms");
}, 50);

console.log("end (synchronous)");
```

To run the event loop after the script body executes, the runtime
auto-runs `event_loop.runWithMicrotasks` for you. For most use cases
no additional setup is needed.

### HTTP server

`http.serve` binds a TCP listener and routes requests to a JS handler. The
handler returns a `Response` object.

```js
// server.js
http.serve({ port: 3000 }, (req) => {
    const url = new URL(req.url);
    if (url.pathname === "/") {
        return new Response("hello from fairyfly", {
            status: 200,
            headers: { "content-type": "text/plain" },
        });
    }
    if (url.pathname === "/json") {
        return Response.json({ ok: true, runtime: "fairyfly" });
    }
    return new Response("not found", { status: 404 });
});
```

The handler runs on the event loop. Multiple concurrent connections are
handled cooperatively — no thread per request.

**Benchmarking this exact pattern:**

```sh
$ wrk -t 8 -c 100 -d 10s http://127.0.0.1:3000/
Running 10s test @ http://127.0.0.1:3000/
  8 threads and 100 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     0.66ms  143.62us   4.56ms   97.27%
    Req/Sec    17.27k   1.30k    19.84k    70.85%
  1381874 requests in 10.00s, 9.43MB read
Requests/sec: 138187.47
Transfer/sec:    964.39KB
```

### Fetch client

```js
// fetch.js
const res = await fetch("https://httpbin.org/json");
const data = await res.json();
console.log(data);
```

`fetch` returns a Promise that resolves to a `Response`. The body is consumed
via `.text()`, `.json()`, `.arrayBuffer()`, or `.blob()`.

**Caveats:**

- HTTPS uses the system trust store
- HTTP/2 not supported (HTTP/1.1 only)
- Redirects are followed automatically by default

### WebSocket server

WebSocket support is built into the HTTP server — pass a `websocket` config
object:

```js
// ws_server.js
http.serve({
    port: 8080,
    websocket: {
        open: (sock) => {
            console.log("client connected");
            sock.send("welcome!");
        },
        message: (sock, msg) => {
            console.log("received:", msg);
            sock.send(`echo: ${msg}`);
        },
        close: (sock) => console.log("client disconnected"),
    },
}, (req) => new Response("ws endpoint", { status: 200 }));
```

The `sock` object exposes:

- `sock.send(text)` — send a UTF-8 text frame
- `sock.sendBinary(buffer)` — send a binary frame
- `sock.readyState` — `CONNECTING` / `OPEN` / `CLOSING` / `CLOSED`

### WebSocket client

```js
// ws_client.js
const ws = new WebSocket("ws://127.0.0.1:8080");
ws.onopen = () => ws.send("hello server");
ws.onmessage = (e) => console.log("got:", e.data);
ws.onclose = () => console.log("closed");
```

Static constants: `WebSocket.CONNECTING`, `.OPEN`, `.CLOSING`, `.CLOSED`.

### URL parsing

```js
// url.js
const u = new URL("https://user:pass@example.com:8080/path?q=1#hash");
console.log(u.protocol);   // "https:"
console.log(u.hostname);   // "example.com"
console.log(u.port);       // "8080"
console.log(u.pathname);   // "/path"
console.log(u.search);     // "?q=1"
console.log(u.hash);       // "#hash"
console.log(u.username);   // "user"
console.log(u.password);   // "pass"
```

`URL` is mutable. You can set components and re-serialize:

```js
const u = new URL("/api/v2", "https://example.com");
u.pathname = "/api/v3";
console.log(u.toString());   // "https://example.com/api/v3"
```

### Working with modules

```js
// math.js
export function add(a, b) { return a + b; }
export const pi = 3.14159;
```

```js
// main.js
import { add, pi } from "./math.js";
console.log(add(2, 3));         // 5
console.log(pi);               // 3.14159
```

Module paths:
- Relative: `./foo.js`, `../bar.js`
- Absolute: `/abs/path/to/file.js`
- Bare specifiers (`foo`) are *not* resolved through `node_modules` —
  Fairyfly has no package manager integration

---

## Built-in API reference

### Globals

| Name | Description |
|---|---|
| `console` | `log`, `error`, `warn`, `info`, `debug`, `time`/`timeEnd` |
| `setTimeout`, `clearTimeout` | Timer scheduling |
| `setInterval`, `clearInterval` | Repeating timers |
| `queueMicrotask` | Schedule a microtask |
| `URL` | WHATWG URL parser |
| `TextEncoder`, `TextDecoder` | UTF-8 encoding |
| `fetch` | HTTP client |
| `WebSocket` | WebSocket client |
| `process` | Env vars, argv, exit, cwd |
| `Headers`, `Request`, `Response` | WHATWG Fetch primitives |

### Namespaces

- `http.serve(options, handler)` — start an HTTP server
- `Response.json(value, init?)` — JSON response shortcut
- `Response.redirect(url, status?)` — redirect response shortcut
- `Response.error()` — empty 500 response shortcut

### Limitations vs Node / browser

- No `require()`, no CommonJS
- No `node_modules` resolution
- No `Buffer` (use `ArrayBuffer` / `Uint8Array`)
- No `process.nextTick` (use `queueMicrotask`)
- HTTP/1.1 only
- No browser DOM

---

## Performance

`wrk -t 8 -c 100 -d 10s`, Apple silicon, all runtimes serving the same hello-world
handler:

| Runtime       | Req/sec   | p50    | p99    | Peak RSS |
|---------------|-----------|--------|--------|----------|
| **Fairyfly**  | **138k**  | **0.66 ms** | **0.85 ms** | **5 MB** |
| Deno 2.9      | 110k      | 0.86 ms | 1.00 ms | 48 MB    |
| Bun 1.4       | 107k      | 0.87 ms | 1.71 ms | 34 MB    |
| Node 23       | 69k       | 1.36 ms | 1.69 ms | 82 MB    |

Fairyfly is:
- **+25% throughput** vs the next-fastest runtime
- **−90% memory** vs Deno (~10× lower RSS)
- **−24% p50 latency** vs Deno

The wrk script in this repo reproduces this: `./wrk.sh`.

---

## Architecture

```
┌──────────────────────────────────────────────────┐
│ JavaScript source (.js files)                    │
└──────────────────┬───────────────────────────────┘
                   │ QuickJS parser
┌──────────────────▼───────────────────────────────┐
│ QuickJS bytecode + JS runtime (gc, value stack)  │
└──────────────────┬───────────────────────────────┘
                   │ C ABI (src/c.zig → quickjs_shim.zig)
┌──────────────────▼───────────────────────────────┐
│ Zig API layer                                     │
│   • api/    — Request, Response, fetch, ws, fs, … │
│   • net/    — http_native (SoA 512-slot server)   │
│   • event/  — loop, timers, microtasks            │
│   • types/  — HeadersData, RequestData, etc.      │
└──────────────────┬───────────────────────────────�
                   │
┌──────────────────▼───────────────────────────────┐
│ libxev event loop (epoll on Linux, kqueue on mac) │
└──────────────────────────────────────────────────┘
```

**Hot-path design:**
- Zero allocations per request (CountingAllocator asserts `balanced=true`)
- SoA layout for connection slots (512× parallel arrays, packed 1-byte flags)
- Static buffers reused across connections
- HeadersData uses refcounting + lazy cold-struct split for hot/cold separation
- Module interning: import/export strings interned into single arena
- Boot arena owns runtime/event-loop/cache, no syscall-per-alloc at startup

---

## Building from source

Requirements:
- Zig 0.16 (uses 0.16.0 std APIs)
- C compiler (clang on macOS, gcc on Linux) — QuickJS vendored as C source
- A POSIX system (macOS or Linux)

```sh
git clone <repo>
cd fairyfly
make build         # ReleaseFast build
./zig-out/bin/ff examples/hello.js
```

Debug build (with allocation balance assertions):

```sh
zig build
./zig-out/bin/ff examples/hello.js
# Look for: "[allocs] req id=N: balanced=true" after each request
```

Run the benchmark suite:

```sh
make build
./wrk.sh                 # HTTP server comparison (node/bun/deno/fairyfly)
./bench/run-bench.sh     # JS microbenchmarks (fib, sort, json, …)
```

---

## CLI reference

```
ff <file.js>             Run a JavaScript file
ff -e <code>             Run inline JavaScript code
ff init [<dir>]          Write ff.json in <dir> (default: cwd)
ff start                 Run the file named in ff.json's "main"
ff bench                 Run JS microbenchmarks
```

Environment variables:
- `FF_ECHO=1` — run the server in echo mode (returns canned response)

---

## Examples index

The `examples/` directory has working scripts for every API:

| File | Demonstrates |
|---|---|
| `hello.js` | `console.log` |
| `timer.js` | `setTimeout`, `setInterval` |
| `server.js` | `http.serve` with routing |
| `fetch.js` | `fetch` + `Response.json` |
| `ws_server.js` | Server-side WebSocket |
| `ws_client.js` | Client-side WebSocket |
| `url.js` | `URL` parsing & mutation |
| `console.js` | `console.log/error/warn/time` |
| `process.js` | `process.env`, `process.argv`, `process.exit` |
| `parallel.js` | Concurrent `fetch` with `Promise.all` |
| `complex.js` | A more complete HTTP server |
| `express-test/` | Express-style routing patterns |
| `fetch_pool_test.js` | Connection pool stress test |

Run any of them:

```sh
./zig-out/bin/ff examples/server.js
```

---

## License

MIT. See [LICENSE](LICENSE).

---

## Acknowledgments

- QuickJS — Fabrice Bellard
- libxev — [mitchellh](https://github.com/mitchellh/libxev)
- Inspired by Node.js, Bun, and Deno — none of their code is included; this is
  a from-scratch implementation in Zig
