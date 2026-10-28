---
title: Examples
description: Every runnable example, indexed by task — file, run command, expected result.
order: 4
---

# Examples

Copy any block into a file, run it with `ff`, check the output. Each entry names its source guide for the full walkthrough.

## Permissions

Fairyfly is deny-by-default, so the run commands below carry the smallest
`--allow-*` set each snippet needs. Add a grant when you add an API; a missing
one fails closed with `PermissionDenied` / `PERMISSION_DENIED`.

- Loading code is not a read: `import`, `Worker` scripts, `ff.json` plus its
  `main`, and `ff test` files need no `--allow-read`.
- `process.argv` is not environment access. Reading `process.env.NAME` needs
  `--allow-env=NAME`; an ungranted name reads as `undefined`, not an error.
- `--allow-run` and `--allow-ffi` are trust-equivalent to full process access.
  Neither confines the code it enables.
- `--allow-all` is not used below. It exists for fully trusted runs and the
  repo's full test suite.

Permissions are an in-process policy layer, not an OS sandbox. Full model:
[Permissions](/docs/concepts/permissions).

## Hello, world

```js
// hello.js
console.log("hello from fairyfly");
```

```sh
ff hello.js
# hello from fairyfly
```

No native API, so no grants. Guide:
[Quickstart](/docs/getting-started/quickstart).

## HTTP server

```js
// server.js
http.serve({ port: 3000 }, (url, method, body) => {
  if (url === "/") return new Response("hello");
  return new Response("not found", { status: 404 });
});
```

```sh
# terminal 1
ff server.js --allow-net=0.0.0.0:3000

# terminal 2
curl http://127.0.0.1:3000/
# hello
```

`http.serve` always binds `0.0.0.0`; `--allow-net=127.0.0.1:3000` does not
match the listener.

Routing, JSON REST API, SQLite-backed notes API: [HTTP Server guide](/docs/guides/http-server). Method/options tables: [`http` API](/docs/api/http).

## Fetch client

```js
// client.js
const res = await fetch("https://example.com/");
console.log(res.status, res.ok);
console.log((await res.text()).length);
```

```sh
ff client.js --allow-net=example.com:443
# 200 true
# 1256   (body length; example.com content can change)
```

Ports matter: `example.com:443` covers only HTTPS on 443. Use
`--allow-net=example.com` to allow any port, or a bare `--allow-net` to allow
every host.

POST JSON, redirect rules, private-CA trust, mirror script: [Fetch Client guide](/docs/guides/fetch-client). Types and readers: [`fetch` API](/docs/api/fetch).

## WebSocket chat room

```js
// room.js
const peers = new Set();
http.serve(
  {
    port: 3000,
    websocket: {
      open: (socket) => peers.add(socket),
      message: (socket, data) => {
        for (const peer of peers) peer.send(data);
      },
      close: (socket) => peers.delete(socket),
    },
  },
  (url, method, body) => new Response(`online: ${peers.size}`),
);
```

```sh
ff room.js --allow-net=0.0.0.0:3000
```

The server needs the listener scope. A separate `ff` client needs
`--allow-net=127.0.0.1:3000` (or `localhost:3000`); browsers are outside the
runtime's permission policy.

Upgrades are automatic when the `websocket` block is present — no handler branch. Presence counter, binary frames, client API: [WebSocket guide](/docs/guides/websocket).

## TLS + WSS

```sh
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout key.pem -out cert.pem -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"

# terminal 1 — ff.json main serves port 3000
ff start --cert cert.pem --key key.pem --allow-net=0.0.0.0:3000

# terminal 2
curl -k https://127.0.0.1:3000/
```

The CLI reads `--cert` / `--key` before the runtime, so those paths need no
`--allow-read`. A `tls: { cert, key }` object inside the app is a runtime read
and does:

```sh
ff tls-server.js \
  --allow-net=0.0.0.0:3000 \
  --allow-read=cert.pem,key.pem
```

Dev certs, self-trust cases, WSS echo: [TLS guide](/docs/guides/tls). ALPN negotiation: [HTTP/2 guide](/docs/guides/http2).

## SQLite notes API

```js
// notes.js
const db = Database.open("notes.db");
db.execNoArgs("CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, text TEXT)");
db.exec("INSERT INTO notes (text) VALUES (?)", ["buy milk"]);
console.log(db.rows("SELECT * FROM notes"));
db.close();
// [ { id: 1, text: "buy milk" } ]
```

```sh
ff notes.js --allow-read=notes.db --allow-write=.
# [ { id: 1, text: "buy milk" } ]
```

`--allow-write=.` is required even though only `notes.db` was named: SQLite
creates `notes.db-wal` and `notes.db-shm` beside it. The read scope covers the
database file; the directory write scope covers the siblings.

Transactions, `lastInsertRowId()`, busy timeout: [SQLite API](/docs/api/sqlite).

## Workers (hash offload)

```js
// main.js
const w = new Worker("./hasher.js", { data: { rounds: 50000 } });
w.onmessage = (e) => console.log("hash:", e.data);
w.postMessage({ password: "hunter2" });
```

```js
// hasher.js
const cfg = globalThis.workerData;
onmessage = (e) => {
  let acc = e.data.password;
  for (let i = 0; i < cfg.rounds; i++) acc = acc.split("").reverse().join("");
  postMessage({ hex: acc.slice(0, 32), rounds: cfg.rounds });
};
```

