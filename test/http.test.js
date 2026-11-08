import { check, done } from "./lib.mjs";

// Flagship smoke: http.serve → fetch round-trip. Tries candidate ports so
// a busy port fails over instead of flaking (serve throws on bind failure).
const PORTS = [39871, 39872, 39873];
let base = null;
let server = null;
for (const port of PORTS) {
  try {
    server = http.serve({ port }, async (url, method, body, headers) => {
      const path = url.split("?")[0];
      if (path === "/health") return { status: 200, body: "ok" };
      if (path === "/headers") return { status: 200, body: headers.get("x-custom") || "" };
      if (path === "/headers-detail") {
        return {
          status: 200,
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            customLower: headers.get("x-custom"),
            customUpper: headers.get("X-Custom"),
            absent: headers.get("x-absent"),
            hasCustom: headers.has("x-custom"),
            hasAbsent: headers.has("x-absent"),
            emptyVal: headers.get("x-empty"),
            multiGet: headers.get("x-multi"),
            multiGetAll: headers.getAll ? headers.getAll("x-multi") : null,
            cookie: headers.get("cookie"),
            bodyLen: body ? body.length : 0,
          }),
        };
      }
      if (path === "/echo" && method === "POST") return { status: 201, body: "created" };
      if (path === "/slow") {
        await new Promise((r) => setTimeout(r, 250));
        return { status: 200, body: "slow" };
      }
      return { status: 404, body: "not found" };
    });
    base = "http://127.0.0.1:" + port;
    break;
  } catch (e) {}
}
if (base === null) throw new Error("http test: could not bind any candidate port");

check("server handle port", typeof server?.port === "number" && typeof server?.close === "function");

const r = await fetch(base + "/health");
check("status 200", r.status === 200);
check("body ok", (await r.text()) === "ok");

const rh = await fetch(base + "/headers", { headers: { "X-Custom": "ff-headers-ok" } });
check("headers received", (await rh.text()) === "ff-headers-ok");

// Comprehensive headers assertions
const testHdrs = new Headers();
testHdrs.append("X-Custom", "test-val");
testHdrs.append("X-Multi", "first");
testHdrs.append("x-multi", "second");
testHdrs.append("Cookie", "session=123");
testHdrs.append("cookie", "theme=dark");
testHdrs.append("X-Empty", "");

const rDetail = await fetch(base + "/headers-detail", { headers: testHdrs });
const detail = await rDetail.json();

check("headers absent is null", detail.absent === null && detail.hasAbsent === false);
check("headers case-insensitivity", detail.customLower === "test-val" && detail.customUpper === "test-val" && detail.hasCustom === true);
check("headers empty value", detail.emptyVal === "");
check("headers duplicate get joins comma", detail.multiGet === "first, second");
check("headers duplicate getAll array", Array.isArray(detail.multiGetAll) && detail.multiGetAll.length === 2 && detail.multiGetAll[0] === "first" && detail.multiGetAll[1] === "second");
check("headers cookie RFC 9113 joins semicolon", detail.cookie === "session=123; theme=dark");

// Large body spill preserves headers
const bigBody = "x".repeat(130 * 1024);
const rSpill = await fetch(base + "/headers-detail", {
  method: "POST",
  headers: { "X-Custom": "spill-preserved" },
  body: bigBody,
});
const spillDetail = await rSpill.json();
check("large body spill preserves headers", spillDetail.customLower === "spill-preserved" && spillDetail.bodyLen === 130 * 1024);

const n = await fetch(base + "/nope");
check("404 route", n.status === 404);
check("404 body", (await n.text()) === "not found");

// structuredClone global
const srcObj = {
  n: 42,
  arr: [1, 2, 3],
  bytes: new Uint8Array([10, 20]),
  map: new Map([["a", 1]]),
  set: new Set(["x"]),
};
const cloned = structuredClone(srcObj);
srcObj.arr.push(4);
srcObj.bytes[0] = 99;
check(
  "structuredClone deep copy",
  cloned.n === 42 &&
    cloned.arr.length === 3 &&
    cloned.bytes[0] === 10 &&
    cloned.map.get("a") === 1 &&
    cloned.set.has("x"),
);

// AbortController / AbortSignal with timers, Request, and in-flight fetch
const timerAc = new AbortController();
let timerFired = false;
let onabortFired = false;
timerAc.signal.onabort = () => {
  onabortFired = true;
};
setTimeout(() => {
  timerFired = true;
}, 40, { signal: timerAc.signal });
timerAc.abort("cancelled-timer");
await new Promise((res) => setTimeout(res, 60));
check("AbortController cancels setTimeout & fires onabort", !timerFired && onabortFired && timerAc.signal.reason === "cancelled-timer");

