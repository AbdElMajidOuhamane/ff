---
title: Fetch Client
description: Call other APIs with fetch — GET, POST, JSON, errors, redirects, and HTTPS trust.
order: 2
---

# Fetch Client

`fetch` is global. It reads `method` / `headers` / `body` / `signal` from the init object and returns a `Promise<Response>`. Everything else in init (`timeout`, `redirect`) is ignored. Method names are exact-case standard tokens — lowercase `"post"` is sent as `GET` (see Troubleshooting).

## Permissions

Outbound requests are deny-by-default. Every `fetch` needs `--allow-net` for
the destination:

```sh
ff client.js --allow-net=api.example.com:443
```

- The URL's **literal host** is matched, lowercased. There is no DNS lookup
  and no IP matching: `localhost` ≠ `127.0.0.1`, and granting
  `api.example.com` does not cover `93.184.216.34`.
- Ports matter. `https://api.example.com/` checks `api.example.com:443`;
  `http://api.example.com/` checks `api.example.com:80`. Omit the port in the
  flag to allow every port on that host.
- `*.example.com` matches subdomains but **not** the apex `example.com`.
  `*` (or bare `--allow-net`) grants every host and port.
- Every redirect hop is checked again against the new URL.
- TLS trust (`--ca`, `FF_CA_FILE`) is separate and does not grant network
  access. Proxy variables are read by the runtime without `--allow-env`, and
  the check applies to the destination, not the proxy host — see
  [fetch Proxies](/docs/api/fetch#proxies).

An initial URL outside the scope **throws synchronously**:

```js
try {
  await fetch("https://api.example.com/items");
} catch (e) {
  console.error(e.name, e.code); // PermissionDenied PERMISSION_DENIED
  console.error(e.message);      // fetch requires --allow-net for 'api.example.com:443'
}
```

A redirect hop outside the scope **rejects with a string** instead:
`"PermissionDenied: fetch requires --allow-net"`. Catch both shapes. Full
model: [Permissions](/docs/concepts/permissions).

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
ff client.js --allow-net=example.com:443
```

## Modules vs scripts

`ff` forces ES module evaluation when a file ends in `.mjs`. For `.js` files,
`ff` tries classic-script compilation first and automatically falls back to ES
module evaluation when the file contains `import`, `export`, or top-level
`await` anywhere in the source. The runnable examples on this page wrap async
code in `(async () => { ... })()` so they also work when pasted into classic-script
contexts.

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

```sh
ff client.js --allow-net=api.example.com:443
```

Check `res.ok` — HTTP error statuses **resolve**, they don't throw:

```js
const res = await fetch("https://api.example.com/missing");
if (!res.ok) {
  console.log("failed:", res.status); // e.g. 404
}
```

> **Caution:** HTTP statuses like `404` or `500` resolve normally. Network
> failures (DNS, refused connection, too many redirects) reject with strings,
> and an initial permission denial throws a `PermissionDenied` error. Always
> check `res.ok` or `res.status` after a response; always handle the
> permission case separately.

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
ff client.js --allow-net=api.example.com:443
```

`string` bodies — and `URLSearchParams`, which coerces to its query string — reach the wire intact. Passing `body` with omitted `method` (or `method: "GET"`) auto-promotes the request method to `"POST"`, and body-carrying methods (`POST`, `PUT`, `PATCH`) with no body explicitly send `Content-Length: 0`. Everything else is coerced with JS `String()` semantics: a `FormData` or `Blob` arrives as `"[object Object]"`, an `ArrayBuffer` as `"[object ArrayBuffer]"`, a `Uint8Array([104, 105])` as `"104,105"`.

> **Known issue:** `fetch` does not multipart-encode `FormData` or send binary bodies as bytes. Build the payload yourself:

```js
const params = new URLSearchParams("name=ada"); // string form only — the record form yields ""
await fetch("https://api.example.com/submit", {
  method: "POST",
  headers: { "content-type": "application/x-www-form-urlencoded" },
  body: params, // "name=ada" — URLSearchParams stringifies to its query
});
```

## Reading the response

Every reader works on `Response` (and `Request`). Bodies can be re-read freely (`bodyUsed` becomes `true` after the first read but does not prevent another), and `res.body` returns a closed single-chunk `ReadableStream` (or `null` if empty):

| Reader / Property | Returns |
|---|---|
| `res.body` | `ReadableStream \| null` |
| `await res.text()` | `string` |
| `await res.json()` | parsed JSON |
| `await res.arrayBuffer()` | `ArrayBuffer` |
| `await res.bytes()` | `ArrayBuffer` |
| `await res.blob()` | `Blob` |
| `await res.formData()` | `FormData` |

```js
const res = await fetch("https://example.com/");
console.log(res.url); // final URL after redirects
console.log(res.redirected); // true when redirected
console.log(res.headers.get("content-type"));
console.log((await res.bytes()).byteLength);
```

## Redirects

Redirects are followed automatically, up to **5 hops**. After that `fetch` rejects the promise with `"Too many redirects"`:

```js
const res = await fetch("https://example.com/old-path");
console.log(res.redirected); // true
console.log(res.url); // where it landed
```

Every hop is re-checked against `--allow-net`. A redirect that crosses hosts
needs both scopes:

```sh
ff client.js --allow-net=example.com,cdn.example.com
```

A hop outside the scope rejects with the string
`"PermissionDenied: fetch requires --allow-net"`.

There is no `redirect: "manual"` mode — the init key is ignored.

## HTTPS trust

Public CAs work out of the box. For private/self-signed CAs:

| Setup | How |
|-------|-----|
| Scripts & watcher | `ff client.js --ca ./ca.pem` (`--ca` works with `ff <file>`, `ff -e`, and `ff --watch <file>`) |
| Any run, incl. `ff start` | `FF_CA_FILE=./ca.pem ff start` |
| Dev TLS pairing | Starting TLS with `--cert`/`FF_CERT` (or `http.serve({ tls: { cert: "<path>" } })`) also trusts that cert for `fetch` |

```sh
FF_CA_FILE=./ca.pem ff client.js --allow-net=api.example.com:443
```

> **Note:** `--ca` is silently ignored by `ff start`. Use `FF_CA_FILE` (or `FF_CERT`) there.

Trust and permission are independent: neither `--ca` nor `FF_CA_FILE` grants
network access, and `--allow-net` does not make an untrusted certificate
valid. `FF_CA_FILE` is runtime configuration, so it needs no `--allow-env`.

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
ff mirror.js \
  --allow-net=api.example.com:443,backup.example.com:443
```

Both hosts need their own scope; `*.example.com` would cover neither of these
two apex domains.

## Reference: limits

| Area | Limit | When hit |
|------|-------|----------|
| Concurrent fetches | 16 | The 17th rejects immediately with `"Failed to start fetch"` |
| Body stage per slot | 64KB | Larger bodies spill to chunks/heap |
| Response body cap | 16 MB (decompressed output; Content-Length pre-checked only for identity responses) | Responses beyond 16 MB reject with `"ResponseTooLarge: body exceeds limit"` |
| I/O timeout | 30s | Slow servers fail |
| Redirects | 5 hops max, each re-checked | Rejects with `"Too many redirects"` or a permission string |
| Cross-origin credentials | Stripped on cross-origin redirect | `authorization`, `cookie`, `proxy-authorization`, `www-authenticate`, `x-api-key`, `x-auth-token` dropped when changing origin |
| Header validation | RFC 7230 character validation | Invalid header pairs (bad name token or CR/LF/NUL/CTL in value) throw `TypeError` |
| Abort | `AbortController` / `AbortSignal` (`signal` init key) | Rejects with `signal.reason` and closes the socket (`AbortSignal.timeout` shares the 128-timer table) |
| Protocol | HTTP/1.1 | No HTTP/2 client |

## Troubleshooting

**`fetch` throws `PermissionDenied`** — the initial URL's host and port are
outside every `--allow-net` scope. Add the exact target:
`--allow-net=api.example.com:443`. Remember `localhost` and `127.0.0.1` are
different scopes, and HTTPS defaults to port 443.

**A redirect fails with `PermissionDenied: fetch requires --allow-net`** — a
later hop crossed into a host or port you did not grant. Grant every host in
the chain, or make the redirect target stay within one host.

**404 resolves instead of throwing** — by design. Check `res.ok` / `res.status` after every call.

**Lowercase `method: "post"` arrives as `GET`** — method tokens match exactly; anything unrecognized goes out as `GET` (the body is still attached). Use `"POST"`.

**`FormData` / `Blob` / `Uint8Array` body arrives mangled** — bodies are string-coerced, not serialized (`"[object Object]"`, `"104,105"`). Send `string`, `URLSearchParams`, or a hand-built multipart string instead.

**Caught fetch error usually has no `.message`** — most failures reject with plain strings (`"Network error"`, `"Invalid URL"`, `"Too many redirects"`, `"Failed to start fetch"`, and the redirect-hop permission string). Log `String(e)`. Two exceptions carry an `Error`: an abort rejects with `signal.reason` (so `.message` is set), and the initial permission denial throws synchronously.

**`Too many redirects`** — the chain exceeded 5 hops. Inspect `res.url` on the last good hop or fix the redirect loop server-side.

**TLS verify fails on a private CA** — pass `--ca` (scripts/`--watch`) or `FF_CA_FILE` (`ff start`). Confirm the PEM path is readable. Trust does not replace `--allow-net`.

**`"Failed to start fetch"` under concurrency** — all 16 concurrent fetch slots are in use. Limit in-flight calls to <= 16 batches instead of launching 17+ at once.

## See also

- [Permissions](/docs/concepts/permissions) — flags, scopes, denial contract
- [fetch API](/docs/api/fetch) — full reference, proxies, gotchas
- [HTTP Server guide](/docs/guides/http-server) — serving instead of calling
- [Limitations](/docs/reference/limitations) — every hard cap
