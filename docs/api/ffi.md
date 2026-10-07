---
title: FFI
description: Load C-ABI shared libraries at runtime and call them from JS.
order: 7
---

# FFI (`ffi` global)

`ffi` opens shared libraries with `dlopen` and turns declared C symbols
into JS functions. No glue code, no build step, no Node-API — the native
library can be anything with a C ABI: system libz, sqlite3, your own
`libfoo.dylib`.

Native code runs with the full privileges of the `ff` process and bypasses
every sandbox guarantee, so the whole global is gated:

```sh
ff app.js --allow-ffi
ff start --allow-ffi
ff test --allow-ffi
```

Without the flag, `ffi.dlopen` throws and `ffi.allowed` is `false`.

> **Prebuilt binaries ship without FFI.** Release binaries and the GHCR image
> are built with `-Dffi=false`, so `ffi.dlopen` throws
> `ffi.dlopen: FFI not compiled in (build with -Dffi=true)` even with
> `--allow-ffi`. FFI works out of the box in source builds (the default).

## Quick look

```js
const lib = ffi.dlopen("libz.1.dylib", {
  crc32: { parameters: ["usize", "buffer", "u32"], result: "usize" },
  div:   { parameters: ["i32", "i32"], result: { struct: [["quot", "i32"], ["rem", "i32"]] } },
});

lib.symbols.crc32(0n, new TextEncoder().encode("123456789"), 9); // 3421780262n

const t = lib.symbols.div(7, 2);   // Uint8Array — the struct's bytes
const v = ffi.view(t);
v.getInt32(0);                     // 3  (quot)
v.getInt32(4);                     // 1  (rem)

lib.close();
```

## dlopen

```js
const lib = ffi.dlopen(path, symbols);
```

- `path` — anything the OS loader accepts: absolute, `./`-relative, or a
  system name (`"libz.1.dylib"`, `"libz.so.1"`).
- `symbols` — `{ name: { parameters: [...], result: "<type>" | struct | union, optional?: true, nonblocking?: true } }`.
- Missing library → `TypeError` with the loader's error text.
- Missing symbol → `TypeError`, unless `optional: true`, in which case
  `lib.symbols.name` is `null`.
- Max 32 parameters per symbol.

Returns a library object:

| Property | What it does |
|---|---|
| `lib.symbols.name(...args)` | Call the C function (returns a `Promise` if `nonblocking: true`) |
| `lib.close()` | `dlclose`; further calls throw. Idempotent |

A closed library throws `TypeError: ffi: library is closed`. If the
library object is garbage-collected, the handle is closed for you.

## Types

