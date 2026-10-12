---
title: Filesystem
description: File access — sync calls and *Async Promise variants: read, write, exists, mkdir, rm, readdir.
order: 4
---

# Filesystem

File access through the `fs` global. There are six operations, each with two forms:

- a **sync** call that blocks the event-loop thread until the syscall returns;
- an `*Async` variant that returns a `Promise`, runs the blocking work on a small worker pool, and keeps the process alive until it settles.

```text
sync                    async
readFile(path, mode?)   readFileAsync(path, mode?)
writeFile(path, data)   writeFileAsync(path, data)
exists(path)            existsAsync(path)
mkdir(path, rec?)       mkdirAsync(path, rec?)
rm(path, rec?)          rmAsync(path, rec?)
readdir(path)           readdirAsync(path)
```

| Call | On success | On failure |
|---|---|---|
| `fs.readFile(path, mode?)` | `string` or `ArrayBuffer` | `undefined` |
| `fs.writeFile(path, data)` | `undefined` | `undefined` |
| `fs.exists(path)` | `true` / `false` | `false` |
| `fs.mkdir(path, rec?)` | `undefined` | `undefined` |
| `fs.rm(path, rec?)` | `undefined` | `undefined` |
| `fs.readdir(path)` | `string[]` | `undefined` |
| `fs.readFileAsync(path, mode?)` | `Promise<string \| ArrayBuffer>` | rejects `Error` |
| `fs.writeFileAsync(path, data)` | `Promise<undefined>` | rejects `Error` |
| `fs.existsAsync(path)` | `Promise<boolean>` | rejects `Error` |
| `fs.mkdirAsync(path, rec?)` | `Promise<undefined>` | rejects `Error` |
| `fs.rmAsync(path, rec?)` | `Promise<undefined>` | rejects `Error` |
| `fs.readdirAsync(path)` | `Promise<string[]>` | rejects `Error` |

## Sync calls never throw

I/O errors from the sync calls are swallowed: `readFile` / `readdir` return `undefined`, `exists` returns `false`, and the mutators (`writeFile`, `mkdir`, `rm`) return `undefined`. No exception reaches JS, so a `try/catch` around a sync call never fires.

```js
const text = fs.readFile("does-not-exist.txt");
console.log(text); // undefined — not a throw
```

Because there is no error to inspect, guard with `fs.exists()` or use the `*Async` form when you need to know what went wrong.

## Read a file

```js
const text = fs.readFile("notes.txt"); // string, or undefined on any error
```

`fs.readFile(path, mode?)` reads the whole file. `path` must be a string; a non-string (or omitted) `path` is treated as a missing path and returns `undefined`.

The optional second argument selects the return type:

| `mode` | Result |
|---|---|
| omitted, or any string other than the two below | `string` — raw file bytes as a UTF-8 string |
| `"buffer"` | `ArrayBuffer` |
| `"binary"` | `ArrayBuffer` |

The match is exact and case-sensitive; `"utf8"` is accepted but behaves like the default (it returns a string).

> **`"buffer"` returns an `ArrayBuffer`, not a `Uint8Array`.** Wrap it to get a typed view:
>
> ```js
> const ab = fs.readFile("logo.png", "buffer");
> const bytes = new Uint8Array(ab);           // view over the same memory
> const text = new TextDecoder().decode(ab);  // back to a string
> ```

