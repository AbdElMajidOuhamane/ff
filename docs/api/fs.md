---
title: Filesystem
description: File access — sync calls and *Async Promise variants: read, write, exists, mkdir, rm, readdir.
order: 4
---

# Filesystem

File access through the `fs` global. Every operation has two forms: a
**sync** call that blocks the event loop until it completes, and an
`*Async` variant (`readFileAsync`, `writeFileAsync`, `existsAsync`,
`mkdirAsync`, `rmAsync`, `readdirAsync`) that returns a Promise, runs on
a dedicated 4-thread pool, and **rejects with a real `Error`** (e.g.
`message === "FileNotFound"`).

Sync calls **never throw on I/O errors** — a missing file or bad path
silently returns `undefined`. Guard with `fs.exists()`, or use the
`*Async` form when you want the error.

## Read a file

```js
const text = fs.readFile("notes.txt");
console.log(text);
```

Returns the file content as a string, or `undefined` when the read fails
(missing file, permission denied) — no exception is thrown. Reads cap at
10MB.

## Write a file

```js
fs.writeFile("out.txt", "Hello from Fairyfly!");
```

Creates the file when missing, overwrites when present. Parent directories must exist — use `mkdir` first.

## Check existence

```js
if (fs.exists("out.txt")) {
  console.log("found");
}
```

Returns `true` or `false`. Never throws.

## Make directories

```js
fs.mkdir("a/b", true);
```

The second argument is `recursive`. Pass `true` to create parents as needed, omit it for a single level.

## Remove files and directories

```js
fs.rm("out.txt");
fs.rm("a", true);
```

The second argument is `recursive`. Pass `true` to delete a directory tree, omit it for a single file.

## List a directory

```js
console.log(fs.readdir("."));
```

Returns an array of names (files and directories), or `undefined` when
the path is missing.

## Async variants

Same names with an `Async` suffix, each returning a Promise:

```js
const text = await fs.readFileAsync("notes.txt");          // string (default)
const bytes = await fs.readFileAsync("data.bin", "buffer"); // Uint8Array
const ok = await fs.existsAsync("notes.txt");               // boolean
await fs.writeFileAsync("out.txt", "hello");
await fs.mkdirAsync("a/b", true);
await fs.rmAsync("out.txt");
const names = await fs.readdirAsync(".");
```

Failures **reject** instead of being swallowed:

```js
try {
  await fs.readFileAsync("missing.txt");
} catch (e) {
  console.error(e.message); // "FileNotFound"
}
```

The second argument of `readFileAsync` is a mode: `"buffer"` / `"binary"`
returns bytes; anything else returns a string.

> **Known issue:** after a *successful* `fs.*Async` call the process may
> never exit — the promise settles and prints, then the loop waits on the
> fs pending counter forever. Failures exit normally. This is invisible
> inside servers; in short scripts prefer sync calls or `process.exit()`.

## Full example

```js
fs.writeFile("out.txt", "Hello from Fairyfly!");
console.log(fs.exists("out.txt"));
console.log(fs.readFile("out.txt"));
fs.mkdir("a/b", true);
console.log(fs.readdir("."));
fs.rm("out.txt");
```

## Limits you will hit

- Max path 4096 bytes.
- Max read 10MB per call.
- Sync failures return `undefined` — no exception is raised, so `try/catch` around sync calls catches nothing.
- No file watching — poll with timers instead.
