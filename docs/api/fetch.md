---
title: fetch API
description: fetch reference — signatures, init keys, Response, Request, and Headers.
order: 2
---

# `fetch` API

`fetch` is a global function. It sends one HTTP request and resolves with a `Response` — including for HTTP error statuses like `404` or `500`.

## Quick look

```js
// client.js
const res = await fetch("https://example.com/");
console.log(res.status, res.ok);
console.log(await res.text());
```

```sh
ff client.js
```

## `fetch(url, init?)`

```js
await fetch("https://example.com/");
await fetch("https://example.com/", { method: "GET" });
await fetch("https://example.com/items", {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ text: "hi" }),
});
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `url` | `string` | Request target. `http://` and `https://` only |
| `init.method` | `string` | Default `"GET"` |
| `init.headers` | object / `Headers` | Header pairs, case-insensitive |
| `init.body` | `string \| ArrayBuffer \| Uint8Array \| Blob \| FormData \| URLSearchParams` | Default none |

Only `method` / `headers` / `body` are read. These init keys are **ignored**: `signal`, `timeout`, `redirect`, `credentials`, `cache`, `mode`.

## `Response` reference

The object `fetch` resolves with — and the object your `http.serve` handler returns.

| Member | Type | Description |
|--------|------|-------------|
| `status` | `number` | e.g. `200`, `404` |
| `ok` | `boolean` | `true` when status is 200–299 |
| `url` | `string` | Final URL after redirects |
| `redirected` | `boolean` | `true` when a redirect was followed |
| `headers` | `Headers` | Response headers |
| `bodyUsed` | `boolean` | `true` once the body has been read |
| `text()` | `() => Promise<string>` | Body as text |
| `json()` | `() => Promise<any>` | Body parsed as JSON |
| `arrayBuffer()` | `() => Promise<ArrayBuffer>` | Body as bytes |
| `bytes()` | `() => Promise<Uint8Array>` | Body as typed array |
| `blob()` | `() => Promise<Blob>` | Body as `Blob` |
| `formData()` | `() => Promise<FormData>` | Body parsed as multipart/urlencoded form |

Each body reads **once**:

```js
const res = await fetch("https://example.com/");
console.log(res.bodyUsed); // false
await res.text();
console.log(res.bodyUsed); // true
```

Construction + statics (for handlers and tests):

| Helper | Signature | Notes |
|--------|-----------|-------|
| `new Response(body, init?)` | body: `string \| ArrayBuffer \| null`; init: `{ status?, headers? }` | Defaults to `200`, `content-type: text/plain` when the body has none |
| `Response.json(data, init?)` | any JSON-serializable data | Sets JSON content-type |
| `Response.redirect(url, status?)` | target + status (default 302) | Standard redirect response |
| `Response.error()` | — | Status `0`, type `"error"` |

## `Request` reference

Build requests explicitly when you need to inspect or reuse them:

```js
const req = new Request("https://example.com/items", {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ a: 1 }),
});
console.log(req.method, req.url);
const res = await fetch(req);
console.log(await res.json());
```

| Member | Description |
|--------|-------------|
| `method` / `url` / `headers` | As passed to the constructor |
| `text()` / `json()` / `arrayBuffer()` / `bytes()` / `blob()` / `formData()` | Same readers as `Response`; single-read |

## `Headers` reference

Case-insensitive; names are lowercased internally:

```js
const h = new Headers({ "Content-Type": "text/html" });
h.get("content-type"); // "text/html"
h.set("x-id", "1");
h.append("x-id", "2");
h.getAll("x-id");      // ["1", "2"]
h.has("x-id");         // true
h.delete("x-id");
h.entries(); h.keys(); h.values();
h.forEach((value, key) => console.log(key, value));
h.toString();
h.size;
```

| Method | Description |
|--------|-------------|
| `get(name)` | First value, or `null` |
| `getAll(name)` | All values as an array |
| `has(name)` | Presence check |
| `set(name, value)` | Replace all values |
| `append(name, value)` | Add another value |
| `delete(name)` | Remove the header |
| `entries()` / `keys()` / `values()` / `forEach()` | Iterate |
| `toString()` / `size` | Debug string / header count |

CR/LF characters in header values are dropped.

## Redirects

Followed automatically up to 5 hops. `res.redirected` and `res.url` tell you where the response actually came from. Past 5 hops, `fetch` throws `Too many redirects`. There is no manual-redirect mode.

## Full example

```js
// client.js
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
```

```sh
ff client.js
```

## Limits (summary)

Full table lives in the Limitations reference: 16 concurrent fetches, 64KB body stage per slot, 30s I/O timeout, 5 redirect hops, no abort/`signal`, HTTP/1.1 only.

## See also

- [Fetch Client guide](/guides/fetch-client) — tutorial version of this page
- [HTTP Server guide](/guides/http-server) — serving instead of calling
- [Limitations](/reference/limitations) — every hard cap
