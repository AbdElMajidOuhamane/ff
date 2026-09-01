// p1.js — run: ./ff p1.js
let pass = 0, fail = 0;
function ok(name, cond) {
  if (cond) { pass++; console.log("  ok  " + name); }
  else      { fail++; console.log("FAIL  " + name); }
}
function done() { console.log("\n" + pass + " passed, " + fail + " failed"); process.exit(fail === 0 ? 0 : 1); }

console.log("== P1: async primitives ==");
const order = [];
order.push("sync");
queueMicrotask(() => order.push("q1"));
queueMicrotask(() => order.push("q2"));
process.nextTick(() => order.push("tick1"));
process.nextTick(() => order.push("tick2"));
setImmediate(() => order.push("imm1"));
const im2 = setImmediate(() => order.push("imm2"));
clearImmediate(im2);

setTimeout(() => {
  ok("sync -> microtasks -> 0ms timer order", order.join(",") === "sync,q1,q2,tick1,tick2,imm1");
  ok("clearImmediate suppressed timer", order.indexOf("imm2") === -1);
  ok("queueMicrotask is function", typeof queueMicrotask === "function");
  ok("setImmediate is function", typeof setImmediate === "function");
  ok("clearImmediate is function", typeof clearImmediate === "function");
  ok("process.nextTick is function", typeof process.nextTick === "function");

  console.log("== P1: unhandled rejection (expect one line below) ==");
  Promise.reject(new Error("boom"));

  setTimeout(() => {
    console.log("== process ==");
    ok("pid > 0", process.pid > 0);
    ok("platform", process.platform === "darwin" || process.platform === "linux");
    ok("arch", process.arch === "x64" || process.arch === "arm64");
    ok("cwd()", process.cwd().length > 0);
    ok("argv[0] string", typeof process.argv[0] === "string");
    ok("env has PATH/HOME", process.env.PATH !== undefined);
    process.env.FF_TEST = "1";
    ok("env writable", process.env.FF_TEST === "1");

    console.log("== timers ==");
    let t1 = 0, t2 = 0;
    const iv = setInterval(() => { if (++t1 === 2) clearInterval(iv); }, 10);
    clearTimeout(setTimeout(() => { t2 = 1; }, 20));

    setTimeout(() => {
      ok("interval ran 2x then stopped", t1 === 2);
      ok("cleared timeout never fired", t2 === 0);

      console.log("== fs ==");
      const tmp = process.cwd() + "/__ff_p1_test.txt";
      try {
        fs.writeFile(tmp, "hello storage");
        ok("writeFile+exists", fs.exists(tmp));
        ok("readFile round-trip", fs.readFile(tmp) === "hello storage");
        fs.rm(tmp);
        ok("rm removes file", !fs.exists(tmp));
      } catch (e) { fail++; console.log("FAIL fs:", e); }

      console.log("== crypto ==");
      ok("getRandomValues non-zero", (() => {
        const a = new Uint8Array(16);
        crypto.getRandomValues(a);
        return a.some((b) => b !== 0);
      })());
      ok("randomUUID v4 format", /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(crypto.randomUUID()));
      crypto.subtle.digest("SHA-256", new Uint8Array([1, 2, 3])).then((d) => {
        ok("subtle.digest -> 32 bytes ArrayBuffer", d && d.byteLength === 32);

        console.log("== URL ==");
        const u = new URL("https://user:pw@example.com:8443/x?q=1#frag");
        ok("URL parse", u.protocol === "https:" && u.host === "example.com:8443" && u.pathname === "/x" && u.searchParams.get("q") === "1");
        ok("URLSearchParams", new URLSearchParams("a=1&b=2").get("b") === "2");

        console.log("== http.serve + native fetch ==");
        const PORT = 8123;
        http.serve({ port: PORT }, (url, method) => ({ status: 200, body: method + " " + url }));
        fetch("http://127.0.0.1:" + PORT + "/ping")
          .then((r) => r.text())
          .then((body) => {
            ok("fetch hits native server", body === "GET /ping");
            done();
          })
          .catch((e) => { fail++; console.log("FAIL fetch:", e); done(); });
      }).catch((e) => { fail++; console.log("FAIL digest:", e); done(); });
    }, 40);
  }, 40);
}, 80);
