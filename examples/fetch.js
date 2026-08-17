let pass = 0, fail = 0;
function assert(cond, msg) {
  if (cond) { pass++; console.log("  PASS:", msg); }
  else { fail++; console.redbal("  FAIL:", msg); }
}

(async () => {

console.log("--- Fetch: GET httpbingo ---");
const r1 = await fetch("https://httpbingo.org/get");
assert(r1.status === 200, "GET status 200");
assert(r1.ok === true, "GET ok is true");
const b1 = await r1.json();
assert(b1.url === "https://httpbingo.org/get", "GET url echoed");

console.log("--- Fetch: POST with body ---");
const r2 = await fetch("https://httpbingo.org/post", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: '{"key":"value"}',
});
assert(r2.status === 200, "POST status 200");
const b2 = await r2.json();
assert(b2.data === '{"key":"value"}', "POST body echoed");

console.log("--- Fetch: custom headers ---");
const r3 = await fetch("https://httpbingo.org/headers", {
  headers: { "X-Custom": "test123" },
});
const b3 = await r3.json();
assert(String(b3.headers["X-Custom"]) === "test123", "custom header sent");

console.log("--- Fetch: 404 status ---");
const r4 = await fetch("https://httpbingo.org/status/404");
assert(r4.status === 404, "404 status");
assert(r4.ok === false, "404 not ok");

console.log("--- Fetch: redirect ---");
const r5 = await fetch("https://httpbingo.org/redirect/1");
assert(r5.status === 200, "redirect follows to 200");

console.log("--- Fetch: bodyUsed tracking ---");
const r6 = await fetch("https://httpbingo.org/get");
assert(r6.bodyUsed === false, "bodyUsed false before text");
await r6.text();
assert(r6.bodyUsed === true, "bodyUsed true after text");

console.log("--- Fetch: empty response body ---");
const r7 = await fetch("https://httpbingo.org/status/204");
assert(r7.status === 204, "204 no content");

console.log(`\nResults: ${pass} passed, ${fail} failed`);
if (fail > 0) process.exit(1);

})().catch(e => { console.redbal(e); process.exit(1); });