```sh
ff main.js
```

No flags: loading `hasher.js` is a program-loading carve-out. The worker inherits
the parent's policy, so a worker that calls `fs.readFile` needs the parent to
hold `--allow-read`.

Spawn rules, `{ data }` vs `workerData`, terminate, pool pattern: [Workers guide](/docs/guides/workers).

## Packages (markdown blog)

```sh
ff init -y blog && cd blog
ff imprint marked@18.0.11
```

```js
// main.js
import { marked } from "marked";
http.serve({ port: 3000 }, () => new Response(marked.parse("# Hello"), {
  headers: { "content-type": "text/html" },
}));
```

```sh
ff start --allow-net=0.0.0.0:3000
curl http://127.0.0.1:3000/
# <h1>Hello</h1>
```

`ff init` and `ff imprint` are CLI operations, not runtime APIs — no permission
flags. Imports from installed packages load as program files. The server needs
only the listener scope.

Install/remove/rebuild/CI: [Packages guide](/docs/guides/packages). Resolution rules: [Modules guide](/docs/guides/modules).

## Testing a JSON endpoint

```js
// test/notes.test.js
import { check, done } from "./lib.mjs";

http.serve({ port: 3902 }, (url, method, body) => {
  if (url === "/notes" && method === "POST") {
    const data = JSON.parse(body || "{}");
    if (!data.text) return Response.json({ error: "text is required" }, { status: 400 });
    return Response.json({ id: 1, text: data.text }, { status: 201 });
  }
  return new Response("not found", { status: 404 });
});

const ok = await fetch("http://127.0.0.1:3902/notes", {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ text: "buy milk" }),
});
check("creates", ok.status === 201);
done("notes");
```

```sh
ff test notes --allow-net=0.0.0.0:3902,127.0.0.1:3902
# OK   test/notes.test.js
```

The grant applies to every test file in the run. Loading test files needs no
`--allow-read`; reads inside a test do. Both net scopes are required here:
`0.0.0.0:3902` for the listener and `127.0.0.1:3902` for the client.

`check`/`done`, server fixtures, `run.sh`: [Testing guide](/docs/guides/testing).

## Bytecode ship

```sh
ff compile app.js -o app.ffbc
# ✓ Compiled app.js → app.ffbc (12345 bytes)
ff app.ffbc
```

`ff compile` is a CLI operation and needs no flags. Bytecode carries no policy:
`ff app.ffbc` needs the same grants the source needed — for example
`--allow-net=0.0.0.0:3000` for a server.

When to compile, caps, stripped traces: [Bytecode guide](/docs/guides/bytecode).

## Timers + process CLI

```js
// poll.js
let delay = 100;
function poll() {
  fetch("https://api.example.com/health")
    .then((r) => { console.log("up:", r.ok); delay = 100; })
    .catch(() => { delay = Math.min(delay * 2, 5000); })
    .finally(() => setTimeout(poll, delay).unref());
}
poll();
```

```js
// tool.js
const [cmd, ...rest] = process.argv.slice(2);
if (cmd === "greet") console.log(`hello, ${rest[0] ?? "world"}`);
else { console.error("usage: tool.js <greet [name]>"); process.exit(1); }
```

```sh
ff poll.js --allow-net=api.example.com:443

ff tool.js greet ada
# hello, ada
```

`poll.js` needs the outbound net scope. `tool.js` reads only `process.argv`,
which is not gated; if it read `process.env`, that would need
`--allow-env=<NAME>`.

Sleep, intervals, unref, microtasks: [Timers guide](/docs/guides/timers). argv/env/exit: [Process guide](/docs/guides/process). Env vars: [Env guide](/docs/guides/env).

## Blobs and forms

```js
// form.js
const form = new FormData();
form.append("name", "ada");
form.append("avatar", new Blob(["<bytes>"], { type: "image/png" }), "avatar.png");
await fetch("https://api.example.com/submit", { method: "POST", body: form });
```

```sh
ff form.js --allow-net=api.example.com:443
```

The blob is in-memory, so no `--allow-read`. If you load the upload with
`fs.readFile`, add `--allow-read` for that path.

`slice`, round-tripping, file-drop endpoint: [Blob and FormData](/docs/api/blobs-formdata).

## Deploy checklist

```sh
./scripts/fetch-vendors.sh && make build && make install

FF_ECHO=1 ff start --allow-net=0.0.0.0:3000 &
sleep 1
curl -i http://127.0.0.1:3000/health
kill %1

ff start --allow-net=0.0.0.0:3000
```

`FF_ECHO` is runtime configuration, not app env, so it needs no `--allow-env`.
If the app reads `PORT`, add `--allow-env=PORT` and make the net scope match
that port. The policy lives in the start command, not `ff.json`.

Docker, `ff start`, production TLS, health endpoint: [Deploy guide](/docs/guides/deploy). Install paths: [Installation](/docs/getting-started/installation). Caps: [Limitations](/docs/reference/limitations).

## See also

- [Permissions](/docs/concepts/permissions) — flags, scopes, denial contract
- [CLI reference](/docs/reference/cli) — every command and flag
- [Quickstart](/docs/getting-started/quickstart) — first run
- [Limitations](/docs/reference/limitations) — every hard cap
