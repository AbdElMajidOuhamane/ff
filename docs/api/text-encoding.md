---
title: Text encoding
description: TextEncoder and TextDecoder — UTF-8 only, lossy by default, no encodeInto.
order: 10
---

# Text encoding

`TextEncoder` and `TextDecoder` are **UTF-8 only**. Both constructors
**ignore their arguments** — there is no `latin1`, `utf-16`, `fatal`, or
streaming mode. Both are globals.

```js
const enc = new TextEncoder();
const dec = new TextDecoder();

const bytes = enc.encode("héllo");   // Uint8Array
const text = dec.decode(bytes);      // "héllo"
```

## `TextEncoder`

| Member | Type | Description |
|---|---|---|
| `encoding` | `string` | Always `"utf-8"` |
| `encode(input?)` | `(any) → Uint8Array` | UTF-8 bytes of `input` |

`encode` returns a **fresh** `Uint8Array` (a copy) holding the UTF-8 encoding
of the string.

```js
const enc = new TextEncoder();
enc.encoding;                     // "utf-8"
[...enc.encode("hi")];            // [104, 105]
enc.encode("").length;            // 0
enc.encode("").constructor.name;  // "Uint8Array"
```

The argument is coerced with `String(...)`, so a missing or non-string input
encodes its string form rather than throwing:

```js
[...new TextEncoder().encode()];     // "undefined" → [117,110,100,101,102,105,110,101,100]
[...new TextEncoder().encode(42)];   // "42"        → [52, 50]
```

There is **no `encodeInto`** (`typeof enc.encodeInto === "undefined"`). If you
need to write into an existing buffer, encode and copy:

```js
const target = new Uint8Array(64);
const bytes = new TextEncoder().encode("hi");
target.set(bytes, 0);            // wrote 2 bytes at offset 0
```

## `TextDecoder`

| Member | Type | Description |
|---|---|---|
| `encoding` | `string` | Always `"utf-8"` |
| `decode(input?)` | `(ArrayBuffer \| TypedArray) → string` | UTF-8 → string |

```js
const enc = new TextEncoder();
const dec = new TextDecoder();
dec.encoding;                          // "utf-8"
dec.decode();                          // ""       (no input)
dec.decode(enc.encode("ok"));          // "ok"
dec.decode(enc.encode("ok").buffer);   // "ok"     (whole ArrayBuffer)
dec.decode(enc.encode("ok").subarray(0, 1));   // "o" (a view works)
```

A `DataView` is **not** accepted, and neither is a string:

```js
dec.decode("not bytes");
// TypeError: TextDecoder.decode requires ArrayBuffer or TypedArray input
```

### Invalid bytes are replaced, never fatal

Malformed UTF-8 is replaced with U+FFFD (``). The scan copies valid
sequences whole and substitutes one U+FFFD **per invalid byte**, so a
truncated multi-byte sequence yields several replacements:

```js
dec.decode(new Uint8Array([0x41, 0xff, 0x42]));   // "A\uFFFDB"   (1 bad byte)
dec.decode(new Uint8Array([0xe2, 0x82]));         // "\uFFFD\uFFFD" (truncated, 2 bad bytes)
dec.decode(new Uint8Array([0xe2, 0x82, 0xac]));   // "€"           (valid 3-byte sequence)
```

There is no `fatal: true` mode — options are ignored, and `decode` **never
throws on bad bytes** (only on the wrong *input type*).

### Labels and options are ignored

```js
new TextDecoder("latin1").encoding;                 // "utf-8"
new TextDecoder("utf-8", { fatal: true }).encoding; // "utf-8"  (options dropped)
new TextEncoder("utf-16").encoding;                 // "utf-8"
```

No streaming: `dec.decode(chunk, { stream: true })` ignores the second
argument, so a multi-byte character split across two chunks decodes to
replacement characters on both sides.

## Patterns

### JSON over bytes

```js
(async () => {
  const res = await fetch("https://example.com/api");
  const data = JSON.parse(new TextDecoder().decode(await res.arrayBuffer()));
  console.log(data);
})();
```

### Base64 text → string

`atob` already returns a UTF-8-decoded string, so decode straight to text;
re-encode only if you want the raw bytes back:

```js
const b64 = btoa("héllo");
const text = atob(b64);                          // "héllo"
const bytes = new TextEncoder().encode(text);    // [104,195,169,108,108,111]
console.log(text, bytes.length);
```

> `atob` is a *text* decoder, not a raw-bytes one — see
> [crypto](/docs/api/crypto#atob-decodes-text-not-bytes).

## Gotchas

- Both classes are **UTF-8 only**; constructor labels don't change behaviour.
- `decode()` is **lossy by design** — invalid bytes become `` (one per bad
  byte). If you need to detect corruption, validate the bytes yourself.
- Wrong input type throws:
  `TextDecoder.decode requires ArrayBuffer or TypedArray input`; a `DataView`
  is rejected.
- `encode()` allocates a fresh `Uint8Array` per call — don't call it in a hot
  loop with large strings.
- Missing/non-string `encode` input is coerced: `encode()` encodes
  `"undefined"`.
- **`instanceof` throws.** `TextEncoder.prototype` and `TextDecoder.prototype`
  are `undefined` (the constructors return plain objects), so
  `x instanceof TextEncoder` raises
  `TypeError: operand 'prototype' property is not an object`. Detect instances
  structurally instead:

```js
const enc = new TextEncoder();
console.log(typeof enc.encode === "function", enc.encoding);   // true utf-8
```

## See also

- [`fetch`](/docs/api/fetch) — reading response bodies
- [Blob and FormData](/docs/api/blobs-formdata)
- [Compatibility](/docs/reference/compatibility)
