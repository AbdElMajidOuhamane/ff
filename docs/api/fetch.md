---
title: fetch API
description: fetch reference — signatures, init keys, Response, Request, and Headers.
order: 2
---

# `fetch` API

`fetch` is a global function. It sends one HTTP/1.1 request and resolves with a `Response` — including for HTTP error statuses like `404` or `500`. Only transport problems (bad URL, connection failure, redirect loop, pool exhaustion) reject, and those rejections are **plain strings**, not `Error` objects.

## Quick look

```js
// client.js
(async () => {
  const res = await fetch("https://example.com/");
  console.log(res.status, res.ok);
  console.log(await res.text());
})();
```

```sh
ff client.js
```

## Modules vs scripts

`ff` treats a file as an ES module only when its name ends in `.mjs` or
its first code is `import`/`export`. A plain `.js` file runs as a classic
script, where top-level `await` is a syntax error — so the runnable
examples on this page wrap async code in `(async () => { ... })()`. Save
any of them with a `.mjs` extension if you'd rather use top-level `await`
as written.

## `fetch(input, init?)`

The first argument can be:

| `input` | Accepted? | How it is read |
|---------|-----------|----------------|
| `string` | yes | Used as the URL verbatim |
| `Request` | yes | `url`, `method`, `headers` and the request body are all used |
| any other object with a string `url` property | yes | The `url` property is read; everything else is ignored |
| `URL` instance | **no** | A `URL` has no `.url` property (use `url.href` or `String(url)`); the object isn't usable as input |
| number / boolean / `null` / `undefined` | **no** | Throws `TypeError` synchronously |

```js
// client.js
(async () => {
  await fetch("https://example.com/");
  await fetch("https://example.com/", { method: "GET" });
  await fetch("https://example.com/items", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ text: "hi" }),
  });

  // A Request may be passed directly — its fields become the request:
  await fetch(new Request("https://example.com/items", { method: "DELETE" }));

  // A plain object with a string url also works:
  await fetch({ url: "https://example.com/" });
})();
```

If `input` is missing entirely, `fetch` throws
`TypeError: fetch requires a URL string or Request as first argument`.

### Init keys

`init` is read as an object (`fetch(url, "nope")` is treated as no init). Exactly three keys are consulted; **every other key is ignored** — including `signal`, `timeout`, `redirect`, `credentials`, `cache`, `mode`, `integrity`, `keepalive`, and `referrer`.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `method` | `string` | `"GET"` | HTTP method token — **exact case** (see below) |
| `headers` | object / `Headers` | none | Header pairs; case-insensitive |
| `body` | `string \| ArrayBuffer \| Uint8Array \| Blob \| FormData \| URLSearchParams` | none | String-coerced before sending (see Gotchas) |

`init.headers` accepts a `Headers` instance or a plain object of own
enumerable string properties. An **array of `[name, value]` pairs is not
supported here** (unlike `new Headers([...])` / `new Request(url, { headers: [...] })`):
the array's indices are read as property names, so `[["a","b"]]` becomes a
header named `"0"` with value `"a,b"`. Build a plain object or a `Headers`.

### Method handling

`init.method` is matched against these tokens **verbatim**:

| Token | Sent as |
|-------|---------|
| `GET`, `PUT` | as written |
| `HEAD`, `POST` | as written |
| `PATCH` | as written |
| `DELETE` | as written |
| `OPTIONS` | as written |
| anything else (incl. lowercase, `CONNECT`, `TRACE`, custom) | `GET` |

Two consequences:

- Lowercase `"post"` is **not** `POST` — it falls through to `GET`.
- If a `body` is present and the method string is exactly `"GET"`, the
  method is upgraded to `POST`. Because the check is on the raw string, a
  lowercase `"get"` **keeps** the body and is still sent as `GET`.

## `Response` reference

The object `fetch` resolves with — and the object your `http.serve` handler returns.

| Member | Type | Description |
|--------|------|-------------|
| `status` | `number` | e.g. `200`, `404` |
| `statusText` | `string` | Reason phrase (`"OK"`, `"Not Found"`, …) |
| `ok` | `boolean` | `true` when status is 200–299 |
| `url` | `string` | Final URL after redirects |
| `redirected` | `boolean` | `true` when a redirect was followed |
| `type` | `string` | `"basic"` for normal responses, `"error"` for `Response.error()` |
| `headers` | `Headers` | Response headers |
| `bodyUsed` | `boolean` | Always `false` — a snapshot taken at construction (see Gotchas) |
| `text()` | `() => Promise<string>` | Body as text |
| `json()` | `() => Promise<any>` | Body parsed as JSON |
| `arrayBuffer()` | `() => Promise<ArrayBuffer>` | Body as bytes |
| `bytes()` | `() => Promise<ArrayBuffer>` | Body as bytes — an `ArrayBuffer`, **not** a `Uint8Array`, despite the name |
| `blob()` | `() => Promise<Blob>` | Body as a Blob-API object |
| `formData()` | `() => Promise<FormData>` | Body parsed as multipart/urlencoded form |
| `clone()` | `() => Response` | Known issue: the copy's body is corrupted (see Gotchas) |

