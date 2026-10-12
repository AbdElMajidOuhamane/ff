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
// client.js
(async () => {
  const res = await fetch("https://example.com/api");
  console.log(res.status);          // 200
  console.log(res.ok);              // true
  const data = await res.json();
  console.log(data);
})();
```

## `Response`

### Constructor

| | |
|---|---|
| Signature | `new Response(body?, init?)` |
| `body` | `string` \| `ArrayBuffer` \| `Uint8Array` (or `null`/omitted) |
| `init` | `{ status?, statusText?, headers? }` |

```js
new Response("hello");
new Response(JSON.stringify(rows), {
  status: 201,
  headers: { "content-type": "application/json" },
});
new Response(null, { status: 204 });
new Response(new Uint8Array([1, 2, 3]), { headers: { "content-type": "application/octet-stream" } });
```

Body handling, in order:

| `body` value | Stored as |
|---|---|
| `ArrayBuffer` | Its bytes (copied) |
| `Uint8Array` (or any typed-array view) | Its bytes (copied) |
| `string` | The string |
| `Blob` / `FormData` / other object | **String-coerced** via `String()` → `"[object Object]"` |

`init` reads only `status` (default `200`), `statusText`, and `headers`.
Other keys are ignored. Note that `statusText` starts as `"OK"` and is
only overwritten when you pass one:

```js
new Response("x", { status: 404 }).statusText; // "OK" — not "Not Found"
```

### Properties

| Property | Type | Description |
|---|---|---|
| `status` | `number` | HTTP status |
| `statusText` | `string` | Reason phrase (default `"OK"`) |
| `ok` | `boolean` | `200 ≤ status ≤ 299` |
| `headers` | `Headers` | Live header collection |
| `url` | `string` | Final URL (after redirects) — set by `fetch` / `Response.redirect`; empty for `new Response(...)` |
| `redirected` | `boolean` | Whether `fetch` followed a redirect (or `Response.redirect` flagged it) |
| `type` | `string` | `"basic"` normally; `"error"` for `Response.error()` |
| `bodyUsed` | `boolean` | Always `false` — a snapshot taken at construction (see Gotchas) |

### Body readers

Readers do **not** consume — call any reader any number of times, in any
order:

| Method | Returns |
|---|---|
| `text()` | `Promise<string>` |
| `json()` | `Promise<any>` — rejects `"Unexpected end of JSON input"` on an empty body |
| `arrayBuffer()` | `Promise<ArrayBuffer>` |
| `bytes()` | `Promise<ArrayBuffer>` — same bytes as `arrayBuffer()`, despite the name; **not** a `Uint8Array` |
| `blob()` | `Promise<Blob>` — a Blob-API object (`size`, `type`, `text()`, `bytes()`, `arrayBuffer()`, `slice()`), not built via `new Blob` |
| `formData()` | `Promise<FormData>` — rejects `"FormData unsupported content-type"` when the header isn't multipart/urlencoded |
| `clone()` | `Response` — Known issue: the copy's body comes back **corrupted**, so don't use it; just re-read the original |

```js
// client.js
(async () => {
  const res = new Response("hello");
  console.log(await res.text());   // "hello"
  console.log(await res.text());   // "hello" — re-readable
  console.log((await res.bytes()).byteLength); // 5 — ArrayBuffer, not Uint8Array
})();
```

`blob()` derives the Blob's `type` from the response's `content-type`
header (normalized: parameters stripped, lowercased). File entries built
by `formData()` come back as Blobs too.

`clone()` corrupts instead of teeing — observed verbatim:

```js
// client.js
(async () => {
  const res = new Response("OKABCDEFGH");
  console.log(await res.clone().text()); // "OKOKABCDEF" — corrupted
  console.log(await res.text());         // "OKABCDEFGH" — original intact
})();
```

The corruption only affects pool-backed (string) bodies — a body stored as
an owned byte buffer clones correctly.

### Statics

```js
Response.json({ ok: true });                      // application/json body
Response.json({ ok: true }, { status: 201 });
Response.redirect("/login");                      // 302 status only — no Location header
Response.redirect("/login", 307);
Response.error();                                 // status 0 — a network-failure marker
```

| Static | Signature | Notes |
|---|---|---|
| `Response.json(value, init?)` | `(any, { status?, statusText?, headers? }) → Response` | Body is `JSON.stringify(value)`; sets `content-type: application/json` (only when a value is given) |
| `Response.redirect(url, status?)` | `(string, number?) → Response` | Throws `TypeError: Response.redirect requires a URL` if missing. Default status `302`, `statusText` `"Found"`, `redirected` `true`. Known issue: no `Location` header is emitted, so no client follows it — send `Location` yourself (see [fetch Gotchas](/docs/api/fetch#gotchas)) |
| `Response.error()` | `() → Response` | `status: 0`, `statusText: ""`, `type: "error"` |

### In an HTTP handler

```js
// server.js
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
| Throws | `TypeError: Request requires a URL string as first argument` (no arguments) |
| | `TypeError: Request requires a URL string or Request object as first argument` (first arg is a number/boolean/`null`) |

```js
// client.js
new Request("https://example.com/api");
new Request("https://example.com/api", { method: "POST", body: "{}" });
new Request(otherRequest);                 // clone
```

