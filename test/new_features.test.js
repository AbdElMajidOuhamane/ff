import { check, done } from "./lib.mjs";

// 1. ReadableStream behavior: enqueue, multi-read, close
check("ReadableStream is defined", typeof ReadableStream === "function");
let streamController = null;
const stream = new ReadableStream({
  start(controller) {
    streamController = controller;
    check("controller desiredSize is positive", controller.desiredSize > 0);
    controller.enqueue("chunkA");
    controller.enqueue("chunkB");
  }
});
check("stream instance created", typeof stream === "object");
const reader = stream.getReader();
check("reader exists", typeof reader === "object");

const r1 = await reader.read();
check("first read settled with chunkA", r1.value === "chunkA" && r1.done === false);

const r2 = await reader.read();
check("second read settled with chunkB", r2.value === "chunkB" && r2.done === false);

streamController.close();
const r3 = await reader.read();
check("third read settled with done:true", r3.value === undefined && r3.done === true);

// 2. process.stdout and process.stdin
check("process.stdout.write is a function", typeof process.stdout.write === "function");
check("process.stdin.read is a function", typeof process.stdin.read === "function");
check("process.stdin.readSync is a function", typeof process.stdin.readSync === "function");
process.stdout.write(""); // should not crash

// 3. Permissions API: dynamic getters & revoke in child
check("permissions.revoke is a function", typeof permissions.revoke === "function");
check("permissions.read exists", typeof permissions.read === "boolean");
check("permissions.write exists", typeof permissions.write === "boolean");
check("permissions.net exists", typeof permissions.net === "boolean");

const cRevoke = child_process.spawn(process.argv[0], ["--allow-read", "-e", "permissions.revoke({ name: 'read' }); if (permissions.read !== false) process.exit(1); console.log('REVOKE_OK');"]);
const stRevoke = await cRevoke.wait();
check("permissions.revoke works in child", stRevoke.code === 0);

// Scoped revoke test
const cScopedRevoke = child_process.spawn(process.argv[0], [
  "--allow-read=/tmp,/var",
  "-e",
  `if (permissions.read !== true) process.exit(1);
  permissions.revoke({ name: 'read', path: '/tmp' });
  if (permissions.read !== true) process.exit(2);
  permissions.revoke({ name: 'read', path: '/var' });
  if (permissions.read !== false) process.exit(3);
  console.log('SCOPED_REVOKE_OK');`
]);
const stScopedRevoke = await cScopedRevoke.wait();
check("scoped revoke drops specific scope while keeping category alive until all dropped", stScopedRevoke.code === 0);

// 4. TCP API
check("tcp.connect is a function", typeof tcp.connect === "function");

// 5. Response.file
check("Response.file is a function", typeof Response.file === "function");
const fRes = Response.file("build.zig");
check("Response.file returns Response object", typeof fRes === "object" && fRes.status === 200);

// Response with ReadableStream body and res.body getter
const dummyStream = new ReadableStream();
const streamResp = new Response(dummyStream);
check("Response accepts ReadableStream body", typeof streamResp === "object");
check("Response.prototype.body getter returns stream", streamResp.body === dummyStream);

// pull-on-demand callback
let pullCount = 0;
const pullStream = new ReadableStream({
  pull(controller) {
    pullCount++;
    if (pullCount === 1) {
      controller.enqueue("chunk1");
    } else if (pullCount === 2) {
      controller.enqueue("chunk2");
      controller.close();
    }
  }
});
const pullReader = pullStream.getReader();
const p1 = await pullReader.read();
check("pull-on-demand first chunk", p1.value === "chunk1" && p1.done === false && pullCount === 1);
const p2 = await pullReader.read();
check("pull-on-demand second chunk", p2.value === "chunk2" && p2.done === false && pullCount === 2);
const p3 = await pullReader.read();
check("pull-on-demand closed", p3.done === true);

// ReadableStream locking & reader methods
const testStream = new ReadableStream();
check("stream.locked initially false", testStream.locked === false);
const rTest = testStream.getReader();
check("stream.locked true after getReader", testStream.locked === true);
let getReaderLockedThrow = false;
try {
  testStream.getReader();
} catch (e) {
  getReaderLockedThrow = true;
}
check("second getReader throws when locked", getReaderLockedThrow === true);
rTest.releaseLock();
check("stream.locked false after releaseLock", testStream.locked === false);
const rTest2 = testStream.getReader();
check("getReader succeeds after releaseLock", testStream.locked === true);
await rTest2.cancel();
check("reader cancel succeeds and unlocks stream", testStream.locked === false);

