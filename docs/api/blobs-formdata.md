---
title: Blob and FormData
description: Binary payloads and HTML forms — construct, inspect, send, and parse them.
order: 17
---

# Blob and FormData

`Blob` carries typed binary data; `FormData` carries multipart-style key/value fields (text or `Blob`s). Both are globals, and both come back out of `res.blob()` / `res.formData()`. Sending is a different story: `fetch` stringifies non-string bodies (see the Known issue below), so only `string` (and `URLSearchParams`) payloads reach the wire intact.

## Quick look

```js
// upload.js
(async () => {
  const form = new FormData();
  form.append("name", "ada");
  form.append("avatar", new Blob(["<bytes>"], { type: "image/png" }), "avatar.png");

  const res = await fetch("https://api.example.com/submit", {
    method: "POST",
    body: form,
  });
  console.log(res.status);
})();
```

```sh
ff upload.js
```

> **Known issue:** that `body: form` does **not** send multipart data — `fetch` coerces the `FormData` with `String()`, so the server receives the literal text `"[object Object]"`. Build the payload as an explicit string (JSON, urlencoded, or a hand-built multipart body with a `content-type` header) until form/binary bodies are serialized natively.

## `Blob` reference

```js
// client.js
const b0 = new Blob();
const b1 = new Blob(["hello", new Uint8Array([32, 33])]);
const b2 = new Blob(["<svg/>"], { type: "image/svg+xml" });
```

The constructor takes `(parts?, options?)`:

- `parts` — a single part or an **array** of parts. Each part may be a
  `string` (its UTF-8 bytes), another `Blob`, an `ArrayBuffer`, or any
  typed-array view. Anything else is coerced with `String()`.
- `options.type` — MIME string. It is normalized (parameters after `;`
  stripped, trimmed, lowercased) and defaults to `""`.

