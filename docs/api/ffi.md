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

`--allow-ffi` is parsed from anywhere on the command line (before or after
the file/command), so `ff app.js --allow-ffi` and `ff --allow-ffi app.js`
both work. It is accepted by `ff <file>`, `ff -e`, `ff test`, and
`ff start`.

Without the flag:
- `ffi.dlopen(...)` throws `TypeError: ffi.dlopen requires --allow-ffi`.
- `ffi.callback(...)` throws `TypeError: ffi.callback requires --allow-ffi`.
- `ffi.allowed === false` (it is `true` only with the flag).

The memory/pointer helpers (`ffi.ptr`, `ffi.view`, `ffi.read`,
`ffi.write`, `ffi.copyBytes`, `ffi.writeBytes`, `ffi.struct`,
`ffi.union`, `ffi.cstring`, `ffi.isNull`) are **not** gated — they only
manipulate pointers you already have.

> **Prebuilt binaries ship without FFI.** Release binaries and the GHCR image
> are built with `-Dffi=false`, so `ffi.dlopen`/`ffi.callback` throw
> `ffi.dlopen: FFI not compiled in (build with -Dffi=true)` even with
> `--allow-ffi`. FFI works out of the box in source builds (`-Dffi` defaults
> to `true`). `-Dffi=false` compiles stubs instead of linking system libffi.

## Quick look

```js
// app.js — run with: ff app.js --allow-ffi
// Platform C library: "libSystem.B.dylib" on macOS, "libc.so.6" on Linux.
const lib = ffi.dlopen("libSystem.B.dylib", {
  getpid: { parameters: [], result: "i32" },
  strlen: { parameters: ["cstring"], result: "usize" },
  div:    { parameters: ["i32", "i32"], result: { struct: [["quot", "i32"], ["rem", "i32"]] } },
});

console.log(lib.symbols.getpid());          // 60395
console.log(lib.symbols.strlen("hello"));   // 5n   (usize → BigInt)

const t = lib.symbols.div(7, 2);            // Uint8Array — the struct's bytes (8)
const v = ffi.view(t);
v.getInt32(0);                              // 3  (quot)
v.getInt32(4);                              // 1  (rem)

lib.close();
```

## Members

| Member | Signature | Gate |
|---|---|---|
| `ffi.allowed` | boolean | — |
| `ffi.dlopen(path, symbols)` | → `FfiLibrary` | `--allow-ffi` + compiled-in |
| `ffi.callback(spec, fn)` | → `FfiCallback` | `--allow-ffi` + compiled-in |
| `ffi.struct(fields)` | → `FfiStruct` | — |
| `ffi.union(members)` | → `FfiUnion` | — |
| `ffi.ptr(value, offset?)` | → `FfiPtr` | — |
| `ffi.view(value, offset?)` | → `FfiPtr` (alias of `ffi.ptr`) | — |
| `ffi.cstring(value)` | → `string \| null` | — |
| `ffi.isNull(value)` | → boolean | — |
| `ffi.read(ptr, type, offset?)` | → value | — |
| `ffi.write(ptr, type, value, offset?)` | → `undefined` | — |
| `ffi.copyBytes(ptr, byteLength)` | → `ArrayBuffer` | — |
| `ffi.writeBytes(ptr, data)` | → `undefined` | — |

## dlopen

```js
const lib = ffi.dlopen(path, symbols);
```

- `path` — anything the OS loader accepts: absolute, `./`-relative, or a
  system name (`"libz.1.dylib"`, `"libz.so.1"`). Symbols are resolved
  eagerly (`RTLD_NOW`): a missing library/symbol fails at `dlopen`, not at
  first call.
- `symbols` — a plain object `{ name: spec }`. Each entry declares one C
  symbol.
- Max **32 parameters** per symbol. `parameters` and `result` are both
  required: omitting `parameters` throws `ffi: '<name>': 'parameters' must be
  an array`; omitting `result` throws `ffi: '<name>': unknown type
  'undefined'` (the missing value is stringified). A parameter list may be
  empty (`[]`).
