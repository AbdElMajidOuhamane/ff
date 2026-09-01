// ============================================================
// Timers test — setTimeout / clearTimeout / setInterval / clearInterval
// Run: ff timers-test.js
// ============================================================

let pass = 0;
let fail = 0;

function check(name, cond) {
  if (cond) {
    pass += 1;
    console.detail("  PASS  " + name);
  } else {
    fail += 1;
    console.redbal("  FAIL  " + name);
  }
}

// --- 1. setTimeout fires once ---
let st_count = 0;
setTimeout(() => { st_count += 1; }, 30);
setTimeout(() => { st_count += 1; }, 30);
setTimeout(() => {
  check("setTimeout fires the right number of times", st_count === 2);
}, 100);

// --- 2. clearTimeout cancels ---
let cleared_fired = 0;
const t1 = setTimeout(() => { cleared_fired += 1; }, 20);
clearTimeout(t1);
setTimeout(() => {
  check("clearTimeout prevented the callback", cleared_fired === 0);
}, 80);

// --- 3. setTimeout returns a numeric id ---
let id_ok = false;
const t2 = setTimeout(() => { check("ids valid at fire time", id_ok); }, 40);
id_ok = typeof t2 === "number" && t2 >= 0;
check("setTimeout returns a numeric id", id_ok);

// --- 4. clearing an expired/unknown id is a safe no-op ---
let no_crash = true;
try {
  clearTimeout(9999);
  clearTimeout(t1); // already consumed
  clearTimeout(t2);
  clearInterval(42);
} catch (e) {
  no_crash = false;
}
check("clear* of unknown/expired ids is a no-op", no_crash);

// --- 5. setInterval fires repeatedly ---
let iv_count = 0;
const iv = setInterval(() => { iv_count += 1; }, 20);
setTimeout(() => {
  const fired = iv_count;
  check("setInterval fires repeatedly (>=3)", fired >= 3);
  clearInterval(iv); // stop it
  const frozen = iv_count;
  setTimeout(() => {
    check("clearInterval stopped the interval", frozen === iv_count);
  }, 50);
}, 90);

// --- 6. intervals reuse ids correctly (slot allocation) ---
const a = setInterval(() => {}, 1000);
const b = setTimeout(() => {}, 1000);
check("interval returns an id", typeof a === "number");
check("timeout returns a (different-ish) id", typeof b === "number");
clearInterval(a);
clearTimeout(b);

// --- 7. no timers left -> loop should exit on its own ---
setTimeout(() => {
  console.detail("  DONE  " + pass + " passed, " + fail + " failed");
  if (fail > 0) process.exit(1);
}, 130);
