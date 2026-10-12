---
title: Packages
description: Add ESM dependencies with ff imprint, remove them with ff sever, and import them.
order: 10
---

# Packages

Fairyfly installs **pure-JS ESM** packages into `node_modules/`. Direct dependencies are pinned in `ff.json`; the full transitive tree is snapshotted in `ff.lock` (v2), which records each package's `resolved` tarball URL and `integrity` hash. Two commands cover everything: `ff imprint` adds, `ff sever` removes.

## Quick look

```sh
ff init -y demo && cd demo
ff imprint marked
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
ff imprint <pkg>@<version>   # pin an exact version
ff imprint marked            # resolve "latest" from the registry first
ff imprint                   # rebuild from the lock (or resolve ff.json)
```

| Form | Effect |
|------|--------|
| `ff imprint <pkg>@<ver> …` | Pin each listed package at exactly `<ver>` into `ff.json` + `ff.lock`, materialize `node_modules/` |
| `ff imprint <pkg> …` | Resolve each name's `latest` from the registry, then pin that exact version |
| `ff imprint` — usable lock present | Exact rebuild from `ff.lock`; nothing is re-resolved |
| `ff imprint` — no usable lock | Resolve every dependency in `ff.json`, then write the lock |

Direct pins use **exact versions**. `ff imprint <pkg>@<version>` (and the resolved form `ff imprint <pkg>`) fetch `https://registry.npmjs.org/<pkg>/<version>` for that exact string, so a range like `<pkg>@^15` is not a valid direct pin — install the exact version and let the tree resolve ranges for transitive dependencies.

### What gets written

- **`ff.json`** — one field is touched: `dependencies.<name> = "<exact version>"`. Every other field is preserved, and the file is written atomically (`ff.json.tmp` → rename). If `ff.json` is missing, a minimal one is created (`name: "my-app"`, `version: "0.0.1"`, `main: "main.js"`). If `ff.json` is invalid JSON, `ff imprint` refuses to overwrite it.
- **`ff.lock`** — rewritten from the resolved tree. Each entry is keyed `node_modules/<name>` and carries `version`, `resolved` (tarball URL), `integrity` (base64 `sha512-…`), an optional `optional: true`, and a `requires` map of the dependency versions it pulled in. A lock in an older format is rewritten and reported as `migrated ff.lock to v2 format.`

### How `node_modules/` is populated

For each package in the resolved tree, `ff imprint`:

1. Downloads the tarball with `curl -fsSL` to `/tmp`, computes its SHA-512, and **verifies it against `integrity`** — a mismatch is a hard error.
2. Extracts it (`tar --strip-components=1`) and always copies `package.json` into `node_modules/<name>/`.
3. Copies the package's **ESM closure**: starting from the manifest's `module` field and `exports` `import` targets, it follows relative `import`/`export … from` statements transitively and copies the reachable `.js`/`.mjs` files. When a package exposes no import entries, it falls back to copying every `.js`/`.mjs` file in the tree, skipping `test`/`tests`/`__tests__`/`spec`/`bin`/`examples`/`example`/`.git` directories.
4. Runs the **pure-JS ESM gate** on every copied file. A file containing any of `node:` imports, `"buffer"` imports, `require(`, `module.exports`, or `exports.` is rejected: `REJECT <path>: needs <needle> (pure-JS ESM only)`.

A subpath entry that cannot be copied (it needs a Node builtin) is warned about and skipped: `warn: skip subpath <key> (<error>)`. A package that ends up with no copyable `.js`/`.mjs` file fails as `EMPTY node_modules/<name>`.

### Transitive versions

The resolver is a minimal SemVer: it supports exact (`1.2.3`, `=1.2.3`), `^`, `~`, `>=`, `<=`, `>`, `<`, `*`, partials (`1`, `1.2`, `1.x`), and space-separated AND sets (`>=1.0.0 <2.0.0`). `||`, hyphen ranges, and `npm:` aliases fail loud (`UnsupportedRange`). Prerelease versions are skipped unless the range names one.