The first argument may be a URL string, a `Request` (whose fields are
copied), or any other object with a string `url` property. An object
without a string `url` is **not** an error — it just yields an empty `url`.

`init` reads `method` (only if it is a string), `headers`, `body`, `cache`,
`credentials`, `mode`, `redirect`, `integrity`, and `keepalive`. Each of
`cache`/`credentials`/`mode`/`redirect`/`integrity` is coerced to a string.

### Properties

| Property | Type | Description |
|---|---|---|
| `url` | `string` | Target URL |
| `method` | `string` | As given — case preserved (`"post"` stays `"post"`, not uppercased); default `"GET"` |
| `headers` | `Headers` | `Headers` instance |
| `bodyUsed` | `boolean` | `false` (a snapshot at construction) |
| `cache` | `string` | `"default"` (or `"no-store"`, `"reload"`, `"no-cache"`, `"force-cache"`, `"only-if-cached"`, or the raw string) |
| `credentials` | `string` | `"same-origin"` (or `"include"`, `"omit"`, or the raw string) |
| `mode` | `string` | `"cors"` (or `"navigate"`, `"same-origin"`, `"no-cors"`, or the raw string) |
| `redirect` | `string` | `"follow"` (or `"error"`, `"manual"`, or the raw string) |
| `integrity` | `string` | `""` unless set |
| `keepalive` | `boolean` | `false` unless set |

### Methods

`text()`, `json()`, `arrayBuffer()`, `blob()`, `formData()`, `bytes()`,
`clone()` — same contract as `Response` (re-readable; `bytes()` is an
`ArrayBuffer`). `Request.clone()` returns a correct copy. Plus:

```js
req.toString();   // the URL
req.toJSON();     // { url, method }
```

## `Headers`

```js
// client.js
const h = new Headers({ accept: "application/json" });
h.append("accept", "text/plain");
h.get("Accept");         // "application/json, text/plain"  (merged)
h.getAll("accept");      // ["application/json", "text/plain"]
h.has("accept");         // true
h.set("x-trace", "1");
h.delete("x-trace");
h.size();                // number of stored entries         ← METHOD
h.toString();            // "accept: application/json\r\naccept: text/plain"
```

The constructor accepts a `Headers` instance, an array of `[name, value]`
pairs, a plain object, or nothing. Values are stored verbatim (no
sanitizing); **names** are lowercased on insert.

| Method | Signature | Notes |
|---|---|---|
| `get(name)` | `(string) → string \| null` | Values joined with `, ` |
| `getAll(name)` | `(string) → string[]` | **Non-standard** (removed from the spec) |
| `has(name)` | `(string) → boolean` | |
| `set(name, value)` | `(string, string)` | Replaces all values with one |
| `append(name, value)` | `(string, string)` | Adds another entry |
| `delete(name)` | `(string) → void` | Removes every entry with that name (an optional second arg removes only the first `name`+`value` match) |
| `size()` | `() → number` | **A method**, not a property; the number of entries (each `append` counts) |
| `entries()` | `() → [string, string][]` | One pair per entry |
| `keys()` | `() → string[]` | **Unique** names, in first-seen order |
| `values()` | `() → string[]` | One value per entry |
| `forEach(fn)` | `((value, key, parent) => void)` | |
| `toString()` | `() → string` | `name: value` lines joined by CRLF |

Names are case-insensitive; iteration order is insertion order. Because
`getAll` may return several values and `get` joins them, `size()` counts
*entries* while `keys()` counts *unique names* — they differ once you
`append` a duplicate name.

### Iterating

`Headers` itself is **not** iterable — iterate the arrays `entries()` returns:

```js
for (const [name, value] of h.entries()) console.log(name, value);
h.forEach((v, k) => console.log(k, v));
```

## Gotchas

- **`bodyUsed` never flips** — it stays `false` before, during, and after
  every read. Don't branch on it; bodies are simply re-readable.
- **`headers.size` is a function** — `h.size` is `undefined`;
  `h.size()` is the entry count. Same for `URLSearchParams.size`.
- **`get()` merges duplicates** — `get(name)` joins every value with
  `", "`, so it is not the same as "the first value". Use `getAll()` for
  the individual values.
- `clone()` corrupts a `Response`'s pooled body (`"OKABCDEFGH"` →
  `"OKOKABCDEF"`); `Request.clone()` is fine. Re-read instead of cloning.
- `new Response(body)` copies the bytes; mutating the original afterwards
  does not change the response.
- `new Response("x", { status: 404 })` keeps `statusText` `"OK"` — pass a
  `statusText` if you care.
- The `Response` `type` is `"basic"` (not `"default"`) for normal
  responses, and `"error"` for `Response.error()`.
- `Response.redirect(url)` without a URL **throws** — and with one it still sends no `Location` header, so clients never follow it.
- `Request` has no `signal` — there is no `AbortController` in Fairyfly.
- In a handler, the third argument (`body`) is already a **string** — you
  don't call `.text()` on it.

## See also

- [`fetch`](/docs/api/fetch) — using `Request` outbound
- [HTTP Server](/docs/guides/http-server) — returning `Response`
- [Blob and FormData](/docs/api/blobs-formdata) — `blob()` / `formData()`
- [WebSocket](/docs/api/websocket) — the `101` response
