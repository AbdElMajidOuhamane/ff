---
title: fetch API
description: fetch reference — signatures, init keys, Response, Request, and Headers.
order: 2
---

# `fetch` API

`fetch` is a global function. It sends one HTTP request and resolves with a `Response` — including for HTTP error statuses like `404` or `500`.

## Permissions

`fetch` reaches the network, so every request needs `--allow-net`:

| Scope | Grants |
|---|---|
| `--allow-net=api.example.com` | That host on **any** port |
| `--allow-net=api.example.com:443` | That host and port only |
| `--allow-net=*.example.com` | Subdomains, but **not** the apex `example.com` |
| `--allow-net=*` or bare `--allow-net` | Every host and port |

- Matching uses the URL's **literal host**, lowercased. There is no DNS
  resolution and no IP matching: `localhost` and `127.0.0.1` are different
  scopes, and granting `api.example.com` does not permit fetching
  `https://93.184.216.34/`.
- Default ports count. `https://example.com/` checks `example.com:443`;
  `http://example.com/` checks `example.com:80`.
- Every redirect hop is checked independently against the new URL.
- A configured proxy does not change the destination check; see
  [Proxies](#proxies) for the proxy-host caveat.

Failure takes two different shapes:

```js
// Initial URL outside --allow-net: fetch() throws synchronously.
try {
  fetch("https://api.example.com/items");
} catch (e) {
  console.error(e.name, e.code); // PermissionDenied PERMISSION_DENIED
}

// A redirect hop outside --allow-net: the promise rejects with a string.
try {
  await fetch("https://allowed.example.com/");
} catch (e) {
  console.error(String(e)); // PermissionDenied: fetch requires --allow-net
}
```

The initial denial message names the host and port:
`fetch requires --allow-net for 'api.example.com:443'`. The redirect-hop
string carries neither `code` nor the host. Full model:
[Permissions](/docs/concepts/permissions).

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
ff client.js --allow-net=example.com:443
```

## Modules vs scripts

`ff` forces ES module evaluation when a file ends in `.mjs`. For `.js` files,
`ff` tries classic-script compilation first and automatically falls back to ES
module evaluation when the file contains `import`, `export`, or top-level
`await` anywhere in the source. The runnable examples on this page wrap async
code in `(async () => { ... })()` so they also work when pasted into classic-script
contexts.

## `fetch(url, init?)`

```js
await fetch("https://example.com/");
await fetch("https://example.com/", { method: "GET" });
await fetch("https://example.com/items", {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ text: "hi" }),
  signal: AbortSignal.timeout(5000),
});
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `url` | `string \| Request` | Request target. `http://` and `https://` only |
| `init.method` | `string` | Default `"GET"` — exact-case token only (see Gotchas) |
| `init.headers` | object / `Headers` | Header pairs, case-insensitive |
| `init.body` | `string \| ArrayBuffer \| Uint8Array \| Blob \| FormData \| URLSearchParams` | Default none — only strings (and `URLSearchParams`) survive intact (see Gotchas) |
| `init.signal` | `AbortSignal` | Cancels the request if already aborted or aborted while in flight |

Only `method`, `headers`, `body`, and `signal` are read. These init keys are **ignored**: `timeout`, `redirect`, `credentials`, `cache`, `mode`.

## Cancellation: `AbortController` and `AbortSignal`

Use `AbortController` or `AbortSignal.timeout(ms)` to cancel a `fetch` before or
during an in-flight request. Aborting closes the underlying socket immediately
and rejects the `fetch` promise with `signal.reason`:

```js
const ac = new AbortController();
setTimeout(() => ac.abort(new Error("timed out")), 2000);

try {
  const res = await fetch("https://example.com/slow", { signal: ac.signal });
} catch (err) {
  console.error("aborted:", err);
}

// Or use the built-in timeout helper:
const res = await fetch("https://example.com/api", {
  signal: AbortSignal.timeout(3000),
});
```

