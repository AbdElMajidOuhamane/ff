import { check, done } from "./lib.mjs";

const decoder = new TextDecoder();

function childOutput(child) {
  const out = decoder.decode(child.stdout);
  const err = decoder.decode(child.stderr);
  return out.length > 0 ? out : err;
}

// 1. Default stack deep recursion raises catchable RangeError (never SIGSEGV / SIGBUS)
let defaultCaught = false;
let defaultErrName = "";
function recurseDefault(n) {
  return recurseDefault(n + 1);
}
try {
  recurseDefault(0);
} catch (e) {
  defaultCaught = true;
  defaultErrName = e.name || (e.constructor && e.constructor.name);
}
check("default stack deep recursion throws RangeError", defaultCaught && defaultErrName === "RangeError");

// 2. Deeply nested JSON.parse raises catchable RangeError, not crash
let jsonCaught = false;
let jsonErrName = "";
try {
  JSON.parse("[".repeat(50000) + "]".repeat(50000));
} catch (e) {
  jsonCaught = true;
  jsonErrName = e.name || (e.constructor && e.constructor.name);
}
check("deeply nested JSON.parse throws RangeError", jsonCaught && jsonErrName === "RangeError");

// 3. Child process with custom safe --max-stack (2MB) catches RangeError on main thread
const c2MB = child_process.spawn(process.argv[0], [
  "--max-stack=2MB",
  "-e",
  "function r(n) { return r(n + 1); } try { r(0); } catch (e) { console.log(e.name); }",
]);
const w2MB = await c2MB.wait();
check("child with --max-stack=2MB exits 0", w2MB.code === 0);
check("child with --max-stack=2MB has null signal (no crash)", w2MB.signal === null);
check("child with --max-stack=2MB outputs RangeError", childOutput(c2MB).trim() === "RangeError");

// 4. Worker thread with --max-stack=2MB (hitting the 8MB floor) raises catchable RangeError
const cWorker2MB = child_process.spawn(process.argv[0], [
  "--max-stack=2MB",
  "-e",
  "const w = new Worker('./test/fixtures/stack_probe_worker.js'); w.onmessage = (e) => { console.log(JSON.stringify(e.data)); w.terminate(); };",
]);
const wWorker2MB = await cWorker2MB.wait();
check("worker with --max-stack=2MB exits 0", wWorker2MB.code === 0);
check("worker with --max-stack=2MB has null signal (no crash)", wWorker2MB.signal === null);
const worker2Out = childOutput(cWorker2MB).trim();
let worker2Data = {};
try {
  worker2Data = JSON.parse(worker2Out);
} catch {}
check("worker receives catchable RangeError at 2MB", worker2Data.ok === true && worker2Data.name === "RangeError");

// 5. Startup failure when --max-stack exceeds safe threshold; parse host ceiling
const cExceed = child_process.spawn(process.argv[0], [
  "--max-stack=64MB",
  "-e",
  "console.log('unreachable')",
]);
const wExceed = await cExceed.wait();
check("child with --max-stack=64MB exits non-zero", wExceed.code !== 0);
check("child with --max-stack=64MB has null signal (normal exit, not crash)", wExceed.signal === null);
const exceedErr = decoder.decode(cExceed.stderr);
check("error message indicates native stack limit exceeded", exceedErr.includes("exceeds safe limit for native stack"));
check("hint includes detected native stack size", exceedErr.includes("native stack"));

const ceilingMatch = exceedErr.match(/safe limit is at most (\d+) MB/);
const safeMaxMB = ceilingMatch ? parseInt(ceilingMatch[1], 10) : 0;
check("hint reports numeric safe stack ceiling", safeMaxMB >= 1);

