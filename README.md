<img src="assets/ff.webp" alt="Fairyfly logo" width="120" />

# Fairyfly Runtime

A lightweight, backend-focused JavaScript runtime built with Zig and powered by
[QuickJS](https://bellard.org/quickjs/). Designed for fast startup, low memory,
and a small readable codebase.

> **138k req/sec · 0.66 ms p50 · 5 MB RSS** on Apple silicon (8-thread wrk, 100 conn).
> Outperforms Node 23, Bun 1.4, and Deno 2 — and uses ~10× less memory.
> Reproduce with [`bench/_bench/wrk.sh`](bench); see [Performance](#performance).

---

## Contents

1. [Documentation](#documentation)
2. [Why Fairyfly](#why-fairyfly)
3. [Quick start](#quick-start)
4. [Core concepts](#core-concepts)
5. [Tutorials](#tutorials)
6. [Built-in API reference](#built-in-api-reference)
7. [Performance](#performance)
8. [Architecture](#architecture)
9. [Building from source](#building-from-source)
10. [CLI reference](#cli-reference)
11. [Limitations vs Node / browser](#limitations-vs-node--browser)
12. [License](#license)

---

## Documentation

The full guide set lives in [`docs/`](docs/index.md) — 28 pages covering
everything this README summarizes.

| Section | Contents |
|---|---|
| [Getting started](docs/getting-started/introduction.md) | Introduction, installation, quickstart |
| [Guides](docs/index.md) | HTTP server, fetch, WebSocket, TLS, HTTP/2, Postgres packages, modules, workers, timers, testing, bytecode, environment, deploy |
| [API reference](docs/api/overview.md) | Every global and module on one page |
| [Reference](docs/reference/cli.md) | CLI, limitations, examples |

---

## Why Fairyfly

Modern backend development doesn't need a 50 MB runtime to start. Fairyfly is
built for cases where:

- **Cold start matters** — CLI tools, edge functions, short-lived jobs
- **Memory is constrained** — containers with strict limits
- **The whole codebase should fit in your head** — ~20k lines of Zig across 54 files

It's *not* aimed at:

- Browser parity (no DOM, no `window`)
- Full npm ecosystem compatibility (pure-JS ESM packages only — see [Packages](docs/guides/packages.md))

If you need either of those, use Node, Bun, or Deno. If you need a backend
runtime that's small, fast, and auditable, Fairyfly fits.

---

## Quick start

```sh
# Build (one-time) — vendors are fetched automatically
docker build -t fairyfly .

# Or build locally after fetching vendors (see "Building from source")
make install

# Run inline code
ff -e 'console.log("hello from fairyfly")'

# Initialize a project (writes ff.json)
ff init
ff start
```

---

## Core concepts

### Event loop + worker threads

Like Node and Bun, Fairyfly runs each JavaScript context on a single OS
thread. Concurrency comes from the event loop: when JS code finishes, the loop
dispatches pending timers, I/O completions, and microtasks.

CPU-bound work goes to `Worker` threads (see [Workers](#workers)): each
worker is an OS thread with its own JS runtime and event loop. Threads share
no JS state — they communicate by message passing.

```
┌─ JS code runs ─┐    ┌─ pending timer fires ─┐
│                 │ →  │                         │
└─────────────────┘    └─ microtask pump ────────┘
                                 ↓
                     ┌─ I/O completion (kqueue/io_uring) ─┐
                     └─ back to JS code ───────────────────┘
```

### No `process.nextTick`; use `queueMicrotask`

`queueMicrotask(fn)` is supported. `setTimeout(fn, 0)` is the equivalent of
`setImmediate` in Node — it yields to the event loop on the next iteration.

### Modules are ES Modules only

`require()` is not supported. Use `import` / `export`.

Include the file extension in relative specifiers:

```js
import { add } from "./math.js";
export const pi = 3.14159;
```

If you omit the extension, the loader probes `X.js`, then `X/index.js`.

Bare specifiers (`nanoid`) resolve through `node_modules/`, which
[`ff imprint`](docs/guides/packages.md) populates — nothing is installed
automatically.

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
$ ff hello.js
hello, world!
```

### Console

Fairyfly provides a full `console` object with colored output and timers:

```js
// Basic output methods
console.log("hello");             // plain text
console.info("informational");    // same as log
console.debug("debug details");   // same as log
console.warn("warning message");  // yellow text
console.error("error occurred");  // red text

// Custom colored output
console.detail("success message");  // green text
console.slops("another warning");   // alias for warn (yellow)
console.redbal("another error");    // alias for error (red)

// Performance timers
console.time("db-query");
// ... some operation ...
console.timeLog("db-query");        // "db-query: 12.345ms"
// ... more work ...
console.timeEnd("db-query");        // "db-query: 45.678ms" (timer removed)
```

> **Note:** `console` writes to **stderr**, so `console.log > out.txt` captures
> nothing. Each call prints the **first two arguments** (see
> [Limitations](#limitations-vs-node--browser)).

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

Output:

```
start
end (synchronous)
after 50ms
after 100ms
```

**Repeating timers** with `setInterval`:

```js
let count = 0;
const id = setInterval(() => {
    count++;
    console.log(`tick ${count}`);
    if (count >= 5) clearInterval(id);
}, 1000);
```

**Queuing microtasks** (runs before the next timer or I/O callback):

```js
queueMicrotask(() => {
    console.log("microtask 1");
});
queueMicrotask(() => {
    console.log("microtask 2");
});
console.log("main code");

// Output:
// main code
// microtask 1
// microtask 2
```

**Timer control** — each timer returns an object with `ref()`, `unref()`,
`refresh()`, and `hasRef()` methods:

```js
const timer = setTimeout(() => console.log("done"), 5000);
timer.unref();        // mark the timer as unreferenced
timer.refresh();      // reset the countdown
timer.hasRef();       // check the ref flag
```

**Max timers**: 128 concurrent timers. The 129th call throws
`TypeError: too many timers (max 128)`.

### HTTP server

`http.serve` binds a TCP listener and routes requests to a JS handler. The
handler returns a `Response` object.

```js
// server.js
http.serve({ port: 3000 }, (url, method, body) => {
    const u = new URL(url, "http://localhost");

    if (u.pathname === "/") {
        return new Response("hello from fairyfly", {
            status: 200,
            headers: { "content-type": "text/plain" },
        });
    }

    if (u.pathname === "/json") {
        return Response.json({ ok: true, runtime: "fairyfly" });
    }

    return new Response("not found", { status: 404 });
});
```

The handler signature is `(url, method, body)`:

- `url` — the raw request target, e.g. `"/api/todos?page=1"`
- `method` — HTTP method string: `"GET"`, `"POST"`, etc.
- `body` — request body as a string (empty string if no body)

The handler runs on the event loop. Multiple concurrent connections are
handled cooperatively — no thread per request.

**Response headers** set on the returned `Response` are sent verbatim —
`content-type`, `set-cookie`, custom headers — except `Content-Length`,
`Transfer-Encoding`, and `Connection`, which the server computes. A hung
handler is failed with `504` after 30 s.

**Response.json** is a shortcut for JSON responses:

```js
// Sets content-type: application/json automatically
return Response.json({ users: [{ name: "Alice" }] }, { status: 200 });

// With custom headers
return Response.json({ data: items }, {
    status: 200,
    headers: { "X-Total-Count": String(items.length) },
});
```

**Benchmarking this exact pattern:**

```sh
$ wrk -t 8 -c 100 -d 10s http://127.0.0.1:3000/
Running 10s test @ http://127.0.0.1:3000/
  8 threads and 100 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     0.66ms  143.62us  4.56ms  97.27%
    Req/Sec    17.27k    1.30k   19.84k   70.85%
  1381874 requests in 10.00s, 9.43MB read
Requests/sec: 138187.47
Transfer/sec:    964.39KB
```
### Async handlers

Handlers can be `async` — the runtime parks the connection and resumes it
when the promise settles. Awaiting timers, `fetch`, or any promise works
inside a handler; no thread is blocked:

```js
// async_server.js
http.serve({ port: 3000 }, async (url, method, body) => {
    const res = await fetch("https://httpbin.org/json");
    const data = await res.json();
    return Response.json({ proxy: data });
});
```

You can also receive a `Request` object if you prefer:

```js
http.serve({ port: 3000 }, async (request) => {
    const body = await request.text();
    return Response.json({ echo: body });
});
```

Rejected promises and thrown errors become `500` responses.

### Fetch client

`fetch` makes HTTP requests and returns a `Promise<Response>`:

```js
// GET request
const res = await fetch("https://httpbin.org/json");
const data = await res.json();
console.log(data);

// POST request with JSON body
const res2 = await fetch("https://httpbin.org/post", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name: "Alice", age: 30 }),
});
const result = await res2.json();
console.log(result);

// Check status
const res3 = await fetch("https://example.com/status/404");
console.log(res3.status);   // 404
console.log(res3.ok);       // false

// Read as text
const html = await fetch("https://example.com").then(r => r.text());
```

**Body consumption methods** (each can only be called once):

- `res.text()` — returns `Promise<string>`
- `res.json()` — returns `Promise<object>`
- `res.arrayBuffer()` — returns `Promise<ArrayBuffer>`
- `res.blob()` — returns `Promise<Blob>`
- `res.formData()` — returns `Promise<FormData>`

**Caveats:**

- HTTPS uses the system trust store (or `FF_CA_FILE` / `--ca`)
- Outbound fetch is HTTP/1.1 only (the server accepts HTTP/2 over TLS)
- Redirects **are** followed, up to **5 hops**; `307`/`308` preserve method and
  body, `303` and `301`/`302` on POST downgrade to `GET`. Beyond 5 hops the
  promise rejects with `Too many redirects`. `res.redirected` reports whether
  any hop occurred.
- `AbortController` / `signal` are not supported

See [Limitations](#limitations-vs-node--browser) for concurrency and body caps.

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
        close: (sock, code, reason) => {
            console.log("client disconnected:", code, reason);
        },
    },
}, (url, method, body) => new Response("ws endpoint", { status: 200 }));
```

The server-side `sock` object exposes:

- `sock.send(text)` — send a UTF-8 text frame
- `sock.sendBinary(buffer)` — send a binary frame (`ArrayBuffer` or `Uint8Array`)

**Binary frames:**

```js
ws.onmessage = (e) => {
    if (e.data instanceof Uint8Array) {
        console.log("binary:", e.data.length, "bytes");
    } else {
        console.log("text:", e.data);
    }
};
```

### WebSocket client

```js
// ws_client.js
const ws = new WebSocket("ws://127.0.0.1:8080");
ws.onopen = () => ws.send("hello server");
ws.onmessage = (e) => console.log("got:", e.data);
ws.onclose = (e) => console.log("closed:", e.code, e.reason);
ws.onerror = (e) => console.error("error:", e);
```

The **client** `WebSocket` exposes `ws.readyState` — `CONNECTING` / `OPEN` /
`CLOSING` / `CLOSED` — plus the static constants
`WebSocket.CONNECTING`, `.OPEN`, `.CLOSING`, `.CLOSED`.

### TLS: HTTPS and WSS servers

Fairyfly ships with a built-in TLS stack ([BearSSL](https://www.bearssl.org)) —
no OpenSSL dependency, no system libraries. The same `http.serve` code serves
plain HTTP and HTTPS; TLS is enabled per server, and WebSocket (`wss://`)
rides on it for free.

**Enable TLS from JavaScript** (cert/key accept file paths *or* inline PEM
content — anything starting with `-----BEGIN` is treated as PEM):

```js
// tls_server.js
http.serve({
    port: 8443,
    tls: {
        cert: "cert.pem",   // path, or PEM string
        key:  "key.pem",
    },
    websocket: {
        message: (sock, msg) => sock.send(`echo: ${msg}`),
    },
}, (url, method, body) => new Response("hello over tls"));
```

**Or enable it from the CLI** (applies to whatever `ff start` runs):

```sh
ff start --cert cert.pem --key key.pem
# env fallback: FF_CERT / FF_KEY
```

If both are given, the JS-level `tls` config wins (it is applied when the
listener starts). A failed TLS config throws a `TypeError` — the server
never starts half-configured.

**WebSocket over TLS (wss):** nothing extra — connect with `wss://` on the
same port:

```js
const ws = new WebSocket("wss://localhost:8443/ws");
ws.onopen = () => ws.send("hello over tls");
```

**Trusting the server:**

- The runtime's own clients (`fetch`, `WebSocket`) trust the served cert
  automatically when it was given as a file path (`tls.cert` or `--cert`) —
  so `fetch("https://localhost:8443")` works against your own server.
- To trust it from a separate script, pass the cert as a CA:

```sh
ff client.js --ca cert.pem      # or env: FF_CA_FILE=cert.pem
```

**Generating a dev certificate** (SANs matter — the runtime verifies the
hostname; use `localhost`, not `127.0.0.1`, unless the SAN includes the IP):

```sh
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout key.pem -out cert.pem -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
```

**Notes & limitations:**

- TLS 1.2 (BearSSL does not implement TLS 1.3)
- RSA or EC keys; RSA is recommended. Ed25519 server certs are not supported yet.
- Zero allocations on the TLS hot path
- Builds can opt out entirely: `zig build -Dbearssl=false`

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

**URLSearchParams** for working with query strings:

```js
const params = new URLSearchParams("page=1&limit=10&tag=zig&tag=fairyfly");
console.log(params.get("page"));      // "1"
console.log(params.getAll("tag"));    // ["zig", "fairyfly"]
console.log(params.has("limit"));     // true

params.append("sort", "desc");
console.log(params.toString());       // "page=1&limit=10&tag=zig&tag=fairyfly&sort=desc"

params.delete("page");
console.log(params.entries());        // [["limit","10"],["tag","zig"],["tag","fairyfly"],["sort","desc"]]
```

**Non-throwing parse** with `URL.parse`:

```js
const valid = URL.parse("https://example.com");
console.log(valid);   // URL { ... }

const invalid = URL.parse("not a url");
console.log(invalid); // null

console.log(URL.canParse("https://example.com")); // true
console.log(URL.canParse("not a url"));           // false
```

### Headers

`Headers` is a case-insensitive collection of HTTP headers:

```js
const h = new Headers({
    "Content-Type": "application/json",
    "X-Custom": "hello",
});

h.append("X-Custom", "world");
console.log(h.get("x-custom"));       // "hello, world" (case-insensitive)
console.log(h.has("content-type"));   // true
console.log(h.size());                // 2  — note: a method, not a getter

h.delete("x-custom");
console.log(h.keys());                // ["content-type"]
```

**Iterate with forEach:**

```js
const h = new Headers({ "Accept": "text/html", "Authorization": "Bearer token" });
h.forEach((value, name) => {
    console.log(`${name}: ${value}`);
});
```

**Create from array of pairs:**

```js
const h = new Headers([
    ["Accept", "application/json"],
    ["X-Request-Id", "123"],
]);
```

### File system

All `fs` methods are **synchronous** (blocking):

```js
// Write a file
fs.writeFile("./data.json", JSON.stringify({ hello: "world" }));

// Read a file
const content = fs.readFile("./data.json");
console.log(content);  // '{"hello":"world"}'

// Check if a path exists
console.log(fs.exists("./data.json"));   // true
console.log(fs.exists("./missing.txt")); // false

// Create a directory
fs.mkdir("./logs/2026", true);  // recursive = true

// List a directory
const files = fs.readdir("./src");
console.log(files);  // ["main.js", "utils.js", ...]

// Remove a file
fs.rm("./temp.txt");

// Remove a directory and everything inside it
fs.rm("./logs", true);  // recursive = true
```

**Error handling** — all methods throw on failure:

```js
try {
    const data = fs.readFile("./nonexistent.txt");
} catch (e) {
    console.error("Failed:", e.message);  // "FileNotFound"
}
```

### SQLite database

Fairyfly includes a built-in SQLite database. No external packages needed.

**Opening a database:**

```js
// In-memory database (lost when process exits)
const db = Database.open(":memory:");

// File-based database (persists across restarts)
const db = Database.open("./data.sqlite");

// WAL mode and 5s busy timeout are enabled automatically
```

**Creating tables and inserting data:**

```js
const db = Database.open("./app.db");

// execNoArgs for multi-statement SQL
db.execNoArgs(`
    CREATE TABLE IF NOT EXISTS users (
        id    INTEGER PRIMARY KEY AUTOINCREMENT,
        name  TEXT NOT NULL,
        email TEXT UNIQUE NOT NULL
    )
`);

// exec for single statements with parameter binding
// ? placeholders prevent SQL injection
db.exec("INSERT INTO users (name, email) VALUES (?, ?)", ["Alice", "alice@example.com"]);
db.exec("INSERT INTO users (name, email) VALUES (?, ?)", ["Bob", "bob@example.com"]);

// lastInsertRowId() returns the auto-generated ID
const id = db.lastInsertRowId();
console.log("Created user:", id);
```

**Querying data:**

```js
// row() — single row as an object, or null if no results
const user = db.row("SELECT * FROM users WHERE id = ?", [1]);
console.log(user.name);   // "Alice"

// rows() — all matching rows as an array
const all = db.rows("SELECT * FROM users ORDER BY name ASC");

// count rows affected by INSERT/UPDATE/DELETE
db.exec("UPDATE users SET name = ? WHERE id = ?", ["Alicia", 1]);
console.log(db.changes());  // 1
```

**Transactions:**

```js
db.transaction(() => {
    db.exec("UPDATE accounts SET balance = balance - ? WHERE id = ?", [100, 1]);
    db.exec("UPDATE accounts SET balance = balance + ? WHERE id = ?", [100, 2]);
});
// If anything throws, the transaction rolls back automatically
```

**Supported parameter types:**

| JS Type | SQLite Type |
|---------|-------------|
| `number` (integer) | `INTEGER` |
| `number` (float) | `REAL` |
| `string` | `TEXT` |
| `null` | `NULL` |
| `boolean` | `INTEGER` (1 or 0) |
| `ArrayBuffer` / `Uint8Array` | `BLOB` |

Full reference: [`Database` methods](#database-methods) and
[docs/api/sqlite.md](docs/api/sqlite.md).

**Closing the database:**

```js
db.close();
```

### PostgreSQL

A native Postgres client ships with the runtime — `sql` and `SQL` are globals,
no import and no package required.

```js
// todos.js
const sql = new SQL("postgres://fairyfly:fairyfly@127.0.0.1:5432/fairyfly");

await sql`CREATE TABLE IF NOT EXISTS todos (
  id serial PRIMARY KEY,
  title text NOT NULL,
  done boolean NOT NULL DEFAULT false
)`;

await sql`INSERT INTO todos(title) VALUES (${"buy milk"})`;

const rows = await sql`SELECT id, title, done FROM todos WHERE done = ${false}`;
console.log(rows);
// [ { id: 1, title: "buy milk", done: false } ]
```

```sh
ff todos.js
```

Interpolated values are always sent as **parameters**, never string-spliced —
the tagged template turns `${x}` into `$1`, `$2`, … `sql.unsafe(sqlString, params)`
stays parameterized too.

**Connecting.** `new SQL(dsn)` builds a pool around that DSN. The global `sql`
is preconfigured from the environment, checked in order: `PG_TEST_DSN`,
`DATABASE_URL`, then `PGHOST` / `PGPORT` / `PGUSER` / `PGPASSWORD` /
`PGDATABASE`, then defaults (`127.0.0.1:5432`). Connections are lazy; the pool
caps at 10.

**Transactions:**

```js
const tx = await sql.begin();
try {
    await tx`UPDATE accounts SET balance = balance - ${100} WHERE id = ${1}`;
    await tx`UPDATE accounts SET balance = balance + ${100} WHERE id = ${2}`;
    await tx.commit();
} catch (e) {
    await tx.rollback();
    throw e;
}
```

**Type mapping:** `bool`, `int2/int4/int8` (int8 beyond ±2⁵³ becomes `BigInt`),
`float4/float8`, `bytea` → `Uint8Array`, `json`/`jsonb` → parsed value, and
Postgres arrays → JS arrays.

Authentication: cleartext, MD5, and SCRAM-SHA-256. Full reference:
[docs/api/postgres.md](docs/api/postgres.md).

> Run `docker compose up -d` to start the bundled Postgres 16 fixture used by
> `test/sql.test.js`, `test/sql3.test.js`, and `test/todo.test.js`.

### Crypto

Fairyfly includes the `crypto` global for random values, UUIDs, and
cryptographic hashing:

```js
// Generate a random UUID (v4)
const id = crypto.randomUUID();
console.log(id);  // "550e8400-e29b-41d4-a716-446655440000"

// Fill a typed array with random bytes
const bytes = new Uint8Array(16);
crypto.getRandomValues(bytes);

// SHA-256 hash (returns a Promise)
const data = new TextEncoder().encode("hello world");
const hash = await crypto.subtle.digest("SHA-256", data);
console.log(new Uint8Array(hash));  // Uint8Array of 32 bytes

// Other algorithms: "SHA-1", "SHA-384", "SHA-512"
```

**Base64 encoding/decoding:**

```js
const encoded = btoa("hello world");
console.log(encoded);  // "aGVsbG8gd29ybGQ="

const decoded = atob("aGVsbG8gd29ybGQ=");
console.log(decoded);  // "hello world"
```

### Text encoding

`TextEncoder` and `TextDecoder` convert between strings and byte arrays:

```js
// Encode a string to bytes
const encoder = new TextEncoder();
const bytes = encoder.encode("hello world");
console.log(bytes);           // Uint8Array [104, 101, 108, 108, 111, ...]
console.log(bytes.length);    // 11

// Decode bytes to a string
const decoder = new TextDecoder();
const text = decoder.decode(bytes);
console.log(text);            // "hello world"

// Both always use UTF-8
console.log(encoder.encoding); // "utf-8"
console.log(decoder.encoding); // "utf-8"
```

### Performance timing

`performance.now()` returns a high-resolution timestamp in milliseconds:

```js
const start = performance.now();
// ... do some work ...
const elapsed = performance.now() - start;
console.log(`Work took ${elapsed.toFixed(2)}ms`);
```

This uses `CLOCK_MONOTONIC` — it's not affected by system clock changes and
is ideal for benchmarking code sections.

### Workers

CPU-bound work runs on `Worker` threads — each worker is an OS thread with
its own JS runtime and event loop. Threads share no state; they talk through
message passing with structured clone (same model as Node, Bun, and Deno).

```js
// main.js
const w = new Worker("./hash-worker.js", {
    data: { rounds: 100000 },   // cloned once, visible as workerData
});
w.onmessage = (e) => {
    console.log("hash:", e.data.hex, "in", e.data.ms, "ms");
    w.terminate();
};
w.onerror = (e) => console.error("worker failed:", e.message);
w.postMessage({ password: "hunter2", salt: "pepper" });
```

```js
// hash-worker.js (worker scope: console + timers only — pure JS here)
const cfg = globalThis.workerData;   // { rounds: 100000 }
function fnv1a(str) {
    let h = 0x811c9dc5;
    for (let i = 0; i < str.length; i++) {
        h ^= str.charCodeAt(i);
        h = Math.imul(h, 0x01000193);
    }
    return ("0000000" + (h >>> 0).toString(16)).slice(-8);
}
onmessage = (e) => {
    const t0 = performance.now();
    let acc = e.data.password + e.data.salt;
    for (let i = 0; i < cfg.rounds; i++) acc = fnv1a(acc + i);
    postMessage({ hex: acc, ms: Math.round(performance.now() - t0) });
};
```

**Cloned as-is:** objects, arrays, `Date`, `RegExp`, `Map`/`Set`,
`ArrayBuffer` (copied), `BigInt`, `undefined` keys, cyclic graphs.
`Error` objects arrive revived with name/message/stack.

**Rejected with `TypeError`:** functions, `WeakMap`/`WeakSet`, getters.

**Limits:** max 8 workers, 32 MB heap + 1 MB JS stack each (8 MB thread
stack), 4 MB per message. Workers exit only via `terminate()`; the process
exits once all workers are terminated. No nested workers yet.

> Worker files are evaluated as **classic scripts**, not ES modules —
> `import`/`export` inside a worker throws.

### Working with modules

```js
// math.js
export function add(a, b) { return a + b; }
export function multiply(a, b) { return a * b; }
export const PI = 3.14159;
```

```js
// main.js
import { add, multiply, PI } from "./math.js";
console.log(add(2, 3));         // 5
console.log(multiply(4, 5));    // 20
console.log(PI);                // 3.14159
```

Module paths:

- Relative: `./foo.js`, `../bar.js` — include the extension. If omitted, the
  loader probes `X.js`, then `X/index.js`.
- Absolute: `/abs/path/to/file.js`
- Bare: `nanoid` resolves through `node_modules/`, populated by
  [`ff imprint`](docs/guides/packages.md)

The `import.meta.url` property contains the `file://` URL of the current
module:

```js
console.log(import.meta.url);  // "file:///path/to/module.js"
```

---

## Built-in API reference

### Globals

| Name | Description |
|---|---|
| `console` | `log`, `info`, `debug`, `warn`, `error`, `detail`, `slops`, `redbal`, `time`, `timeLog`, `timeEnd` — first 2 args, stderr |
| `setTimeout`, `clearTimeout` | One-shot timer scheduling (max 128 concurrent) |
| `setInterval`, `clearInterval` | Repeating timer scheduling |
| `queueMicrotask` | Queue a microtask (runs before next I/O/timer) |
| `performance` | `performance.now()` — high-resolution monotonic timestamp |
| `URL`, `URLSearchParams` | WHATWG-style URL parser and query string manipulation |
| `Headers`, `Request`, `Response` | Fetch API primitives |
| `Blob` | Binary data container |
| `FormData` | Multipart/form-data container |
| `TextEncoder`, `TextDecoder` | UTF-8 string and byte array conversion |
| `fetch` | HTTP client (Promise-based), HTTP/1.1, 16 concurrent |
| `WebSocket` | WebSocket client (max 64 sockets) |
| `Database` | SQLite database (via `Database.open(path)`) |
| `sql`, `SQL`, `Tx` | Postgres — tagged templates, pools, transactions |
| `crypto` | `randomUUID`, `getRandomValues`, `subtle.digest` |
| `btoa`, `atob` | Base64 encode/decode |
| `fs` | `readFile`, `writeFile`, `exists`, `mkdir`, `rm`, `readdir` (all sync) |
| `process` | `exit`, `cwd`, `chdir`, `pid`, `platform`, `arch`, `env`, `argv` |
| `http` | `http.serve(options, handler)` — start an HTTP/HTTPS server |
| `ffi` | `dlopen`, `struct`, `union`, `callback` — C-ABI shared libraries (needs `--allow-ffi`) |
| `Worker` | `new Worker(path, {data})`, `postMessage`, `onmessage`, `onerror`, `terminate` (max 8) |
| `import.meta.url` | `file://` URL of the current module (per-module, not a global) |

### Response static methods

| Method | Signature | Description |
|---|---|---|
| `Response.json(value, init?)` | `(any, { status?, headers? }) -> Response` | JSON response shortcut |
| `Response.redirect(url, status?)` | `(string, number?) -> Response` | Redirect response (default 302) |
| `Response.error()` | `() -> Response` | Error response (status 0) |

### Database methods

| Method | Signature | Description |
|---|---|---|
| `Database.open(path)` | `(string) -> Database` | Open or create a SQLite database |
| `db.exec(sql, params?)` | `(string, Array?) -> undefined` | Execute SQL with optional parameters |
| `db.execNoArgs(sql)` | `(string) -> undefined` | Execute multi-statement SQL without parameters |
| `db.row(sql, params?)` | `(string, Array?) -> object or null` | Fetch one row or null |
| `db.rows(sql, params?)` | `(string, Array?) -> object[]` | Fetch all matching rows |
| `db.changes()` | `() -> number` | Rows affected by last exec |
| `db.lastInsertRowId()` | `() -> number` | ID of last inserted row |
| `db.transaction(fn)` | `(Function) -> any` | Execute in a transaction (auto-rollback on error) |
| `db.close()` | `() -> undefined` | Close the database |
| `db.busyTimeout(ms)` | `(number) -> undefined` | Set busy timeout |

### SQL (Postgres) methods

| Method | Signature | Description |
|---|---|---|
| `sql\`...\`` | `` (template) -> Promise<rows> `` | Parameterized query via tagged template |
| `sql.unsafe(str, params?)` | `(string, Array?) -> Promise<rows>` | Query built from a string, still parameterized |
| `sql.connect()` | `() -> Promise<undefined>` | Probe the pool (`SELECT 1`), rejects if unreachable |
| `sql.begin()` | `() -> Promise<Tx>` | Start a transaction, pinning one connection |
| `sql.close()` | `() -> undefined` | Close the default pool |
| `tx\`...\`` | `` (template) -> Promise<rows> `` | Query inside the transaction |
| `tx.commit()` / `tx.rollback()` | `() -> Promise<undefined>` | End the transaction |
| `new SQL(dsn)` | `(string) -> SQL` | Pool bound to a specific DSN |

---

## Performance

### macOS (Apple silicon, kqueue)

`wrk -t 8 -c 100 -d 10s`, all runtimes serving the same hello-world handler:

| Runtime       | Req/sec   | p50    | p99    | Peak RSS |
|---------------|-----------|--------|--------|----------|
| **Fairyfly**  | **138k**  | **0.66 ms** | **0.85 ms** | **5 MB** |
| Deno 2.9      | 110k      | 0.86 ms | 1.00 ms | 48 MB    |
| Bun 1.4       | 107k      | 0.87 ms | 1.71 ms | 34 MB    |
| Node 23       | 69k       | 1.36 ms | 1.69 ms | 82 MB    |

### Linux (io_uring vs epoll)

hyperfine × wrk `-t4 -c100 -d 10s`, 3-run medians across two campaigns,
Linux aarch64 VM, musl `ReleaseFast` builds, same hello-world handler:

| Runtime | req/s (io_uring) | req/s (epoll) | Peak RSS (io_uring / epoll) |
|---|---|---|---|
| **Fairyfly** | **309k** | 171k | **10 MB / 16 MB** |
| Deno 2.9.7 | 248k | 247k | 44 MB / 44 MB |
| Bun 1.4.2 | 187k | 184k | 34 MB / 35 MB |
| Node 18 | 55k | 57k | 88 MB / 88 MB |

Fairyfly with io_uring is **~1.8× its own epoll backend** (≈2× on the
`wrk.sh` harness), **+25% throughput over Deno** with **~4× lower peak
RSS** on this workload.

> These are VM-relative numbers: compare rows within a table, not across
> tables or against other machines. Hello-JSON keep-alive is one workload;
> TLS/WebSocket/Postgres paths are not represented here.

**Reproducing:** [`bench/_bench/wrk.sh`](bench) (wrk + RSS sampling),
[`bench/_bench/hyperfine-http.sh`](bench) (3-run medians per runtime).
Server-side numbers use `ReleaseFast` builds (`make build`). Broader
interpreter and I/O comparisons live in [`bench/run-bench.sh`](bench) and
[`bench/mem-bench.sh`](bench).

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
                   │ C ABI (src/c.zig -> quickjs_shim.zig)
┌──────────────────▼───────────────────────────────┐
│ Zig API layer                                     │
│   api/  - console, fs, process, crypto, url,      │
│           fetch, websocket_client, sqlite, sql    │
│   net/  - http_native (SoA 512-slot server),      │
│           http2_server, pg_client, async_fetch    │
│   event/- loop, timers, microtasks                │
│   types/- Headers, Request, Response, Blob,       │
│           FormData, PoolSlice                     │
│   worker/- worker, message_port, serialize        │
└──────────────────┬───────────────────────────────┘
                   │
┌──────────────────▼───────────────────────────────┐
│ libxev event loop (io_uring/epoll, kqueue on mac) │
└──────────────────────────────────────────────────┘
```

**Hot-path design:**

- SoA layout for connection slots (512× parallel arrays, packed 1-byte flags)
- Static per-slot buffers reused across connections; heap spill is counted,
  not hidden
- `HeadersData` is a heap object with an atomic refcount, shared by
  `Request`/`Response`/`Headers` and handed across the fetch threads
- URL objects: one allocation per URL; components are pooled slices, so
  property reads are zero-copy
- Worker messaging: one small alloc + memcpy per message, zero per-iteration
  cost when idle; the parent drains once per tick and exits at liveCount 0
- Postgres: per-job arena (32 KB retain cap) + job freelist, so a warm query
  path allocates nothing

---

## Building from source

Requirements:

- **Zig 0.16** (uses 0.16.0 std APIs)
- C compiler (clang on macOS, gcc on Linux)
- A POSIX system (macOS or Linux)

### The vendors are not committed

`vendor/quickjs`, `vendor/bearssl`, `vendor/sqlite`, and `vendor/nghttp2` are
**gitignored** — a fresh clone has no C sources and `zig build` will fail
until they are fetched.

| Dependency | Version | Purpose |
|---|---|---|
| [quickjs-ng](https://github.com/quickjs-ng/quickjs) | 0.16.2 | The JS engine |
| [BearSSL](https://www.bearssl.org) | 0.6 | TLS for HTTPS/WSS (optional, `-Dbearssl=false` to drop) |
| [SQLite](https://sqlite.org) | 3.53.4 | The `Database` global |
| [nghttp2](https://nghttp2.org) | 1.70.0 | HTTP/2 framing + HPACK |

### Option A — Docker (recommended)

The Dockerfile fetches all four at pinned versions, generates the Zig bridge
headers, and cross-compiles a static musl binary:

```sh
docker build -t fairyfly .
```

### Option B — local build

First fetch the vendors, then `make install`:

```sh
#!/bin/sh
set -e

# quickjs-ng 0.16.2
curl -fL https://github.com/quickjs-ng/quickjs/archive/refs/tags/v0.16.2.tar.gz -o /tmp/qjs.tgz
rm -rf /tmp/qjs vendor/quickjs && mkdir -p /tmp/qjs vendor/quickjs
tar -xzf /tmp/qjs.tgz -C /tmp/qjs --strip-components=1
cp /tmp/qjs/*.h /tmp/qjs/quickjs.c /tmp/qjs/libregexp.c /tmp/qjs/libunicode.c /tmp/qjs/dtoa.c vendor/quickjs/

# BearSSL 0.6  (skip if you build with -Dbearssl=false)
curl -fL https://www.bearssl.org/bearssl-0.6.tar.gz -o /tmp/bearssl.tgz
rm -rf /tmp/bearssl vendor/bearssl && mkdir -p /tmp/bearssl vendor/bearssl
tar -xzf /tmp/bearssl.tgz -C /tmp/bearssl --strip-components=1
cp -r /tmp/bearssl/src /tmp/bearssl/inc vendor/bearssl/
printf '#ifndef FF_BEARSSL_BRIDGE_H\n#define FF_BEARSSL_BRIDGE_H\n\n#include "bearssl.h"\n\n#endif\n' > vendor/bearssl/zig_bridge.h

# SQLite 3.53.4
curl -fL https://www.sqlite.org/2026/sqlite-amalgamation-30530400.zip -o /tmp/sqlite.zip
rm -rf /tmp/sqlite vendor/sqlite && mkdir -p /tmp/sqlite vendor/sqlite
unzip -q -o /tmp/sqlite.zip -d /tmp/sqlite
cp /tmp/sqlite/sqlite-amalgamation-*/sqlite3.c /tmp/sqlite/sqlite-amalgamation-*/sqlite3.h vendor/sqlite/
printf '#ifndef FF_SQLITE_BRIDGE_H\n#define FF_SQLITE_BRIDGE_H\n\n#include "sqlite3.h"\n\n#endif\n' > vendor/sqlite/zig_bridge.h

# nghttp2 1.70.0
curl -fL https://github.com/nghttp2/nghttp2/releases/download/v1.70.0/nghttp2-1.70.0.tar.gz -o /tmp/nghttp2.tgz
rm -rf /tmp/nghttp2 vendor/nghttp2 && mkdir -p /tmp/nghttp2 vendor/nghttp2/lib vendor/nghttp2/includes
tar -xzf /tmp/nghttp2.tgz -C /tmp/nghttp2 --strip-components=1
cp /tmp/nghttp2/lib/*.c /tmp/nghttp2/lib/*.h vendor/nghttp2/lib/
cp -r /tmp/nghttp2/lib/includes/nghttp2 vendor/nghttp2/includes/

# build + install
make install
```

Then:

```sh
ff -e 'console.log("hello")'
```

### Build options

```sh
zig build -Doptimize=ReleaseFast   # default for `make build`
zig build -Dbearssl=false          # drop TLS support entirely
zig build -Dio_uring=false         # Linux: epoll backend instead of io_uring
zig build -Dversion=1.2.3          # version reported by `ff --version`
zig build test                     # Zig unit tests
make test                          # Zig unit tests + test/run.sh
make ci                            # test/run.sh only
```

### I/O backend on Linux (io_uring)

The Linux backend is **io_uring** by default; **epoll** stays available as a
build-time fallback. Other platforms are unchanged (kqueue on macOS).

| Build | Linux backend |
|---|---|
| `zig build` | io_uring (default) |
| `zig build -Dio_uring=false` | epoll (runs anywhere) |

io_uring needs **Linux 5.1+** and a seccomp profile that allows
`io_uring_setup` / `io_uring_enter` / `io_uring_register`. Docker's default
profile blocks them: run containers with `--security-opt seccomp=unconfined`
or ship an epoll build. If the binary prints

```
ff: I/O backend unavailable (io_uring requires Linux 5.1+ and must not be blocked by seccomp; rebuild with -Dio_uring=false for epoll)
```

it detected a blocked or absent io_uring and exited deliberately — rebuild
with `-Dio_uring=false`.

**Testing io_uring (rc1) — help wanted.** Under sustained load, please
exercise: the HTTP server (plain + TLS), WebSockets, `fetch`, and
PostgreSQL/SQLite query paths. Run `make test` and `ff bench/fetch_spill.js`.
File an issue including `uname -r`, `cat /proc/sys/kernel/io_uring_disabled`,
your seccomp/container setup, `ff --version`, the workload, and throughput /
latency / RSS numbers — plus the same build with `-Dio_uring=false` for
comparison when possible.

Known issues in rc1:

- A failed `db.execNoArgs` leaks SQLite's error message (error paths only).
- A multi-statement query that re-describes columns can leak cached name
  atoms (currently unreachable through the extended query protocol).
- On some custom kernels glibc thread creation fails and `fetch` worker
  threads panic at startup; musl static builds are unaffected.

---
## CLI reference

```
ff init [-y|--yes] [<dir>]
                         Initialize a new project (writes ff.json)
ff imprint [pkg[@ver] ...]
                         Add exact dep(s) to ff.json + ff.lock, fetch pure-JS ESM
ff sever [pkg ...] [--force]
                         Remove dep(s), prune orphans
ff start [--cert cert.pem --key key.pem]
                         Run ff.json's "main" (TLS enabled with cert+key)
ff --watch <file|start> [args...]
                         Restart the child when files change (200ms poll)

ff test [filter]         Run test/*.test.js
ff repl                  Interactive REPL
ff upgrade [--check]     Self-update from GitHub Releases
ff compile <f.js> [-o out.ffbc]
                         Compile to bytecode (run back with ff <file.ffbc>)
ff fmt [--write|--check] <files...>
                         Format via prettier (needs npx/network)
ff -e <code>             Run inline JavaScript code
ff <file.js>             Run a JavaScript file
ff --version             Print runtime version
```

**`ff --watch`** never runs a runtime itself — it polls the project tree
(mtime + size, 200 ms, 100 ms debounce), then SIGTERMs the child, waits up to
500 ms, SIGKILLs, and respawns. `--watch` must be the **first** argument.
Forward everything after the target (e.g. `ff --watch app.js --ca cert.pem`).

Environment variables:

- `FF_ECHO=1` — run the server in echo mode (returns canned response)
- `FF_CERT` / `FF_KEY` — TLS cert/key paths (same as `--cert/--key`)
- `FF_CA_FILE` — CA file for the runtime's own TLS client (fetch/WebSocket)
- `FF_WATCH_PARENT` — set internally by `--watch` (orphan watchdog)

Database:

- `DATABASE_URL`, `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE` —
  configure the global `sql`
- `PG_TEST_DSN` — used by the Postgres test files (they self-skip if unset)

---

## Limitations vs Node / browser

**Modules & language**

- No `require()`, no CommonJS
- ES Modules only; worker files are classic scripts (no `import`/`export`)
- No `Buffer` (use `ArrayBuffer` / `Uint8Array`)
- No browser DOM
- TypeScript is not supported — compile to `.js` first

**HTTP**

- HTTP/2 accepted by the server (TLS + ALPN); outbound clients are HTTP/1.1 only
- Max **512** concurrent HTTP connections
- Request bodies: ~4 KB (headers + body share a 4 KB buffer; beyond → `413`)
- Response bodies: buffered, hard cap **10 MB** (64 KB static stage buffer,
  larger bodies spill to the heap; beyond 10 MB → `500`)
- Response headers capped at 2048 bytes; server-computed
  `Content-Length` / `Transfer-Encoding` / `Connection` are not overridable
- No `Expect: 100-continue`, no chunked **request** bodies
- No idle/keep-alive timeout — only hung handlers are reaped (504 after 30 s)

**Outbound**

- `fetch`: **16** concurrent slots, HTTP/1.1, 30 s I/O timeout, max 5 redirects
- No `AbortController` / `signal` / `timeout` / `redirect` init keys
- WebSocket client: **64** sockets, 16384-byte messages (larger sends truncate)
- Outbound TLS connection pool: **64**

**Timers & loop**

- Max **128** concurrent timers; the 129th throws `TypeError`
- Max **8** extra timer arguments
- No `process.nextTick` — use `queueMicrotask`

**Console**

- Prints only the **first two arguments** of each call
- Writes to **stderr**, not stdout

**Workers**

- Max **8**; 32 MB heap, 1 MB JS stack, 8 MB thread stack each
- 4 MB per message; no `ArrayBuffer` transfer (always copied)
- Worker scope is `console` + timers + `postMessage` — no `fs`, `fetch`, or `http.serve`
- No nested workers; exit only via `terminate()`

**SQLite**

- `db.exec()` runs the **first** statement only — use `db.execNoArgs()` for
  multi-statement SQL
- Positional `?` parameters only (no named `:x` / `$x`)
- Integer columns beyond 2⁵³ lose precision in JS

**Postgres**

- No TLS (`sslmode`), no connection/socket timeouts, no keepalive
- Pool caps at 10 connections
- `rowCount` reflects returned rows only (INSERT/UPDATE row counts are not reported)
- No COPY support

**Process**

- `process.env` is a snapshot taken at boot — assigning to it does not affect
  the OS environment
- No `stdout`/`stdin` streams, no `hrtime`, no `kill`
- No interrupt/watchdog for runaway JS — an infinite loop hangs the process

**Packages**

- `ff imprint` installs **pure-JS ESM** packages only; anything using
  `require(`, `module.exports`, or `node:` imports is rejected
- One flat `node_modules` — a conflicting transitive version is a hard error

---

## License

MPL-2.0 (Mozilla Public License Version 2.0). See [LICENSE](LICENSE).

---

## Acknowledgments

- QuickJS — Fabrice Bellard
- [BearSSL](https://www.bearssl.org) — Thomas Pornin
- libxev — [mitchellh](https://github.com/mitchellh/libxev)
- [nghttp2](https://nghttp2.org) — HTTP/2
- Inspired by Node.js, Bun, and Deno — none of their code is included; this is
  a from-scratch implementation in Zig