| Member | Description |
|--------|-------------|
| `new AbortController()` | Creates `{ signal, abort(reason?) }` |
| `AbortSignal.abort(reason?)` | Returns an already-aborted `AbortSignal` |
| `AbortSignal.timeout(ms)` | Returns an `AbortSignal` that aborts with a `"TimeoutError"` after `ms` |
| `signal.aborted` / `signal.reason` | Boolean state and rejection reason (defaults to `"AbortError"`) |
| `signal.throwIfAborted()` | Throws `signal.reason` if `signal.aborted` is `true` |
| `signal.onabort` / `addEventListener("abort", fn, { once? })` / `removeEventListener("abort", fn)` | Abort event listeners |

## `Response` reference

The object `fetch` resolves with — and the object your `http.serve` handler returns.

| Member | Type | Description |
|--------|------|-------------|
| `status` | `number` | e.g. `200`, `404` |
| `ok` | `boolean` | `true` when status is 200–299 |
| `url` | `string` | Final URL after redirects |
| `redirected` | `boolean` | `true` when a redirect was followed |
| `headers` | `Headers` | Response headers |
| `bodyUsed` | `boolean` | Always `false` — bodies can be re-read freely (see Gotchas) |
| `text()` | `() => Promise<string>` | Body as text |
| `json()` | `() => Promise<any>` | Body parsed as JSON |
| `arrayBuffer()` | `() => Promise<ArrayBuffer>` | Body as bytes |
| `bytes()` | `() => Promise<ArrayBuffer>` | Body as bytes in an `ArrayBuffer` |
| `blob()` | `() => Promise<Blob>` | Body as `Blob` |
| `formData()` | `() => Promise<FormData>` | Body parsed as multipart/urlencoded form |

Bodies can be re-read freely (`bodyUsed` remains `false`):

```js
const res = await fetch("https://example.com/");
console.log(await res.text());
console.log(await res.json()); // re-reading the body is supported
console.log(res.bodyUsed);     // false
```

Construction + statics (for handlers and tests):

| Helper | Signature | Notes |
|--------|-----------|-------|
| `new Response(body, init?)` | body: `string \| ArrayBuffer \| Uint8Array \| null`; init: `{ status?, headers? }` | Defaults to `200`, `content-type: text/plain` when the body has none |
| `Response.json(data, init?)` | any JSON-serializable data | Sets JSON content-type |
| `Response.redirect(url, status?)` | target + status (default 302) | Known issue: sets the status but **no `Location` header**, so no client follows it (see Gotchas) |
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
| `method` / `url` / `headers` / `signal` | As passed to the constructor |
| `text()` / `json()` / `arrayBuffer()` / `bytes()` / `blob()` / `formData()` | Same readers as `Response`; re-readable (`bodyUsed` stays `false`) |

`fetch(req)` applies the same `--allow-net` check to `req.url` as it does to a
string URL, including on redirect hops.

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
h.size();              // header count
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
| `toString()` / `size()` | Debug string / header count |

CR/LF characters in header values are dropped.

## Redirects

Followed automatically up to 5 hops. `res.redirected` and `res.url` tell you where the response actually came from. Past 5 hops, `fetch` throws `Too many redirects`. There is no manual-redirect mode.

Every hop is re-checked against `--allow-net`. A redirect from an allowed host
to a host outside the scope rejects the promise with the string
`"PermissionDenied: fetch requires --allow-net"`; the initial request is not
retried and no `Response` is produced.

Note: redirects your own `http.serve` handler returns via `Response.redirect()` carry no `Location` header, so nothing follows them — see Gotchas.

## Proxies

`fetch` honors the standard proxy environment variables. They are read once
at process start — set them before launching `ff`:

| Variable | Applies to |
|----------|------------|
| `HTTP_PROXY` / `http_proxy` | `http://` requests |
| `HTTPS_PROXY` / `https_proxy` | `https://` requests |
| `ALL_PROXY` / `all_proxy` | both, when the protocol-specific variable is unset |
| `NO_PROXY` / `no_proxy` | comma-separated bypass list |

