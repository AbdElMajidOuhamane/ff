---
title: Filesystem
description: Sync file access — read, write, exists, mkdir, rm, readdir.
order: 4
---

# Filesystem

Synchronous file access through the `fs` global. Every call blocks the event loop until it completes, so keep files small and paths local.

## Read a file

```js
const text = fs.readFile("notes.txt");
console.log(text);
```

Returns the file content as a string. Throws when the file is missing. Reads cap at 10MB.

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

Returns an array of names (files and directories). Throws when the path is missing.

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
- Missing files throw — always guard with `exists` or `try/catch`.
- Sync only. There is no file watching — poll with timers instead.