| Type | JS in | JS out | Notes |
|---|---|---|---|
| `i8 u8 i16 u16 i32 u32` | `number` | `number` | Silent truncation to the C width |
| `i64 u64 isize usize` | `BigInt` (or `number`) | `BigInt` | |
| `f32 f64` | `number` | `number` | |
| `void` | — | `undefined` | Results only |
| `pointer` | `FfiPtr`, `bigint`, `null` | `FfiPtr` \| `null` | |
| `buffer` | `TypedArray`, `ArrayBuffer`, `null` | `FfiPtr` \| `null` | Passes the data pointer (view-adjusted); a result is a pointer, not a copy |
| `cstring` | `string`, `null` | `string` \| `null` | In: NUL-terminated copy, valid for the call. Out: cloned JS string |
| `function` | `FfiCallback` `.pointer` | — | JS→C callback — see [Callbacks](#callbacks) |
| struct | `Uint8Array` (≥ `size` bytes) | `Uint8Array` (`size` bytes) | Byte image in C layout — see [Structs](#structs) |
| union | `Uint8Array` (≥ `size` bytes) | `Uint8Array` (`size` bytes) | Byte image, all members at offset 0 — see [Unions](#unions) |

Unknown type names throw at `dlopen`. `void` as a parameter throws.

## Pointers

`FfiPtr` is an opaque handle — the address lives inside it.

```js
const p = ffi.ptr(typedArray);     // pointer to buffer data
const q = ffi.ptr(p, 16);          // p + 16 bytes
const r = ffi.ptr(0x1000n);        // raw address

p.addr;        // 140234n (BigInt)
p.toString();  // "FfiPtr(0x224b0)"
ffi.isNull(p); // true for null/undefined and for 0-address pointers
ffi.cstring(p);        // read a C string → JS string | null
ffi.cstring(typedArray); // same, from a buffer
```

## Memory

Read and write native memory at any pointer, with byte offsets:

```js
ffi.write(p, "u32", 0xdeadbeef, 4);   // (ptr, type, value, offset?)
ffi.read(p, "u32", 4);                // → 3735928559
ffi.copyBytes(p, 16);                 // → ArrayBuffer copy
ffi.writeBytes(p, typedArray);        // typedArray → native bytes
```

`ffi.view(p)` returns the same pointer object with DataView-style
getters (Deno-compatible names):

```js
const v = ffi.view(p);
v.getInt8(off);  v.getUint8(off);
v.getInt16(off); v.getUint16(off);
v.getInt32(off); v.getUint32(off);
v.getBigInt64(off); v.getBigUint64(off);
v.getFloat32(off); v.getFloat64(off);
v.getPointer(off);                    // → FfiPtr | null
v.getCString(off?);                   // → string | null
v.getArrayBuffer(byteLength, off?);   // → ArrayBuffer copy
v.copyInto(destination, off?);        // native → TypedArray
```

Readable/writable types are the scalars plus `pointer`; `cstring` strings
are read with `ffi.cstring`/`getCString`, buffers with
`ffi.copyBytes`/`copyInto`. No bounds checking — C's rules.

## Structs

A C struct is a **byte image** in C layout. Describe it once, get the
layout math for free:

```js
const Blob = ffi.struct([["ptr", "pointer"], ["len", "i32"]]);
Blob.size;          // 16  (ptr @0, len @8 — padded to align 8)
Blob.offsets;       // { ptr: 0, len: 8 }
```

Fields are positional; names are yours (they key `offsets`). Deno-style
type-only lists work too — fields become `f0`, `f1`, …:

```js
const S = ffi.struct(["u8", "u64"]);   // { f0: 0, f1: 8 }, size 16
```

Layout follows C rules automatically: natural alignment per field,
struct alignment = the largest field's, size padded to it. Need a packed
layout? Insert `u8` padding fields yourself. Field types may be any
scalar including `pointer`/`cstring`/`buffer`, or nested struct/union
specs. `void` fields are rejected.

**Nested structs** work inline or with named specs:

```js
const Inner = ffi.struct([["x", "i32"], ["y", "i32"]]);
const Outer = ffi.struct([["id", "i32"], ["inner", Inner]]);
Outer.size;          // 12  (id @0, inner @4)
Outer.offsets;       // { id: 0, inner: 4 }

// inline nested spec
const T = ffi.struct([["tag", "i32"], ["val", { struct: [["a", "u8"], ["b", "u8"]] }]]);
```

Nested fields are bytes at the parent's offset — no flattening, no
copies. Depth is capped at 8 levels.

Use the spec inline or as a named value in a symbol table:

```js
const lib = ffi.dlopen("libprobe.dylib", {
  add_blob:  { parameters: [Blob], result: Blob },            // named
  make_blob: { parameters: [], result: { struct: [["ptr","pointer"],["len","i32"]] } },  // inline
});
```

- **Parameters:** pass a `Uint8Array` of at least `Blob.size` bytes,
  fields written at `Blob.offsets`.
- **Results:** a fresh `Uint8Array` of `Blob.size` bytes — read it with
  `DataView`, or `ffi.view(ffi.ptr(result))`.

```js
const img = new Uint8Array(Blob.size);
const ip = ffi.view(img);
ffi.write(ip, "pointer", ffi.ptr(payload), 0);
ffi.write(ip, "i32", payload.byteLength, 8);

const out = lib.symbols.add_blob(img);      // Uint8Array, Blob.size
const op = ffi.view(out);
ffi.read(op, "pointer", 0);                 // → FfiPtr
ffi.read(op, "i32", 8);                     // → doubled length
```

Limits: at most 64 fields and 512 bytes per struct.

**Structs passed by pointer** (the common C pattern — `void f(const
z_stream *)`) don't use struct types at all: lay the fields into a scratch
buffer and pass it as `buffer`/`pointer`. `Blob.offsets` and
`ffi.read`/`ffi.write` do the layout work:

```js
const scratch = new Uint8Array(Blob.size);
const sp = ffi.view(scratch);
ffi.write(sp, "pointer", ffi.ptr(payload), Blob.offsets.ptr);
ffi.write(sp, "i32", payload.byteLength, Blob.offsets.len);
lib.symbols.consume_struct(ffi.ptr(scratch));   // passed by pointer
```

## Unions

A C union overlays all members at offset 0. Size = the largest member's
size, aligned to the largest member's alignment. Passing works exactly
like structs — byte images in, byte images out:

```js
const U4 = ffi.union([["i", "i32"], ["f", "f32"]]);
U4.size;   // 4  (both members are 4 bytes)

const U8 = ffi.union([["c", "u8"], ["n", "u64"]]);
U8.size;   // 8  (u64 dominates)
```

Members are positional; names are yours. Inline `{ union: [...] }` works
in symbol specs and as nested struct fields:

```js
// inline in a symbol spec
const lib = ffi.dlopen("libprobe.dylib", {
  identity: {
    parameters: [{ union: [["i", "i32"], ["f", "f32"]] }],
    result:    { union: [["i", "i32"], ["f", "f32"]] },
  },
});

// union as a struct field
const Tagged = ffi.union([["tag", "i32"], ["val", { union: [["i", "i32"], ["f", "f32"]] }]]);
```

Reading a union member: write/read at offset 0 with the member's type:

```js
const img = new Uint8Array(U4.size);
const dv = new DataView(img.buffer);
dv.setInt32(0, 42, true);          // write as i32
const out = lib.symbols.identity(img);
const odv = new DataView(out.buffer, out.byteOffset, out.byteLength);
odv.getFloat32(0, true);           // read the same bytes as f32
```

Limits: at most 64 members, 512 bytes per union, nesting depth 8.

## Callbacks

Pass a JS function where C expects a function pointer. Create one with
`ffi.callback(spec, fn)`:

```js
const add = ffi.callback(
  { parameters: ["i32", "i32"], result: "i32" },
  (a, b) => a + b
);

add.pointer;   // FfiPtr — the native code address
add.close();   // free the native closure (call when C is done with it)
```

The spec shape matches symbol specs (`parameters`, `result`). Use
`add.pointer` as a `function`-type argument:

```js
const lib = ffi.dlopen("libprobe.dylib", {
  apply: { parameters: ["function", "i32", "i32"], result: "i32" },
});

lib.symbols.apply(add.pointer, 3, 4);   // 7
```

**Same-thread calls** (C calls back synchronously on the JS thread) are
direct — zero overhead. **Foreign-thread calls** (C calls back from a
thread it owns) go through a bridge: the raw argument bytes are copied,
enqueued, and the JS function runs on the JS thread. The C caller blocks
until the result is ready.

A JS throw inside a callback:
- **same-thread:** rethrows at the caller (`lib.symbols.apply(...)` throws)
- **foreign-thread with `nonblocking`:** rejects the enclosing Promise
- **foreign-thread without `nonblocking`:** reported as an uncaught error

`close()` frees the native closure. It refuses (`TypeError`) while a
call is in flight — call it when C is done with the pointer. The
finalizer is a backstop; freeing under a live native pointer crashes.

`cstring` results are not supported from callbacks (v1).

## Nonblocking calls

Mark a symbol `nonblocking: true` and it returns a `Promise` instead of
running on the JS thread. The native call runs on a worker thread; the
event loop stays free:

```js
const lib = ffi.dlopen("libz.1.dylib", {
  compress: {
    parameters: ["buffer", "usize", "buffer", "usize"],
    result: "i32",
    nonblocking: true,
  },
});

const out = new Uint8Array(1024);
const p = lib.symbols.compress(out, 1024n, input, input.length);
// p is a Promise — the loop keeps running
const rc = await p;
```

Semantics:
- `buffer` arguments are **copied in** at call time and **copied back**
  after settle. Mutation is only visible after the Promise resolves.
- `cstring` arguments are copied; `pointer` is passed by value (caller
  keeps the memory alive).
- The result is wrapped at settle time (same as a sync call).
- Up to 32 concurrent calls (job pool).

Combine with callbacks — a JS callback invoked from C during a
nonblocking call runs on the JS thread via the bridge, and a throw
rejects the Promise:

```js
const onProgress = ffi.callback({ parameters: ["i32"], result: "void" }, (pct) => {
  console.log("progress:", pct);
});

const rc = await lib.symbols.long_running(onProgress.pointer);
```

## Ownership

The rules are C's rules — the FFI adds no safety net:

- A `buffer` you pass must stay alive for the duration of the call. Keep
  the `TypedArray` referenced; don't rely on detached/collected memory.
  (For `nonblocking` calls, buffers are copied — safe to mutate after
  settle.)
- A `pointer`/`buffer` result carries no ownership. If the library
  allocated it, call the library's own free function — `ffi` never frees
  native memory.
- `cstring` results and struct/union results are copies — always safe to
  keep.
- Calling past a buffer's bounds, or through a stale pointer, is
  undefined behavior. Keep the FFI surface you expose small.

## Contracts & limits

- **Deadlock:** never invoke a JS callback from a thread spawned by a
  *synchronous* `ffi` call. The JS thread is blocked inside `ffi_call`
  and cannot service the bridge. Callbacks from threads owned by C (or
  from nonblocking worker threads) are safe.
- **`close()` while busy:** `FfiCallback.close()` throws while a bridged
  call is in flight or a nonblocking call holds the callback. Close after
  C is done.
- `cstring` callback results are not supported (v1).
- No Windows (POSIX `dlopen` only), no variadic functions.
- Max 32 parameters, 64 fields/members, 512 bytes per struct/union,
  nesting depth 8.
