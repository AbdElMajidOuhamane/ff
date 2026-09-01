// examples/fetch_pool_test.js — Phase 4 persistent-worker-pool verification.
// Run: ff examples/fetch_pool_test.js   (exit 0 = all green)

let pass = 0, fail = 0;
function assert(cond, msg) {
  if (cond) { pass++; console.log("  PASS:", msg); }
  else { fail++; console.error("  FAIL:", msg); }
}
const BASE = "http://127.0.0.1:3000";

// ---- local origin server: deterministic routes, zero network noise ----
// NOTE: runtime responses are staged in a 16KB buffer — keep local bodies
// under that ceiling; large-body accumulation is tested via httpbin instead.
http.serve({ port: 3000 }, (url) => {
  if (url === "/ok") return { status: 200, body: "ok" };
  if (url === "/big") return { status: 200, body: "B".repeat(12288) };
  if (url === "/404") return { status: 404, body: "nf" };
  if (url === "/204") return { status: 204, body: "" };
  return { status: 404, body: "nf" };
});

// Network endpoints can stall even when healthy moments earlier; bound
// remote scenarios so flakiness SKIPs instead of wedging the whole suite.
// (The runtime's own 30s socket timeout is the backstop behind this.)
function timedFetch(url, opts = {}, ms = 15000) {
  const p = fetch(url, opts);
  p.catch(() => {}); // a late rejection after timeout must not become unhandled
  return Promise.race([
    p,
    new Promise((_, rej) =>
      setTimeout(() => rej(new Error(`timeout ${ms}ms: ${url}`)), ms)
    ),
  ]);
}

(async () => {
  // ---- 1. single basic GET through a pooled worker ----
  console.log("--- 1. basic pooled GET ---");
  {
    const r = await fetch(`${BASE}/ok`);
    assert(r.status === 200 && (await r.text()) === "ok", "single GET roundtrip");
  }

  // ---- 2. sequential churn: slot free-list acquire/release cycling ----
  console.log("--- 2. sequential churn x25 ---");
  {
    let okCount = 0;
    for (let i = 0; i < 25; i++) {
      const r = await fetch(`${BASE}/ok`);
      if (r.status === 200) okCount++;
      await r.text();
    }
    assert(okCount === 25, "25 sequential fetches all OK");
  }

  // ---- 3. concurrent burst: multiple pooled workers in flight ----
  console.log("--- 3. concurrent burst x32 ---");
  {
    const rs = await Promise.all(
      Array.from({ length: 32 }, () => fetch(`${BASE}/ok`))
    );
    const goods = rs.filter(r => r.status === 200);
    const bodies = await Promise.all(goods.map(r => r.text()));
    assert(goods.length === 32 && bodies.every(b => b === "ok"), "32 parallel GETs all OK");
  }

  // ---- 4. slot exhaustion: >64 in-flight -> fast-fail extras, pool recovers ----
  console.log("--- 4. saturation: 70 concurrent (cap 64) ---");
  {
    const results = await Promise.allSettled(
      Array.from({ length: 70 }, () => fetch(`${BASE}/ok`))
    );
    const fulfilled = results.filter(r => r.status === "fulfilled");
    const rejected  = results.filter(r => r.status === "rejected");
    assert(fulfilled.length >= 55, `most in-flight succeeded (${fulfilled.length}/70)`);
    assert(rejected.length >= 1,  `overflow rejected fast (${rejected.length})`);
    // pool must fully recover after the wave drains
    const r = await fetch(`${BASE}/ok`);
    assert(r.status === 200 && (await r.text()) === "ok", "pool recovered post-saturation");
  }

  // ---- 5. bodies: 12KB local (server ceiling) + 100KB network exact-size read ----
  console.log("--- 5. bodies: 12KB local + 100KB httpbin ---");
  {
    const rl = await fetch(`${BASE}/big`);
    const tl = await rl.text();
    assert(rl.status === 200 && tl.length === 12288 &&
           tl[0] === "B" && tl[tl.length - 1] === "B", "12KB local body intact");
  }
  try {
    const rb = await timedFetch("https://httpbin.org/bytes/100000");
    const bb = await rb.arrayBuffer();
    assert(rb.status === 200 && bb.byteLength === 100000,
           "100KB network body intact (exact-size read)");
  } catch (e) {
    console.log("  SKIP/ERR:", e && e.message ? e.message : e);
  }

  // ---- 6. non-GET methods survive pool hand-off ----
  console.log("--- 6. POST / PUT / DELETE / HEAD ---");
  {
    for (const m of ["POST", "PUT", "DELETE"]) {
      const r = await fetch(`${BASE}/ok`, { method: m });
      assert(r.status === 200, `${m} dispatched`);
      await r.text();
    }
    const h = await fetch(`${BASE}/ok`, { method: "HEAD" });
    assert(h.status === 200, "HEAD dispatched");
  }

  // ---- 7. custom headers ride along ----
  console.log("--- 7. custom headers ---");
  {
    const r = await fetch(`${BASE}/ok`, { headers: { "X-Pool": "phase4" } });
    assert(r.status === 200, "custom header accepted");
    await r.text();
  }

  // ---- 8. statuses: 404 / 204 ----
  console.log("--- 8. status codes ---");
  {
    const r4 = await fetch(`${BASE}/404`);
    assert(r4.status === 404 && r4.ok === false, "404 status + ok=false");
    const r2 = await fetch(`${BASE}/204`);
    assert(r2.status === 204, "204 no-content status");
  }

  // ---- 9. rejection paths: invalid URL + unreachable port ----
  console.log("--- 9. rejection paths ---");
  {
    let badUrlMsg = "";
    try { await fetch("not-a-url"); } catch (e) { badUrlMsg = String(e); }
    assert(badUrlMsg.length > 0, "invalid URL rejects");

    let netMsg = "";
    try { await fetch("http://127.0.0.1:1/"); } catch (e) { netMsg = String(e); }
    assert(netMsg.length > 0, "unreachable host rejects");
  }

  // ---- 10. redirect still followed (network, time-bounded) ----
  console.log("--- 10. redirect (httpbin) ---");
  try {
    const r = await timedFetch("https://httpbin.org/redirect/1");
    assert(r.status === 200, "redirect follows to 200");
  } catch (e) {
    console.log("  SKIP/ERR:", e && e.message ? e.message : e);
  }

  // ---- 11. timers interleave with in-flight pool work ----
  console.log("--- 11. timers interleave ---");
  {
    let ticked = false;
    setTimeout(() => { ticked = true; }, 50);
    const rs = await Promise.all([
      fetch(`${BASE}/ok`),
      new Promise(res => setTimeout(res, 80)),
    ]);
    await rs[0].text();
    assert(ticked && rs[0].status === 200, "timer fired while job in flight");
  }

  // ---- 12. final drain: pool idle, one more for the road ----
  console.log("--- 12. final drain ---");
  {
    const r = await fetch(`${BASE}/ok`);
    assert(r.status === 200, "final fetch after all waves");
    await r.text();
  }

  console.log(`\nResults: ${pass} passed, ${fail} failed`);
  console.log("EXIT_CLEAN");
  if (fail > 0) process.exit(1);
})().catch(e => {
  console.error("FATAL:", e);
  process.exit(1);
});
