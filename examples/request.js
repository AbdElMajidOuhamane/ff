let pass = 0, fail = 0;
function assert(cond, msg) {
  if (cond) { pass++; console.log("  PASS:", msg); }
  else { fail++; console.redbal("  FAIL:", msg); }
}

(async () => {

console.log("--- Request: constructor with string URL ---");
const r1 = new Request("/api/users");
assert(r1.url === "/api/users", "url from string");
assert(r1.method === "GET", "default method is GET");
assert(r1.bodyUsed() === false, "bodyUsed false initially");

console.log("--- Request: method override ---");
const r2 = new Request("/submit", { method: "POST" });
assert(r2.method === "POST", "method overridden to POST");

console.log("--- Request: headers from object ---");
const r3 = new Request("/data", { headers: { "X-Custom": "hello", "Accept": "text/html" } });
assert(r3.headers.get("x-custom") === "hello", "headers from init object");
assert(r3.headers.has("accept"), "headers has accept");

console.log("--- Request: headers case insensitive ---");
assert(r3.headers.get("X-CUSTOM") === "hello", "case insensitive get");
assert(r3.headers.get("ACCEPT") === "text/html", "case insensitive get 2");

console.log("--- Request: options defaults ---");
assert(r1.cache() === "default", "cache default");
assert(r1.credentials() === "same-origin", "credentials default");
assert(r1.mode() === "cors", "mode default");
assert(r1.redirect() === "follow", "redirect default");
assert(r1.integrity() === "", "integrity default empty");
assert(r1.keepalive() === false, "keepalive default false");

console.log("--- Request: options override ---");
const r4o = new Request("/api", {
  method: "POST",
  cache: "no-store",
  credentials: "include",
  mode: "no-cors",
  redirect: "manual",
  integrity: "sha256-abc",
  keepalive: true,
  body: "data",
});
assert(r4o.cache() === "no-store", "cache overridden");
assert(r4o.credentials() === "include", "credentials overridden");
assert(r4o.mode() === "no-cors", "mode overridden");
assert(r4o.redirect() === "manual", "redirect overridden");
assert(r4o.integrity() === "sha256-abc", "integrity overridden");
assert(r4o.keepalive() === true, "keepalive overridden");

console.log("--- Request: body text ---");
const r4 = new Request("/api", { method: "POST", body: '{"name":"test"}' });
assert(r4.bodyUsed() === false, "bodyUsed false before text");
const text = await r4.text();
assert(text === '{"name":"test"}', "text() returns body string");
assert(r4.bodyUsed() === true, "bodyUsed true after text");

console.log("--- Request: body json ---");
const r5 = new Request("/api", { body: '{"a":1,"b":"two"}' });
const obj = await r5.json();
assert(obj.a === 1, "json() parses number field");
assert(obj.b === "two", "json() parses string field");

console.log("--- Request: body arrayBuffer ---");
const r6 = new Request("/api", { body: "hello" });
const buf = await r6.arrayBuffer();
assert(buf instanceof ArrayBuffer, "arrayBuffer() returns ArrayBuffer");
assert(buf.byteLength === 5, "arrayBuffer byteLength matches body length");

console.log("--- Request: body bytes ---");
const r6b = new Request("/api", { body: "hi" });
const bytesResult = await r6b.bytes();
assert(bytesResult instanceof ArrayBuffer, "bytes() returns ArrayBuffer");
assert(r6b.bodyUsed() === true, "bodyUsed true after bytes");

console.log("--- Request: body blob rejects ---");
const rBlob = new Request("/api", { body: "test" });
let blobRejected = false;
try { await rBlob.blob(); } catch (e) { blobRejected = true; }
assert(blobRejected, "blob() rejects");

console.log("--- Request: body formData rejects ---");
const rFd = new Request("/api", { body: "test" });
let fdRejected = false;
try { await rFd.formData(); } catch (e) { fdRejected = true; }
assert(fdRejected, "formData() rejects");

console.log("--- Request: empty body ---");
const r7 = new Request("/api");
const emptyText = await r7.text();
assert(emptyText === "", "empty body text() returns empty string");

console.log("--- Request: clone ---");
const r8 = new Request("/clone-test", { method: "PUT", headers: { "X-Id": "123" }, body: "data" });
const r9 = r8.clone();
assert(r9.url === r8.url, "clone url matches");
assert(r9.method === r8.method, "clone method matches");
assert(r9.headers.get("x-id") === "123", "clone headers match");
assert(r9.bodyUsed() === false, "clone bodyUsed resets to false");
assert(r9.cache() === r8.cache(), "clone cache matches");
assert(r9.credentials() === r8.credentials(), "clone credentials matches");
assert(r9.mode() === r8.mode(), "clone mode matches");
assert(r9.redirect() === r8.redirect(), "clone redirect matches");
assert(r9.keepalive() === r8.keepalive(), "clone keepalive matches");
const clonedText = await r9.text();
assert(clonedText === "data", "clone body is independent copy");

console.log("--- Request: from Request input ---");
const r10 = new Request(r8, { method: "DELETE" });
assert(r10.method === "DELETE", "override method from Request input");
assert(r10.url === r8.url, "url inherited from Request input");

console.log("--- Request: from Request input with new headers ---");
const r11 = new Request(r8, { headers: { "X-New": "val" } });
assert(r11.headers.get("x-new") === "val", "new headers added");
assert(r11.headers.get("x-id") === "123", "original headers preserved");

console.log("--- Request: toString ---");
const r12 = new Request("/toString-test");
assert(r12.toString() === "/toString-test", "toString returns url");

console.log("--- Request: toJSON ---");
const r13 = new Request("/json-test", { method: "PATCH" });
const json = r13.toJSON();
assert(json.url === "/json-test", "toJSON has url");
assert(json.method === "PATCH", "toJSON has method");

console.log(`\nResults: ${pass} passed, ${fail} failed`);
if (fail > 0) process.exit(1);

})().catch(e => { console.redbal(e); process.exit(1); });