// 6. HTTP Routes method matching, :id param capture, 405, 404, 414
const testPort = 38941;
try {
  const server = http.serve({ port: testPort }, {
    "GET /users/:id": (url, method, body, headers, params) => {
      return new Response(`user:${params.id}`);
    },
    "POST /items": () => {
      return new Response("item created");
    },
    "GET /stream": () => {
      const s = new ReadableStream({
        start(controller) {
          controller.enqueue("chunkA ");
          controller.enqueue("chunkB");
          controller.close();
        }
      });
      return new Response(s, { headers: { "Content-Type": "text/plain" } });
    },
    "GET /bigstream": () => {
      const s = new ReadableStream({
        start(controller) {
          const big = new Uint8Array(100 * 1024);
          big.fill(65);
          controller.enqueue(big);
          controller.close();
        }
      });
      return new Response(s);
    }
  });

  // GET /users/42
  const uRes = await fetch(`http://127.0.0.1:${testPort}/users/42`);
  const uText = await uRes.text();
  check("route param captured correctly", uRes.status === 200 && uText === "user:42");

  // GET /stream
  const sRes = await fetch(`http://127.0.0.1:${testPort}/stream`);
  check("stream fetch status 200", sRes.status === 200);
  check("stream fetch has res.body", typeof sRes.body === "object");
  const sText = await sRes.text();
  check("stream fetch text() aggregates chunks", sText.includes("chunkA chunkB"));

  // GET /bigstream (oversized 100 KB chunk)
  const bigRes = await fetch(`http://127.0.0.1:${testPort}/bigstream`);
  check("bigstream fetch status 200", bigRes.status === 200);
  const bigBuf = await bigRes.arrayBuffer();
  check("oversized 100KB stream chunk received intact", bigBuf.byteLength === 100 * 1024);

  // POST /users/42 -> method mismatch -> 405
  const postMismatch = await fetch(`http://127.0.0.1:${testPort}/users/42`, { method: "POST" });
  check("route method mismatch returns 405", postMismatch.status === 405);

  // Missing route -> 404
  const notFound = await fetch(`http://127.0.0.1:${testPort}/unknown`);
  check("missing route returns 404", notFound.status === 404);

  // TCP connect and round-trip to the HTTP server
  const sock = await tcp.connect("127.0.0.1", testPort);
  sock.write("GET /users/99 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
  const tcpData = await sock.read();
  check("tcp.read returns data", tcpData instanceof Uint8Array && tcpData.length > 0);
  const tcpStr = new TextDecoder().decode(tcpData);
  check("tcp response contains user:99", tcpStr.includes("user:99"));
  sock.close();

  server.close();
} catch (e) {
  // Fail on unexpected errors if server setup or route handling failed
  console.error("HTTP/TCP test error:", e);
  check("HTTP and TCP test succeeded without error", false);
}

// 7. CLI runtime flags & limits validation
const decoder = new TextDecoder();
function decode(b) { return b ? decoder.decode(b) : ""; }

// Invalid heap fails loud
const c1 = child_process.spawn(process.argv[0], ["--max-heap=banana", "-e", "1"]);
const st1 = await c1.wait();
check("invalid --max-heap fails non-zero", st1.code !== 0);

// Missing env-file path fails loud
const c2 = child_process.spawn(process.argv[0], ["--env-file"]);
const st2 = await c2.wait();
check("missing --env-file value fails non-zero", st2.code !== 0);

// --env-file <path> -e '...' runs script, not the env file!
const c3 = child_process.spawn(process.argv[0], ["--env-file", "build.zig", "-e", "console.log('RAN_OK')"]);
const st3 = await c3.wait();
const out3 = decode(c3.stdout) + decode(c3.stderr);
check("--env-file path consumed without running it as script", st3.code === 0 && out3.includes("RAN_OK"));

// 8. ff.cron in isolated child so interval timer doesn't keep parent suite hanging
const cCron = child_process.spawn(process.argv[0], ["-e", "ff.cron('test', '@every 10ms', () => { console.log('CRON_OK'); process.exit(0); });"]);
const stCron = await cCron.wait();
const outCron = decode(cCron.stdout) + decode(cCron.stderr);
check("ff.cron executes interval job in child", stCron.code === 0 && outCron.includes("CRON_OK"));

// 9. controller.error() rejects pending and subsequent reads
let errCtrl = null;
const errStream = new ReadableStream({
  start(c) { errCtrl = c; }
});
const errReader = errStream.getReader();
let pendingCaught = false;
let subsequentCaught = false;
errReader.read().catch(e => {
  if (e === "test_err") pendingCaught = true;
});
errCtrl.error("test_err");
await new Promise(r => setTimeout(r, 10));
check("controller.error() rejects pending read", pendingCaught === true);

await errReader.read().catch(e => {
  if (e === "test_err") subsequentCaught = true;
});
check("read on errored stream rejects immediately", subsequentCaught === true);

// 10. --max-heap=16MB succeeds (no spurious worker-heap failure)
const cHeap16 = child_process.spawn(process.argv[0], ["--max-heap=16MB", "-e", "console.log('HEAP16_OK')"]);
const stHeap16 = await cHeap16.wait();
const outHeap16 = decode(cHeap16.stdout) + decode(cHeap16.stderr);
check("--max-heap=16MB succeeds", stHeap16.code === 0 && outHeap16.includes("HEAP16_OK"));

// 11. Empty deny scope fails loud
const cEmptyDeny = child_process.spawn(process.argv[0], ["--deny-net=", "-e", "1"]);
const stEmptyDeny = await cEmptyDeny.wait();
check("empty --deny-net= fails non-zero", stEmptyDeny.code !== 0);

// 12. CPU budget kills infinite loop in direct loop and microtask continuation
const cCpuDirect = child_process.spawn(process.argv[0], ["--cpu-budget=100", "-e", "while(true){}"]);
const stCpuDirect = await cCpuDirect.wait();
check("cpu budget terminates direct infinite loop", stCpuDirect.code !== 0);

const cCpuMicro = child_process.spawn(process.argv[0], ["--cpu-budget=100", "-e", "Promise.resolve().then(() => { while(true){} });"]);
const stCpuMicro = await cCpuMicro.wait();
check("cpu budget terminates microtask infinite loop", stCpuMicro.code !== 0);

// 13. ff.cron 5-field syntax, range+step, and impossible date rejection
let cron5Ok = true;
try {
  ff.cron("cron5", "0 3 * * *", () => {});
  ff.cron("cron_step", "0-30/5 * * * *", () => {});
} catch (e) {
  cron5Ok = false;
}
check("ff.cron accepts valid 5-field and range/step expressions", cron5Ok === true);

let cronImpossibleRejected = false;
try {
  ff.cron("impossible", "0 0 31 2 *", () => {});
} catch (e) {
  cronImpossibleRejected = true;
}
check("ff.cron rejects expressions with no fire date within 366 days", cronImpossibleRejected === true);

// 14. Absolute-path entry with relative module resolution
const absScript = `${process.cwd()}/test/text.test.js`;
const cAbs = child_process.spawn(process.argv[0], [absScript]);
const stAbs = await cAbs.wait();
check("absolute path script resolves relative imports correctly", stAbs.code === 0);

// 15. Standalone compilation round-trip
const standaloneJs = "test/fixtures/standalone_probe.js";
const standaloneBin = "test/fixtures/standalone_probe_bin";
fs.writeFile(standaloneJs, "console.log('STANDALONE_RUN_OK');\n");
const cComp = child_process.spawn(process.argv[0], ["compile", "--standalone", standaloneJs, "-o", standaloneBin]);
const stComp = await cComp.wait();
check("standalone compilation succeeds", stComp.code === 0);
const cRunStand = child_process.spawn(`./${standaloneBin}`);
const stRunStand = await cRunStand.wait();
const outRunStand = decode(cRunStand.stdout) + decode(cRunStand.stderr);
check("standalone binary executes correctly", stRunStand.code === 0 && outRunStand.includes("STANDALONE_RUN_OK"));
try { fs.rm(standaloneJs); } catch (_) {}
try { fs.rm(standaloneBin); } catch (_) {}

// 16. Scoped revoke subpath with broader grant
const cRevokeSub = child_process.spawn(process.argv[0], [
  "--allow-read=/",
  "-e",
  `
  permissions.revoke({ name: "read", path: "/tmp" });
  let readTmpBlocked = false;
  try {
    fs.readFile("/tmp");
  } catch (e) {
    if (e.name === "PermissionDenied") readTmpBlocked = true;
  }
  if (readTmpBlocked) console.log("REVOKE_SUBPATH_OK");
  `
]);
const stRevokeSub = await cRevokeSub.wait();
const outRevokeSub = decode(cRevokeSub.stdout) + decode(cRevokeSub.stderr);
check("scoped revoke correctly blocks subpath under broader grant", stRevokeSub.code === 0 && outRevokeSub.includes("REVOKE_SUBPATH_OK"));

// 17. CPU budget terminates infinite loop inside pull callback
const cCpuPull = child_process.spawn(process.argv[0], [
  "--cpu-budget=100",
  "-e",
  `
  const s = new ReadableStream({
    pull() { while(true){} }
  });
  const r = s.getReader();
  r.read().catch(e => {
    if (e.name === "InternalError") {
      console.log("PULL_INTERRUPT_OK");
      process.exit(0);
    }
  });
  `
]);
const stCpuPull = await cCpuPull.wait();
const outCpuPull = decode(cCpuPull.stdout) + decode(cCpuPull.stderr);
check("cpu budget terminates infinite loop inside pull callback", stCpuPull.code === 0 && outCpuPull.includes("PULL_INTERRUPT_OK"));

// 18. fs.readFileAsync settles and exits cleanly without hanging on idle xev.Async
const cFsOk = child_process.spawn(process.argv[0], [
  "--allow-read",
  "-e",
  "(async () => { const s = await fs.readFileAsync('build.zig'); if (!s.length) process.exit(2); })()",
]);
const stFsOk = await cFsOk.wait();
check("fs.readFileAsync resolves and process exits 0 cleanly", stFsOk.code === 0);

const cFsErr = child_process.spawn(process.argv[0], [
  "--allow-read",
  "-e",
  "(async () => { await fs.readFileAsync('build.zig'); throw new Error('after_fs'); })()",
]);
const stFsErr = await cFsErr.wait();
check("unhandled error after fs.readFileAsync exits 1 cleanly", stFsErr.code === 1);

done("new_features");
process.exit(0);
