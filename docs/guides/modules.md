---
title: Modules
description: ESM imports that resolve — relative paths, bare packages, and the lookup rules.
order: 12
---

# Modules

Fairyfly has exactly one loader: ES modules. There is no `require()`, no CommonJS, no `Buffer`, and no URL imports. Three specifier shapes resolve: relative (`./`, `../`), absolute (`/`), and bare (`marked`, `@scope/pkg`).

## How a file is classified

When `ff <file>` runs a source file, the runtime decides module vs. classic script like this:

1. If the filename ends in `.mjs` → **module**. Always.
2. Otherwise, scan the source, skipping leading whitespace, `;`, `,`, `//` and `/* */` comments, and look at the **first significant token**. If it begins with any of `import `, `export `, `import{`, `export{`, `import('`, or `import("` → **module**.
3. Anything else → **classic script** (evaluated as a global program).

Two consequences worth internalizing:

- `import`/`export` must come **before any other statement**. A file that logs something and *then* imports (e.g. `console.log(...)` on line 1, `import …` on line 2) is classified as a classic script, and the `import` fails to parse. Put imports at the very top.
- `ff -e '<code>'` is always a classic script — no `import`/`export`, no top-level `await`.

Top-level `await` works in every **module** (no async wrapper needed) and in no classic script.

## Quick look

```js
// main.js — first token is `import`, so this is a module
import { greet } from "./greet.js";
import { marked } from "marked";

console.log(greet("ada"));
console.log(marked.parse("# hi"));
```

```js
// greet.js
export function greet(name) {
  return `hello, ${name}`;
}
```

```sh
ff imprint marked
ff main.js
# hello, ada
# <h1>hi</h1>
```

Async at the top level is fine in a module:

```js
// fetch-top.mjs — or any file whose first token is import/export
const res = await fetch("https://example.com/");
console.log(res.status);
```

## Relative imports: `./` and `../`

A relative specifier is joined onto the **importer's** directory and normalized (`.` and `..` are collapsed). Then:

- If the resulting basename contains a `.`, it is loaded **literally**.
- Otherwise the loader probes `<path>.js`, then `<path>/index.js`.
- If neither exists, the load error names the `<path>.js` candidate.

```js
import { router } from "./router.js";     // ./router.js
import { legacy } from "./legacy";        // probes ./legacy.js, then ./legacy/index.js
import { check } from "./lib.mjs";        // .mjs works too — any literal name
import { db } from "../shared/db.js";     // up one, then down
```

> **Note:** The probe only tries `X.js` and `X/index.js`. Every other
> extension (`.mjs`, `.json`, `.node`, …) must be written out.

`..` segments normalize against the importer's directory (`./a/../b.js` → `./b.js`). Relative paths are anchored by a leading `.` component, so an entry run from the project root resolves root-level files correctly.

## Bare imports: packages

A specifier is **bare** when it does not start with `.` or `/` and does not contain `://`. For a bare specifier the loader extracts the package name — the first path segment, or the first two for `@scope/pkg` — and the optional subpath:

```js
import { marked } from "marked";            // pkg = "marked"
import Button from "@scope/ui/button.js";   // pkg = "@scope/ui", rest = "button.js"
```

It then walks **up** from the importer's directory. At each level `<dir>` it tries `<dir>/node_modules/<pkg>`; if that resolves, the walk stops. The walk ascends by stripping the last path segment, and stops when the directory no longer contains a `/`:

```js
// importer:  ./lib/server.js   (dir = "./lib")
// tries:     ./lib/node_modules/marked
//            ./node_modules/marked         <- hit
```

Because resolution is anchored at the importer's path as written, run the entry point from the project root (or keep it at the root) so the walk reaches `./node_modules`. `ff start` reads `main` from `ff.json` — usually `main.js` at the root — so the common case works.

### What a package directory resolves to

Inside `<dir>/node_modules/<pkg>`, the first of these rules that yields **an existing file** wins, in order:

| # | Rule |
|---|------|
| 1 | `package.json` `exports` |
| 2 | `package.json` `module` |
| 3 | `package.json` `main` |
| 4 | Subpath passthrough — `pkg/rest` loads `node_modules/pkg/rest` if that file exists |
| 5 | Root fallback — bare `pkg` loads `node_modules/pkg/index.js` if it exists |

`exports` in detail:

