let pass = 0, fail = 0;
function assert(cond, msg) {
  if (cond) { pass++; console.log("  PASS:", msg); }
  else { fail++; console.redbal("  FAIL:", msg); }
}

(async () => {

console.log("--- Response: constructor with body ---");
const r1 = new Response("hello world");
assert(r1.status() === 200, "default status 200");
assert(r1.statusText() === "OK", "default statusText OK");
assert(r1.ok() === true, "ok is true for 200");
assert(r1.type() === "basic", "type is basic");
assert(r1.redirected() === false, "redirected is false");
assert(r1.url() === "", "url is empty");

console.log("--- Response: custom status ---");
const r2 = new Response("not found", { status: 404, statusText: "Not Found" });
assert(r2.status() === 404, "custom status 404");
assert(r2.statusText() === "Not Found", "custom statusText");
assert(r2.ok() === false, "ok is false for 404");

console.log("--- Response: headers from init ---");
const r3 = new Response("data", { headers: { "X-Custom": "val" } });
assert(r3.headers.get("x-custom") === "val", "headers from init");

console.log("--- Response: body text ---");
const r4 = new Response("test body");
assert(r4.bodyUsed() === false, "bodyUsed false before text");
const text = await r4.text();
assert(text === "test body", "text() returns body");
assert(r4.bodyUsed() === true, "bodyUsed true after text");

console.log("--- Response: body json ---");
const r5 = new Response('{"a":1}');
const obj = await r5.json();
assert(obj.a === 1, "json() parses body");

console.log("--- Response: body arrayBuffer ---");
const r6 = new Response("abc");
const buf = await r6.arrayBuffer();
assert(buf instanceof ArrayBuffer, "arrayBuffer returns ArrayBuffer");
assert(buf.byteLength === 3, "byteLength matches");

console.log("--- Response: body bytes ---");
const r6b = new Response("hi");
const bytesResult = await r6b.bytes();
assert(bytesResult instanceof ArrayBuffer, "bytes() returns ArrayBuffer");
assert(r6b.bodyUsed() === true, "bodyUsed true after bytes");

console.log("--- Response: body blob rejects ---");
const rBlob = new Response("test");
let blobRejected = false;
try { await rBlob.blob(); } catch (e) { blobRejected = true; }
assert(blobRejected, "blob() rejects");

console.log("--- Response: body formData rejects ---");
const rFd = new Response("test");
let fdRejected = false;
try { await rFd.formData(); } catch (e) { fdRejected = true; }
assert(fdRejected, "formData() rejects");

console.log("--- Response: empty body ---");
const r7 = new Response();
const emptyText = await r7.text();
assert(emptyText === "", "empty body text");

console.log("--- Response: clone ---");
const r8 = new Response("data", { status: 201, headers: { "X-Id": "1" } });
const r9 = r8.clone();
assert(r9.status() === 201, "clone status matches");
assert(r9.headers.get("x-id") === "1", "clone headers match");
assert(r9.bodyUsed() === false, "clone bodyUsed resets");
const clonedText = await r9.text();
assert(clonedText === "data", "clone body is independent");

console.log("--- Response.json static ---");
const r10 = Response.json({ msg: "hi" });
const jsonBody = await r10.text();
assert(jsonBody === '{"msg":"hi"}', "json() stringifies body");
assert(r10.headers.get("content-type") === "application/json", "json() sets content-type");

console.log("--- Response.redirect static ---");
const r11 = Response.redirect("/new-location");
assert(r11.status() === 302, "redirect default 302");
assert(r11.url() === "/new-location", "redirect url");
assert(r11.redirected() === true, "redirected is true");

console.log("--- Response.redirect with status ---");
const r12 = Response.redirect("/moved", 301);
assert(r12.status() === 301, "redirect custom status");

console.log("--- Response.error static ---");
const r13 = Response.error();
assert(r13.status() === 0, "error status 0");
assert(r13.type() === "error", "error type");

console.log(`\nResults: ${pass} passed, ${fail} failed`);
if (fail > 0) process.exit(1);

})().catch(e => { console.redbal(e); process.exit(1); });
