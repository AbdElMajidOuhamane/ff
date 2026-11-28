---
title: Request / Response / Headers
description: Constructors, body readers, statics, and the Headers quirks (getAll, size()).
order: 13
---

# Request / Response / Headers

The three objects shared by `fetch` and `http.serve`:

- **`Request`** — an outbound request (or the inbound one, in a handler)
- **`Response`** — what you return from a handler or get from `fetch`
- **`Headers`** — a case-insensitive header collection

```js
const res = await fetch("https://example.com/api");
res.status;            // 200
res.ok;                // true
const data = await res.json();
```

## `Response`

### Constructor

| | |
|---|---|
| Signature | `new Response(body?, init?)` |
| `body` | `string` \| `ArrayBuffer` \| `Uint8Array` \| [`ReadableStream`](/docs/api/streams) (or `null`/omitted) |
| `init` | `{ status?, statusText?, headers? }` (status must be `100`–`999`, default `200`) |

```js
new Response("hello");
new Response(JSON.stringify(rows), {
  status: 201,
  headers: { "content-type": "application/json" },
});
new Response(null, { status: 204 });
new Response(new Uint8Array([1, 2, 3]), { headers: { "content-type": "application/octet-stream" } });
```

### Properties

| Property | Type | Description |
|---|---|---|
| `status` | `number` | HTTP status |
| `statusText` | `string` | Reason phrase. Fetched responses derive it from `status`; a constructed response keeps the default `"OK"` unless `init.statusText` is given |
| `ok` | `boolean` | `200 ≤ status ≤ 299` |
| `headers` | `Headers` | Live header collection |
| `body` | `ReadableStream \| null` | Stream passed to `new Response(stream)`, `null` for empty bodies, or a closed single-chunk `ReadableStream` for buffered responses |
| `url` | `string` | Final URL (after redirects) — for `fetch` results |
| `redirected` | `boolean` | Whether `fetch` followed a redirect |
| `type` | `string` | `"basic"` (or `"error"` from `Response.error()`) |
| `bodyUsed` | `boolean` | Flips to `true` after the first body reader (`text()`, `json()`, `arrayBuffer()`, `bytes()`, `blob()`, `formData()`); it never blocks a later read |

### Body readers

For buffered responses (including `fetch()` and `Response.file()`), readers do **not** consume — call any reader any number of times, in any order:

