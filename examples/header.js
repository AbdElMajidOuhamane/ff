let pass = 0, fail = 0;
function assert(cond, msg) {
  if (cond) { pass++; console.log("  PASS:", msg); }
  else { fail++; console.redbal("  FAIL:", msg); }
}

console.log("--- Headers: constructor ---");
let h = new Headers();
assert(h.size() === 0, "empty size=0");

h = new Headers({ "Content-Type": "text/html", "X-Custom": "hello" });
assert(h.size() === 2, "object init size=2");
assert(h.get("content-type") === "text/html", "case-insensitive get");
assert(h.has("X-CUSTOM"), "case-insensitive has");

console.log("--- Headers: set ---");
h.set("X-Foo", "bar");
assert(h.get("x-foo") === "bar", "set then get");

console.log("--- Headers: append ---");
h.append("X-Foo", "baz");
assert(h.get("x-foo") === "bar, baz", "append comma-join");
assert(h.getAll("X-FOO").length === 2, "getAll returns 2");

console.log("--- Headers: set replaces all ---");
h.set("x-foo", "only");
assert(h.get("x-foo") === "only", "set replaces all values");
assert(h.getAll("x-foo").length === 1, "after set only 1 value");

console.log("--- Headers: delete ---");
h.delete("x-foo");
assert(h.get("x-foo") === null, "delete removes all");

console.log("--- Headers: clone ---");
const h2 = new Headers(h);
assert(h2.size() === h.size(), "clone size matches");

console.log("--- Headers: array init ---");
const h3 = new Headers([["a", "1"], ["b", "2"]]);
assert(h3.size() === 2, "array init size=2");
assert(h3.get("a") === "1", "array init a=1");
assert(h3.get("b") === "2", "array init b=2");

console.log("--- Headers: get null for missing ---");
assert(h3.get("z") === null, "get missing returns null");

console.log("--- Headers: forEach ---");
let count = 0;
h3.forEach(() => { count++; });
assert(count === 2, "forEach iterates 2");

console.log("--- Headers: forEach value/name ---");
const names = [];
const values = [];
h3.forEach((val, name) => { names.push(name); values.push(val); });
assert(names.length === 2, "forEach names collected");
assert(values.length === 2, "forEach values collected");

console.log("--- Headers: entries ---");
const entries = [...h3.entries()];
assert(entries.length === 2, "entries length=2");

console.log("--- Headers: keys ---");
const keys = [...h3.keys()];
assert(keys.length === 2, "keys length=2");
assert(keys.includes("a"), "keys includes a");
assert(keys.includes("b"), "keys includes b");

console.log("--- Headers: values ---");
const vals = [...h3.values()];
assert(vals.length === 2, "values length=2");
assert(vals.includes("1"), "values includes 1");
assert(vals.includes("2"), "values includes 2");

console.log("--- Headers: toString ---");
const str = h3.toString();
assert(typeof str === "string", "toString returns string");
assert(str.length > 0, "toString not empty");

console.log("--- Headers: delete by value ---");
const h4 = new Headers([["x", "a"], ["x", "b"]]);
h4.delete("x", "a");
assert(h4.get("x") === "b", "delete by value removes only match");
assert(h4.size() === 1, "size after delete by value");

console.log("--- Headers: append duplicates ---");
const h5 = new Headers();
h5.append("Set-Cookie", "a=1");
h5.append("Set-Cookie", "b=2");
h5.append("Set-Cookie", "c=3");
assert(h5.getAll("set-cookie").length === 3, "three Set-Cookie values");
assert(h5.get("set-cookie") === "a=1, b=2, c=3", "get joins all with comma");

console.log("--- Headers: toString after mutations ---");
const h6 = new Headers();
h6.set("Content-Type", "application/json");
h6.set("X-Request-Id", "123");
const str2 = h6.toString();
assert(str2.includes("content-type: application/json"), "toString has content-type");
assert(str2.includes("x-request-id: 123"), "toString has x-request-id");

console.log(`\nResults: ${pass} passed, ${fail} failed`);
if (fail > 0) process.exit(1);
