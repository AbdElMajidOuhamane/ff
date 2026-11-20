// JSON body parsing regression: JS_ParseJSON requires a NUL sentinel at
// buf[len] (vendor/quickjs/quickjs.c:51193). Both pool-backed and heap-owned
// (ArrayBuffer) bodies must parse. Pre-fix this was heap-layout dependent —
// see bench/fetch.js ipify "unexpected data at the end" repro.
let fail = 0;
function check(name, cond) {
  if (!cond) {
    console.log("FAIL", name);
    fail++;
  }
}

(async () => {
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

  // 7. Header validation is reported, not silently dropped (TigerStyle:
  // every error handled). CRLF injection attempts must throw TypeError.
  let badAppend = false;
  try {
    new Headers().append("x-bad", "a\r\nX-Injected: 1");
  } catch (e) {
    badAppend = e instanceof TypeError;
  }
  check("headers append rejects CRLF value", badAppend);

  let badName = false;
  try {
    new Headers().set("bad name", "v");
  } catch (e) {
    badName = e instanceof TypeError;
  }
  check("headers set rejects invalid name", badName);

  const hOk = new Headers({ "x-good": "1" });
  hOk.append("x-multi", "a");
  hOk.append("x-multi", "b");
  check("headers valid append", hOk.get("x-good") === "1" && hOk.getAll("x-multi").length === 2);

  // 8. clone() copies headers and body independently.
  const rc = new Response("clone-body", { headers: { "x-a": "1" } });
  const rcc = rc.clone();
  check("clone body", (await rcc.text()) === "clone-body");
  check("clone headers", rcc.headers.get("x-a") === "1");
  check("clone leaves source readable", (await rc.text()) === "clone-body");

  if (fail) {
    console.log("FAIL", fail, "checks");
    process.exit(1);
  }
  console.log("response json tests OK");
})();