- **Root import** (`pkg`): a bare string (`"exports": "./dist/index.mjs"`), or an object with an `import` or `default` string, or an object with a `"."` entry (itself a string, or an object with `import`/`default`).
- **Subpath import** (`pkg/feature`): only the `exports` map is consulted — the key must be `"./feature"` (itself a string, or an object with `import`/`default`). `module`/`main` are **not** used for subpaths.
- Wildcard keys (`"./*"`) are not expanded by the resolver; a matching literal file is required.

If `node_modules/<pkg>/package.json` is absent or silent on the specifier, rules 4–5 apply; if those fail too, the walk continues to the parent directory.

Two sharp edges, both fail **loud**:

- A manifest entry naming a file that is not on disk is a broken install: the loader prints `could not load module filename '<path>'` and errors hard. It never silently falls through to a higher copy (same strictness as npm).
- A subpath import (`pkg/feature`) needs an `exports` map entry (`"./feature"`) **or** a matching literal file. Neither = keep walking, then fail.

When the whole walk is exhausted, the loader reports the **first** candidate it tried (`<importer-dir>/node_modules/<pkg>/index.js`, or `…/<rest>` for a subpath).

Install packages first — resolution needs the files on disk:

```sh
ff imprint marked
```

See the [Packages guide](/docs/guides/packages) for the install gate (pure-JS ESM only) and lockfiles.

## Absolute paths

A leading `/` loads literally from the filesystem root — no lookup, no fallback. An extensionless absolute path still gets the `.js` / `/index.js` probe:

```js
import { cfg } from "/etc/myapp/config.js";
```

## `import.meta.url`

In a module, `import.meta` is an object. For every module the loader reads from disk (your `import` targets), it sets `import.meta.url` to `"file://"` followed by the module's **resolved** path. That path is whatever the rules above produced, so it is relative to the process working directory rather than guaranteed absolute:

```js
// imported modules, run from the project root:
//   ./node_modules/marked/lib/marked.esm.js  -> file://./node_modules/marked/lib/marked.esm.js
//   ./lib/server.js                          -> file://./lib/server.js
console.log(import.meta.url);
```

`import.meta` exists only in modules; classic scripts have no `import.meta`.

## Dynamic import

A module may use `import()` (the async form), which resolves through the same loader and returns a promise. Its presence is itself a module signal (see classification above):

```js
// top-level await is fine in a module
const { greet } = await import("./greet.js");
console.log(greet("ada"));
```

## Reference

| Specifier | Resolves to |
|-----------|-------------|
| `./x.js`, `../x.js` | Literal join onto importer dir, normalized |
| `./x` (extensionless) | Probes `./x.js`, then `./x/index.js` (error names `./x.js`) |
| `pkg`, `pkg/sub` | `node_modules` walk-up: `exports` → `module` → `main` → literal subpath → `index.js` |
| `@scope/pkg` (+ `/sub`) | Same, with scoped-package name parsing |
| `/abs/path.js` | Literal filesystem path |
| `https://…`, `data:…` | Not supported — the loader reports `could not load module filename '…'` |
| `require()`, `module.exports` | Absent — `require` is not defined; ESM only |

## Troubleshooting

**`could not load module filename '…'`** — the specifier resolved to a path with no file. For relative imports: check spelling and extension. For bare imports: run `ff imprint <pkg>`, confirm `node_modules/<pkg>` exists, and run from the project root so the walk reaches `./node_modules`.

**My `import` isn't recognized / "unexpected token import"** — the file was classified as a classic script. `import`/`export` must be the first statement (after whitespace and comments). Add `.mjs` or move the imports to the top.

**Extensionless relative import fails** — the probe only tries `X.js` and `X/index.js`. Write out any other extension (`.mjs`, …).

**`require is not defined`** — ESM only. Convert to `import`, or pick a package that ships ESM.

**Works from the root, fails from a subdirectory** — bare resolution is anchored at the importer's directory and ascends until no `/` remains. A nested importer (`lib/server.js`) only reaches `./node_modules` when its path carries the leading `.` anchor (which relative imports from the root do). Prefer running `ff start` (main at the root) or running from the project root.

**Wrong file loaded from a package** — the manifest's `exports`/`module`/`main` chain picked it. Inspect `node_modules/<pkg>/package.json` to see which entry won.
