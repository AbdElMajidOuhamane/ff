import { check, done } from "./lib.mjs";

// Proxy smoke, ff-only (no external processes):
//   A) http:// via proxy: CONNECT is attempted first, the server refuses it
//      with 405, and std falls back to forward-proxy absolute-form -> the
//      server sees "http://..." and answers "proxied".
//   B) NO_PROXY bypass: the request goes direct and the server sees "/".
//   C) https:// via proxy: tls_tunnel CONNECTs to the proxy; the 405 refusal
//      must reject the fetch with no plaintext fallback and no response from
//      the probe server. (Before tls_tunnel this case returned the probe
//      server's plaintext response — the header leak this test guards.)
// The positive https-through-CONNECT e2e needs a proxy that can tunnel raw
// bytes, which the JS API cannot implement (no raw TCP); it lives in the
// manual, non-shipped examples/proxy-https/run.sh (Python tunnel proxy).
// console.log writes to stderr in this runtime, so child output is read from
// stderr with BODY:/ERR: markers.

const PORTS = [39911, 39912, 39913];
let port = 0;
let connectCount = 0;
for (const p of PORTS) {
  try {
    http.serve({ port: p }, (url, method) => {
      if (method === "CONNECT") {
        connectCount += 1;
        return new Response("no tunnel", { status: 405 });
      }
      if (url.startsWith("http://") || url.startsWith("https://")) {
        return new Response("proxied");
      }
      return new Response("direct");
    });
    port = p;
    break;
  } catch (e) {}
}
if (port === 0) throw new Error("proxy test: could not bind any candidate port");

const decoder = new TextDecoder();
function childCode(url) {
  return (
    "(async()=>{try{" +
    "const r=await fetch('" + url + "');" +
    "console.log('BODY:'+(await r.text()))" +
    "}catch(e){console.log('ERR:'+e)}})()"
  );
}
async function runChild(env, url) {
  // The child is a fresh, deny-by-default ff process. All three cases fetch
  // localhost:<port>; the proxy hop to 127.0.0.1 is internal and not gated.
  const c = child_process.spawn(
    process.argv[0],
    ["-e", childCode(url), "--allow-net=localhost:" + port],
    { env },
  );
  await c.wait();
  return decoder.decode(c.stderr);
}

const target = "http://localhost:" + port + "/";

try {
  // A: proxy host differs from the target host so std does not short-circuit
  // via its "prevent proxying through itself" rule.
  const beforeA = connectCount;
  const a = await runChild({ HTTP_PROXY: "http://127.0.0.1:" + port }, target);
  if (!a.includes("BODY:proxied")) console.log("  child A stderr:", JSON.stringify(a));
  check("HTTP_PROXY used", a.includes("BODY:proxied"));
  check("HTTP_PROXY attempted CONNECT", connectCount === beforeA + 1);

  // B: NO_PROXY bypass routes to the direct client — no CONNECT at all.
  const beforeB = connectCount;
  const b = await runChild(
    { HTTP_PROXY: "http://127.0.0.1:" + port, NO_PROXY: "localhost" },
    target,
  );
  if (!b.includes("BODY:direct")) console.log("  child B stderr:", JSON.stringify(b));
  check("NO_PROXY bypass", b.includes("BODY:direct"));
  check("NO_PROXY skipped CONNECT", connectCount === beforeB);

  // C: https via proxy — a refused CONNECT must reject cleanly and must not
  // send the request in plaintext (no BODY:).
  const beforeC = connectCount;
  const c = await runChild(
    { HTTPS_PROXY: "http://127.0.0.1:" + port },
    "https://localhost:" + port + "/",
  );
  if (!c.includes("ERR:") || c.includes("BODY:")) console.log("  child C stderr:", JSON.stringify(c));
  check("HTTPS tunnel refused rejects", c.includes("ERR:") && !c.includes("BODY:"));
  check("HTTPS tunnel attempted CONNECT", connectCount === beforeC + 1);
} catch (e) {
  console.log("FAIL: proxy test threw: " + e);
}

done("proxy");
