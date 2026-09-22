---
title: Blob and FormData
description: Binary payloads and HTML forms — construct, inspect, send, and parse them.
order: 4
---

# Blob and FormData

`Blob` carries typed binary data; `FormData` carries multipart-style key/value fields (text or `Blob`s). Both are globals, both ride `fetch` bodies, and both come back out of `res.blob()` / `res.formData()`.

## Quick look

```js
// upload.js
const form = new FormData();
form.append("name", "ada");
form.append("avatar", new Blob(["<bytes>"], { type: "image/png" }), "avatar.png");

const res = await fetch("https://api.example.com/submit", {
  method: "POST",
  body: form,
});
console.log(res.status);
```

```sh
ff upload.js
```

## `Blob` reference

```js
const b0 = new Blob();
const b1 = new Blob(["hello", new Uint8Array([32, 33])]);
const b2 = new Blob(["<svg/>"], { type: "image/svg+xml" });
```

| Member | Description |
|--------|-------------|
| `new Blob(parts?, options?)` | `parts`: array of strings / buffers / blobs; `options.type`: MIME string (sniffed when omitted) |
| `size` | Byte length (number property) |
| `type` | MIME type string (property, `""` when unknown) |
| `slice(start?, end?, type?)` | New `Blob` windowed over the bytes |
| `text()` | `Promise<string>` — decode as UTF-8 |
| `arrayBuffer()` | `Promise<ArrayBuffer>` |
| `bytes()` | `Promise<Uint8Array>` |

```js
const b = new Blob(["hello world"], { type: "text/plain" });
console.log(b.size, b.type); // 11 "text/plain"
console.log(await b.slice(0, 5).text()); // "hello"
console.log((await b.bytes()).length); // 11
```

> **Note:** There is no `blob.stream()`. Read with `text()` / `arrayBuffer()` / `bytes()`.

Send one directly — `fetch` sets the content type from `blob.type`:

```js
await fetch("https://api.example.com/raw", {
  method: "POST",
  body: new Blob([json], { type: "application/json" }),
});
```

## `FormData` reference

```js
const form = new FormData();
form.append("name", "ada");
form.append("tag", "x");
form.append("tag", "y");
form.append("avatar", blob, "avatar.png");
```

| Method | Description |
|--------|-------------|
| `append(name, value, filename?)` | Add a field (third arg names a `Blob` part) |
| `set(name, value, filename?)` | Replace all values for the field |
| `get(name)` | First value, or `null` |
| `getAll(name)` | All values as an array |
| `has(name)` | Presence check |
| `delete(name)` | Remove the field |
| `entries()` / `keys()` / `values()` / `forEach()` | Iterate |
| `size` | Field count |

```js
form.get("name"); // "ada"
form.getAll("tag"); // ["x", "y"]
form.has("avatar"); // true
form.delete("tag");
form.size;
form.forEach((value, key) => console.log(key, value));
```

## Round-tripping: `res.blob()` / `res.formData()`

Both readers work on `Request` and `Response`, single-read like every body reader:

```js
// server.js — echo an upload back as JSON
http.serve({ port: 3000 }, async (url, method, body) => {
  if (url === "/upload" && method === "POST") {
    const req = new Request("http://localhost/upload", { method: "POST", body });
    const form = await req.formData().catch(() => null);
    if (!form) return Response.json({ error: "need multipart form" }, { status: 400 });
    return Response.json({
      name: form.get("name"),
      avatarBytes: (await form.get("avatar").bytes()).length,
    });
  }
  return new Response("POST /upload");
});
```

Hmm — one wrinkle: the handler receives `body` as a string, and re-wrapping it in a `Request` re-parses it. That works for text fields but binary parts may not survive the string round-trip. Prefer parsing uploads from real `fetch`-delivered requests (proxies, tests) rather than the `(url, method, body)` string form:

```js
// client side of the same server — binary-safe
const form = new FormData();
form.append("name", "ada");
form.append("avatar", new Blob([new Uint8Array([1, 2, 3])], { type: "application/octet-stream" }), "a.bin");
const res = await fetch("http://127.0.0.1:3000/upload", { method: "POST", body: form });
console.log(await res.json()); // { name: "ada", avatarBytes: 3 }
```

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

**`get("field")` returns null** — the field name is misspelled (names are exact, case-sensitive) or the request wasn't multipart/urlencoded at all. Check `form.has(name)` and `form.size` first.

**Binary corrupted through the handler** — the `(url, method, body)` handler form stringifies bodies. Keep binary uploads on paths served to real `fetch` clients, or accept base64 text and decode server-side.

**`X is not a function` on `blob.stream()`** — doesn't exist. Use `text()` / `arrayBuffer()` / `bytes()`.

**Server rejects a 5MB upload** — the 64KB response/request staging caps still apply. Chunk large uploads across requests.
