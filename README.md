<img src="assets/ff.webp" alt="Fairyfly logo" width="120" />

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
   - [Console](#console)
   - [Timers and the event loop](#timers-and-the-event-loop)
   - [HTTP server](#http-server)
   - [Async handlers](#async-handlers)
   - [Fetch client](#fetch-client)
   - [WebSocket server](#websocket-server)
   - [WebSocket client](#websocket-client)
   - [TLS: HTTPS and WSS servers](#tls-https-and-wss-servers)
   - [URL parsing](#url-parsing)
   - [Headers](#headers)
   - [File system](#file-system)
   - [SQLite database](#sqlite-database)
   - [Crypto](#crypto)
   - [Text encoding](#text-encoding)
   - [Performance timing](#performance-timing)
   - [Workers](#workers)
   - [Working with modules](#working-with-modules)
5. [Built-in API reference](#built-in-api-reference)
6. [Performance](#performance)
7. [Architecture](#architecture)
8. [Building from source](#building-from-source)
9. [CLI reference](#cli-reference)
10. [Limitations](#limitations-vs-node--browser)
11. [License](#license)

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
make install


# Run inline code
ff -e 'console.log("hello from fairyfly")'

# Initialize a project (writes ff.json)
f init
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
$ ff hello.js
hello, world!
```

### Console

Fairyfly provides a full `console` object with colored output and timers:

```js
// Basic output methods
console.log("standard output");         // plain text
console.info("informational");          // same as log
console.debug("debug details");         // same as log
console.warn("warning message");        // yellow text
console.error("error occurred");        // red text

// Custom colored output
console.detail("success message");      // green text
console.slops("another warning");       // alias for warn (yellow)
console.redbal("another error");        // alias for error (red)

// Performance timers
console.time("db-query");
// ... some operation ...
console.timeLog("db-query");            // "db-query: 12.345ms"
// ... more work ...
console.timeEnd("db-query");            // "db-query: 45.678ms" (timer removed)

// All methods accept any number of arguments, any type
console.log("count:", 42, "items:", ["a", "b"]);
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
timer.unref();        // process can exit even if timer is still pending
timer.refresh();      // reset the countdown
timer.hasRef();       // check if timer keeps process alive
```

**Max timers**: 128 concurrent timers. After that, new timers queue and wait.

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
    Latency     0.66ms  143.62us   4.56ms   97.27%
    Req/Sec    17.27k   1.30k    19.84k    70.85%
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
const res3 = await fetch("https://httpbin.org/status/404");
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

- HTTPS uses the system trust store
- Outbound fetch is HTTP/1.1 only (the server accepts HTTP/2 over TLS)
- Redirects are not followed yet — 3xx responses are returned as-is

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

The `sock` object exposes:

- `sock.send(text)` — send a UTF-8 text frame
- `sock.sendBinary(buffer)` — send a binary frame (`ArrayBuffer` or `Uint8Array`)
- `sock.readyState` — `CONNECTING` / `OPEN` / `CLOSING` / `CLOSED`

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

Static constants: `WebSocket.CONNECTING`, `.OPEN`, `.CLOSING`, `.CLOSED`.

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
- RSA or EC keys; RSA is recommended
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
console.log([...params.entries()]);   // [["limit","10"],["tag","zig"],["tag","fairyfly"],["sort","desc"]]
```

**Non-throwing parse** with `URL.parse`:

```js
const valid = URL.parse("https://example.com");
console.log(valid);   // URL { ... }

const invalid = URL.parse("not a url");
console.log(invalid); // null

console.log(URL.canParse("https://example.com")); // true
console.log(URL.canParse("not a url"));            // false
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
console.log(h.size());                // 2

h.delete("x-custom");
console.log([...h.keys()]);           // ["content-type"]
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
console.log(user.email);  // "alice@example.com"

// rows() — all matching rows as an array
const all = db.rows("SELECT * FROM users ORDER BY name ASC");
for (const u of all) {
    console.log(`${u.name} <${u.email}>`);
}

// count rows affected by INSERT/UPDATE/DELETE
db.exec("UPDATE users SET name = ? WHERE id = ?", ["Alicia", 1]);
console.log(db.changes());  // 1
```

**Partial updates:**

```js
function updateUser(id, patch) {
    const sets = [];
    const params = [];
    if (typeof patch.name === "string")  { sets.push("name = ?");  params.push(patch.name); }
    if (typeof patch.email === "string") { sets.push("email = ?"); params.push(patch.email); }
    if (sets.length === 0) return db.row("SELECT * FROM users WHERE id = ?", [id]);
    params.push(id);
    db.exec("UPDATE users SET " + sets.join(", ") + " WHERE id = ?", params);
    return db.row("SELECT * FROM users WHERE id = ?", [id]);
}
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

**Closing the database:**

```js
db.close();
```

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
console.log(Array.from(bytes).map(b => b.toString(16).padStart(2, "0")).join(""));

// SHA-256 hash (returns a Promise)
const data = new TextEncoder().encode("hello world");
const hash = await crypto.subtle.digest("SHA-256", data);
console.log(new Uint8Array(hash));  // Uint8Array of 32 bytes

// SHA-512 hash
const bigHash = await crypto.subtle.digest("SHA-512", data);

// Other algorithms: "SHA-1", "SHA-384"
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

**Limits:** max 8 workers, 32 MB heap + 1 MB stack each, 4 MB per message.
Workers exit only via `terminate()`; the process exits once all workers
are terminated. No nested workers yet.

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

- Relative: `./foo.js`, `../bar.js`
- Absolute: `/abs/path/to/file.js`
- Bare specifiers (`foo`) are *not* resolved through `node_modules` —
  Fairyfly has no package manager integration

The `import.meta.url` property contains the `file://` URL of the current module:

```js
console.log(import.meta.url);  // "file:///path/to/module.js"
```

---

## Built-in API reference

### Globals

| Name | Description |
|---|---|
| `console` | `log`, `info`, `debug`, `warn`, `error`, `detail`, `slops`, `redbal`, `time`, `timeLog`, `timeEnd` |
| `setTimeout`, `clearTimeout` | One-shot timer scheduling (max 128 concurrent) |
| `setInterval`, `clearInterval` | Repeating timer scheduling |
| `queueMicrotask` | Queue a microtask (runs before next I/O/timer) |
| `performance` | `performance.now()` — high-resolution monotonic timestamp |
| `URL`, `URLSearchParams` | WHATWG URL parser and query string manipulation |
| `Headers`, `Request`, `Response` | Fetch API primitives |
| `Blob` | Binary data container |
| `FormData` | Multipart/form-data container |
| `TextEncoder`, `TextDecoder` | UTF-8 string and byte array conversion |
| `fetch` | HTTP client (Promise-based) |
| `WebSocket` | WebSocket client |
| `Database` | SQLite database (via `Database.open(path)`) |
| `crypto` | `randomUUID`, `getRandomValues`, `subtle.digest` |
| `btoa`, `atob` | Base64 encode/decode |
| `fs` | `readFile`, `writeFile`, `exists`, `mkdir`, `rm`, `readdir` (all sync) |
| `process` | `exit`, `cwd`, `chdir`, `pid`, `platform`, `arch`, `env`, `argv` |
| `http` | `http.serve(options, handler)` — start an HTTP/HTTPS server |
| `Worker` | `new Worker(path, {data})`, `postMessage`, `onmessage`, `onerror`, `terminate` — threads with structured clone (max 8) |

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
- **-90% memory** vs Deno (~10x lower RSS)
- **-24% p50 latency** vs Deno



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
│           fetch, websocket_client, sqlite          │
│   net/  - http_native (SoA 512-slot server)       │
│   event/- loop, timers, microtasks                │
│   types/- Headers, Request, Response, Blob,       │
│           FormData, PoolSlice                      │
└──────────────────┬───────────────────────────────┘
                   │
┌──────────────────▼───────────────────────────────┐
│ libxev event loop (epoll on Linux, kqueue on mac) │
└──────────────────────────────────────────────────┘
```

**Hot-path design:**

- Zero allocations per request (CountingAllocator asserts `balanced=true`)
- SoA layout for connection slots (512x parallel arrays, packed 1-byte flags)
- Static buffers reused across connections
- HeadersData uses refcounting + lazy cold-struct split for hot/cold separation
- URL objects: one refcounted allocation per URL (components pooled, zero-copy property reads)
- Module interning: import/export strings interned into single arena
- Boot arena owns runtime/event-loop/cache, no syscall-per-alloc at startup
- Worker messaging: one small alloc + memcpy per message, zero
  per-iteration cost when idle; parent drains per tick, exits at liveCount 0

---

## Building from source

Requirements:

- Zig 0.16 (uses 0.16.0 std APIs)
- C compiler (clang on macOS, gcc on Linux) — QuickJS vendored as C source
- A POSIX system (macOS or Linux)

TLS is built in by default (BearSSL, fetched into `vendor/bearssl/`). Disable
with: `zig build -Dbearssl=false`

```sh
git clone <repo>
cd fairyfly
make install         # ReleaseFast build and install
ff examples/hello.js
```



**Docker:**

```sh
docker build -t fairyfly .
```


---

## CLI reference

```
ff <file.js>             Run a JavaScript file
ff -e <code>             Run inline JavaScript code
ff init [<dir>]          Write ff.json in <dir> (default: cwd)
ff start [--cert cert.pem --key key.pem]
                         Run ff.json's "main" (TLS enabled with cert+key)
ff imprint [pkg[@ver] ...]
                         Add exact dep(s) to ff.json + ff.lock, fetch pure-JS ESM
ff sever [pkg ...] [--force]
                         Remove dep(s), prune orphans
ff --version             Print runtime version
```

Environment variables:

- `FF_ECHO=1` — run the server in echo mode (returns canned response)
- `FF_CERT` / `FF_KEY` — TLS cert/key paths (same as `--cert/--key`)
- `FF_CA_FILE` — CA file for the runtime's own TLS client (fetch/WebSocket)

---

## Limitations vs Node / browser

- No `require()`, no CommonJS
- No `node_modules` resolution
- No `Buffer` (use `ArrayBuffer` / `Uint8Array`)
- HTTP/2 accepted by the server (TLS + ALPN); outbound clients are HTTP/1.1 only
- No browser DOM
- TLS 1.2 only (BearSSL does not implement TLS 1.3)
- Response bodies buffered (64 KB cap per response); request bodies <= ~4 KB
- Max 128 concurrent timers
- Max 512 concurrent HTTP connections
- Max 64 concurrent outbound TLS connections
- Workers: max 8, 32 MB heap each; worker scope is console + timers
  (no fs/fetch/crypto yet); no nested workers; 4 MB message cap

---

## License

MPL-2.0 (Mozilla Public License Version 2.0). See [LICENSE](LICENSE).

---

## Acknowledgments

- QuickJS — Fabrice Bellard
- [BearSSL](https://www.bearssl.org) — Thomas Pornin
- libxev — [mitchellh](https://github.com/mitchellh/libxev)
- Inspired by Node.js, Bun, and Deno — none of their code is included; this is
  a from-scratch implementation in Zig
