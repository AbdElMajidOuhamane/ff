// JSON body parsing regression: JS_ParseJSON requires a NUL sentinel at
// buf[len] (vendor/quickjs/quickjs.c:51193). Both pool-backed and heap-owned
// (ArrayBuffer) bodies must parse. Pre-fix this was heap-layout dependent —
// see bench/fetch.js ipify "unexpected data at the end" repro.
import { check, done } from "./lib.mjs";

async function main() {
  // 1. Pool-backed string body (new Response).
  const r1 = new Response('{"ip":"196.127.110.105"}');
  const j1 = await r1.json();
  check("response json string body", j1.ip === "196.127.110.105");

  // 2. Response.json() static helper (JSON.stringify -> pool body).
  const r2 = Response.json({ a: 1, b: [2, 3] });
  const j2 = await r2.json();
  check("Response.json roundtrip", j2.a === 1 && j2.b[1] === 3);

  // 3. Heap-owned body (ArrayBuffer path -> setBodyOwned, copied parse).
  const src = new TextEncoder().encode('{"owned":true}');
  const r3 = new Response(src.buffer);
  const j3 = await r3.json();
  check("response json owned buffer", j3.owned === true);

  // 4. Large body (> stack scratch) exercising the heap NUL-copy path.
  const big = { pad: "x".repeat(8192) };
  const r4 = new Response(JSON.stringify(big));
  const j4 = await r4.json();
  check("response json large body", j4.pad.length === 8192);

  // 5. Request.json() (pool-backed; same sentinel contract).
  const req = new Request("http://example.invalid/", { body: '{"k":"v"}' });
  const j5 = await req.json();
  check("request json body", j5.k === "v");

  // 6. Heap-churn guard: dirty the allocator with same-size-class strings
  // then parse a short body — the sequence that used to read stale bytes.
  const junk = [];
  for (let i = 0; i < 256; i++) junk.push("j".repeat(24 + (i % 7)));
  const r6 = new Response('{"n":42}');
  const j6 = await r6.json();
  check("response json after heap churn", j6.n === 42);

  // Owned bodies on either side of the 4096-byte JSON scratch buffer.
  // String bodies use the pool, so only binary bodies cover the heap fallback.
  const encoder = new TextEncoder();
  for (const length of [4095, 4096, 4097, 8192]) {
    const json = '"' + "x".repeat(length - 2) + '"';
    for (const kind of ["arraybuffer", "uint8array"]) {
      const bytes = encoder.encode(json);
      const body = kind === "arraybuffer" ? bytes.buffer : bytes;
      const response = new Response(body);
      const copy = response.clone();
      check(kind + " exact body length " + length, bytes.byteLength === length);
      check(kind + " JSON boundary " + length, (await response.json()) === "x".repeat(length - 2));
      check(kind + " JSON clone boundary " + length, (await copy.json()) === "x".repeat(length - 2));
    }
  }

  // The NUL sentinel must not appear in text or binary readers.
  const json = '{"text":"é日本語","nul":"a\\u0000b"}';
  for (const body of [json, encoder.encode(json), encoder.encode(json).buffer]) {
    const response = new Response(body, { statusText: "Metadata after the body" });
    const textCopy = response.clone();
    const binaryCopy = response.clone();
    const parsed = await response.json();
    check("unicode JSON value", parsed.text === "é日本語");
    check("escaped NUL decoded", parsed.nul === "a\u0000b");
    check("text excludes sentinel", (await textCopy.text()) === json);
    const raw = new Uint8Array(await binaryCopy.arrayBuffer());
    check("binary excludes sentinel", raw.byteLength === encoder.encode(json).byteLength);
    check("binary body unchanged", new TextDecoder().decode(raw) === json);
  }

  // Request constructors append integrity and custom fields after the body.
  const request = new Request("http://example.invalid/", {
    method: "CUSTOM",
    body: json,
    integrity: "x".repeat(8192),
  });
  const requestCopy = request.clone();
  const requestTextCopy = request.clone();
  check("request JSON after metadata growth", (await request.json()).text === "é日本語");
  check("request clone JSON", (await requestCopy.json()).nul === "a\u0000b");
  check("request text excludes sentinel", (await requestTextCopy.text()) === json);

  // JSON may be a primitive or array, not only an object.
  for (const value of [null, false, 0, "", [1, true, null]]) {
    const source = JSON.stringify(value);
    const response = new Response(source);
    const request = new Request("http://example.invalid/", { body: source });
    check("response JSON primitive " + source, JSON.stringify(await response.json()) === source);
    check("request JSON primitive " + source, JSON.stringify(await request.json()) === source);
  }

  // A terminator must not hide malformed data or trailing bytes.
  for (const source of ["", " ", '{"x":', "{}trailing"]) {
    for (const body of [source, encoder.encode(source).buffer]) {
      const response = new Response(body);
      let rejected = false;
      try {
        await response.json();
      } catch {
        rejected = true;
      }
      check("response rejects invalid JSON " + JSON.stringify(source), rejected);
    }
    const request = new Request("http://example.invalid/", { body: source });
    let rejected = false;
    try {
      await request.json();
    } catch {
      rejected = true;
    }
    check("request rejects invalid JSON " + JSON.stringify(source), rejected);
  }

  // In an owned byte buffer, an interior NUL is not the end sentinel.
  const nulBody = new Response(encoder.encode("{}\u0000garbage").buffer);
  let nulRejected = false;
  try {
    await nulBody.json();
  } catch {
    nulRejected = true;
  }
  check("owned body rejects interior NUL", nulRejected);
}

main().then(
  () => done("response"),
  (error) => {
    check("response JSON tests complete: " + String(error), false);
    done("response");
  },
);
