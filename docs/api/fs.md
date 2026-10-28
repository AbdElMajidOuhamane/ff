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
`*Async` form when you want the error. Permission denial is separate: it
throws `PermissionDenied` before the operation runs.

## Permissions

`fs` is deny-by-default.

| Operations | Flag |
|---|---|
| `readFile`, `exists`, `readdir` (sync and async) | `--allow-read` |
| `writeFile`, `mkdir`, `rm` (sync and async) | `--allow-write` |

```sh
ff script.js --allow-read=. --allow-write=./out
```

- Relative scopes resolve against the **launch** cwd and stay fixed. A later
  `process.chdir()` does not move them.
- Matching is component-exact: `--allow-read=/srv/app` covers
  `/srv/app/data.json`, not `/srv/app2/data.json`.
- Symlinks are resolved before matching. The target must be inside a scope; a
  symlink inside an allowed directory that points outside is denied. Writes
  through a dangling symlink are denied.
- `..` traversal, NUL bytes, and paths at or beyond 4096 bytes are denied.
- Bare `--allow-read` / `--allow-write` grant every path.
- There are no globs or per-extension rules.

Full model: [Permissions](/docs/concepts/permissions).

## Read a file

```js
const text = fs.readFile("notes.txt");
console.log(text);
```

Returns the file content as a string, or `undefined` when the **I/O** fails
(missing file, OS permission). Reads cap at 10MB. Without `--allow-read` on the
path, the call throws `PermissionDenied` instead.

```sh
ff read.js --allow-read=notes.txt
# or: --allow-read=.
```

## Write a file

```js
fs.writeFile("out.txt", "Hello from Fairyfly!");
```

Creates the file when missing, overwrites when present. Parent directories must exist — use `mkdir` first. Needs `--allow-write` on the file.

## Check existence

```js
if (fs.exists("out.txt")) {
  console.log("found");
}
```

Returns `true` or `false`. It never throws on a missing path, but a path
outside `--allow-read` throws `PermissionDenied` — a missing file inside the
scope returns `false`.

## Make directories

```js
fs.mkdir("a/b", true);
```

The second argument is `recursive`. Pass `true` to create parents as needed, omit it for a single level. Needs `--allow-write` on the target path.

## Remove files and directories

```js
fs.rm("out.txt");
fs.rm("a", true);
```

The second argument is `recursive`. Pass `true` to delete a directory tree, omit it for a single file. Needs `--allow-write` on the target path.

## List a directory

```js
console.log(fs.readdir("."));
```

Returns an array of names (files and directories), or `undefined` when
the path is missing. Needs `--allow-read` on the directory.

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

Permission denial is thrown **synchronously**, before the Promise is created:

```js
try {
  const p = fs.readFileAsync("/etc/passwd"); // throws here
} catch (e) {
  console.error(e.name, e.code); // "PermissionDenied" "PERMISSION_DENIED"
}
```

Inside an `async` function that synchronous throw becomes a rejected promise.
The flag and scope rules are identical to the sync calls.

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

```sh
ff example.js --allow-read=. --allow-write=.
```

## Limits you will hit

- Max path 4096 bytes.
- Max read 10MB per call.
- Sync **I/O** failures return `undefined` — no exception is raised, so a
  `try/catch` around a missing file catches nothing. Permission denial is the
  exception and does throw.
- Scope roots are fixed at launch; `process.chdir()` does not move them.
- No file watching — poll with timers instead.