Body readers do **not** consume — call any reader any number of times, in
any order:

```js
// client.js
(async () => {
  const res = await fetch("https://example.com/");
  console.log(res.bodyUsed);          // false
  console.log(await res.text());      // body
  console.log(res.bodyUsed);          // false — never flips
  console.log(await res.text());      // body again — re-readable
  console.log((await res.bytes()).byteLength); // ArrayBuffer, not a typed array
})();
```

`json()` on an empty body rejects with the plain string
`"Unexpected end of JSON input"`; malformed JSON rejects with the parser's
`SyntaxError`.

### Construction + statics

| Helper | Signature | Notes |
|--------|-----------|-------|
| `new Response(body?, init?)` | body: `string \| ArrayBuffer \| Uint8Array \| null`; init: `{ status?, statusText?, headers? }` | Defaults to status `200`. `statusText` stays `"OK"` unless you pass one. `Blob`/`FormData` bodies are string-coerced to `"[object Object]"` |
| `Response.json(value, init?)` | any JSON-serializable data; init: `{ status?, statusText?, headers? }` | Sets `content-type: application/json` (only when a value is supplied) |
| `Response.redirect(url, status?)` | target + status (default `302`) | Throws `TypeError: Response.redirect requires a URL` when `url` is missing. Known issue: sets the status but emits **no `Location` header**, so no client follows it (see Gotchas) |
| `Response.error()` | — | Status `0`, empty `statusText`, `type` `"error"` |

The `Response` constructor ignores `type`, `url`, `redirected` and any
other init key; only `status`, `statusText`, and `headers` are read. With
no body (or `null`) the body readers resolve empty (`""` / `0` bytes).

`new Response(body)` copies the bytes up front — mutating the source
afterwards does not change the response.

## `Request` reference

Build requests explicitly when you need to inspect or reuse them:

```js
// client.js
(async () => {
  const req = new Request("https://example.com/items", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ a: 1 }),
  });
  console.log(req.method, req.url);
  const res = await fetch(req);
  console.log(await res.json());
})();
```

| Member | Description |
|--------|-------------|
| `method` | As passed (case preserved); default `"GET"` |
| `url` | The target URL |
| `headers` | `Headers` instance |
| `bodyUsed` | `false` — a snapshot at construction |
| `cache` / `credentials` / `mode` / `redirect` / `integrity` | Stored strings; defaults `"default"` / `"same-origin"` / `"cors"` / `"follow"` / `""` |
| `keepalive` | `boolean` (default `false`) |
| `text()` / `json()` / `arrayBuffer()` / `bytes()` / `blob()` / `formData()` | Same readers as `Response`; re-readable |
| `clone()` | Returns a copy (works correctly — unlike `Response.clone()`) |
| `toString()` | The URL |
| `toJSON()` | `{ url, method }` |

See [Request / Response / Headers](/docs/api/request-response) for the
constructor's argument handling and every thrown message.

## `Headers` reference

Case-insensitive; names are lowercased internally, values are stored verbatim:

```js
// client.js
const h = new Headers({ "Content-Type": "text/html" });
console.log(h.get("content-type")); // "text/html"
h.set("x-id", "1");
h.append("x-id", "2");
console.log(h.getAll("x-id"));      // ["1", "2"]
console.log(h.get("X-ID"));         // "1, 2"  — duplicates joined with ", "
console.log(h.has("x-id"));         // true
console.log(h.size());              // 2 — entry count, a METHOD
h.delete("x-id");
h.entries(); h.keys(); h.values();
h.forEach((value, key) => console.log(key, value));
console.log(h.toString());
```

| Method | Description |
|--------|-------------|
| `get(name)` | All values for `name` **joined with `", "`**, or `null` |
| `getAll(name)` | All values as an array (non-standard; removed from the spec) |
| `has(name)` | Presence check |
| `set(name, value)` | Replace all values with one |
| `append(name, value)` | Add another entry |
| `delete(name)` | Remove every entry with that name |
| `entries()` / `keys()` / `values()` / `forEach()` | Iterate (arrays, not iterators) |
| `toString()` | `name: value` lines joined by CRLF |
| `size()` | Entry count — a **method**, not a property |

See [Request / Response / Headers](/docs/api/request-response) for the
iteration-return-shape and `size()` details.

## Redirects

