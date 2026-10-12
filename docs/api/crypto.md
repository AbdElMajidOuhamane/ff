---
title: crypto
description: randomUUID, getRandomValues, subtle.digest — and btoa/atob, with their deviations.
order: 11
---

# `crypto`

`crypto` is a global object with exactly three members — `getRandomValues`,
`randomUUID`, and `subtle.digest`. The two base64 helpers `btoa`/`atob` are
**globals**, not members of `crypto`. Everything is synchronous except
`subtle.digest`, which returns a Promise (already resolved, delivered on the
microtask queue).

```js
// crypto.js
const id = crypto.randomUUID();          // "3f8a1c2e-…"
const key = new Uint8Array(32);
crypto.getRandomValues(key);             // filled in place

(async () => {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("abc"));
  console.log(id, key.length, new Uint8Array(digest).length);
})();
```

Randomness comes from the OS CSPRNG (`getrandom(2)` on Linux,
`arc4random_buf` elsewhere) — the same source `randomUUID` uses.

## `crypto.randomUUID()`

| | |
|---|---|
| Signature | `() → string` |
| Returns | RFC 4122 **v4** UUID, lowercase hex, 36 characters |

```js
crypto.randomUUID();
// "3f8a1c2e-6b4d-4e2a-9c3f-1a2b3c4d5e6f"
```

Use it for request ids, session ids, and primary keys:

```js
http.serve({ port: 3000 }, () => Response.json({ requestId: crypto.randomUUID() }));
```

## `crypto.getRandomValues(typedArray)`

| | |
|---|---|
| Signature | `(TypedArray) → TypedArray` |
| Returns | The **same array**, filled with random data |

```js
const bytes = new Uint8Array(16);
const same = crypto.getRandomValues(bytes);   // `same === bytes`
```

### Only `Uint8Array` is filled byte-for-byte

`Uint8Array` is handled specially: its whole backing store is filled with
random bytes. **Every other TypedArray** is filled **one element at a time**
with a random integer in `0`–`255`, converted to the element's type — a
deviation from WebCrypto (which fills the entire backing buffer).

```js
const u32 = new Uint32Array(4);
crypto.getRandomValues(u32);      // each element is 0–255, NOT a full random uint32

const i8 = new Int8Array(4);
crypto.getRandomValues(i8);       // values 0–255 written through int8, so some go negative
```

If you need uniformly random values across a wider type, build them from a
`Uint8Array` yourself.

### Limits and type errors

The size cap is **65536 bytes**, and it is checked *before* filling:

| Input | Result |
|---|---|
| `Uint8Array` / TypedArray of length ≤ 65536 | filled, returned |
| Any TypedArray of length **0** | `TypeError: getRandomValues: max 65536 bytes` |
| Any TypedArray of length > 65536 | `TypeError: getRandomValues: max 65536 bytes` |
| `DataView`, plain array, string, non-object | `TypeError: getRandomValues requires a TypedArray argument`¹ |

¹ A `DataView` is an object but has no `length`, so it fails the size check
first and reports the *max bytes* message instead.

```js
try { crypto.getRandomValues(new Uint8Array(0)); }
catch (e) { console.log(e.message); }   // getRandomValues: max 65536 bytes

try { crypto.getRandomValues("nope"); }
catch (e) { console.log(e.message); }   // getRandomValues requires a TypedArray argument
```

## `crypto.subtle.digest(algorithm, data)`

| | |
|---|---|
| Signature | `(string, ArrayBuffer \| TypedArray) → Promise<ArrayBuffer>` |
| Algorithms | `SHA-1`, `SHA-256`, `SHA-384`, `SHA-512` (case-insensitive) |

The digest is computed **synchronously** and the result is wrapped in an
already-resolved Promise; `await` just yields once to the microtask queue.

```js
(async () => {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("abc"));
  console.log([...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join(""));
  // "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
})();
```

Output sizes: SHA-1 → 20, SHA-256 → 32, SHA-384 → 48, SHA-512 → 64 bytes.
The algorithm name is matched case-insensitively (`"sha-256"` works), and an
empty `data` is allowed (it hashes the empty input).

### Errors are `TypeError`s thrown synchronously

Bad calls throw **before** the Promise is created, so a plain `try/catch`
around the call catches them — you don't need `await`:

```js
let caught = false;
try { crypto.subtle.digest("MD5", new Uint8Array([1])); } catch (e) { caught = true; }
console.log(caught);   // true
```

