---
title: Bytecode
description: Ship without source — compile JS to .ffbc with ff compile and run it back.
order: 15
---

# Bytecode

`ff compile` turns an ES module into QuickJS bytecode (`.ffbc`) with **source and debug info stripped**. Run the result with plain `ff` — the runtime detects the `.ffbc` filename and loads bytecode instead of source.

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
| `ff compile app.js` | `app.ffbc` — the input's **last** extension is replaced |
| `ff compile app.js -o out.ffbc` | `out.ffbc` |
| `ff compile app.js --output dist/app.ffbc` | `dist/app.ffbc` |

`-o` and `--output` are equivalent. Without one, the output is the input path with everything from its last `.` replaced by `.ffbc` (`dist/app.js` → `dist/app.ffbc`).

Rules:

- The input is compiled as an **ES module** (`EVAL_TYPE_MODULE`). A syntax error prints `compile error in '<path>'` and writes **nothing**.
- Input cap is **20 MB** — `ff compile` reads at most that; larger files fail.
- The object is written with `WRITE_OBJ_BYTECODE | WRITE_OBJ_STRIP_SOURCE | WRITE_OBJ_STRIP_DEBUG`: bytecode only, no source text, no debug info.
- Success prints `Compiled <input> -> <output> (<N> bytes)`.

## Running bytecode

```sh
ff app.ffbc
```

No flag needed. When the filename ends in `.ffbc`, `ff` reads it as a bytecode object, evaluates it, and then runs the event loop to quiescence — exactly like a source module. Everything else behaves identically: `FF_ECHO`, `--ca` TLS trust, and env vars all apply.

```sh
FF_ECHO=1 ff app.ffbc
curl http://127.0.0.1:3000/x
# {"message":"ok"}
```

Because bytecode is compiled as a module, its `import`s still resolve through the module loader when you run the `.ffbc`.

> **Note:** `ff test` ignores `.ffbc` files — it only runs `test/*.test.js`. Keep the `.js` sources for your test suite and compile only what you ship.

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

`ff start` evaluates its `main` as JavaScript **source** — it does not run `.ffbc`. Ship the artifact and run it directly (`ff main.ffbc`), or set your process/supervisor command to that. Keep the `.js` around for `ff start`/tests during development.

## When to use it (and when not to)

| Use bytecode when… | Keep source when… |
|---|---|
| Shipping to environments where source visibility matters | Debugging — stack traces are stripped |
| You want a single deploy artifact with no readable source | Iterating locally (`ff file.js` starts faster to type) |
| Locking what was reviewed (bytecode matches a build) | Tests run (`ff test` needs `.test.js` sources) |

## Troubleshooting

**`compile error in 'x.js'`** — the input has a syntax error (or uses syntax that isn't valid in a module). Run `ff x.js` to see the real parse error, fix, recompile.

**Output missing after compile** — check the printed path (`Compiled a -> b (N bytes)`); with `-o` a typo'd directory fails the write. Create the directory first.

**Stack traces look stripped** — expected. Bytecode drops source + debug info by design; reproduce against the `.js` for real traces.

**Test runner ignores my `.ffbc`** — by design. `ff test` only loads `*.test.js`; keep sources alongside artifacts.
