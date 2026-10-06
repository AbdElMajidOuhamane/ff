---
title: Examples
description: Every runnable example, indexed by task — file, run command, expected result.
order: 4
---

# Examples

Copy any block into a file, run it with `ff`, check the output. Each entry names its source guide for the full walkthrough.

## Hello, world

```js
// hello.js
console.log("hello from fairyfly");
```

```sh
ff hello.js
# hello from fairyfly
```

Guide: [Quickstart](/docs/getting-started/quickstart).

## HTTP server

```js
// server.js
http.serve({ port: 3000 }, (url, method, body) => {
  if (url === "/") return new Response("hello");
  return new Response("not found", { status: 404 });
});
```

```sh
ff server.js
curl http://127.0.0.1:3000/
# hello
```

Routing, JSON REST API, SQLite-backed notes API: [HTTP Server guide](/docs/guides/http-server). Method/options tables: [`http` API](/docs/api/http).

## Fetch client

```js
// client.js
const res = await fetch("https://example.com/");
console.log(res.status, res.ok);
console.log((await res.text()).length);
```

```sh
ff client.js
```

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
  (url, method, body) => {
    if (url === "/room") return { status: 101 };
    return new Response(`online: ${peers.size}`);
  },
);
```

```sh
ff room.js
```

Presence counter, binary frames, client API: [WebSocket guide](/docs/guides/websocket).

## TLS + WSS

```sh
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout key.pem -out cert.pem -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
ff start --cert cert.pem --key key.pem
curl -k https://127.0.0.1:3000/
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
# [ { id: 1, text: "buy milk" } ]
```

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

Spawn rules, `{ data }` vs `workerData`, terminate, pool pattern: [Workers guide](/docs/guides/workers).

## Packages (markdown blog)

```sh
ff init -y blog && cd blog
ff imprint marked@18.0.11
```

```js
import { marked } from "marked";
http.serve({ port: 3000 }, () => new Response(marked.parse("# Hello"), {
  headers: { "content-type": "text/html" },
}));
```

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
ff test notes
# OK   test/notes.test.js
```

`check`/`done`, server fixtures, `run.sh`: [Testing guide](/docs/guides/testing).

## Bytecode ship

```sh
ff compile app.js -o app.ffbc
# Compiled app.js -> app.ffbc (12345 bytes)
ff app.ffbc
```

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

Sleep, intervals, unref, microtasks: [Timers guide](/docs/guides/timers). argv/env/exit: [Process guide](/docs/guides/process). Env vars: [Env guide](/docs/guides/env).

## Blobs and forms

```js
const form = new FormData();
form.append("name", "ada");
form.append("avatar", new Blob(["<bytes>"], { type: "image/png" }), "avatar.png");
await fetch("https://api.example.com/submit", { method: "POST", body: form });
```

`slice`, round-tripping, file-drop endpoint: [Blob and FormData](/docs/api/blobs-formdata).

## Deploy checklist

```sh
make build && make install
FF_ECHO=1 ff start & curl -i http://127.0.0.1:3000/health; kill %1
ff start
```

Docker, `ff start`, production TLS, health endpoint: [Deploy guide](/docs/guides/deploy). Install paths: [Installation](/docs/getting-started/installation). Caps: [Limitations](/docs/reference/limitations).
