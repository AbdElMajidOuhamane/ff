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
| `encode(input)` | `(string) → Uint8Array` | UTF-8 bytes |

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
| `encoding` | `string` | Always `"utf-8"` |
| `decode(input?)` | `(ArrayBuffer \| TypedArray) → string` | UTF-8 → string |

```js
const dec = new TextDecoder();
dec.encoding;                          // "utf-8"
dec.decode();                          // ""  (no input)
dec.decode(enc.encode("ok"));          // "ok"
dec.decode(new Uint8Array([0xff, 0x41]));  // "\uFFFDA"  — never throws
```

### Invalid bytes are replaced, never fatal

Malformed UTF-8 becomes U+FFFD (``) — byte by byte:

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

- Both classes are **UTF-8 only**; labels don't change behaviour.
- `decode()` is **lossy by design** — invalid sequences become ``. If you
  need to detect corruption, validate the bytes yourself
  (`TextDecoder` won't tell you).
- `encode()` allocates a fresh `Uint8Array` per call — don't call it in a
  hot loop with large strings.
- No streaming: `decode(chunk, { stream: true })` ignores the option and
  may mangle multi-byte characters split across chunks.

## See also

- [`fetch`](/docs/api/fetch) — reading response bodies
- [Blob and FormData](/docs/api/blobs-formdata)
- [Compatibility](/docs/reference/compatibility)