An empty file yields `""` (default) or a zero-length `ArrayBuffer`. Reads are capped at 10 MiB — see [Limits](#limits).

## Write a file

```js
fs.writeFile("out.txt", "Hello from Fairyfly!");
```

`fs.writeFile(path, data)` creates the file or overwrites it. `data` is converted with `ToString`, so pass a string: objects become `"[object Object]"`. There is **no binary write path** — pass a string, not an `ArrayBuffer`.

- Parent directories are **not** created; writing into a missing directory fails. Call `fs.mkdir(dir, true)` first.
- `data` longer than 10 MiB is silently truncated to 10 MiB.
- Returns `undefined` in every case.

## Check existence

```js
if (fs.exists("out.txt")) {
  console.log("found");
}
```

Returns `true` if the path is accessible, otherwise `false` — including when `path` is not a string or is omitted. Never throws.

## Make directories

```js
fs.mkdir("a");           // one directory
fs.mkdir("a/b/c", true); // create any missing parents
```

The second argument is coerced to a boolean:

| `recursive` | Behaviour |
|---|---|
| falsy / omitted | creates a single directory; fails if a parent is missing |
| truthy | creates the directory and any missing parents |

Returns `undefined` (also on failure — check with `fs.exists`).

## Remove files and directories

```js
fs.rm("out.txt");
fs.rm("a");          // a single empty directory
fs.rm("a", true);    // a directory tree
```

The second argument is coerced to a boolean:

| `recursive` | Behaviour |
|---|---|
| falsy / omitted | removes a file, then (if that fails) an empty directory; fails on a non-empty directory |
| truthy | removes the path and, for a directory, its entire subtree |

Returns `undefined` (also on failure).

## List a directory

```js
console.log(fs.readdir(".")); // ["build.zig", "docs", "src", …]
```

Returns an array of entry names — both files and directories, no `.` / `..` — or `undefined` when the path cannot be opened (missing path, a plain file, a non-string argument). Order is whatever the OS returns; it is not sorted.

## Async variants

Each `*Async` call returns a `Promise` and runs the blocking work off the JS thread, on a fixed pool of **16 job slots** backed by **4 worker threads**; completions are delivered back on the JS thread.

```js
(async () => {
  const text = await fs.readFileAsync("notes.txt");          // string
  const ab   = await fs.readFileAsync("data.bin", "buffer"); // ArrayBuffer
  const ok   = await fs.existsAsync("notes.txt");            // boolean
  await fs.writeFileAsync("out.txt", "hello");               // undefined
  await fs.mkdirAsync("a/b", true);                          // undefined
  await fs.rmAsync("out.txt");                               // undefined
  const names = await fs.readdirAsync(".");                  // string[]

  process.exit(0); // required — see "The process does not exit" below
})();
```

The arguments behave like their sync counterparts, with one difference in *when* errors surface:

- `path` must be a string. A missing or non-string `path` throws a **synchronous** `TypeError` — it does **not** return a rejected promise:
  - `"fs.readFileAsync requires a path"`
  - `"fs.existsAsync requires a path"`
  - `"fs.mkdirAsync requires a path"`
  - `"fs.rmAsync requires a path"`
  - `"fs.readdirAsync requires a path"`
  - `"fs.writeFileAsync requires data"` (when the `data` argument is absent)
- `mode`, `recursive`, and `data` behave exactly as in the sync calls (`"buffer"` / `"binary"` → `ArrayBuffer`; the boolean is coerced from truthiness).

### Async failures reject with a real `Error`

```js
(async () => {
  try {
    await fs.readFileAsync("missing.txt");
  } catch (e) {
    console.log(e instanceof Error); // true
    console.log(e.name);             // "Error"
    console.log(e.message);          // "FileNotFound"
  }
})();
```

`e.message` is the runtime's error name. Observed values:

| Situation | `e.message` |
|---|---|
| path does not exist (read / write / rm / readdir, or a missing parent directory) | `"FileNotFound"` |
| file larger than the read limit | `"FileTooLarge"` |

If all 16 job slots are busy — e.g. you submit more than 16 operations in one synchronous turn, before the loop can drain any — the extra submission throws a **synchronous** `"out of memory"` error instead of queueing.

### The process does not exit after an `*Async` call

This is current, verified behaviour: after any `fs.*Async` operation settles — **success or failure** — the event loop keeps the process alive and it never exits on its own.

```js
// prints "got: x" and then hangs forever
(async () => {
  console.log("got:", await fs.readFileAsync("out.txt"));
})();
```

The loop is deliberately held open while jobs are in flight (so `await` can settle), but it does not release once they finish. Sync-only scripts and timer-only scripts exit normally. **Short scripts that use `*Async` must call `process.exit()`** (or prefer the sync calls); inside a long-running server the hang is invisible.

## Full example

Runs to completion with `ff example.js`:

```js
// ff example.js
fs.writeFile("out.txt", "Hello from Fairyfly!");
console.log("exists:", fs.exists("out.txt"));
console.log("read:  ", fs.readFile("out.txt"));
console.log("buffer:", new Uint8Array(fs.readFile("out.txt", "buffer")).length, "bytes");

fs.mkdir("a/b", true);
console.log("entries:", fs.readdir(".").filter((n) => n === "out.txt" || n === "a"));

fs.rm("out.txt");
fs.rm("a", true);
```

Output:

```text
exists: true
read:   Hello from Fairyfly!
buffer: 20 bytes
entries: out.txt,a
```

## Limits

| Limit | Value |
|---|---|
| Path length | 4096 bytes — longer paths are silently truncated |
| Max write payload | 10 MiB (`10485760` bytes) — longer `data` is truncated |
| Max read (`*Async`) | 10 MiB (`10485760` bytes) — larger files reject with `"FileTooLarge"` |
| Max read (sync) | one byte under 10 MiB (`10485759` bytes) — the sync limit is exclusive |
| Concurrent async jobs | 16 (a 17th submission in the same turn throws `"out of memory"`) |
| Worker threads | 4 |

- No file watching — poll with timers instead.
- Sync failures return `undefined` / `false`, so `try/catch` around sync calls catches nothing.
