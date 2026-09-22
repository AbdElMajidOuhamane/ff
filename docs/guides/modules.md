---
title: Modules
description: ESM imports that resolve — relative paths, bare packages, and the lookup rules.
order: 12
---

# Modules

Every file runs as an ES module. `import` is the only loader — there is no `require()`, no CommonJS, and no URL imports. Three specifier shapes resolve: relative (`./`, `../`), absolute (`/`), and bare (`lodash`).

## Quick look

```js
// main.js
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
ff imprint marked@18.0.11
ff main.js
# hello, ada
# <h1>hi</h1>
```

Top-level `await` works in every module — no async wrapper needed:

```js
const res = await fetch("https://example.com/");
console.log(res.status);
```

## Relative imports: `./` and `../`

Joined onto the importer's directory and loaded **literally** — no extension probing, no directory index:

```js
import { router } from "./router.js";     // ./router.js
import { check } from "./lib.mjs";        // .mjs works too — any literal name
import { db } from "../shared/db.js";     // up one, then down
```

> **Caution:** Always write the extension. `import "./router"` looks for a file literally named `router` — it will not try `router.js`. This is the single most common import failure.

`..` segments normalize against the importer dir (`./a/../b.js` → `./b.js`); escaping past the filesystem root resolves to the joined remainder and fails to load.

## Bare imports: packages

Anything not starting with `.`, `/`, or containing `://` is bare, and walks **up** the directory tree through `node_modules/<pkg>`:

```js
import { marked } from "marked";            // node_modules/marked/…
import Button from "@scope/ui/button.js";   // scoped: node_modules/@scope/ui/…
```

For each level (starting at the importer's dir, then each parent), the first `node_modules/<pkg>` hit wins via these rules, in order:

| Step | Rule |
|------|------|
| 1 | `package.json` `exports` — string form, `import`/`default` conditions, or the `"."` root entry for subpath maps |
| 2 | `package.json` `module` field |
| 3 | `package.json` `main` field |
| 4 | Subpath passthrough — `pkg/rest` loads `node_modules/pkg/rest` when that file exists |
| 5 | Root fallback — bare `pkg` loads `node_modules/pkg/index.js` when it exists |

Then the walk continues to the parent directory. Misses everywhere and the loader prints its standard filename error for the first candidate.

Two sharp edges, both fail **loud**:

- A manifest entry naming a file that isn't on disk is a broken install: `could not load module filename '…'` and a hard error. It never silently falls through to a higher copy (same strictness as npm).
- Subpath imports (`pkg/feature`) need an `exports` map entry (`"./feature"`) or a matching literal file. No map + no file = keep walking, then fail.

Install packages first — resolution needs the files:

```sh
ff imprint marked@18.0.11
```

## Absolute paths

A leading `/` loads literally from the filesystem root:

```js
import { cfg } from "/etc/myapp/config.js";
```

No lookup, no fallback. Missing file = load error.

## Practical example: tiny multi-file API

```sh
ff init -y shop && cd shop
ff imprint marked@18.0.11
```

```js
// products.js
export const products = [
  { id: 1, name: "Boots", price: 120 },
  { id: 2, name: "Hat", price: 35 },
];
```

```js
// views.js
import { marked } from "marked";

export function productList(items) {
  const md = items.map((p) => `- **${p.name}** — $${p.price}`).join("\n");
  return marked.parse(md);
}
```

```js
// main.js
import { products } from "./products.js";
import { productList } from "./views.js";

http.serve({ port: 3000 }, (url) => {
  const path = new URL(url, "http://localhost").pathname;
  if (path === "/") {
    return new Response(productList(products), {
      headers: { "content-type": "text/html" },
    });
  }
  if (path === "/api/products") return Response.json(products);
  return new Response("not found", { status: 404 });
});
```

```sh
ff start
curl http://127.0.0.1:3000/              # rendered list
curl http://127.0.0.1:3000/api/products  # JSON
```

## Reference

| Specifier | Resolves to |
|-----------|-------------|
| `./x.js`, `../x.js` | Literal join onto importer dir — extension mandatory |
| `pkg`, `pkg/sub` | `node_modules` walk-up via exports → module → main → passthrough → index.js |
| `@scope/pkg` (+ `/sub`) | Same, with scoped directory handling |
| `/abs/path.js` | Literal filesystem path |
| `https://…` / `require()` | Not supported — loader error |

## Troubleshooting

**`could not load module filename '…'`** — the specifier resolved to a path with no file. For relative imports: check the spelling and the extension. For bare imports: run `ff imprint <pkg>` and confirm `node_modules/<pkg>` exists from the importer's directory upward.

**Extensionless relative import fails** — by design, no probing. Add `.js` (or `.mjs`).

**`require is not defined`** — ESM only. Convert to `import`, or pick an ESM package.

**Works locally, fails after move** — bare resolution walks up from the *importer's* dir. Moving the importer without its `node_modules` ancestry breaks it; keep project files under the installed root.

**Wrong file loaded from a package** — the manifest's `exports`/`module`/`main` chain picked it. Inspect `node_modules/<pkg>/package.json` to see which entry won.
