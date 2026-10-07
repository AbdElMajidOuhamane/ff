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

### Properties

| Property | Type | Description |
|---|---|---|
| `status` | `number` | HTTP status |
| `statusText` | `string` | Reason phrase |
| `ok` | `boolean` | `200 ≤ status ≤ 299` |
| `headers` | `Headers` | Live header collection |
| `url` | `string` | Final URL (after redirects) — for `fetch` results |
| `redirected` | `boolean` | Whether `fetch` followed a redirect |
| `type` | `string` | `"default"` |
| `bodyUsed` | `boolean` | Always `false` — never flips, even after reading (see Gotchas) |

### Body readers

Readers do **not** consume — call any reader any number of times, in any
order:

| Method | Returns |
|---|---|
| `text()` | `Promise<string>` |
| `json()` | `Promise<any>` |
| `arrayBuffer()` | `Promise<ArrayBuffer>` |
| `bytes()` | `Promise<ArrayBuffer>` — same bytes as `arrayBuffer()`, despite the name; **not** a `Uint8Array` |
| `blob()` | `Promise<Blob>` — a plain `Object` with the Blob API (`size`, `type`, `text()`, `bytes()`), not a `Blob` instance |
| `formData()` | `Promise<FormData>` |
| `clone()` | `Response` — Known issue: the copy comes back **corrupted**, so don't use it; just re-read the original |

```js
const res = await fetch(url);
console.log(await res.text());   // "hello"
console.log(await res.text());   // "hello" — re-readable
console.log((await res.bytes()).byteLength); // 5 — ArrayBuffer, not Uint8Array
```

`clone()` corrupts instead of teeing — observed verbatim:

```js
const res = new Response("OKABCDEFGH");
console.log(await res.clone().text()); // "OKOKABCDEF" — corrupted
console.log(await res.text());         // "OKABCDEFGH" — original intact
```

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
| `Response.json(value, init?)` | `(any, { status?, headers? }) → Response` | Sets `content-type: application/json` |
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
| `headers` | `headers` | `Headers` instance |
| `bodyUsed` | `boolean` | Consumed flag |
| `cache`, `credentials`, `mode`, `redirect`, `integrity` | `string` | Standard init fields, stored as given |
| `keepalive` | `boolean` | |

### Methods

`text()`, `json()`, `arrayBuffer()`, `blob()`, `formData()`, `bytes()`,
`clone()` — same contract as `Response`. Plus:

```js
req.toString();   // the URL
req.toJSON();     // { url, method }
```

## `Headers`

```js
const h = new Headers({ accept: "application/json" });
h.append("accept", "text/plain");
h.get("Accept");         // "application/json, text/plain"  (merged)
h.getAll("accept");      // ["application/json", "text/plain"]
h.has("accept");         // true
h.set("x-trace", "1");
h.delete("x-trace");
h.size();                // number of header names          ← METHOD
h.toString();            // "accept: application/json, text/plain\n…"
```

| Method | Signature | Notes |
|---|---|---|
| `get(name)` | `(string) → string \| null` | Values joined with `, ` |
| `getAll(name)` | `(string) → string[]` | **Non-standard** (removed from the spec) |
| `has(name)` | `(string) → boolean` | |
| `set(name, value)` | `(string, string)` | Replaces |
| `append(name, value)` | `(string, string)` | |
| `delete(name)` | `(string) → void` | |
| `size()` | `() → number` | **A method**, not a property |
| `entries()` / `keys()` / `values()` | `() → string[][]` / `string[]` / `string[]` | Return **arrays**, not iterators |
| `forEach(fn)` | `((value, key, parent) => void)` | |
| `toString()` | `() → string` | `name: value` lines |

Names are case-insensitive; iteration order is insertion order.

### Iterating

`Headers` itself is **not** iterable — iterate the arrays `entries()` returns:

```js
for (const [name, value] of res.headers.entries()) console.log(name, value);
res.headers.forEach((v, k) => console.log(k, v));
```

## Gotchas

- **`bodyUsed` never flips** — it stays `false` before, during, and after
  every read. Don't branch on it; bodies are simply re-readable.
- **`headers.size` is a function** — `h.size` is `undefined`;
  `h.size()` is the number. Same for `URLSearchParams.size`.
- `clone()` corrupts the copy (`"OKABCDEFGH"` → `"OKOKABCDEF"`) — re-read
  the original instead of cloning.
- `new Response(body)` copies the bytes; mutating the original afterwards
  does not change the response.
- `Response.redirect(url)` without a URL **throws** — and with one it still sends no `Location` header, so clients never follow it.
- `Request` has no `signal` — there is no `AbortController` in Fairyfly.
- In a handler, the third argument (`body`) is already a **string** — you
  don't call `.text()` on it.

## See also

- [`fetch`](/docs/api/fetch) — using `Request` outbound
- [HTTP Server](/docs/guides/http-server) — returning `Response`
- [Blob and FormData](/docs/api/blobs-formdata) — `blob()` / `formData()`
- [WebSocket](/docs/api/websocket) — the `101` response
