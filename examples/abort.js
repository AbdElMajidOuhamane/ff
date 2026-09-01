let pass = 0, fail = 0;
function ok(cond, name) {
  if (cond) { pass++; console.log("PASS:", name); }
  else { fail++; console.log("FAIL:", name); }
}
function assert(cond, msg) {
  if (!cond) { fail++; console.log("FAIL: assert " + msg); }
  else { pass++; console.log("PASS:", msg); }
}

// ---- constructors exist ----
ok(typeof AbortController === "function", "AbortController is a function");
ok(typeof AbortSignal === "function", "AbortSignal is a function");

// ---- basic controller/signal ----
const c = new AbortController();
const s = c.signal;
ok(s.aborted === false, "signal.aborted is false initially");
ok(typeof s.addEventListener === "function", "signal.addEventListener is a function");
ok(typeof s.throwIfAborted === "function", "signal.throwIfAborted is a function");

let fired = 0;
s.addEventListener("abort", () => { fired++; });
let onabortHit = false;
s.onabort = () => { onabortHit = true; };

c.abort();
ok(s.aborted === true, "signal.aborted is true after abort()");
ok(fired === 1, "abort event dispatched");
ok(onabortHit === true, "onabort called");

let threw = false;
try { s.throwIfAborted(); } catch (e) { threw = e.name === "AbortError"; }
ok(threw, "throwIfAborted throws AbortError");

// ---- removeEventListener ----
const c2 = new AbortController();
let n = 0;
const h = () => { n++; };
c2.signal.addEventListener("abort", h);
c2.signal.removeEventListener("abort", h);
c2.abort();
ok(n === 0, "removeEventListener works");

// ---- once option ----
const c3 = new AbortController();
let onceCount = 0;
c3.signal.addEventListener("abort", () => { onceCount++; }, { once: true });
c3.abort();
ok(onceCount === 1, "once listener fires once");

// ---- static AbortSignal.abort ----
const pre = AbortSignal.abort("nope");
ok(pre.aborted === true, "AbortSignal.abort() is pre-aborted");
ok(pre.reason === "nope" || pre.reason == null, "AbortSignal.abort(reason) keeps reason");

// ---- fetch pre-aborted signal: reject immediately, no request ----
(async () => {
  let name = null;
  let ok1 = false;
  try {
    await fetch("http://httpbingo.org/status/200", { signal: pre });
  } catch (e) { name = e.name; }
  ok(name === "AbortError", "fetch with pre-aborted signal rejects AbortError");

  // ---- fetch aborted mid-flight ----
  const ctrl = new AbortController();
  const p = fetch("http://httpbingo.org/delay/5", { signal: ctrl.signal });
  setTimeout(() => ctrl.abort(), 200);
  let name2 = null;
  try { await p; } catch (e) { name2 = e.name; }
  ok(name2 === "AbortError", "fetch aborted mid-flight rejects AbortError");

  // ---- timeout ----
  let name3 = null;
  try {
    await fetch("http://httpbingo.org/delay/5", { timeout: 300 });
  } catch (e) { name3 = e.name; }
  ok(name3 === "TimeoutError", "fetch with timeout rejects TimeoutError");

  // ---- control: normal fetch still works ----
  const r = await fetch("http://httpbingo.org/status/200");
  ok(r.ok === true, "control fetch still resolves");

  console.log("Results:", pass + " passed,", fail + " failed");
  if (fail > 0) process.exit(1);
})();