Proxy URLs may include credentials (`http://user:pass@proxy:8080`), which
are sent as `proxy-authorization`. `http://` requests are tunneled with
`CONNECT` (falling back to an absolute-form request line when the proxy
refuses it); `https://` targets always tunnel through `CONNECT` and carry
real end-to-end TLS to the target. `NO_PROXY` entries match the host itself
and its subdomains (`example.com` also matches `api.example.com`); append
`:port` to scope an entry, and `*` bypasses every host. Only HTTP proxies
are supported (no SOCKS), and the proxy URL itself must be `http://` — an
`https://` proxy URL (TLS to the proxy) is rejected.

```sh
HTTP_PROXY=http://127.0.0.1:8080 ff client.js --allow-net=api.example.com:443
NO_PROXY=localhost,127.0.0.1 HTTPS_PROXY=http://proxy.corp:8080 ff client.js --allow-net=api.example.com:443
```

> **Permissions caveat:** proxy variables are read by the runtime directly, so
> no `--allow-env` grant is needed. `--allow-net` is checked against the
> **destination** URL, not the proxy host. If the environment configures a
> proxy, an allowed request will connect to that proxy even when its host is
> absent from every `--allow-net` scope. Set `NO_PROXY` or clear the proxy
> variables when that is not intended.

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
ff client.js --allow-net=api.example.com:443
```

## Limits (summary)

Full table lives in the Limitations reference: 16 concurrent fetches, 64KB body stage per slot, 16 MB max response body (both Content-Length and decompressed output), 30s I/O timeout, `AbortSignal` cancellation (`init.signal` / `req.signal`), 5 redirect hops, every hop re-checked against `--allow-net`, cross-origin redirect credential stripping (`authorization`, `cookie`, `x-api-key`), RFC 7230 header validation, HTTP/1.1 only, HTTP proxies via env vars only (no SOCKS).

## Gotchas

**Permission denial is two different shapes.** The initial URL throws a real
`Error` with `name: "PermissionDenied"` and `code: "PERMISSION_DENIED"`.
A redirect-hop denial rejects with the plain string
`"PermissionDenied: fetch requires --allow-net"` — no `code`, no host. Catch
both, and log with `String(e)` so string rejections print something useful.

**Cross-origin redirects strip credentials.** If a redirect crosses to a different origin (different scheme, host, or port), Fairyfly automatically strips sensitive headers (`authorization`, `cookie`, `x-api-key`) to prevent credential leakage.

**Response body limit is 16 MB.** Both the declared Content-Length and decompressed (gzip/deflate) body data are capped at 16 MiB. Larger responses fail and reject the promise.

**Method names are exact-case.** `fetch` matches `init.method` against the standard tokens verbatim — `"POST"`, `"PUT"`, `"PATCH"`, `"DELETE"`, `"HEAD"`, `"OPTIONS"`. Anything else, including lowercase (`"post"`), is sent as `GET` (a body is still attached). Your `http.serve` handler likewise sees the method exactly as the client sent it, so normalize before comparing (`method.toUpperCase() === "POST"`).

**Only string bodies reach the wire intact.** Every other body value is coerced with JS `String()` semantics: a `FormData` or `Blob` arrives as `"[object Object]"`, an `ArrayBuffer` as `"[object ArrayBuffer]"`, and a `Uint8Array([104, 105])` as `"104,105"`. `URLSearchParams` survives only because its `toString()` is the query string. There is no multipart encoding and no binary-body path — serialize yourself (`JSON.stringify`, `params.toString()`, base64, or a hand-built multipart string with an explicit `content-type` header).

**`Response.redirect()` sends no `Location` header.** It sets the status (default 302) and flags the object as redirected, but clients never follow it. Build the response yourself when clients must follow:

```js
return new Response(null, { status: 302, headers: { Location: "/new-path" } });
```

**Rejections are plain strings.** Network failures reject with `"Network error"`, bad URLs with `"Invalid URL"`, long chains with `"Too many redirects"` — `e.message` is `undefined`, so log `String(e)`. The initial permission denial is the exception: it throws an `Error` and never reaches the promise.

## See also

- [Permissions](/docs/concepts/permissions) — flags, scopes, denial contract
- [Fetch Client guide](/docs/guides/fetch-client) — tutorial version of this page
- [HTTP Server guide](/docs/guides/http-server) — serving instead of calling
- [Limitations](/docs/reference/limitations) — every hard cap