Followed automatically, up to **5 hops**. `res.redirected` becomes `true`
and `res.url` is the final URL once any hop is followed. A 6th redirect
rejects with `"Too many redirects"`. There is no manual-redirect mode.

Redirect method/body rules (matching the Fetch standard):

| Status | Method | Body |
|--------|--------|------|
| `303` | becomes `GET` | dropped |
| `301` / `302` after a `POST` | becomes `GET` | dropped |
| `301` / `302` otherwise | unchanged | dropped |
| `307` / `308` | unchanged | re-sent |

A `3xx` response with no `Location` header is **not** followed — it
resolves as-is (with an empty body).

Note: redirects your own `http.serve` handler returns via `Response.redirect()`
carry no `Location` header, so nothing follows them — see Gotchas.

## Response bodies and compression

Responses with `content-encoding: gzip`, `deflate`, or `zstd` are
decompressed transparently before the body readers see them. Any other
`content-encoding` is passed through as raw bytes.

## Full example

```js
// client.js
(async () => {
  async function getJSON(url) {
    const res = await fetch(url, {
      headers: { authorization: "Bearer TOKEN" },
    });
    if (!res.ok) throw new Error(`GET ${url}: ${res.status}`);
    return res.json();
  }

  const items = await getJSON("https://api.example.com/items");
  console.log(items.length, "items");

  const created = await fetch("https://api.example.com/items", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ text: "hello" }),
  });
  console.log("created:", created.status);
})();
```

```sh
ff client.js
```

## Limits (summary)

16 concurrent fetches (the 17th in flight rejects immediately — see
Gotchas), 64KB body stage per slot (larger response bodies spill to the
heap), 30s socket I/O timeout, 5 redirect hops, no abort/`signal`,
HTTP/1.1 only.

## Gotchas

**Method names are exact-case.** `fetch` matches `init.method` against the
standard tokens verbatim — `"POST"`, `"PUT"`, `"PATCH"`, `"DELETE"`,
`"HEAD"`, `"OPTIONS"`, `"GET"`. Anything else, including lowercase
(`"post"`), is sent as `GET` (a body is still attached). Your `http.serve`
handler likewise sees the method exactly as the client sent it, so
normalize before comparing (`method.toUpperCase() === "POST"`).

**Only string bodies reach the wire intact.** Every other body value is
coerced with JS `String()` semantics: a `FormData` or `Blob` arrives as
`"[object Object]"`, an `ArrayBuffer` as `"[object ArrayBuffer]"`, and a
`Uint8Array([104, 105])` as `"104,105"`. `URLSearchParams` survives only
because its `toString()` is the query string. There is no multipart
encoding and no binary-body path — serialize yourself (`JSON.stringify`,
`params.toString()`, base64, or a hand-built multipart string with an
explicit `content-type` header).

**A body flips the method to `POST`.** If you pass a body without a
method, `fetch` sends `POST`, not `GET`.

**`bytes()` is an `ArrayBuffer`.** On `Response`/`Request`, `bytes()`
returns the same `ArrayBuffer` as `arrayBuffer()` — not the `Uint8Array`
the name suggests. (On `Blob`, `bytes()` *does* return a `Uint8Array`; see
[Blob and FormData](/docs/api/blobs-formdata).)

**`bodyUsed` never becomes `true`.** It is captured when the object is
built (always `false`), so it never reflects reads. Bodies are simply
re-readable; don't branch on `bodyUsed`.

**`clone()` corrupts the copy for string-bodied responses.** The clone's
body slice lands at the wrong offset, so it reads garbage ("OKOKABCDEF"
instead of "OKABCDEFGH"). Don't clone a `Response` — re-read the original.
`Request.clone()` is fine.

**The 17th concurrent fetch rejects.** The worker pool holds 16 slots.
Because `fetch` claims a slot synchronously, launching a 17th request
before any settle rejects it with `"Failed to start fetch"`. Await in
batches (or sequence) rather than firing more than 16 at once.

**`Response.redirect()` sends no `Location` header.** It sets the status
(default 302) and flags the object as redirected, but clients never follow
it. Build the response yourself when clients must follow:

```js
return new Response(null, { status: 302, headers: { Location: "/new-path" } });
```

**Rejections are plain strings.** Network failures reject with
`"Network error"`, bad URLs with `"Invalid URL"`, long chains with
`"Too many redirects"`, pool exhaustion with `"Failed to start fetch"` —
`e.message` is `undefined`, so log `String(e)`.

## See also

- [Fetch Client guide](/docs/guides/fetch-client) — tutorial version of this page
- [Request / Response / Headers](/docs/api/request-response) — constructor and member details
- [Blob and FormData](/docs/api/blobs-formdata) — `blob()` / `formData()`
- [HTTP Server guide](/docs/guides/http-server) — serving instead of calling
- [Limitations](/docs/reference/limitations) — every hard cap