- Missing library → `TypeError: ffi.dlopen: '<path>': <loader message>`.
- Missing symbol → `TypeError: ffi: symbol '<name>' not found` at
  `dlopen`, unless `optional: true`, in which case `lib.symbols.name` is
  `null`.

The per-symbol spec:

```js
{
  parameters: [type, ...],     // required, array; each type below
  result:     type,            // required
  optional:   true,            // optional: missing symbol → null instead of throw
  nonblocking: true,           // optional: calls return a Promise (see below)
}
```

Returns a **library object**:

| Property | What it does |
|---|---|
| `lib.symbols.name(...args)` | Call the C function (returns a `Promise` if `nonblocking: true`) |
| `lib.symbols.name` | `null` for an `optional` symbol the library didn't export |
| `lib.close()` | `dlclose`; further calls throw. Idempotent |

A closed library throws `TypeError: ffi: library is closed`. If the library
object is garbage-collected, the handle is closed for you.

The library path argument is required first (`ffi.dlopen` with no arguments
throws `ffi.dlopen: expected a library path`), and the symbols object is
required second (`ffi.dlopen: expected a symbols object`).

## Types

The type name is a string (`"i32"`, `"cstring"`, …), or an object for an
aggregate: `{ struct: [...] }`, `{ union: [...] }`, or an `FfiStruct` /
`FfiUnion` value from `ffi.struct` / `ffi.union`.

