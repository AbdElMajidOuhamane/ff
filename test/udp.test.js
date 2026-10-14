import { check, done } from "./lib.mjs";

// Full-surface smoke for the native UDP feature: udp.socket / bind /
// connect / sendto / recvfrom / send / recv / getsockname / getpeername /
// close — plus capacity (64 slots), zero-copy result views, error paths
// and the close-with-pending-recv cancel path.
//
// Everything uses ephemeral ports (bind port 0 + getsockname) so the suite
// never fights another process for a fixed port. Every recv is wrapped in
// a timeout so a broken completion fails fast instead of hanging the suite.
//
// The body lives in main() and main()'s rejection is routed to done():
// an uncaught top-level rejection currently exits 0 silently in this
// runtime, which a test harness would report as a pass.

const IP = "127.0.0.1";

function eqBytes(view, expected) {
  if (view.length !== expected.length) return false;
  for (let i = 0; i < view.length; i++) if (view[i] !== expected[i]) return false;
  return true;
}

function msgOf(e) {
  return String((e && e.message) || e);
}

// Sync call: returns the thrown message, or null when fn() did not throw.
function throwMsg(fn) {
  try {
    fn();
    return null;
  } catch (e) {
    return msgOf(e);
  }
}

// Returns the rejection message, or null when p resolved.
async function rejectMsg(p) {
  try {
    await p;
    return null;
  } catch (e) {
    return msgOf(e);
  }
}

function withTimeout(p, ms, label) {
  return Promise.race([
    p,
    new Promise((_, rej) => setTimeout(() => rej(new Error("timeout: " + label)), ms)),
  ]);
}

function sleep(ms) {
  return new Promise((res) => setTimeout(res, ms));
}

function addrEq(a, b) {
  return a.address === b.address && a.port === b.port && a.family === b.family;
}

