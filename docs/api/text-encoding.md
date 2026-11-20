---
title: Text encoding
description: TextEncoder and TextDecoder — UTF-8 only, lossy by default, no encodeInto.
order: 10
---

# Text encoding

UTF-8 only. Both constructors **ignore their arguments** — there is no
`latin1`, `utf-16`, or `fatal` mode.

```js
const enc = new TextEncoder();
const dec = new TextDecoder();

const bytes = enc.encode("héllo");        // Uint8Array
const text = dec.decode(bytes);           // "héllo"
```

## `TextEncoder`

| Member | Type | Description |
|---|---|---|
| `encoding` | `string` | Always `"utf-8"` |
| `encode(input)` | `(string) → Uint8Array` | UTF-8 bytes (`encode()` / `encode(undefined)` coerces `undefined` to `"undefined"`) |

```js
const enc = new TextEncoder();
enc.encoding;                     // "utf-8"
[...enc.encode("hi")];            // [104, 105]
[...enc.encode("")];              // []
```

There is **no `encodeInto`** — write into a target buffer yourself:

```js
function encodeInto(str) {                 // poor man's encodeInto
  const bytes = new TextEncoder().encode(str);
  return { read: str.length, written: bytes.length, bytes };
}
```

## `TextDecoder`

| Member | Type | Description |
|---|---|---|
| `encoding` | `string` | Always `"utf-8"` (`.fatal` and `.ignoreBOM` are not defined / `undefined`) |
| `decode(input?)` | `(ArrayBuffer \| TypedArray) → string` | UTF-8 → string (`decode()` returns `""`; passing explicit `undefined` throws `TypeError`) |

```js
const dec = new TextDecoder();
dec.encoding;                          // "utf-8"
dec.decode();                          // ""  (0 arguments)
dec.decode(enc.encode("ok"));          // "ok"
dec.decode(new Uint8Array([0xff, 0x41]));  // "\uFFFDA"  — never throws
```

### Invalid bytes are replaced, never fatal

Malformed UTF-8 becomes U+FFFD (`\uFFFD`) — byte by byte:

```js
dec.decode(new Uint8Array([0x41, 0xff, 0x42]));
// "A\uFFFDB"
```

There is no `fatal: true` mode: `new TextDecoder("utf-8", { fatal: true })`
parses but the options are ignored.

### Wrong input type throws

```js
dec.decode("not bytes");
// TypeError: TextDecoder.decode requires ArrayBuffer or TypedArray input
```

Strings are rejected — convert with `encode()` first. `ArrayBuffer` itself
is accepted:

```js
dec.decode(enc.encode("ok").buffer);   // "ok"
```

### Constructor labels are ignored

```js
new TextDecoder("latin1").encoding;    // "utf-8"  — silently ignored
```

## Patterns

### JSON over bytes

```js
const res = await fetch("https://example.com/api");
const data = JSON.parse(new TextDecoder().decode(await res.arrayBuffer()));
```

### Base64 → bytes → string

```js
const bin = atob(base64);
const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
console.log(new TextDecoder().decode(bytes));
```

## Gotchas

- Both classes are **UTF-8 only**; labels don't change behaviour, and `TextDecoder` instances do not define `.fatal` or `.ignoreBOM` (`undefined`).
- `decode()` is **lossy by design** — invalid sequences become U+FFFD (`\uFFFD`). If you
  need to detect corruption, validate the bytes yourself
  (`TextDecoder` won't tell you).
- `encode()` or `encode(undefined)` coerces `undefined` to the 9-byte string `"undefined"` (rather than an empty `Uint8Array`); 0-arg `decode()` returns `""`, whereas `decode(undefined)` throws `TypeError`.
- `encode()` allocates a fresh `Uint8Array` per call — don't call it in a
  hot loop with large strings.
- No streaming: `decode(chunk, { stream: true })` ignores the option and
  may mangle multi-byte characters split across chunks.

## See also

- [`fetch`](/docs/api/fetch) — reading response bodies
- [Blob and FormData](/docs/api/blobs-formdata)
- [Compatibility](/docs/reference/compatibility)
