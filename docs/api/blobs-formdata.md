---
title: Blob and FormData
description: Binary payloads and HTML forms — construct, inspect, send, and parse them.
order: 17
---

# Blob and FormData

`Blob` carries typed binary data; `FormData` carries multipart-style key/value fields (text or `Blob`s). Both are globals, and both come back out of `res.blob()` / `res.formData()`. Sending is a different story: `fetch` stringifies non-string bodies (see Known issue below), so only `string` (and `URLSearchParams`) payloads reach the wire intact.

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

> **Known issue:** that `body: form` does **not** send multipart data — `fetch` coerces the `FormData` with `String()`, so the server receives the literal text `"[object Object]"`. Build the payload as an explicit string (JSON, urlencoded, or a hand-built multipart body with a `content-type` header) until form/binary bodies are serialized natively.

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

> **Known issue:** a `Blob` body is stringified to `"[object Object]"`, not sent as bytes — and no `content-type` is inferred. Send the text yourself:

```js
const blob = new Blob([json], { type: "application/json" });
await fetch("https://api.example.com/raw", {
  method: "POST",
  headers: { "content-type": blob.type },
  body: await blob.text(),
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
| `size()` | Field count — a **method**, not a property (unlike `Blob.size`); call it |

```js
form.get("name"); // "ada"
form.getAll("tag"); // ["x", "y"]
form.has("avatar"); // true
form.delete("tag");
form.size(); // 2
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

One wrinkle: the handler receives `body` as a string, and re-wrapping it in a `Request` re-parses it. Since `fetch` also sends strings as-is, build multipart (or urlencoded) payloads as explicit strings with a matching `content-type` header — `FormData` objects stringify to `"[object Object]"` instead:

```js
// client side of the same server — multipart as an explicit string
const boundary = "ff-boundary";
const CRLF = "\r\n";
const body =
  `--${boundary}${CRLF}` +
  `content-disposition: form-data; name="name"${CRLF}${CRLF}ada${CRLF}` +
  `--${boundary}${CRLF}` +
  `content-disposition: form-data; name="avatar"; filename="a.txt"${CRLF}` +
  `content-type: text/plain${CRLF}${CRLF}abc${CRLF}` +
  `--${boundary}--${CRLF}`;
const res = await fetch("http://127.0.0.1:3000/upload", {
  method: "POST",
  headers: { "content-type": `multipart/form-data; boundary=${boundary}` },
  body,
});
console.log(await res.json()); // { name: "ada", avatarBytes: 3 }
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
