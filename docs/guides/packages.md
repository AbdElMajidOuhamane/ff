---
title: Packages
description: Add ESM dependencies with ff imprint, remove them with ff sever, and import them.
order: 10
---

# Packages

Fairyfly installs pure-JS ESM packages into `node_modules/`, pinned in `ff.json` and locked in `ff.lock` (v2, with integrity hashes). Two commands cover everything: `ff imprint` adds, `ff sever` removes.

## Quick look

```sh
ff init -y demo && cd demo
ff imprint marked@18.0.11
```

```js
// main.js
import { marked } from "marked";

http.serve({ port: 3000 }, (url, method, body) => {
  if (url === "/readme") {
    return new Response(marked.parse("# Hello"), {
      headers: { "content-type": "text/html" },
    });
  }
  return new Response("try /readme");
});
```

```sh
ff start
curl http://127.0.0.1:3000/readme
# <h1>Hello</h1>
```

## Installing: `ff imprint`

```sh
ff imprint marked@18.0.11   # pin an exact version
ff imprint marked            # resolve latest from the registry
ff imprint                   # rebuild from the lock (CI-like)
```

| Form | Effect |
|------|--------|
| `ff imprint pkg@ver …` | Pin listed packages into `ff.json` + `ff.lock`, materialize `node_modules/` |
| `ff imprint pkg …` | Same, with `@ver` resolved to latest first |
| `ff imprint` (v2 lock present) | Exact rebuild from `ff.lock` — nothing re-resolved |
| `ff imprint` (no lock) | Resolve everything in `ff.json`, then write the lock |

Only ESM-compatible packages pass the pure-ESM gate — CommonJS-only packages are rejected at install time.

> **Note:** Commit both `ff.json` and `ff.lock`. The lock carries integrity hashes; without it a fresh clone re-resolves and may drift.

## Importing: bare vs relative

After install, import by bare specifier (resolved through `node_modules/`):

```js
import { marked } from "marked";
import lodash from "lodash";
```

Your own files use relative imports — **with the extension**:

```js
import { router } from "./router.js";
import { check, done } from "./lib.mjs";
```

```sh
ff main.js
```

> **Caution:** `import "./router"` (no extension) may fail. Always write `./router.js`.

## Removing: `ff sever`

```sh
ff sever marked            # drop one dep, prune what becomes unreachable
ff sever marked@18.0.11    # version suffix ignored — strips to the name
ff sever                   # confirm, then wipe node_modules + deps + lock
ff sever --force           # wipe without confirming
```

Removal is scope-aware (`ff sever @scope/pkg@1.0` strips to `@scope/pkg`) and pnpm-style: shared packages still needed by remaining deps stay; only newly-unreachable ones are pruned.

## Practical example: markdown blog

```sh
ff init -y blog && cd blog
ff imprint marked@18.0.11
cat > main.js <<'EOF'
import { marked } from "marked";

const posts = { hello: "# Hello\n\nFirst post." };

http.serve({ port: 3000 }, (url) => {
  const path = new URL(url, "http://localhost").pathname;
  if (path === "/") {
    const list = Object.keys(posts)
      .map((s) => `<li><a href="/p/${s}">${s}</a></li>`)
      .join("");
    return new Response(`<ul>${list}</ul>`, {
      headers: { "content-type": "text/html" },
    });
  }
  if (path.startsWith("/p/")) {
    const slug = path.slice(3);
    if (!posts[slug]) return new Response("not found", { status: 404 });
    return new Response(marked.parse(posts[slug]), {
      headers: { "content-type": "text/html" },
    });
  }
  return new Response("not found", { status: 404 });
});
EOF
ff start
```

```sh
curl http://127.0.0.1:3000/        # <ul><li>...
curl http://127.0.0.1:3000/p/hello # <h1>Hello</h1>...
```

## CI pattern

```sh
git clone <repo> && cd <repo>
ff imprint        # exact rebuild from ff.lock, no re-resolve
ff test
```

## Troubleshooting

**Install rejects my package** — it's likely CommonJS-only. Only pure-JS ESM passes the gate; look for an ESM build or replacement.

**`Cannot find module 'x'`** — you forgot `ff imprint x`, or ran from the wrong directory (resolution is relative to cwd's `node_modules/`).

**Lock keeps changing** — someone runs bare `ff imprint` without a lock present, which re-resolves. Commit `ff.lock` and use no-args `ff imprint` for rebuilds.

**Stale dep after `sever`** — with names, only unreachable packages prune. If it's still needed transitively, it stays — check `ff.json` for who still requires it. For a clean slate: `ff sever --force`, then `ff imprint`.
