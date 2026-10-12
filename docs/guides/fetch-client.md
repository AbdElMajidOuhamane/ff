---
title: Fetch Client
description: Call other APIs with fetch — GET, POST, JSON, errors, redirects, and HTTPS trust.
order: 2
---

# Fetch Client

`fetch` is global. It reads `method` / `headers` / `body` from the init object and returns a `Promise<Response>`. Everything else in init (`signal`, `timeout`, `redirect`, `credentials`, `cache`, `mode`, …) is ignored. Method names are exact-case standard tokens — lowercase `"post"` is sent as `GET` (see Troubleshooting).

The first argument may be a URL string, a `Request`, or any object with a
string `url` property. A `URL` object is **not** accepted.

## Quick look

```js
// client.js
(async () => {
  const res = await fetch("https://example.com/");
  console.log(res.status); // 200
  console.log(await res.text()); // body text
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

## GET with headers

```js
// client.js
(async () => {
  const res = await fetch("https://api.example.com/users/42", {
    headers: { authorization: "Bearer TOKEN" },
  });

  console.log(res.status); // 200
  console.log(res.ok); // true when 200–299
})();
```

Check `res.ok` — HTTP error statuses **resolve**, they don't throw:

```js
// client.js
(async () => {
  const res = await fetch("https://api.example.com/missing");
  if (!res.ok) {
    console.log("failed:", res.status); // e.g. 404
  }
})();
```

> **Caution:** `fetch` only rejects on transport failures (bad URL, DNS, refused connection, redirect loop, pool exhaustion). A `404` or `500` still resolves — always check `res.ok` or `res.status`.

## POST JSON

```js
// client.js
(async () => {
  const res = await fetch("https://api.example.com/notes", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ text: "buy milk" }),
  });

  const data = await res.json();
  console.log(data); // e.g. { id: 1, text: "buy milk" }
})();
```

```sh
ff client.js
```

`string` bodies — and `URLSearchParams`, which coerces to its query string — reach the wire intact. Everything else is coerced with JS `String()` semantics: a `FormData` or `Blob` arrives as `"[object Object]"`, an `ArrayBuffer` as `"[object ArrayBuffer]"`, a `Uint8Array([104, 105])` as `"104,105"`.

Two body-related rules to remember:

- Supplying a body without a `method` makes `fetch` send **`POST`** (not `GET`).
- `init.headers` accepts a `Headers` instance or a plain object, but **not** an array of `[name, value]` pairs.

> **Known issue:** `fetch` does not multipart-encode `FormData` or send binary bodies as bytes. Build the payload yourself:

```js
// client.js
(async () => {
  const params = new URLSearchParams({ name: "ada" });
  await fetch("https://api.example.com/submit", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: params, // "name=ada" — URLSearchParams stringifies to its query
  });
})();
```

## Reading the response

Every reader works on `Response` (and `Request`). Readers do **not**
consume the body — call any of them, any number of times:

| Reader | Returns |
|--------|---------|
| `await res.text()` | `string` |
| `await res.json()` | parsed JSON (rejects `"Unexpected end of JSON input"` on an empty body) |
| `await res.arrayBuffer()` | `ArrayBuffer` |
| `await res.bytes()` | `ArrayBuffer` — **not** a `Uint8Array`, despite the name |
| `await res.blob()` | `Blob`-API object (`size`, `type`, `text()`, `bytes()`, `arrayBuffer()`) |
| `await res.formData()` | `FormData` (rejects `"FormData unsupported content-type"` when unsupported) |

```js
// client.js
(async () => {
  const res = await fetch("https://example.com/");
  console.log(res.url); // final URL after redirects
  console.log(res.redirected); // true when redirected
  console.log(res.headers.get("content-type"));
  console.log((await res.bytes()).byteLength); // ArrayBuffer → byteLength
})();
```

> **Note:** `res.bodyUsed` stays `false` forever (it is snapshotted at
> construction). Don't use it to detect reads — just re-read.

## Redirects

Redirects are followed automatically, up to **5 hops**. After that `fetch`
rejects with `"Too many redirects"`:

```js
// client.js
(async () => {
  const res = await fetch("https://example.com/old-path");
  console.log(res.redirected); // true
  console.log(res.url); // where it landed
})();
```

There is no `redirect: "manual"` mode — the init key is ignored.

## HTTPS trust

Public CAs work out of the box. For private/self-signed CAs:

| Setup | How |
|-------|-----|
| One-off script | `ff client.js --ca ./ca.pem` (`--ca` works with `ff <file>` and `ff -e` only) |
| Any run, incl. `ff start` | `FF_CA_FILE=./ca.pem ff start` |
| Dev TLS pairing | Starting TLS with `--cert`/`FF_CERT` also trusts that cert for `fetch` |

```sh
FF_CA_FILE=./ca.pem ff client.js
```

> **Note:** `--ca` is **not** accepted by `ff start`. Use `FF_CA_FILE` (or `FF_CERT`) there.

## Practical example: synced mirror

Fetch a list, then POST each item onward, checking every status:

```js
// mirror.js
(async () => {
  const src = await fetch("https://api.example.com/items");
  if (!src.ok) throw new Error(`source: ${src.status}`);

  for (const item of await src.json()) {
    const dst = await fetch("https://backup.example.com/items", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(item),
    });
    console.log(item.id, dst.status);
  }
})();
```

```sh
ff mirror.js
```

## Reference: limits

| Area | Limit | When hit |
|------|-------|----------|
| Concurrent fetches | 16 | The 17th in flight **rejects** with `"Failed to start fetch"` |
| Body stage per slot | 64KB | Larger response bodies spill to the heap |
| Socket I/O timeout | 30s | A stalled connection fails the request |
| Redirects | 5 hops max | Rejects `"Too many redirects"` |
| Abort | Not supported | `signal` / `timeout` init keys ignored |
| Protocol | HTTP/1.1 | No HTTP/2 client |
| Compression | gzip / deflate / zstd | Decoded automatically |

## Troubleshooting

**404 resolves instead of throwing** — by design. Check `res.ok` / `res.status` after every call.

**Lowercase `method: "post"` arrives as `GET`** — method tokens match exactly; anything unrecognized goes out as `GET` (the body is still attached). Use `"POST"`.

**A body with no `method` sends `POST`** — that's intended: a body upgrades the default `GET` to `POST`.

**`FormData` / `Blob` / `Uint8Array` body arrives mangled** — bodies are string-coerced, not serialized (`"[object Object]"`, `"104,105"`). Send `string`, `URLSearchParams`, or a hand-built multipart string instead.

**`[["name","value"]]` headers don't work** — `fetch` doesn't treat an array as a pair list. Pass a plain object or a `Headers`.

**`await res.bytes()` isn't a `Uint8Array`** — on `Response`/`Request`, `bytes()` returns an `ArrayBuffer` (use `byteLength`, or wrap it). `Blob.bytes()` *does* return a `Uint8Array`.

**Caught fetch error has no `.message`** — transport failures reject with plain strings (`"Network error"`, `"Invalid URL"`, `"Too many redirects"`, `"Failed to start fetch"`). Log `String(e)`.

**`Too many redirects`** — the chain exceeded 5 hops. Inspect `res.url` on the last good hop or fix the redirect loop server-side.

**TLS verify fails on a private CA** — pass `--ca` (scripts) or `FF_CA_FILE` (`ff start`). Confirm the PEM path is readable.

**`Failed to start fetch` under load** — more than 16 requests were launched before earlier ones settled; the pool is full and the extra request is rejected up front. Await results (or batch them ≤16 at a time) instead of firing them all at once.
