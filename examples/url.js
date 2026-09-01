// Test 1: Basic URL parsing
var url = new URL("https://example.com:8080/path?q=1#hash");
console.log("href:", url.href === "https://example.com:8080/path?q=1#hash" ? "PASS" : "FAIL");
console.log("origin:", url.origin === "https://example.com:8080" ? "PASS" : "FAIL");
console.log("protocol:", url.protocol === "https:" ? "PASS" : "FAIL");
console.log("host:", url.host === "example.com:8080" ? "PASS" : "FAIL");
console.log("hostname:", url.hostname === "example.com" ? "PASS" : "FAIL");
console.log("port:", url.port === "8080" ? "PASS" : "FAIL");
console.log("pathname:", url.pathname === "/path" ? "PASS" : "FAIL");
console.log("search:", url.search === "?q=1" ? "PASS" : "FAIL");
console.log("hash:", url.hash === "#hash" ? "PASS" : "FAIL");

// Test 2: Default port omission
var url2 = new URL("https://example.com:443/path");
console.log("default port:", url2.port === "" ? "PASS" : "FAIL");
console.log("default host:", url2.host === "example.com" ? "PASS" : "FAIL");

// Test 3: URLSearchParams
var params = new URLSearchParams("a=1&b=2&a=3");
console.log("get:", params.get("a") === "1" ? "PASS" : "FAIL");
console.log("getAll:", params.getAll("a").length === 2 ? "PASS" : "FAIL");
console.log("has:", params.has("b") === true ? "PASS" : "FAIL");
console.log("size:", params.size() === 3 ? "PASS" : "FAIL");

// Test 4: URLSearchParams set/delete
params.set("a", "100");
console.log("set:", params.toString() === "a=100&b=2" ? "PASS" : "FAIL");

// Test 5: Relative URL resolution
var base = new URL("https://example.com/a/b/c");
var rel = new URL("../d", base.href);
console.log("resolve:", rel.pathname === "/a/d" ? "PASS" : "FAIL");

// Test 6: URL.parse (non-throwing)
var parsed = URL.parse("https://example.com");
console.log("parse:", parsed !== null ? "PASS" : "FAIL");
var invalid = URL.parse("not a url");
console.log("parse invalid:", invalid === null ? "PASS" : "FAIL");

// Test 7: URL.canParse
console.log("canParse valid:", URL.canParse("https://example.com") === true ? "PASS" : "FAIL");
console.log("canParse invalid:", URL.canParse("not a url") === false ? "PASS" : "FAIL");
