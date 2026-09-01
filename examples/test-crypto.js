// test-crypto.js
console.log("=== Crypto API Tests ===\n");

// 1. getRandomValues
var buf = new Uint8Array(16);
crypto.getRandomValues(buf);
console.log("getRandomValues:", buf.every(function(b) { return b === 0; }) ? "FAIL" : "PASS");

// 2. randomUUID
var id = crypto.randomUUID();
console.log("randomUUID:", /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(id) ? "PASS" : "FAIL", id);

// 3. subtle.digest
var hello = new Uint8Array([104, 101, 108, 108, 111]);
crypto.subtle.digest("SHA-256", hello).then(function(hash) {
  var hex = Array.from(new Uint8Array(hash)).map(function(b) { return b.toString(16).padStart(2, '0'); }).join('');
  console.log("digest SHA-256:", hex === "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" ? "PASS" : "FAIL");
}).catch(function(e) { console.log("digest: FAIL", e); });

// 4. generateKey + import/exportKey
crypto.subtle.generateKey("AES-GCM", true, ["encrypt", "decrypt"]).then(function(key) {
  console.log("generateKey AES-GCM:", key.type === "secret" ? "PASS" : "FAIL");
  return crypto.subtle.exportKey(key);
}).then(function(exported) {
  console.log("exportKey:", new Uint8Array(exported).length === 32 ? "PASS" : "FAIL");
}).catch(function(e) { console.log("generateKey/exportKey: FAIL", e); });

// 5. encrypt + decrypt roundtrip
var plainBytes = new Uint8Array([72, 101, 108, 108, 111, 32, 87, 111, 114, 108, 100]); // "Hello World"
var iv = new Uint8Array(12);
crypto.getRandomValues(iv);
var encKey;
crypto.subtle.generateKey("AES-GCM", true, ["encrypt", "decrypt"]).then(function(key) {
  encKey = key;
  return crypto.subtle.encrypt({ name: "AES-GCM", iv: iv }, key, plainBytes);
}).then(function(encrypted) {
  console.log("encrypt:", encrypted.byteLength > 0 ? "PASS" : "FAIL");
  return crypto.subtle.decrypt({ name: "AES-GCM", iv: iv }, encKey, encrypted);
}).then(function(decrypted) {
  var result = new Uint8Array(decrypted);
  var match = result.length === 11 && result[0] === 72 && result[1] === 101;
  console.log("decrypt:", match ? "PASS" : "FAIL");
}).catch(function(e) { console.log("encrypt/decrypt: FAIL", e); });

// 6. HMAC sign + verify
var hmacData = new Uint8Array([116, 101, 115, 116]); // "test"
var hmacWrong = new Uint8Array([119, 114, 111, 110, 103]); // "wrong"
var hmacKey;
crypto.subtle.generateKey("HMAC", true, ["sign", "verify"]).then(function(key) {
  hmacKey = key;
  return crypto.subtle.sign("HMAC", key, hmacData);
}).then(function(sig) {
  console.log("sign:", new Uint8Array(sig).length === 32 ? "PASS" : "FAIL");
  return crypto.subtle.verify("HMAC", hmacKey, sig, hmacData);
}).then(function(valid) {
  console.log("verify (correct):", valid === true ? "PASS" : "FAIL");
  return crypto.subtle.sign("HMAC", hmacKey, hmacData);
}).then(function(sig) {
  return crypto.subtle.verify("HMAC", hmacKey, sig, hmacWrong);
}).then(function(invalid) {
  console.log("verify (wrong):", invalid === false ? "PASS" : "FAIL");
}).catch(function(e) { console.log("sign/verify: FAIL", e); });

// 7. importKey raw
var rawKey = new Uint8Array([1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16]);
crypto.subtle.importKey("raw", rawKey, "AES-GCM", true, ["encrypt"]).then(function(key) {
  console.log("importKey:", key.type === "secret" ? "PASS" : "FAIL");
  return crypto.subtle.exportKey(key);
}).then(function(exported) {
  var bytes = new Uint8Array(exported);
  console.log("exportKey match:", bytes[0] === 1 && bytes[15] === 16 ? "PASS" : "FAIL");
}).catch(function(e) { console.log("importKey: FAIL", e); });

console.log("\n=== Tests queued, results follow ===");