`node_modules` is **flat** — one version per package name. If two dependencies require incompatible versions, the install stops with:

```text
conflict: <parent> needs <name>@<range> but <version> is pinned via <pinned-parent>. Pin "<name>" in ff.json dependencies to override.
```

`peerDependencies` are not installed in v1; the resolver prints `note <pkg>: peerDependencies skipped in v1 (…)`. Optional dependencies that cannot be satisfied are skipped with a note.

> **Note:** Commit both `ff.json` and `ff.lock`. The lock carries integrity hashes; without it a fresh clone re-resolves and may drift.

## Importing

After install, import by bare specifier (resolved through `node_modules/` — see the [Modules guide](/docs/guides/modules)):

```js
import { marked } from "marked";
import lodash from "lodash";
```

Your own files use relative imports — extensions are optional (omitting one probes `X.js`, then `X/index.js`):

```js
import { router } from "./router.js";
import { check, done } from "./lib.mjs";
import { helper } from "./helper";       // probes ./helper.js
```

```sh
ff main.js
```

> **Note:** The probe only tries `X.js` and `X/index.js`. Non-`.js`
> targets (`./lib.mjs`) must be written out.

## Removing: `ff sever`

```sh
ff sever marked            # remove one dep (a version suffix is stripped)
ff sever @scope/pkg@1.2.3  # scoped: strips to "@scope/pkg"
ff sever                   # confirm, then wipe node_modules + deps + lock
ff sever --force           # wipe without confirming
```

With names, `ff sever` rewrites `ff.json` (dropping the named keys from `dependencies`, preserving everything else), then prunes. Pruning is pnpm-style and needs `ff.lock` to see the dependency graph:

- It seeds the reachable set with the direct dependencies still in `ff.json` and closes over each lock entry's `requires` map.
- Anything not reachable is deleted — `severed <name>` for the explicitly named packages, `pruned <name> (orphaned)` for transitive strays.
- The lock is rewritten to keep only reachable entries.

Without a usable `ff.lock` it cannot compute reachability, so it removes only the named packages: `no usable ff.lock — removing named packages only (run ff imprint to regenerate the lock).`

With no names at all, `ff sever` is a full reset: it prints a `[y/N]` prompt (unless `--force`), deletes `node_modules/`, empties `dependencies` in `ff.json`, and writes a fresh empty lock. If nothing is installed and `dependencies` is empty, it reports `Nothing to sever…` and does nothing.

## Practical example: markdown blog

```sh
ff init -y blog && cd blog
ff imprint marked
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
ff imprint        # exact rebuild from ff.lock — no registry range queries
ff test
```

## Troubleshooting

**`REJECT …: needs … (pure-JS ESM only)`** — the package (or one of its files) uses Node builtins or CommonJS. Only pure-JS ESM passes the gate; look for an ESM build or a replacement.

**`could not load module filename '…'`** — you forgot `ff imprint <pkg>`, or you imported it from a directory where the `node_modules` walk can't reach the install (see Modules). Run from the project root.

**`conflict: … Pin "<name>" in ff.json dependencies to override.`** — two dependencies need incompatible versions and `node_modules` is flat. Add an explicit `ff imprint <name>@<version>` to force a single version.

**`IntegrityMismatch` / `UnsupportedIntegrity`** — the downloaded tarball didn't match the lock/registry hash. Retry; if it persists, the registry metadata and tarball disagree.

**Lock keeps changing** — a bare `ff imprint` with no usable lock re-resolves from `ff.json`. Commit `ff.lock` and use no-args `ff imprint` for exact rebuilds.

**Stale dep after `ff sever`** — with names, only unreachable packages prune. If a package is still needed transitively it stays; check `ff.json` for who still requires it. For a clean slate: `ff sever --force`, then `ff imprint`.
