---
title: Bytecode
description: Ship without source — compile JS to .ffbc with ff compile and run it back.
order: 15
---

# Bytecode

`ff compile` turns an ES module into QuickJS bytecode (`.ffbc`) with **source and debug info stripped**, or packages a self-contained script into a standalone executable (`--standalone`). Run `.ffbc` files with plain `ff` — detected by the `.ffbc` filename extension.

## Quick look

```js
// app.js
http.serve({ port: 3000 }, () => new Response("hello from bytecode"));
```

```sh
ff compile app.js
# ✓ Compiled app.js → app.ffbc (12345 bytes)
ff app.ffbc --allow-net=0.0.0.0:3000
curl http://127.0.0.1:3000/
# hello from bytecode
```

## Compiling

```sh
ff compile app.js
ff compile app.js -o app.ffbc
ff compile app.js --output dist/app.ffbc
ff compile app.js --standalone
ff compile app.js --standalone -o app
```

| Form | Output path |
|------|-------------|
| `ff compile app.js` | `app.ffbc` (extension replaced) |
| `ff compile app.js -o out.ffbc` | `out.ffbc` |
| `ff compile app.js --output dist/app.ffbc` | `dist/app.ffbc` |
| `ff compile app.js --standalone` | `app` (extension stripped, `chmod 0755`) |
| `ff compile app.js --standalone -o dist/app` | `dist/app` (self-executable binary) |

Rules:

- Input must be an ES module; a syntax error prints `error: compile failed in '<path>': <reason>` and writes nothing.
- Input cap is 20MB — larger files fail.
- Output embeds bytecode only: no source text, no debug info. Stack traces from `.ffbc` won't show original line names.

### Standalone executables (`--standalone`)

`--standalone` copies the `ff` binary, appends the compiled bytecode plus a 24-byte `FFSTANDA` trailer (bytecode length + Wyhash integrity check of the binary prefix), sets mode `0755`, and prints `✓ Compiled standalone binary <in> → <out> (<N> bytes)`:

- **Single-file only**: files containing `"import "` or `"import("` are rejected (`error: standalone compilation does not support imports yet` — bundle to a single file first).
- **Default output**: omitting `-o`/`--output` strips the input extension (`app.js` → `app`).
- **Permissions and limits**: standalone executables stay deny-by-default and accept `--allow-*`, `--deny-*`, `--env-file`, and runtime limit flags on their CLI (e.g. `./app --allow-net=0.0.0.0:3000`). Note that `--cpu-budget` is not enforced during top-level `.ffbc` / `--standalone` module evaluation (only inside subsequent handlers, timers, microtasks, streams, and workers).

## Running bytecode

```sh
ff app.ffbc --allow-net=0.0.0.0:3000
```

No special flag is needed — `ff` checks for the `.ffbc` filename extension and loads bytecode instead of source (while `--standalone` executables detect their appended `FFSTANDA` trailer). `--ca`, `FF_CA_FILE`, `FF_ECHO`, `http.serve({ tls })`, permission flags, and env vars all work the same; CLI `--cert`/`--key` and `FF_CERT`/`FF_KEY` are `ff start`-only and do not apply to `ff app.ffbc` (or `ff start` itself — see below).

```sh
FF_ECHO=1 ff app.ffbc --allow-net=0.0.0.0:3000
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
PORT=8080 ff main.ffbc --allow-env=PORT --allow-net=0.0.0.0:8080 &
curl http://127.0.0.1:8080/health
# {"ok":true}
kill %1
```

Run `.ffbc` files directly with `ff main.ffbc` (`ff start` expects JS source in `ff.json` and does not detect `.ffbc`). Recipients get a working bytecode artifact with no readable source.

## When to use it (and when not to)

| Use bytecode when… | Keep source when… |
|---|---|
| Shipping to environments where source visibility matters | Debugging — stack traces need source |
| You want the smallest deploy artifact | Iterating locally (`ff file.js` starts faster to type) |
| Locking what was reviewed (bytecode matches a build) | Tests run (`ff test` needs `.test.js` sources) |

## Troubleshooting

**`error: compile failed in 'x.js': <reason>`** — the module has a syntax error (or unsupported imports for `--standalone`). Run it first with `ff x.js` to see the real parse error, fix, recompile.

**Output missing after compile** — check the printed path (`✓ Compiled a → b (N bytes)` or `✓ Compiled standalone binary a → b (N bytes)`); with `-o` a typo'd directory fails the write. Create the dir first.

**Stack traces look stripped** — expected. Bytecode drops source + debug info by design; reproduce against the `.js` for real traces.

**Test runner ignores my `.ffbc`** — by design. `ff test` only loads `*.test.js`; keep sources alongside artifacts.