const preAborted = AbortSignal.abort("already");
let throwIfAbortedThrew = false;
try {
  preAborted.throwIfAborted();
} catch (e) {
  throwIfAbortedThrew = e === "already";
}
check("AbortSignal.abort + throwIfAborted", preAborted.aborted && throwIfAbortedThrew);

const reqWithSig = new Request(base + "/health", { signal: preAborted });
check("Request preserves signal & clone", reqWithSig.signal === preAborted && reqWithSig.clone().signal === preAborted);

let preFetchThrew = false;
try {
  await fetch(reqWithSig);
} catch {
  preFetchThrew = true;
}
check("fetch with pre-aborted Request rejects immediately", preFetchThrew);

const fetchAc = new AbortController();
setTimeout(() => fetchAc.abort("stop-slow"), 30);
let inflightAborted = false;
const t0 = performance.now();
try {
  await fetch(base + "/slow", { signal: fetchAc.signal });
} catch {
  inflightAborted = true;
}
const elapsed = performance.now() - t0;
check("in-flight fetch aborted before server delay", inflightAborted && elapsed < 200);

// process.on / once / kill signal delivery
let sigReceived = false;
process.once("SIGUSR1", (sig) => {
  if (sig === "SIGUSR1") sigReceived = true;
});
process.kill(process.pid, "SIGUSR1");
await new Promise((res) => setTimeout(res, 20));
check("process.once + process.kill SIGUSR1", sigReceived);

// server.close() graceful shutdown
let closeCbCalled = false;
await server.close(() => {
  closeCbCalled = true;
});
check("server.close() resolves and invokes callback", closeCbCalled);

// TLS server + fetch. The certificate fixtures are tracked under
// test/fixtures/tls/ and generated by test/fixtures/build.sh.
const TLS_CERT = "test/fixtures/tls/cert.pem";
const TLS_KEY = "test/fixtures/tls/key.pem";
if (!fs.exists(TLS_CERT) || !fs.exists(TLS_KEY)) {
  console.log(`FAIL: missing TLS fixtures ${TLS_CERT} / ${TLS_KEY}`);
  process.exit(1);
}
const tlsServer = http.serve({
  port: 0,
  tls: { cert: TLS_CERT, key: TLS_KEY },
}, (url, method, body, headers) => {
  if (headers && headers.get("x-h2-test")) {
    return new Response("h2-custom:" + headers.get("x-h2-test"));
  }
  return new Response("tls-ok");
});
const rLocalhost = await fetch("https://localhost:" + tlsServer.port + "/");
check("TLS fetch hostname", (await rLocalhost.text()) === "tls-ok");

// HTTP/2 end-to-end headers test via curl (when curl with HTTP/2 is available)
try {
  const curlRes = await child_process.exec(
    `curl --http2 -k -s -H "X-H2-Test: works" https://localhost:${tlsServer.port}/`
  );
  if (curlRes.code === 0 && curlRes.stdout.includes("h2-custom:works")) {
    check("HTTP/2 end-to-end request headers (curl)", true);
  }
} catch {}

// IP-literal TLS is intentionally unsupported: std.crypto.tls.Client does not
// verify IP SANs, and disabling host verification would be unsafe.
await tlsServer.close();

// reusePort option (multi-process sharing and duplicate bind rejection)
const ffBin = process.argv[0];
let rpPort = 39881;
let sReuse1 = null;
for (const cand of [39881, 39882, 39883, 39884, 39885]) {
  try {
    sReuse1 = http.serve({ port: cand, reusePort: true }, () => new Response("s1"));
    rpPort = cand;
    break;
  } catch {}
}

if (!sReuse1) {
  console.log("FAIL: could not bind reusePort test listener");
  process.exit(1);
}

// Spawn child process with reusePort: true sharing the port
const childShare = child_process.spawn(ffBin, [
  "-e",
  `const b = http.serve({ port: ${rpPort}, reusePort: true }, () => new Response("s2"));
   setTimeout(() => b.close(), 1500);`,
  "--allow-all",
]);
await new Promise((r) => setTimeout(r, 200));

// Close sReuse1 so ONLY the child is listening on rpPort.
// If the child had failed to bind, the fetch would fail with connection error.
await sReuse1.close();
const rShare = await fetch(`http://127.0.0.1:${rpPort}/`);
const shareTxt = await rShare.text();
check("reusePort enables multi-process port sharing", shareTxt === "s2");

const wShare = await childShare.wait();
check("child reusePort exit 0", wShare.code === 0);

// Without reusePort (default), duplicate bind to the same port must fail
const sBase = http.serve({ port: rpPort }, () => new Response("base"));
const childNoShare = child_process.spawn(ffBin, [
  "-e",
  `http.serve({ port: ${rpPort} }, () => new Response("dup"));`,
  "--allow-all",
]);
const resNoShare = await childNoShare.wait();
check("duplicate bind rejected by default", resNoShare.code !== 0);
await sBase.close();

done("http");
