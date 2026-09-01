// test-async.js

// Test 1: Basic await with synchronous promise
async function test1() {
  var data = new Uint8Array([104, 101, 108, 108, 111]);
  var hash = await crypto.subtle.digest("SHA-256", data);
  var hex = Array.from(new Uint8Array(hash)).map(function(b) {
    return b.toString(16).padStart(2, '0');
  }).join('');
  var expected = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";
  console.log("Test 1 - basic await:", hex === expected ? "PASS" : "FAIL");
}

// Test 2: Chained awaits
async function test2() {
  var data1 = new Uint8Array([104, 101, 108, 108, 111]);
  var data2 = new Uint8Array([119, 111, 114, 108, 100]);
  var hash1 = await crypto.subtle.digest("SHA-256", data1);
  var hash2 = await crypto.subtle.digest("SHA-256", data2);
  var h1 = new Uint8Array(hash1);
  var h2 = new Uint8Array(hash2);
  console.log("Test 2 - chained await:", h1.length === 32 && h2.length === 32 ? "PASS" : "FAIL");
}

// Test 3: await with generateKey + encrypt + decrypt
async function test3() {
  var plain = new Uint8Array([72, 101, 108, 108, 111]);
  var key = await crypto.subtle.generateKey("AES-GCM", true, ["encrypt", "decrypt"]);
  var iv = new Uint8Array(12);
  crypto.getRandomValues(iv);
  var encrypted = await crypto.subtle.encrypt({ name: "AES-GCM", iv: iv }, key, plain);
  var decrypted = await crypto.subtle.decrypt({ name: "AES-GCM", iv: iv }, key, encrypted);
  var result = new Uint8Array(decrypted);
  console.log("Test 3 - await encrypt/decrypt:", result[0] === 72 && result[4] === 111 ? "PASS" : "FAIL");
}

// Test 4: await with sign + verify
async function test4() {
  var data = new Uint8Array([116, 101, 115, 116]);
  var wrong = new Uint8Array([119, 114, 111, 110, 103]);
  var key = await crypto.subtle.generateKey("HMAC", true, ["sign", "verify"]);
  var sig = await crypto.subtle.sign("HMAC", key, data);
  var valid = await crypto.subtle.verify("HMAC", key, sig, data);
  var invalid = await crypto.subtle.verify("HMAC", key, sig, wrong);
  console.log("Test 4 - await sign/verify:", valid === true && invalid === false ? "PASS" : "FAIL");
}

// Test 5: await with setTimeout (truly async)
async function test5() {
  var start = Date.now();
  await new Promise(function(resolve) { setTimeout(resolve, 200); });
  var elapsed = Date.now() - start;
  console.log("Test 5 - await setTimeout:", elapsed >= 150 ? "PASS" : "FAIL", "(elapsed:", elapsed + "ms)");
}

// Run all tests
test1();
test2();
test3();
test4();
test5();
console.log("\n=== async/await tests queued ===");
