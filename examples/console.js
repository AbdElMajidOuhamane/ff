// examples/console.js — exercises every IMPLEMENTED console.* feature.
// Emits deterministic output to stderr (fairyfly std.debug.print).
// NOTE: assert/count/table/trace are not yet implemented (future work).
let pass = 0, fail = 0;
function ok(cond, msg) {
  if (cond) { pass++; console.log("  PASS:", msg); }
  else { fail++; console.redbal("  FAIL:", msg); }
}

// ---- 1. existence ----
const METHODS = ["log", "warn", "error", "info", "debug",
                 "slops", "redbal", "detail"];
for (const m of METHODS) {
  ok(typeof console[m] === "function", `console.${m} is a function`);
}

// ---- 2. return values are undefined ----
for (const m of METHODS) {
  ok(console[m]("x") === undefined, `console.${m}() returns undefined`);
}

// ---- 3. formatting / interpolation, plain + colored ----
console.log("plain", 1, true, null);
console.info("info", "line");
console.debug("debug", "line");
console.warn("warned", "here");
console.error("errored", 42);
console.slops("slops alias");
console.detail("detail alias");
console.redbal("redbal alias");

// ---- 4. mixed multi-arg output ----
console.log(`interp ${1 + 1}`);

// ---- summary ----
console.log(`\nResults: ${pass} passed, ${fail} failed`);
if (fail > 0) process.exit(1);