| Type | JS in | JS out | Notes |
|---|---|---|---|
| `i8 u8 i16 u16 i32 u32` | `number`, `BigInt` | `number` | Truncated to the C width; `newInt32`/`newUint32` |
| `i64 u64 isize usize` | `BigInt`, `number` | `BigInt` | `usize`/`isize` are 64-bit on supported targets |
| `f32 f64` | `number` | `number` | `ToNumber` on the way in |
| `void` | — | `undefined` | **Result only** — a `void` parameter throws |
| `pointer` | `FfiPtr`, `BigInt`, `null`/`undefined` | `FfiPtr` \| `null` | `null`/`undefined` → NULL; `0` address → `null` |
| `buffer` | `TypedArray`, `ArrayBuffer`, `FfiPtr`, `BigInt`, `null` | `FfiPtr` \| `null` | Passes the data pointer (view-adjusted); a result is a pointer, not a copy |
| `cstring` | `string`, `null`/`undefined` | `string` \| `null` | In: NUL-terminated copy, valid for the call. Out: cloned JS string |
| `function` | `FfiCallback.pointer` (or `FfiPtr`/`BigInt`) | `FfiPtr` \| `null` | JS→C callback — see [Callbacks](#callbacks) |
| struct | `Uint8Array` (≥ `size` bytes) | `Uint8Array` (`size` bytes) | Byte image in C layout — see [Structs](#structs) |
| union | `Uint8Array` (≥ `size` bytes) | `Uint8Array` (`size` bytes) | Byte image, all members at offset 0 — see [Unions](#unions) |

Unknown type names throw at `dlopen` (`ffi: '<name>': unknown type '<t>'`).
The exact set of accepted names: `i8 u8 i16 u16 i32 u32 i64 u64 isize
usize f32 f64 void pointer buffer cstring function`. There are no aliases
(`int`, `size_t`, `bool`, `f16`, `ptr` are **not** types — see the note
under [Structs](#structs)).

## Calling a symbol

```js
lib.symbols.name(a, b, ...);
```

- Fewer arguments than declared → `TypeError: ffi: '<name>' expects <n>
  arguments, got <m>`. **Extra arguments are ignored.**
- Results are wrapped by type: small ints/floats as `number`, 64-bit
  ints as `BigInt`, pointers as `FfiPtr` (or `null`), `cstring` as a
  string copy, struct/union as a fresh `Uint8Array`.
- A symbol declared `nonblocking: true` returns a `Promise` instead — see
  [Nonblocking calls](#nonblocking-calls).

## Pointers

`FfiPtr` is an opaque handle — the address lives inside it.

```js
const p = ffi.ptr(typedArray);     // pointer to the TypedArray's data (view-adjusted)
const q = ffi.ptr(p, 16);          // p + 16 bytes
const r = ffi.ptr(0x1000n);        // raw address

p.addr;        // 140234n (BigInt)
p.toString();  // "FfiPtr(0x224b0)"
ffi.isNull(p); // true for null/undefined and for 0-address pointers
ffi.cstring(p);        // read a NUL-terminated C string → JS string | null
ffi.cstring(typedArray); // same, from a buffer's first byte
```

`ffi.ptr` accepts an existing `FfiPtr` (optionally plus a byte offset), a
`BigInt` address, a `TypedArray`/`ArrayBuffer` (pointer to its data), or
`null`/`undefined` (NULL). Anything else throws
`ffi.ptr: expected pointer or buffer` (and a non-buffer object throws
`ffi.ptr: expected a TypedArray or ArrayBuffer`). `ffi.view(x)` is an
**alias of `ffi.ptr(x)`**; every `FfiPtr` already carries the view getters
below.

## Memory

Read and write native memory at any pointer, with byte offsets:

```js
ffi.write(p, "u32", 0xdeadbeef, 0);   // (ptr, type, value, offset?)
ffi.read(p, "u32", 0);                // → 3735928559
ffi.copyBytes(p, 16);                 // → ArrayBuffer copy of 16 bytes
ffi.writeBytes(p, typedArray);        // typedArray bytes → native memory
```

Readable/writable types are the **scalars plus `pointer`/`function`**;
`void`, `struct`, `cstring`, and `buffer` are rejected (`ffi: type '<t>' is not
readable/writable this way`). Read/write a `cstring` with
`ffi.cstring`/`getCString`, and a struct/union through its `Uint8Array`
image. There is no bounds checking — C's rules.

`ffi.view(p)` returns a `FfiPtr` with DataView-style getters
(Deno-compatible names):

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

Negative offsets/lengths throw `TypeError` (`ffi view: negative offset`,
`ffi view: negative length`, `ffi.copyBytes: negative length`).

## Structs

A C struct is a **byte image** in C layout. Describe it once, get the
layout math for free:

```js
const Blob = ffi.struct([["ptr", "pointer"], ["len", "i32"]]);
Blob.size;          // 16  (ptr @0, len @8 — padded to align 8)
Blob.offsets;       // { ptr: 0, len: 8 }
```

Fields are positional; names are yours (they key `offsets`). Type-only
lists work too — fields become `f0`, `f1`, …:

```js
const S = ffi.struct(["u8", "u64"]);   // { f0: 0, f1: 8 }, size 16
```

Layout follows C rules automatically: natural alignment per field, struct
alignment = the largest field's, size padded to it. Field types may be any
scalar including `pointer`/`cstring`/`buffer`, or nested struct/union
specs. `void` fields are rejected. There is **no packed/unaligned mode** —
a C `__attribute__((packed))` struct must be passed as a raw
`buffer`/`pointer` and addressed by byte offsets with `ffi.read`/`ffi.write`.

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
  add_blob:  { parameters: [Blob], result: Blob },            // named FfiStruct
  make_blob: { parameters: [], result: { struct: [["ptr","pointer"],["len","i32"]] } },  // inline
});
```

- **Parameters:** pass a `Uint8Array` of at least `Blob.size` bytes,
  fields written at `Blob.offsets`. A smaller image throws
  `ffi: struct argument <i>: image is <n> bytes, needs <m>`.
- **Results:** a fresh `Uint8Array` of `Blob.size` bytes — read it with
  `DataView`, or get a pointer with `ffi.view(t)`.

```js
const img = new Uint8Array(Blob.size);
const ip = ffi.view(img);
ffi.write(ip, "pointer", ffi.ptr(payload), Blob.offsets.ptr);
ffi.write(ip, "i32", payload.byteLength, Blob.offsets.len);

const out = lib.symbols.add_blob(img);      // Uint8Array, Blob.size
const op = ffi.view(out);
ffi.read(op, "pointer", 0);                 // → FfiPtr
ffi.read(op, "i32", 8);                     // → doubled length
```

Limits: at most **64 fields** and **512 bytes** per struct; nesting depth
**8**. Exceeding them throws (`bad struct field count`, `struct exceeds the
512-byte limit`, `struct nesting too deep (max 8)`).

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
like structs — byte images in, byte images out. The returned object only
has `size` (no `offsets`: every member is at 0):

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

Limits: at most **64 members**, **512 bytes** per union, nesting depth
**8**.

## Callbacks

Pass a JS function where C expects a function pointer. Create one with
`ffi.callback(spec, fn)`:

```js
// app.js — run with: ff app.js --allow-ffi
const add = ffi.callback(
  { parameters: ["i32", "i32"], result: "i32" },
  (a, b) => a + b
);

add.pointer;   // FfiPtr — the native code address (null after close())
add.close();   // free the native closure (call when C is done with it)
```

The spec shape matches symbol specs (`parameters`, `result`). Use
`add.pointer` as a `function`-type argument. A full worked example with
libc's `qsort`:

```js
// app.js — run with: ff app.js --allow-ffi
const cmp = ffi.callback(
  { parameters: ["pointer", "pointer"], result: "i32" },
  (a, b) => ffi.read(a, "i32") - ffi.read(b, "i32")
);

const lib = ffi.dlopen("libSystem.B.dylib", {
  qsort: { parameters: ["buffer", "usize", "usize", "function"], result: "void" },
});

const arr = new Int32Array([3, 1, 2, 9, -4]);
lib.symbols.qsort(arr, 5n, 4n, cmp.pointer);
console.log(Array.from(arr));   // [ -4, 1, 2, 3, 9 ]

cmp.close();
lib.close();
```

`parameters` may be empty and `result` may be `void`, but a `void`
parameter throws and a `cstring` **result** is not supported (v1) — both
rejected at `ffi.callback` time.

**Same-thread calls** (C calls back synchronously on the JS thread) are
direct — zero overhead. **Foreign-thread calls** (C calls back from a
thread it owns) go through a bridge: the raw argument bytes are copied,
enqueued, and the JS function runs on the JS thread. The C caller blocks
until the result is ready. A 64-slot pool handles the common case; beyond
that (or for oversized argument lists) the bridge spills to the heap.

A JS throw inside a callback:
- **same-thread:** rethrows at the caller — the enclosing
  `lib.symbols.fn(...)` throws
- **foreign-thread during a `nonblocking` call:** rejects the enclosing
  Promise
- **foreign-thread with no FFI job in flight:** printed as
  `Uncaught (in ffi callback): <message>` (and the run is marked failed)

`close()` frees the native closure and is idempotent. It refuses
(`TypeError`) while a call is in flight — either a foreign-thread call is
being serviced (`FfiCallback.close: callback is busy (in-flight native
call)`) or a `nonblocking` call holds it (`… (in-flight nonblocking
call)`). The finalizer is a backstop; freeing under a live native pointer
crashes.

## Nonblocking calls

Mark a symbol `nonblocking: true` and it returns a `Promise` instead of
running on the JS thread. The native call runs on a worker thread; the
event loop stays free:

```js
// app.js — run with: ff app.js --allow-ffi
(async () => {
  const lib = ffi.dlopen("libSystem.B.dylib", {
    strlen: { parameters: ["cstring"], result: "usize", nonblocking: true },
  });

  const r = await lib.symbols.strlen("hello world"); // Promise → 11n
  console.log(r);
})();
```

Semantics:
- `buffer` arguments are **copied in** at call time and **copied back**
  after settle. Mutation is only visible after the Promise resolves.
- `cstring` arguments are copied; `pointer` is passed by value (caller
  keeps the memory alive).
- The result is wrapped at settle time (same as a sync call).
- Up to **32 concurrent** nonblocking calls (job pool). A 33rd throws an
  out-of-memory error.

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
- No Windows (POSIX `dlopen` only), no variadic functions, no packed
  structs.
- Max 32 parameters, 64 fields/members, 512 bytes per struct/union,
  nesting depth 8, 32 concurrent nonblocking calls, 64 concurrent
  foreign-thread callbacks.

## Error strings

| Message | Raised by |
|---|---|
| `ffi.dlopen requires --allow-ffi` | `ffi.dlopen` without the flag |
| `ffi.callback requires --allow-ffi` | `ffi.callback` without the flag |
| `ffi.dlopen: FFI not compiled in (build with -Dffi=true)` | `-Dffi=false` build |
| `ffi.dlopen: expected a library path` / `… a symbols object` | `ffi.dlopen` arity |
| `ffi.dlopen: '<path>': <loader text>` | `dlopen` failed |
| `ffi.callback: expected (spec, fn)` | `ffi.callback` arity |
| `ffi.callback: 'parameters' must be an array` | callback spec |
| `ffi.callback: bad parameter count` | > 32 callback params |
| `ffi.callback: 'void' is not a parameter type` | `void` callback param |
| `ffi.callback: cstring results are not supported (v1)` | `cstring` callback result |
| `ffi.callback: bad signature` / `closure allocation failed` / `closure preparation failed` | libffi setup |
| `FfiCallback.close: callback is busy (in-flight native call)` | `close()` mid-call |
| `FfiCallback.close: callback is busy (in-flight nonblocking call)` | `close()` mid-nonblocking call |
| `ffi: '<name>': unknown type '<t>'` | bad type name |
| `ffi: '<name>': bad type spec` | non-string, non-object spec |
| `ffi: '<name>': spec object needs a 'struct' or 'union' field` | `{}` spec |
| `ffi: '<name>': struct spec must be an array` | `{ struct: "x" }` |
| `ffi: '<name>': bad struct field count` | 0 or > 64 fields |
| `ffi: '<name>': fields must be scalar or aggregate specs (no void)` | `void` field |
| `ffi: '<name>': struct nesting too deep (max 8)` | depth > 8 |
| `ffi: '<name>': struct exceeds the 512-byte limit` | size > 512 |
| `ffi: symbol '<name>' not found` | missing non-optional symbol |
| `ffi: '<name>': bad signature` | `ffi_prep_cif` failed |
| `ffi: library is closed` | symbol call after `close()` |
| `ffi: '<name>' expects <n> arguments, got <m>` | too few arguments |
| `ffi: argument <i> is not an integer` | non-integer int arg |
| `ffi: expected pointer, bigint, or buffer` | bad pointer arg |
| `ffi: expected a TypedArray or ArrayBuffer` | bad `buffer` arg |
| `ffi: struct argument <i>: expected a TypedArray image` | non-object struct arg |
| `ffi: struct argument <i>: image is <n> bytes, needs <m>` | undersized image |
| `ffi: 'void' is not a parameter type` | `void` param |
| `ffi: argument <i>: callback is closed` | closed callback arg |
| `ffi: expected a type name` / `ffi: unknown type '<t>'` | `ffi.read`/`ffi.write` type |
| `ffi: type '<t>' is not readable/writable this way` | struct/cstring/buffer/void in `read`/`write` |
| `ffi.read: expected (ptr, type, offset?)` | `ffi.read` arity |
| `ffi.write: expected (ptr, type, value, offset?)` | `ffi.write` arity |
| `ffi.write: unsupported type` | write of an unsupported kind |
| `ffi.copyBytes: expected (ptr, byteLength)` / `ffi.copyBytes: negative length` | `ffi.copyBytes` |
| `ffi.writeBytes: expected (ptr, data)` | `ffi.writeBytes` arity |
| `ffi view: not a pointer` | getter on a non-pointer receiver |
| `ffi view: negative offset` / `ffi view: negative length` | negative view arg |
| `ffi view: getArrayBuffer needs a byte length` | arity |
| `ffi view: copyInto needs a destination` / `… needs a TypedArray destination` | `copyInto` |
| `ffi.struct: expected a field array` / `ffi.union: expected a member array` | arity |
| `ffi.cstring: expected pointer or buffer` | `ffi.cstring` |
| `ffi.ptr: expected pointer or buffer` / `ffi.ptr: expected a TypedArray or ArrayBuffer` | `ffi.ptr` |

## See also

- [Concurrency](/docs/concepts/concurrency) — the FFI pools and threads
- [Architecture](/docs/concepts/architecture) — where `src/api/ffi.zig` sits
- [Errors and exit codes](/docs/concepts/errors)