async function main() {
// ── 1. creation + family validation ─────────────────────────────
check("bad family rejected", /family/.test(throwMsg(() => udp.socket("bogus")) || ""));
{
  const s = udp.socket("inet");
  check("explicit inet family accepted", typeof s.sendto === "function");
  s.close();
}

// ── 2. fresh socket state ───────────────────────────────────────
const A = udp.socket();
const n0 = A.getsockname();
check("unbound getsockname defaults", n0.address === "0.0.0.0" && n0.port === 0 && n0.family === "inet");
check("unbound getpeername throws", /not connected/.test(throwMsg(() => A.getpeername()) || ""));
check("unbound send throws", /not connected/.test(throwMsg(() => A.send(new Uint8Array(1))) || ""));
check("unbound recv throws", /not connected/.test(throwMsg(() => A.recv(new Uint8Array(1))) || ""));
A.bind({}); // default address + ephemeral port
const la = A.getsockname();
check("implicit bind picks ephemeral port", la.port > 0 && la.family === "inet");
A.close();

// ── 3. sendto/recvfrom round-trip (unconnected) ─────────────────
const srv = udp.socket();
srv.bind({ address: IP });
const srvPort = srv.getsockname().port;
check("bound address reflected", srv.getsockname().address === IP && srv.getsockname().port === srvPort);

const cli = udp.socket();
const payload = new Uint8Array([1, 2, 3, 250, 0, 255]);
const sent = await withTimeout(cli.sendto(payload, { address: IP, port: srvPort }), 2000, "sendto");
check("sendto returns byte count", sent === payload.length);

const rbuf = new Uint8Array(64);
const [data, from] = await withTimeout(srv.recvfrom(rbuf), 2000, "recvfrom");
check("recvfrom payload bytes", eqBytes(data, payload));
check("recvfrom returns Uint8Array", data instanceof Uint8Array);
check("recvfrom is a zero-copy view", data.buffer === rbuf.buffer && data.byteOffset === 0 && data.length === payload.length);
check("recvfrom sender address", from.address === IP && from.family === "inet");
check("recvfrom sender port", from.port > 0);

// ── 4. connected send/recv ──────────────────────────────────────
cli.connect({ address: IP, port: srvPort });
check("getpeername after connect", addrEq(cli.getpeername(), { address: IP, port: srvPort, family: "inet" }));

const payload2 = new Uint8Array([9, 8, 7]);
const sent2 = await withTimeout(cli.send(payload2), 2000, "send");
check("connected send byte count", sent2 === payload2.length);

const [data2, from2] = await withTimeout(srv.recvfrom(new Uint8Array(64)), 2000, "recvfrom 2");
check("connected payload arrives", eqBytes(data2, payload2));
check("sender is cli's auto-bound port", from2.port === cli.getsockname().port && from2.port > 0);
check("sender address/family", from2.address === IP && from2.family === "inet");

const reply = new Uint8Array([42, 43]);
await withTimeout(srv.sendto(reply, { address: from2.address, port: from2.port }), 2000, "reply");
const got = await withTimeout(cli.recv(new Uint8Array(16)), 2000, "recv reply");
check("connected recv payload", eqBytes(got, reply));

// ── 5. sequenced datagrams (order preserved on loopback) ────────
await withTimeout(cli.send(new Uint8Array([1])), 2000, "send m1");
const [d1] = await withTimeout(srv.recvfrom(new Uint8Array(8)), 2000, "recv m1");
await withTimeout(cli.send(new Uint8Array([2])), 2000, "send m2");
const [d2] = await withTimeout(srv.recvfrom(new Uint8Array(8)), 2000, "recv m2");
check("datagram order preserved", d1[0] === 1 && d2[0] === 2);

// ── 6. truncation + ArrayBuffer target ──────────────────────────
const big = new Uint8Array(100);
for (let i = 0; i < big.length; i++) big[i] = i;
await withTimeout(cli.send(big), 2000, "send big");
const small = new Uint8Array(10);
const [trunc, from3] = await withTimeout(srv.recvfrom(small), 2000, "recv truncated");
check("short buffer truncates", trunc.length === 10 && trunc[9] === 9 && from3.port > 0);

await withTimeout(cli.send(payload), 2000, "send ab");
const ab = new ArrayBuffer(64);
const [abView] = await withTimeout(srv.recvfrom(ab), 2000, "recv ab");
check("ArrayBuffer target yields view", abView instanceof Uint8Array && abView.buffer === ab && abView.byteOffset === 0);
check("ArrayBuffer view bytes", abView.length === payload.length && eqBytes(abView, payload));

// Send and receive views with nonzero offsets; guard bytes must stay untouched.
const sendBacking = new Uint8Array([99, 99, 4, 0, 255, 5, 99]);
const sendView = sendBacking.subarray(2, 6);
const receiveBacking = new Uint8Array(16);
receiveBacking.fill(77);
const receiveView = receiveBacking.subarray(3, 11);
check("offset send count", (await withTimeout(cli.send(sendView), 2000, "offset send")) === 4);
const [offsetData] = await withTimeout(srv.recvfrom(receiveView), 2000, "offset receive");
check("offset receive bytes", eqBytes(offsetData, new Uint8Array([4, 0, 255, 5])));
check("offset receive aliases target", offsetData.buffer === receiveBacking.buffer && offsetData.byteOffset === 3);
check("receive prefix guard", eqBytes(receiveBacking.subarray(0, 3), new Uint8Array([77, 77, 77])));
check("receive suffix guard", eqBytes(receiveBacking.subarray(7), new Uint8Array(9).fill(77)));
check("send view remains unchanged", eqBytes(sendBacking, new Uint8Array([99, 99, 4, 0, 255, 5, 99])));

// Non-byte typed arrays send their bytes, including the view's offset.
const typedBacking = new Uint8Array([99, 99, 10, 20, 30, 40, 99, 99]);
const typedPayload = new Uint16Array(typedBacking.buffer, 2, 2);
check("typed send byte count", (await withTimeout(cli.send(typedPayload), 2000, "typed send")) === 4);
const [typedData] = await withTimeout(srv.recvfrom(new Uint8Array(8)), 2000, "typed receive");
check("typed send raw bytes", eqBytes(typedData, typedBacking.subarray(2, 6)));

// A truncated datagram's remainder must not leak into the next receive.
await withTimeout(cli.send(new Uint8Array([11, 12, 13, 14])), 2000, "truncation send");
const [shortData] = await withTimeout(srv.recvfrom(new Uint8Array(2)), 2000, "truncation receive");
check("truncation returns prefix", eqBytes(shortData, new Uint8Array([11, 12])));
await withTimeout(cli.send(new Uint8Array([21])), 2000, "post truncation send");
const [nextData] = await withTimeout(srv.recvfrom(new Uint8Array(8)), 2000, "post truncation receive");
check("truncation discards remainder", eqBytes(nextData, new Uint8Array([21])));

// A rejected second receive must leave the first receive usable.
const firstReceive = srv.recvfrom(new Uint8Array(8));
check("duplicate recv rejected", /RecvPending/.test(throwMsg(() => srv.recvfrom(new Uint8Array(8))) || ""));
await withTimeout(cli.send(new Uint8Array([31])), 2000, "pending receive send");
const [firstData] = await withTimeout(firstReceive, 2000, "first receive survives");
check("first recv survives duplicate", eqBytes(firstData, new Uint8Array([31])));

// Empty datagrams are messages, and the documented maximum is inclusive.
check("empty send count", (await withTimeout(cli.send(new Uint8Array(0)), 2000, "empty send")) === 0);
try {
  const [emptyData, emptySender] = await withTimeout(srv.recvfrom(new Uint8Array(8)), 2000, "empty receive");
  check("empty datagram received", emptyData.length === 0 && emptySender.port === cli.getsockname().port);
} catch (error) {
  check("empty datagram received: " + msgOf(error), false);
}
const maximum = new Uint8Array(65507);
for (let i = 0; i < maximum.length; i++) maximum[i] = i % 256;
check("maximum send count", (await withTimeout(cli.send(maximum), 2000, "maximum send")) === maximum.length);
const [maximumData] = await withTimeout(srv.recvfrom(new Uint8Array(maximum.length)), 2000, "maximum receive");
check("maximum datagram intact", eqBytes(maximumData, maximum));

// Reconnecting replaces the default peer used by connected send().
const other = udp.socket();
try {
  other.bind({ address: IP });
  const otherPort = other.getsockname().port;
  cli.connect({ address: IP, port: otherPort });
  check("reconnect updates peer", cli.getpeername().port === otherPort);
  await withTimeout(cli.send(new Uint8Array([41])), 2000, "reconnect send");
  const [rerouted] = await withTimeout(other.recvfrom(new Uint8Array(8)), 2000, "reconnect receive");
  check("reconnect routes to new peer", eqBytes(rerouted, new Uint8Array([41])));
} finally {
  other.close();
}

srv.close();
cli.close();

// ── 7. IPv6 round-trip (skips cleanly when ::1 is unavailable) ──
let s6 = null;
let c6 = null;
let v6ok = false;
try {
  s6 = udp.socket("inet6");
  s6.bind({ address: "::1" });
  c6 = udp.socket("inet6");
  c6.bind({ address: "::1" }); // unbound v6 senders report "::" on macOS
  v6ok = true;
} catch (e) {
  console.log("SKIP udp6 (no ::1): " + msgOf(e));
}
if (v6ok) {
  const p6 = s6.getsockname();
  check("inet6 getsockname", p6.family === "inet6" && p6.address === "::1" && p6.port > 0);
  const v6payload = new Uint8Array([7, 7, 7]);
  const n6 = await withTimeout(c6.sendto(v6payload, { address: "::1", port: p6.port }), 2000, "v6 sendto");
  check("inet6 sendto count", n6 === v6payload.length);
  const [d6, f6] = await withTimeout(s6.recvfrom(new Uint8Array(16)), 2000, "v6 recvfrom");
  check("inet6 payload", eqBytes(d6, v6payload));
  check("inet6 sender", f6.family === "inet6" && f6.address === "::1");
}
if (s6) s6.close();
if (c6) c6.close();

// ── 8. error paths ──────────────────────────────────────────────
const E = udp.socket();
check("bind invalid address", /invalid address/.test(throwMsg(() => E.bind({ address: "999.999.999.999" })) || ""));
check("bind invalid port", /invalid port/.test(throwMsg(() => E.bind({ address: IP, port: 70000 })) || ""));
check("sendto address required", /address required/.test(throwMsg(() => E.sendto(new Uint8Array(1), { port: 1 })) || ""));
check("sendto port required", /port required/.test(throwMsg(() => E.sendto(new Uint8Array(1), { address: IP })) || ""));
check("sendto invalid address", /invalid address/.test(throwMsg(() => E.sendto(new Uint8Array(1), { address: "not-an-ip", port: 1 })) || ""));
check("connect address required", /address required/.test(throwMsg(() => E.connect({ port: 1 })) || ""));
check("connect port required", /port required/.test(throwMsg(() => E.connect({ address: IP })) || ""));
check("connect invalid address", /invalid address/.test(throwMsg(() => E.connect({ address: "nope", port: 1 })) || ""));
check("recvfrom non-buffer throws", /NotABuffer/.test(throwMsg(() => E.recvfrom(42)) || ""));
check("recvfrom plain array throws", /NotABuffer/.test(throwMsg(() => E.recvfrom([1, 2, 3])) || ""));
check("recvfrom non-byte view throws", /NotABuffer/.test(throwMsg(() => E.recvfrom(new Uint16Array(2))) || ""));
check("bind options required", /options object required/.test(throwMsg(() => E.bind()) || ""));
check("connect options required", /options object required/.test(throwMsg(() => E.connect()) || ""));
check("sendto options required", /requires/.test(throwMsg(() => E.sendto(new Uint8Array(1))) || ""));
check("recvfrom buffer required", /requires a buffer/.test(throwMsg(() => E.recvfrom()) || ""));
check("bind negative port rejected", /invalid port/.test(throwMsg(() => E.bind({ port: -1 })) || ""));
check("connect negative port rejected", /port required/.test(throwMsg(() => E.connect({ address: IP, port: -1 })) || ""));
check("sendto nonnumeric port rejected", /port required/.test(throwMsg(() => E.sendto(new Uint8Array(1), { address: IP, port: "1234" })) || ""));
check("sendto empty address rejected", /address required/.test(throwMsg(() => E.sendto(new Uint8Array(1), { address: "", port: 1 })) || ""));
check("oversized datagram", /MessageTooLong/.test(throwMsg(() => E.sendto(new Uint8Array(65508), { address: IP, port: 1 })) || ""));
E.close();

const EC = udp.socket();
EC.connect({ address: IP, port: srvPort }); // srv is gone; UDP connect never fails
check("send non-buffer throws", /NotABuffer/.test(throwMsg(() => EC.send("hello")) || ""));
EC.close();

// ── 9. close semantics + pending-recv cancel ────────────────────
const H = udp.socket();
H.bind({});
H.close();
check("double close is a no-op", throwMsg(() => H.close()) === null);
check("closed bind throws", /closed/.test(throwMsg(() => H.bind({})) || ""));
check("closed sendto throws", /closed/.test(throwMsg(() => H.sendto(new Uint8Array(1), { address: IP, port: 1 })) || ""));
check("closed recvfrom throws", /closed/.test(throwMsg(() => H.recvfrom(new Uint8Array(1))) || ""));
check("closed getsockname throws", /closed/.test(throwMsg(() => H.getsockname()) || ""));
check("closed getpeername throws", /closed/.test(throwMsg(() => H.getpeername()) || ""));
check("closed connect throws", /closed/.test(throwMsg(() => H.connect({ address: IP, port: 1 })) || ""));
check("closed send throws", /closed/.test(throwMsg(() => H.send(new Uint8Array(1))) || ""));
check("closed recv throws", /closed/.test(throwMsg(() => H.recv(new Uint8Array(1))) || ""));

const P = udp.socket();
P.bind({ address: IP });
const pending = P.recvfrom(new Uint8Array(16));
P.close();
const pendMsg = await withTimeout(rejectMsg(pending), 2000, "pending recv reject");
check("close rejects pending recv", pendMsg !== null && /closed/.test(pendMsg));

// ── 10. capacity: 64 slots, free-list recovery ──────────────────
await sleep(100); // let close/cancel completions drain and finalize slots
const pool = [];
let capErr = null;
for (let i = 0; i < 96; i++) {
  try {
    pool.push(udp.socket());
  } catch (e) {
    capErr = msgOf(e);
    break;
  }
}
check("slot limit enforced", capErr !== null && /no socket slots/.test(capErr));
check("all 64 slots usable (no leaks)", pool.length === 64);
for (const s of pool) s.close();
await sleep(100);
const reopened = udp.socket();
check("slots recycled after close", typeof reopened.sendto === "function");
// An old handle must remain closed even when its native slot is recycled.
for (const closed of pool) closed.close();
reopened.bind({ address: IP });
check("stale close preserves recycled socket", reopened.getsockname().address === IP && reopened.getsockname().port > 0);
check("stale bind remains rejected", /closed/.test(throwMsg(() => pool[pool.length - 1].bind({})) || ""));
reopened.close();
}

main().then(
  () => done("udp"),
  (e) => {
    check("UDP tests complete: " + msgOf(e), false);
    done("udp");
  },
);