| Method | Returns |
|---|---|
| `text()` | `Promise<string>` |
| `json()` | `Promise<any>` |
| `arrayBuffer()` | `Promise<ArrayBuffer>` |
| `bytes()` | `Promise<ArrayBuffer>` — same bytes as `arrayBuffer()`, despite the name; **not** a `Uint8Array` |
| `blob()` | `Promise<Blob>` — a `Blob` instance (`size`, `type`, `slice()`, `text()`, `arrayBuffer()`, `bytes()`) |
| `formData()` | `Promise<FormData>` |
| `clone()` | `Response` — copies headers and buffered body; the original stays readable. A `ReadableStream` body is not carried over (the clone's `body` is an empty, already-closed stream) |

> **Streaming body note:** When `new Response(stream)` is constructed directly with a [`ReadableStream`](/docs/api/streams), `res.text()` only pops chunks already queued synchronously (it does not invoke `pull()` or await async chunks). `arrayBuffer()`, `bytes()`, `blob()`, `formData()`, and `clone()` read only buffered bytes (`""`/empty) without consuming the stream, while `json()` rejects with `Unexpected end of JSON input`. Use `res.body.getReader()` (or stream via `http.serve`) instead.

```js
const res = await fetch(url);
console.log(await res.text());   // "hello"
console.log(await res.text());   // "hello" — re-readable
console.log((await res.bytes()).byteLength); // 5 — ArrayBuffer, not Uint8Array
```

`clone()` copies the buffered body; the source stays intact (it does not tee a stream):

```js
const res = new Response("OKABCDEFGH");
console.log(await res.clone().text()); // "OKABCDEFGH"
console.log(await res.text());         // "OKABCDEFGH" — original intact
```

### Statics

```js
Response.json({ ok: true });                      // application/json body
Response.json({ ok: true }, { status: 201 });
Response.file("./public/index.html");             // reads file, requires --allow-read
Response.redirect("/login");                      // 302 status only — no Location header
Response.redirect("/login", 307);
Response.error();                                 // status 0 — a network-failure marker
```

| Static | Signature | Notes |
|---|---|---|
| `Response.json(value, init?)` | `(any, { status?, statusText?, headers? }) → Response` | Sets `content-type: application/json` |
| `Response.file(path)` | `(string) → Response` | Synchronously reads file (`--allow-read`, 50 MB read cap; `http.serve` enforces 10 MB wire cap), guesses `Content-Type` by extension |
| `Response.redirect(url, status?)` | `(string, number?) → Response` | Throws `Response.redirect requires a URL` if missing. Known issue: no `Location` header is emitted, so no client follows it — send `Location` yourself (see [fetch Gotchas](/docs/api/fetch#gotchas)) |
| `Response.error()` | `() → Response` | `status: 0`, `type: "error"` |

### In an HTTP handler

```js
http.serve({ port: 3000 }, async (url, method, body) => {
  if (method === "POST") {
    const input = JSON.parse(body || "{}");        // body is a string
    return Response.json({ echo: input }, { status: 201 });
  }
  return new Response("not found", { status: 404 });
});
```

`Response.error()` builds a network-error-shaped response (`status: 0`,
`type: "error"`). The WebSocket upgrade is automatic and never passes
through your handler — there is no `{ status: 101 }` return (see
[WebSocket](/docs/api/websocket)).

## `Request`

### Constructor

| | |
|---|---|
| Signature | `new Request(url, init?)` or `new Request(request)` |
| Throws | `Request requires a URL string as first argument` |
| | `Request requires a URL string or Request object as first argument` |

```js
new Request("https://example.com/api");
new Request("https://example.com/api", { method: "POST", body: "{}" });
new Request(otherRequest);                 // clone
```

### Properties

| Property | Type | Description |
|---|---|---|
| `url` | `string` | Target URL |
| `method` | `string` | As given — case preserved (`"post"` stays `"post"`, not uppercased) |
| `headers` | `Headers` | `Headers` instance |
| `bodyUsed` | `boolean` | Always `false` — bodies can be re-read freely (see Gotchas) |
| `cache`, `credentials`, `mode`, `redirect`, `integrity` | `string` | Standard init fields, stored as given |
| `keepalive` | `boolean` | |
| `signal` | `AbortSignal \| undefined` | Abort signal passed via `init.signal` (preserved across `clone()`) |

### Methods

`text()`, `json()`, `arrayBuffer()`, `blob()`, `formData()`, `bytes()`,
`clone()` — same re-readable contract as `Response` (note `Request` has no `.body` getter). Plus:

```js
req.toString();   // the URL
req.toJSON();     // { url, method }
```

## `Headers`

```js
const h = new Headers({ accept: "application/json" });
h.append("accept", "text/plain");
h.get("Accept");         // "application/json, text/plain"  (joined)
h.getAll("accept");      // ["application/json", "text/plain"]
h.has("accept");         // true
h.set("x-trace", "1");
h.delete("x-trace");
h.size();                // total number of header entries (including duplicates) ← METHOD
h.toString();            // "accept: application/json\r\naccept: text/plain"
```

| Method | Signature | Notes |
|---|---|---|
| `get(name)` | `(string) → string \| null` | Multi-values joined with `, ` (except `cookie` → `; `, and `set-cookie` → first value only) |
| `getAll(name)` | `(string) → string[]` | **Non-standard** (removed from the spec) |
| `has(name)` | `(string) → boolean` | |
| `set(name, value)` | `(string, string)` | Replaces existing entries for `name` (uses swap-remove) |
| `append(name, value)` | `(string, string)` | |
| `delete(name, value?)` | `(string, string?) → void` | Deletes all entries for `name`, or only the first entry matching `(name, value)` if `value` is given |
| `size()` | `() → number` | **A method**, not a property; counts raw entries including duplicates |
| `entries()` / `keys()` / `values()` | `() → string[][]` / `string[]` / `string[]` | Return **arrays**, not iterators (`keys()` deduplicates names; `entries()`/`values()` return all raw entries) |
| `forEach(fn)` | `((value, key, parent) => void)` | |
| `toString()` | `() → string` | Raw `name: value` entries joined with `\r\n` (duplicates not merged) |

Names are case-insensitive. Invalid RFC 7230 header names or values containing CR/LF/NUL/CTLs throw a `TypeError` (allocation failure throws instead of dropping); a header is never silently discarded. `delete()` and duplicate-collapsing `set()` use swap-remove internally, so order is not preserved after deletions.

### Iterating

`Headers` itself is **not** iterable — iterate the arrays `entries()` returns:

```js
for (const [name, value] of res.headers.entries()) console.log(name, value);
res.headers.forEach((v, k) => console.log(k, v));
```

## Gotchas

- **`bodyUsed` never prevents a second read** — on `Response` it flips to
  `true` once a body reader has run, while on `Request` it stays `false`. In
  neither case does it block subsequent reads, so don't use it to guard against
  re-reading.
- **Status code range (100–999)** — `status` is bounded to valid 3-digit HTTP status codes. Out-of-range numbers (negative, `< 100`, or `> 999`) fall back to default (`200`, or `302` for `Response.redirect`).
- **Stream body borrow** — In HTTP/1.1 chunked streaming, oversized binary chunks (>16 KB) are emitted one slice per write, copied into the write buffer, and the `Uint8Array` / `ArrayBuffer` backing buffer is retained until the last slice drains. If the producer mutates the buffer in-place while streaming, not-yet-written slices reflect the mutation.
- **HTTP/2 stream responses** — Returning a `ReadableStream` body over HTTP/2 returns `501 Not Implemented`.
- **`headers.size` is a method** — `h.size` evaluates to a function, not a
  number; call `h.size()` for the count. Same for `URLSearchParams.size`.
- `clone()` snapshots headers and buffered body; the source stays readable. A `ReadableStream` body is not carried over — the clone's `body` is an empty, already-closed stream.
- `new Response(body)` copies the bytes; mutating the original afterwards
  does not change the response.
- `Response.redirect(url)` without a URL **throws** — and with one it still sends no `Location` header, so clients never follow it.
- In a handler, the third argument (`body`) is already a **string** — you
  don't call `.text()` on it.

## See also

- [`fetch`](/docs/api/fetch) — using `Request` outbound
- [HTTP Server](/docs/guides/http-server) — returning `Response`
- [Blob and FormData](/docs/api/blobs-formdata) — `blob()` / `formData()`
- [WebSocket](/docs/api/websocket) — the `101` response
