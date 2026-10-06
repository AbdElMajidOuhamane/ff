---
title: Bytecode
description: Ship without source — compile JS to .ffbc with ff compile and run it back.
order: 9
---

# Bytecode

`ff compile` turns an ES module into QuickJS bytecode (`.ffbc`) with **source and debug info stripped**. Run the result with plain `ff` — the loader detects the `.ffbc` magic.

## Quick look

```js
// app.js
http.serve({ port: 3000 }, () => new Response("hello from bytecode"));
```

```sh
ff compile app.js
# Compiled app.js -> app.ffbc (12345 bytes)
ff app.ffbc
curl http://127.0.0.1:3000/
# hello from bytecode
```

## Compiling

```sh
ff compile app.js
ff compile app.js -o app.ffbc
ff compile app.js --output dist/app.ffbc
```

| Form | Output path |
|------|-------------|
| `ff compile app.js` | `app.ffbc` (extension replaced) |
| `ff compile app.js -o out.ffbc` | `out.ffbc` |
| `ff compile app.js --output dist/app.ffbc` | `dist/app.ffbc` |

Rules:

- Input must be an ES module; a syntax error prints `compile error in '<path>'` and writes nothing.
- Input cap is 20MB — larger files fail.
- Output embeds bytecode only: no source text, no debug info. Stack traces from `.ffbc` won't show original line names.

## Running bytecode

```sh
ff app.ffbc
```

No flag needed — `ff` sniffs the file magic and loads bytecode instead of source. Everything else behaves identically: `ff test`-style harnesses, `FF_ECHO`, TLS flags, and env vars all work the same.

```sh
FF_ECHO=1 ff app.ffbc
curl http://127.0.0.1:3000/x
# {"message":"ok"}
```

> **Note:** `ff test` ignores `.ffbc` files (it only runs `*.test.js`). Keep the `.js` sources for your test suite and compile only what you ship.

## Practical example: ship a server without source

```sh
ff init -y ship
cd ship
cat > main.js <<'EOF'
const port = Number(process.env.PORT ?? 3000);
http.serve({ port }, (url) => {
  if (new URL(url, "http://localhost").pathname === "/health") {
    return Response.json({ ok: true });
  }
  return new Response("shipped");
});
EOF
ff compile main.js -o main.ffbc
ls -la main.ffbc
PORT=8080 ff main.ffbc &
curl http://127.0.0.1:8080/health
# {"ok":true}
kill %1
```

Deploy `main.ffbc` (+ `ff.json` if you use `ff start` semantics elsewhere) instead of `main.js`. Recipients get a working binary artifact with no readable source.

## When to use it (and when not to)

| Use bytecode when… | Keep source when… |
|---|---|
| Shipping to environments where source visibility matters | Debugging — stack traces need source |
| You want the smallest deploy artifact | Iterating locally (`ff file.js` starts faster to type) |
| Locking what was reviewed (bytecode matches a build) | Tests run (`ff test` needs `.test.js` sources) |

## Troubleshooting

**`compile error in 'x.js'`** — the module has a syntax error. Run it first with `ff x.js` to see the real parse error, fix, recompile.

**Output missing after compile** — check the printed path (`Compiled a -> b (N bytes)`); with `-o` a typo'd directory fails the write. Create the dir first.

**Stack traces look stripped** — expected. Bytecode drops source + debug info by design; reproduce against the `.js` for real traces.

**Test runner ignores my `.ffbc`** — by design. `ff test` only loads `*.test.js`; keep sources alongside artifacts.