| Member | Description |
|--------|-------------|
| `size` | Byte length (number property, fixed at construction) |
| `type` | MIME type string (property, `""` when unknown) |
| `slice(start?, end?, type?)` | New `Blob` windowed over the bytes (negative indices count from the end; `type` overrides the copy's type) |
| `text()` | `Promise<string>` — decode as UTF-8 |
| `arrayBuffer()` | `Promise<ArrayBuffer>` |
| `bytes()` | `Promise<Uint8Array>` — **a `Uint8Array`** (unlike `Response.bytes()`) |

```js
// client.js
(async () => {
  const b = new Blob(["hello world"], { type: "text/plain" });
  console.log(b.size, b.type);              // 11 "text/plain"
  console.log(await b.slice(0, 5).text());  // "hello"
  console.log((await b.bytes()).length);    // 11
  console.log((await b.arrayBuffer()).byteLength); // 11
})();
```

> **Note:** There is no `blob.stream()`. Read with `text()` / `arrayBuffer()` / `bytes()`.

> **Known issue:** a `Blob` body is stringified to `"[object Object]"`, not sent as bytes — and no `content-type` is inferred. Send the text yourself:

```js
// client.js
(async () => {
  const json = JSON.stringify({ ok: true });
  const blob = new Blob([json], { type: "application/json" });
  await fetch("https://api.example.com/raw", {
    method: "POST",
    headers: { "content-type": blob.type },
    body: await blob.text(),
  });
})();
```

## `FormData` reference

```js
// client.js
const form = new FormData();
form.append("name", "ada");
form.append("tag", "x");
form.append("tag", "y");
form.append("avatar", new Blob(["PNG"], { type: "image/png" }), "avatar.png");
```

`new FormData()` takes no meaningful argument (there is no DOM to adopt,
so an `HTMLFormElement` argument is ignored).

| Method | Description |
|--------|-------------|
| `append(name, value, filename?)` | Add a field. A `Blob` `value` is stored as a file part (the third arg names it; default `""`); anything else is a text field |
| `set(name, value)` | Replace all entries for the field (a `Blob` value becomes a file part with an empty filename — the third arg is ignored) |
| `get(name)` | First value (a `string`, or a `Blob` for a file part), or `null` |
| `getAll(name)` | All values as an array |
| `has(name)` | Presence check |
| `delete(name)` | Remove every entry with that name |
| `entries()` / `keys()` / `values()` / `forEach()` | Iterate (arrays, not iterators) |
| `size()` | Entry count — a **method**, not a property (unlike `Blob.size`); call it |

Names are **case-sensitive** (unlike `Headers`). `keys()` returns one name
per entry (duplicates included). File parts are rebuilt as `Blob`s
whenever a value is read.

```js
console.log(form.get("name"));         // "ada"
console.log(form.getAll("tag"));       // ["x", "y"]
console.log(form.has("avatar"));       // true
form.delete("tag");
console.log(form.size());              // 2
form.forEach((value, key) => console.log(key, value));
```

## Round-tripping: `res.blob()` / `res.formData()`

Both readers work on `Request` and `Response`, and like every body reader
they are **re-readable**:

```js
// client.js
(async () => {
  const res = await fetch("https://api.example.com/data.json");
  console.log(res.headers.get("content-type")); // "application/json; charset=utf-8"
  const asBlob = await res.blob();
  console.log(asBlob.size, asBlob.type);        // bytes, "application/json"
  console.log(await asBlob.text());             // decoded body
  console.log(await res.text());                // original still readable
})();
```

`formData()` parses the body according to the `content-type` header:

| `content-type` | Behaviour |
|---|---|
| `application/x-www-form-urlencoded` | `+` → space, `%XX` decoded; each `name=value` pair becomes a text field |
| `multipart/form-data; boundary=…` | Each part is parsed (`content-disposition` `name`/`filename`, `content-type` default `text/plain`); parts with a `filename` become file fields |
| empty body | Resolves an **empty** `FormData` regardless of content-type |
| anything else, or multipart **without** a boundary | Rejects `"FormData unsupported content-type"` |

```js
// server.js — echo a urlencoded upload back as JSON
http.serve({ port: 3000 }, async (url, method, body) => {
  if (url === "/upload" && method === "POST") {
    // The handler gets the body but not the incoming headers, so re-state the
    // content-type on the Request you build from it.
    const req = new Request("http://localhost/upload", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body,
    });
    const form = await req.formData().catch(() => null);
    if (!form) return Response.json({ error: "need a form body" }, { status: 400 });
    return Response.json({ name: form.get("name") });
  }
  return new Response("POST /upload");
});
```

Since the handler receives `body` as a **string** (and no headers), a
`multipart/form-data` upload can't be re-parsed server-side — the boundary
lives in the headers you never see. Use urlencoded for round-trips through
the handler; `fetch` also sends strings as-is, so build the payload as an
explicit string with a matching `content-type`:

```js
// client.js — urlencoded, matching the server above
(async () => {
  const params = new URLSearchParams({ name: "ada" });
  const res = await fetch("http://127.0.0.1:3000/upload", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: params, // "name=ada"
  });
  console.log(await res.json()); // { name: "ada" }
})();
```

Binary parts may not survive the handler's string round-trip — prefer base64 text for binary uploads.

## Practical example: file drop endpoint

Accept a blob, store it, report back:

```js
// drop.js
http.serve({ port: 3000 }, async (url, method, body) => {
  if (url === "/drop" && method === "POST") {
    const incoming = new Blob([body], { type: "application/octet-stream" });
    const bytes = await incoming.bytes();
    fs.writeFile(`drop-${Date.now()}.bin`, bytes);
    return Response.json({ received: bytes.length }, { status: 201 });
  }
  return new Response("POST /drop");
});
```

```sh
ff drop.js
curl -X POST http://127.0.0.1:3000/drop --data-binary @photo.png
# {"received":12345}
```

## Troubleshooting

**`get("field")` returns null** — the field name is misspelled (names are exact, case-sensitive) or the request wasn't multipart/urlencoded at all. Check `form.has(name)` and `form.size()` first.

**Binary corrupted through the handler** — the `(url, method, body)` handler form stringifies bodies. Keep binary uploads on paths served to real `fetch` clients, or accept base64 text and decode server-side.

**`X is not a function` on `blob.stream()`** — doesn't exist. Use `text()` / `arrayBuffer()` / `bytes()`.

**Server rejects an upload over ~4KB with `413`** — the whole request (headers + body) must fit in a single 4 KB read buffer. Responses are the roomy side: bodies up to 10 MB (a 64 KB stage buffer spills to the heap past that). Chunk large uploads across requests.