| Condition | Message |
|---|---|
| Fewer than 2 arguments | `subtle.digest requires algorithm and data` |
| Algorithm not coercible to a string (e.g. a `Symbol`) | `subtle.digest: invalid algorithm` |
| Unknown algorithm name | `subtle.digest: unsupported algorithm (SHA-1/SHA-256/SHA-384/SHA-512)` |
| Data not an `ArrayBuffer` or TypedArray | `subtle.digest: data must be ArrayBuffer or TypedArray` |

> There is no `SubtleCrypto.sign`, `verify`, `encrypt`, `decrypt`,
> `generateKey`, or `importKey`. For signatures and key exchange, use
> [`ffi`](/docs/api/ffi) with a native library.

### Hashing a stream of chunks

Streaming digests don't chain, so concatenate first:

```js
(async () => {
  const chunks = [new TextEncoder().encode("ab"), new TextEncoder().encode("c")];
  const all = new Uint8Array(chunks.reduce((n, c) => n + c.length, 0));
  let off = 0;
  for (const c of chunks) { all.set(c, off); off += c.length; }
  const buf = await crypto.subtle.digest("SHA-256", all);
  console.log([...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join(""));
  // ba7816bf… (same digest as hashing "abc" in one shot)
})();
```

## `btoa` / `atob` (globals)

| Function | Signature | Behaviour |
|---|---|---|
| `btoa(str)` | `(any) → string` | Base64-**encode** the string's **UTF-8 bytes** |
| `atob(str)` | `(string) → string` | Base64-decode, then interpret the bytes as **UTF-8** |

```js
btoa("hi!");        // "aGkh"
atob("aGkh");       // "hi!"
```

Both are **UTF-8**, not Latin-1 (a deliberate deviation from browsers):

```js
btoa("\u00ff");     // "w78="   (browser btoa gives "/w==")
btoa("😀");         // "8J+YgA=="  (browser btoa throws)
atob(btoa("héllo"));// "héllo"
```

Non-string input to `btoa` is coerced with `String(...)`:

```js
btoa(123);          // "MTIz"
```

`atob` is **strict**: it requires correct padding, rejects embedded
whitespace, and does not accept the base64url alphabet. Malformed input
throws:

```js
atob("!!!");        // TypeError: atob: invalid base64 input
atob("aG k=");      // TypeError: atob: invalid base64 input  (space)
atob("aGk");        // TypeError: atob: invalid base64 input  (missing padding)
atob("aGk_");       // TypeError: atob: invalid base64 input  (base64url)
atob("");           // ""
```

### `atob` decodes *text*, not bytes

Because `atob` always interprets the decoded bytes as UTF-8, base64 that
encodes non-UTF-8 binary is **not** recovered faithfully — invalid bytes
become U+FFFD:

```js
atob("//8=");                       // "\uFFFD\uFFFD" (was bytes FF FF)
new TextEncoder().encode(atob("//8="));   // [239,191,189,239,191,189]
```

For **text**, the round-trip is exact — re-encode the string to get the
original UTF-8 bytes back:

```js
new TextEncoder().encode(atob(btoa("héllo")));   // [104,195,169,108,108,111]
```

There is no raw-bytes base64 codec: `btoa`/`atob` are a text convenience,
not a binary transport.

> `atob.length` reports `7` (an artifact of how it is registered). Don't
> branch on its arity.

## Not provided

| Missing | Instead |
|---|---|
| `crypto.subtle.sign` / `verify` | [`ffi`](/docs/api/ffi) + a native crypto library |
| `crypto.createHash` / `createHmac` (Node) | `crypto.subtle.digest` |
| `crypto.timingSafeEqual` | compare digests, or write a constant-time loop |
| `crypto.randomBytes` (Node) | `crypto.getRandomValues(new Uint8Array(n))` |
| PBKDF2 / scrypt / HKDF | not available in-runtime |
| `crypto.getRandomValues` on `DataView` | copy into a `Uint8Array` first |

## Gotchas

- `subtle.digest` computes synchronously and resolves on the microtask queue
  — awaiting it does not free the loop for I/O.
- `getRandomValues` rejects a **zero-length** TypedArray (the cap check fires
  before the fill); it also only byte-fills `Uint8Array`.
- `btoa`/`atob` are UTF-8, so Unicode round-trips (unlike browsers) but
  arbitrary binary does not.
- `atob` is strict about padding and rejects base64url.
- No key material, no TLS access — see [TLS](/docs/guides/tls) for server
  certificates.

## See also

- [Text encoding](/docs/api/text-encoding)
- [`fetch`](/docs/api/fetch)
- [FFI](/docs/api/ffi)
- [Compatibility](/docs/reference/compatibility)
