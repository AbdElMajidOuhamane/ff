---
title: Fetch Client
description: Call other APIs with fetch — GET, POST, JSON, errors, redirects, and HTTPS trust.
order: 2
---

# Fetch Client

`fetch` is global. It reads `method` / `headers` / `body` from the init object and returns a `Promise<Response>`. Everything else in init (`signal`, `timeout`, `redirect`) is ignored.

## Quick look

```js
// client.js
const res = await fetch("https://example.com/");
console.log(res.status); // 200
console.log(await res.text()); // body text
```

```sh
ff client.js
```

## GET with headers

```js
// client.js
const res = await fetch("https://api.example.com/users/42", {
  headers: { authorization: "Bearer TOKEN" },
});

console.log(res.status); // 200
console.log(res.ok); // true when 200–299
```

Check `res.ok` — HTTP error statuses **resolve**, they don't throw:

```js
const res = await fetch("https://api.example.com/missing");
if (!res.ok) {
  console.log("failed:", res.status); // e.g. 404
}
```

> **Caution:** `fetch` only throws on network failures (DNS, refused connection, too many redirects). A `404` or `500` still resolves — always check `res.ok` or `res.status`.

## POST JSON

```js
// client.js
const res = await fetch("https://api.example.com/notes", {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ text: "buy milk" }),
});

const data = await res.json();
console.log(data); // e.g. { id: 1, text: "buy milk" }
```

```sh
ff client.js
```

Other body shapes work too — `string`, `ArrayBuffer`, `Uint8Array`, `Blob`, `FormData`, `URLSearchParams`:

```js
const form = new FormData();
form.append("name", "ada");
await fetch("https://api.example.com/submit", { method: "POST", body: form });
```

## Reading the response

Every reader works on `Response` (and `Request`). Each body reads **once** — after that `bodyUsed` is `true`:

| Reader | Returns |
|--------|---------|
| `await res.text()` | `string` |
| `await res.json()` | parsed JSON |
| `await res.arrayBuffer()` | `ArrayBuffer` |
| `await res.bytes()` | `Uint8Array` |
| `await res.blob()` | `Blob` |
| `await res.formData()` | `FormData` |

```js
const res = await fetch("https://example.com/");
console.log(res.url); // final URL after redirects
console.log(res.redirected); // true when redirected
console.log(res.headers.get("content-type"));
console.log((await res.bytes()).length);
```

## Redirects

Redirects are followed automatically, up to **5 hops**. After that `fetch` throws `Too many redirects`:

```js
const res = await fetch("https://example.com/old-path");
console.log(res.redirected); // true
console.log(res.url); // where it landed
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
```

```sh
ff mirror.js
```

## Reference: limits

| Area | Limit | When hit |
|------|-------|----------|
| Concurrent fetches | 16 | The 17th waits for a free slot |
| Body stage per slot | 64KB | Larger bodies spill to chunks/heap |
| I/O timeout | 30s | Slow servers fail |
| Redirects | 5 hops max | Throws `Too many redirects` |
| Abort | Not supported | `signal` / `timeout` init keys ignored |
| Protocol | HTTP/1.1 | No HTTP/2 client |

## Troubleshooting

**404 resolves instead of throwing** — by design. Check `res.ok` / `res.status` after every call.

**`Too many redirects`** — the chain exceeded 5 hops. Inspect `res.url` on the last good hop or fix the redirect loop server-side.

**TLS verify fails on a private CA** — pass `--ca` (scripts) or `FF_CA_FILE` (`ff start`). Confirm the PEM path is readable.

**Hanging with 17+ parallel fetches** — the 16-slot pool is full. Await in batches or raise concurrency by sequencing.