// 6. Host-portable ceiling, over-ceiling boundary, and worker 2x growth tests
if (safeMaxMB >= 1) {
  // Main thread at detected host ceiling
  const cMax = child_process.spawn(process.argv[0], [
    "--max-stack=" + safeMaxMB + "MB",
    "-e",
    "function r(n) { return r(n + 1); } try { r(0); } catch (e) { console.log(e.name); }",
  ]);
  const wMax = await cMax.wait();
  check(`main thread at ${safeMaxMB}MB host ceiling exits 0`, wMax.code === 0);
  check(`main thread at ${safeMaxMB}MB host ceiling has null signal (no SIGSEGV/SIGBUS)`, wMax.signal === null);
  check(`main thread at ${safeMaxMB}MB host ceiling outputs RangeError`, childOutput(cMax).trim() === "RangeError");

  // Over-ceiling boundary: safeMaxMB + 1 must be rejected cleanly
  const overMB = safeMaxMB + 1;
  const cOver = child_process.spawn(process.argv[0], [
    "--max-stack=" + overMB + "MB",
    "-e",
    "console.log('unreachable')",
  ]);
  const wOver = await cOver.wait();
  check(`over-ceiling boundary --max-stack=${overMB}MB exits non-zero`, wOver.code !== 0);
  check(`over-ceiling boundary --max-stack=${overMB}MB has null signal`, wOver.signal === null);
  const overErr = decoder.decode(cOver.stderr);
  check(`over-ceiling boundary --max-stack=${overMB}MB reports exceeded native stack`, overErr.includes("exceeds safe limit for native stack"));

  // Worker thread at detected host ceiling (exercises 16MB native stack growth when safeMaxMB == 8)
  const cWorkerMax = child_process.spawn(process.argv[0], [
    "--max-stack=" + safeMaxMB + "MB",
    "-e",
    "const w = new Worker('./test/fixtures/stack_probe_worker.js'); w.onmessage = (e) => { console.log(JSON.stringify(e.data)); w.terminate(); };",
  ]);
  const wWorkerMax = await cWorkerMax.wait();
  check(`worker at ${safeMaxMB}MB host ceiling exits 0`, wWorkerMax.code === 0);
  check(`worker at ${safeMaxMB}MB host ceiling has null signal (no SIGSEGV/SIGBUS)`, wWorkerMax.signal === null);
  const workerMaxOut = childOutput(cWorkerMax).trim();
  let workerMaxData = {};
  try {
    workerMaxData = JSON.parse(workerMaxOut);
  } catch {}
  check(`worker at ${safeMaxMB}MB host ceiling receives catchable RangeError`, workerMaxData.ok === true && workerMaxData.name === "RangeError");

  // Explicit 8MB worker 2x growth fallback when host default ceiling <= 4MB (e.g. Linux ulimit -s 8192)
  if (safeMaxMB <= 4) {
    const probe = child_process.spawn("/bin/sh", [
      "-c",
      'ulimit -s 16384 2>/dev/null && exec "$1" --max-stack=8MB -e "process.exit(0)"',
      "sh",
      process.argv[0],
    ]);
    const probeWait = await probe.wait();
    if (probeWait.code === 0) {
      const cMain8 = child_process.spawn("/bin/sh", [
        "-c",
        'ulimit -s 16384 && exec "$1" --max-stack=8MB -e "$2"',
        "sh",
        process.argv[0],
        "function r(n) { return r(n + 1); } try { r(0); } catch (e) { console.log(e.name); }",
      ]);
      const wMain8 = await cMain8.wait();
      check("main thread at 8MB (via ulimit -s 16384) exits 0", wMain8.code === 0);
      check("main thread at 8MB has null signal (no SIGSEGV/SIGBUS)", wMain8.signal === null);
      check("main thread at 8MB outputs RangeError", childOutput(cMain8).trim() === "RangeError");

      const cWork8 = child_process.spawn("/bin/sh", [
        "-c",
        'ulimit -s 16384 && exec "$1" --max-stack=8MB -e "$2"',
        "sh",
        process.argv[0],
        "const w = new Worker('./test/fixtures/stack_probe_worker.js'); w.onmessage = (e) => { console.log(JSON.stringify(e.data)); w.terminate(); };",
      ]);
      const wWork8 = await cWork8.wait();
      check("worker at 8MB JS limit (16MB native stack growth) exits 0", wWork8.code === 0);
      check("worker at 8MB JS limit has null signal (no SIGSEGV/SIGBUS)", wWork8.signal === null);
      let work8Data = {};
      try {
        work8Data = JSON.parse(childOutput(cWork8).trim());
      } catch {}
      check("worker at 8MB JS limit receives catchable RangeError", work8Data.ok === true && work8Data.name === "RangeError");
    } else {
      console.log(`note: skipping 8MB worker-growth regression (host ceiling ${safeMaxMB}MB, cannot raise stack rlimit)`);
    }
  }
}

// 7. Startup failure when --max-stack is below floor (128KB)
const cFloor = child_process.spawn(process.argv[0], [
  "--max-stack=64KB",
  "-e",
  "console.log('unreachable')",
]);
const wFloor = await cFloor.wait();
check("child with --max-stack=64KB exits non-zero", wFloor.code !== 0);
check("child with --max-stack=64KB has null signal", wFloor.signal === null);
const floorErr = decoder.decode(cFloor.stderr);
check("error message indicates invalid stack size", floorErr.includes("invalid --max-stack value"));
check("hint mentions minimum of 128KB", floorErr.includes("128KB"));

// 8. Format error distinction: non-numeric or fractional byte formats must fail as byte format errors
const cBanana = child_process.spawn(process.argv[0], [
  "--max-stack=banana",
  "-e",
  "console.log('unreachable')",
]);
const wBanana = await cBanana.wait();
check("child with --max-stack=banana exits non-zero", wBanana.code !== 0);
check("child with --max-stack=banana has null signal", wBanana.signal === null);
const bananaErr = decoder.decode(cBanana.stderr);
check("format error message for banana", bananaErr.includes("invalid byte size format"));

const cFract = child_process.spawn(process.argv[0], [
  "--max-stack=15.5MB",
  "-e",
  "console.log('unreachable')",
]);
const wFract = await cFract.wait();
check("child with --max-stack=15.5MB exits non-zero", wFract.code !== 0);
check("child with --max-stack=15.5MB has null signal", wFract.signal === null);
const fractErr = decoder.decode(cFract.stderr);
check("format error message for 15.5MB", fractErr.includes("invalid byte size format"));

// 9. Missing value hint: --max-stack without value must report "requires a value"
const cNoVal = child_process.spawn(process.argv[0], [
  "--max-stack",
  "-e",
  "console.log('unreachable')",
]);
const wNoVal = await cNoVal.wait();
check("child with --max-stack (no value) exits non-zero", wNoVal.code !== 0);
check("child with --max-stack (no value) has null signal", wNoVal.signal === null);
const noValErr = decoder.decode(cNoVal.stderr);
check("error indicates --max-stack requires a value", noValErr.includes("--max-stack requires a value"));

const cEmptyVal = child_process.spawn(process.argv[0], [
  "--max-stack=",
  "-e",
  "console.log('unreachable')",
]);
const wEmptyVal = await cEmptyVal.wait();
check("child with --max-stack= (empty value) exits non-zero", wEmptyVal.code !== 0);
check("child with --max-stack= (empty value) has null signal", wEmptyVal.signal === null);
const emptyValErr = decoder.decode(cEmptyVal.stderr);
check("error indicates --max-stack= requires a value", emptyValErr.includes("--max-stack requires a value"));

done("stack_limit");
