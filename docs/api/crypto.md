---
title: crypto
description: randomUUID, getRandomValues, subtle.digest — and btoa/atob, with their deviations.
order: 11
---

# `crypto`

Random values, digests, and base64. Everything is synchronous except
`subtle.digest`, which returns a Promise (resolved immediately).

```js
const id = crypto.randomUUID();           // "3f8a1c2e-…"
const key = new Uint8Array(32);
crypto.getRandomValues(key);              // filled in place

const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("abc"));
```

## `crypto.randomUUID()`

| | |
|---|---|
| Signature | `() → string` |
| Returns | RFC 4122 **v4** UUID, lowercase hex |

```js
crypto.randomUUID();
// "3f8a1c2e-6b4d-4e2a-9c3f-1a2b3c4d5e6f"
```

Use it for request ids, session ids, and primary keys:

```js
http.serve({ port: 3000 }, (url) => Response.json({ requestId: crypto.randomUUID() }));
```

## `crypto.getRandomValues(typedArray)`

| | |
|---|---|
| Signature | `(TypedArray) → TypedArray` |
| Returns | The **same array**, filled with random bytes |

```js
const bytes = new Uint8Array(16);
crypto.getRandomValues(bytes);          // returns `bytes` itself
crypto.getRandomValues(new Uint32Array(4));
```

Non-typed arguments throw:

```js
crypto.getRandomValues("nope");
// TypeError: getRandomValues requires a TypedArray argument
```

## `crypto.subtle.digest(algorithm, data)`

| | |
|---|---|
| Signature | `(string, ArrayBuffer \| TypedArray) → Promise<ArrayBuffer>` |
| Algorithms | `SHA-1`, `SHA-256`, `SHA-384`, `SHA-512` (case-insensitive) |

```js
const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("abc"));
[...new Uint8Array(buf)].slice(0, 4).map((b) => b.toString(16).padStart(2, "0")).join("");
// "ba7816bf"   (SHA-256 of "abc" — matches every other implementation)
```

Errors are `TypeError`s thrown synchronously (before the Promise):

| Condition | Message |
|---|---|
| Fewer than 2 arguments | `subtle.digest requires algorithm and data` |
| Unknown algorithm | `subtle.digest: unsupported algorithm (SHA-1/SHA-256/SHA-384/SHA-512)` |
| Data not bytes | `subtle.digest: data must be ArrayBuffer or TypedArray` |

### Hashing a stream of chunks

```js
async function sha256Hex(chunks) {
  // digests don't chain — concatenate first, then digest
  const all = new Uint8Array(chunks.reduce((n, c) => n + c.length, 0));
  let off = 0;
  for (const c of chunks) { all.set(c, off); off += c.length; }
  const buf = await crypto.subtle.digest("SHA-256", all);
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
```

> There is no `SubtleCrypto.sign`, `verify`, `encrypt`, `decrypt`,
> `generateKey`, or `importKey`. For signatures and key exchange, use
> [`ffi`](/docs/api/ffi) with a native library.

## `btoa` / `atob` (globals)

```js
btoa("hi!");        // "aGkh"
atob("aGkh");       // "hi!"
```

| Function | Signature | Behaviour |
|---|---|---|
| `btoa(str)` | `(string) → string` | Base64-encode |
| `atob(str)` | `(string) → string` | Base64-decode |

**`btoa` deviates from the spec in your favour:** non-Latin-1 input does
**not** throw — it encodes the **UTF-8 bytes**, and `atob` decodes them
straight back, so Unicode round-trips with no workaround:

```js
btoa("😀");                  // "8J+YgA=="   (browser btoa throws)
atob("8J+YgA==");           // "😀" — UTF-8-decoded, not Latin-1 bytes
atob(btoa("héllo"));        // "héllo"
```

`atob` **does** throw on malformed input:

```js
atob("!!!");
// TypeError: atob: invalid base64 input
```

## Not provided

| Missing | Instead |
|---|---|
| `crypto.subtle.sign` / `verify` | `ffi` + a native crypto library |
| `crypto.createHash` / `createHmac` | `crypto.subtle.digest` |
| `crypto.timingSafeEqual` | compare hashes, or write a constant-time loop |
| `crypto.randomBytes` (Node) | `crypto.getRandomValues(new Uint8Array(n))` |
| PBKDF2 / scrypt / HKDF | not available in-runtime |

## Gotchas

- `subtle.digest` computes synchronously and resolves on the microtask
  queue — awaiting it does not free the loop for I/O.
- `getRandomValues` is `Uint8Array`-only-ish: any TypedArray works, plain
  arrays/strings throw.
- `btoa` / `atob` don't throw on non-Latin-1 — both sides go through
  UTF-8, so Unicode round-trips (unlike browsers).
- No `crypto` keys, no TLS material access — see [TLS](/docs/guides/tls)
  for server certificates.

## See also

- [Text encoding](/docs/api/text-encoding)
- [`fetch`](/docs/api/fetch)
- [FFI](/docs/api/ffi)
- [Compatibility](/docs/reference/compatibility)
