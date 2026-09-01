// Independent cross-check with Node's built-in fetch + WebSocket (Node >= 22).
// Run:  NODE_TLS_REJECT_UNAUTHORIZED=0 node node-client.mjs   (exit 0 = pass)

const BASE = "https://localhost:8443";
let fail = 0;
const ok = (name, cond) => { console.log((cond ? "OK   " : "FAIL ") + name); if (!cond) fail++; };

// --- HTTPS ---------------------------------------------------------
const health = await fetch(`${BASE}/health`);
ok("https /health status 200", health.status === 200);
const h = await health.json();
ok("https /health payload {ok, tls}", h.ok === true && h.tls === true);

const echoRes = await fetch(`${BASE}/echo`, { method: "POST", body: "ping-through-tls" });
ok("https /echo POST round-trip", (await echoRes.text()) === "ping-through-tls");

const bigRes = await fetch(`${BASE}/big`);
ok("https /big (20KB, multi-record)", bigRes.status === 200 && (await bigRes.text()).length === 20000);

// --- WSS -----------------------------------------------------------
const ws = new WebSocket("wss://localhost:8443/ws");
const msg = await new Promise((resolve, reject) => {
  const to = setTimeout(() => reject(new Error("wss timeout")), 5000);
  ws.addEventListener("open", () => ws.send("node-wss-ping"));
  ws.addEventListener("message", (ev) => { clearTimeout(to); resolve(ev.data); });
  ws.addEventListener("error", () => { clearTimeout(to); reject(new Error("wss error")); });
});
ok("wss echo over TLS", msg === "echo: node-wss-ping");
ws.close();

console.log(fail === 0 ? "ALL PASS" : "FAILURES: " + fail);
process.exit(fail === 0 ? 0 : 1);
