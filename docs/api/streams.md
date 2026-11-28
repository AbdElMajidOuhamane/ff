---
title: ReadableStream
description: ReadableStream, ReadableStreamDefaultReader, and ReadableStreamDefaultController — pull on demand, HTTP/1.1 chunked streaming, and fixed bounds.
order: 18
---

# `ReadableStream`

Lightweight WHATWG `ReadableStream` implementation for on-demand streaming and HTTP/1.1 chunked responses. Available globally with **no imports** and **no permission flags**.

## Quick look

```js
const stream = new ReadableStream({
  start(controller) {
    controller.enqueue("chunk-1\n");
  },
  pull(controller) {
    controller.enqueue("chunk-2\n");
    controller.close();
  },
});

const reader = stream.getReader();
while (true) {
  const { value, done } = await reader.read();
  if (done) break;
  process.stdout.write(value);
}
```

## Constructor

```js
new ReadableStream(underlyingSource?)
```

| Callback | Behavior |
|---|---|
| `start(controller)` | Runs synchronously during construction (`this` is `underlyingSource`). Any returned Promise is not awaited, and synchronous throws are not automatically routed to `controller.error()`. |
| `pull(controller)` | Invoked automatically when the internal chunk queue is empty during `reader.read()` or HTTP/1.1 chunked writes. Synchronous throws (including `--cpu-budget` interrupts) automatically call `controller.error(err)`. Async rejections are not auto-caught. |

- `underlyingSource.cancel` and the second `queuingStrategy` constructor argument are ignored.
- Exceeding `1024` live streams throws `TypeError: Max ReadableStreams exceeded`.

## `ReadableStream`

| Member | Signature / Type | Description |
|---|---|---|
| `locked` | `boolean` (getter) | `true` while locked to a `ReadableStreamDefaultReader`. |
| `getReader()` | `() → ReadableStreamDefaultReader` | Locks the stream and returns its reader. Throws `TypeError: ReadableStream is already locked by a reader` if already locked. |
| `cancel(reason?)` | `(any?) → Promise<undefined>` | Closes the stream and discards buffered chunks (`reason` is ignored). Throws `TypeError: Cannot cancel a locked stream` if locked. |

**Not implemented:** `tee()`, `pipeTo()`, `pipeThrough()`, `Symbol.asyncIterator` (`for await...of`), and BYOB (`{ mode: "byob" }`) readers.

## `ReadableStreamDefaultReader`

| Member | Signature / Type | Description |
|---|---|---|
| `read()` | `() → Promise<{ value, done }>` | Calls `pull(controller)` if empty, rejects if errored, resolves `{ value, done: false }` if queued, resolves `{ value: undefined, done: true }` once closed & empty, or queues a pending reader (max 4). |
| `releaseLock()` | `() → undefined` | Unlocks the stream and invalidates the reader. Throws `TypeError: Cannot release lock with pending reads` while reads are pending, or `TypeError: Reader is closed or already released` if already released. |
| `cancel(reason?)` | `(any?) → Promise<undefined>` | Closes the stream, drops queued chunks, unlocks the stream, and invalidates the reader. |

- Calling `read()` on a released/invalid reader throws `TypeError: Stream is closed, released, or invalid`.
- Calling `read()` with 4 reads already pending throws `TypeError: Max concurrent reads exceeded`.
- `reader.closed` is not implemented (`undefined`).

## `ReadableStreamDefaultController`

| Member | Signature / Type | Description |
|---|---|---|
| `enqueue(chunk)` | `(any) → undefined` | Delivers `chunk` to the next waiting reader or pushes to the internal queue (capacity 8). Throws `TypeError: Stream queue full or stream not readable` if full or not readable. |
| `close()` | `() → undefined` | Marks the stream closed; resolves waiting readers with `{ value: undefined, done: true }` once drained and finishes HTTP/1.1 chunked encoding (`0\r\n\r\n`). |
| `error(err?)` | `(any?) → undefined` | Marks the stream errored (defaults to `new Error()`) and rejects all pending and subsequent reads. |
| `desiredSize` | `number \| null` (getter) | `8 - queueLen` when readable, `0` when closed or errored, `null` if controller is invalid. |

## HTTP & `Response` integration

```js
http.serve({ port: 3000 }, () => {
  let i = 0;
  const body = new ReadableStream({
    pull(controller) {
      if (i >= 3) {
        controller.close();
        return;
      }
      controller.enqueue(`event: ${i++}\n`);
    },
  });
  return new Response(body, {
    headers: { "content-type": "text/plain" },
  });
});
```

- Pass a `ReadableStream` to `new Response(stream, init?)` or return `{ status, body: stream }` from an `http.serve` handler. (Returning a bare `ReadableStream` is not a Response — HTTP/1.1 emits an empty `200`, HTTP/2 returns `501`.)
- `res.body` returns the original `ReadableStream` when constructed with one, `null` when empty, or a closed `ReadableStream` holding one `ArrayBuffer` chunk for buffered responses (including `fetch()` and `Response.file()`).
- **HTTP/1.1:** Emits `Transfer-Encoding: chunked` (default `Content-Type: text/plain` if unset). Accepts `string`, `Uint8Array`, and `ArrayBuffer` chunks; chunks larger than `16352` bytes (`16384 - 32`) are sliced transparently across writes, borrowing a `Uint8Array`'s backing buffer across slices (do not mutate a queued `Uint8Array` mid-stream). `HEAD`, `204`, and `304` suppress the body; `controller.error()` closes the connection.
- **HTTP/2:** Streaming responses are not supported over HTTP/2 — any `ReadableStream` body responds with **`501`** (status-only).
- **`Response` body readers on `new Response(stream)`:** `res.text()` only pops synchronously-queued chunks (does not await async chunks or `pull()`), and `json()`, `arrayBuffer()`, `bytes()`, `blob()`, `formData()`, and `clone()` read buffered bytes only. Read via `res.body.getReader()` instead.

## Limits

| Area | Cap | When hit |
|---|---|---|
| Live streams | `1024` | Throws `TypeError: Max ReadableStreams exceeded` |
| Queue capacity per stream | `8` chunks | `controller.enqueue()` throws `TypeError: Stream queue full or stream not readable` |
| Concurrent pending reads per stream | `4` | `reader.read()` throws `TypeError: Max concurrent reads exceeded` |
| HTTP/1.1 write slice | `16352` bytes | Larger chunks slice across sequential writes |

## Related

- [Request / Response / Headers](/docs/api/request-response)
- [HTTP Server](/docs/guides/http-server)
- [`http` API](/docs/api/http)
