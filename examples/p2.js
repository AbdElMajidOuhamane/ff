// p2.js — run: ./ff p2.js   (after make install)
let pass = 0, fail = 0;
function ok(name, cond) {
  if (cond) { pass++; console.log("  ok  " + name); }
  else      { fail++; console.log("FAIL  " + name); }
}
function done() { console.log("\n" + pass + " passed, " + fail + " failed"); process.exit(fail === 0 ? 0 : 1); }

console.log("== P2: performance ==");
ok("performance exists on global", typeof performance === "object");
ok("performance.now is function", typeof performance.now === "function");
const t0 = performance.now();
let spin = 0; for (let i = 0; i < 1e6; i++) spin += i;
const t1 = performance.now();
ok("now() returns number > 0", typeof t0 === "number" && t0 > 0);
ok("now() is monotonic", t1 >= t0);

console.log("== P2: process.memoryUsage ==");
const mu = process.memoryUsage();
ok("rss is a positive number", typeof mu.rss === "number" && mu.rss > 0);
ok("heapUsed > 0", typeof mu.heapUsed === "number" && mu.heapUsed > 0);
ok("heapTotal >= heapUsed", mu.heapTotal >= mu.heapUsed);
ok("has external/arrayBuffers keys", typeof mu.external === "number" && typeof mu.arrayBuffers === "number");

console.log("== P2: btoa / atob ==");
ok("btoa is function", typeof btoa === "function");
ok("atob is function", typeof atob === "function");
ok("btoa('hello')", btoa("hello") === "aGVsbG8=");
ok("atob round-trip", atob("aGVsbG8=") === "hello");
ok("btoa('')", btoa("") === "");
let b64_threw = false;
try { btoa("你好"); } catch (e) { b64_threw = e instanceof TypeError; }
ok("btoa rejects non-Latin-1", b64_threw);
ok("btoa('é') Latin-1 ok", btoa("é") === "6Q==" && atob(btoa("é")) === "é");
ok("btoa rejects astral", (() => { try { btoa("😀"); return false; } catch (e) { return e instanceof TypeError; } })());

console.log("== P2: Buffer ==");
ok("Buffer is function", typeof Buffer === "function");
ok("Buffer.alloc(4) zeros + length", (() => {
  const b = Buffer.alloc(4);
  return b.length === 4 && b[0] === 0 && b[3] === 0;
})());
ok("Buffer.allocUnsafe(4) length", Buffer.allocUnsafe(4).length === 4);
ok("instanceof Uint8Array", Buffer.from([1, 2, 3]) instanceof Uint8Array);
ok("from hex -> utf8", Buffer.from("6869", "hex").toString() === "hi");
ok("to hex", Buffer.from("hi").toString("hex") === "6869");
ok("hex round-trip", Buffer.from(Buffer.from("hello").toString("hex"), "hex").toString() === "hello");
ok("from base64", Buffer.from("aGVsbG8=", "base64").toString() === "hello");
ok("to base64", Buffer.from("hello").toString("base64") === "aGVsbG8=");
ok("from array", (() => { const b = Buffer.from([1, 2, 3]); return b.length === 3 && b[0] === 1 && b[2] === 3; })());
ok("from Uint8Array copy", (() => { const b = Buffer.from(new Uint8Array([7, 8])); return b[1] === 8 && b.length === 2; })());
ok("index write", (() => { const b = Buffer.alloc(3); b[1] = 0x41; return b[1] === 65; })());
ok("byteLength utf8", Buffer.byteLength("hello") === 5);
ok("byteLength utf8 multibyte", Buffer.byteLength("héllo") === 6);
ok("byteLength latín1", Buffer.byteLength("héllo", "latin1") === 5);
ok("byteLength base64", Buffer.byteLength("aGVsbG8=", "base64") === 5);
ok("byteLength hex", Buffer.byteLength("6869", "hex") === 2);
ok("concat", Buffer.concat([Buffer.from("a"), Buffer.from("b")]).toString() === "ab");
ok("subarray view", Buffer.from("hello").subarray(1, 3).toString() === "el");
ok("slice copies", Buffer.from("hello").slice(1, 3).toString() === "el");
ok("write()", (() => { const b = Buffer.alloc(5); b.write("hello"); return b.toString() === "hello"; })());
ok("toJSON", (() => {
  const j = Buffer.from("A").toJSON();
  return j.type === "Buffer" && Array.isArray(j.data) && j.data[0] === 65;
})());
ok("equals same", Buffer.from("abc").equals(Buffer.from("abc")));
ok("equals diff", !Buffer.from("abc").equals(Buffer.from("abd")));
ok("isBuffer true", Buffer.isBuffer(Buffer.alloc(2)));
ok("isBuffer false for Uint8Array", !Buffer.isBuffer(new Uint8Array(2)));
ok("isView true for Buffer", Buffer.isView(Buffer.alloc(2)));
ok("isView false for ArrayBuffer", !Buffer.isView(new ArrayBuffer(4)));

console.log("== P2: TextEncoder / TextDecoder ==");
ok("TextEncoder is function", typeof TextEncoder === "function");
ok("TextDecoder is function", typeof TextDecoder === "function");
const enc = new TextEncoder();
ok("encode('hi')", Array.from(enc.encode("hi")).join(",") === "104,105");
ok("encode emoji is 4 bytes", enc.encode("😀").length === 4);
const dec = new TextDecoder();
ok("decode round-trip", dec.decode(enc.encode("hello")) === "hello");
ok("decode emoji round-trip", dec.decode(enc.encode("😀")) === "😀");
ok("decode invalid -> U+FFFD", dec.decode(new Uint8Array([0xff, 0x41])) === "\uFFFDA");

done();
