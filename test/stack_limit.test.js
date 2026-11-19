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

// 5. REGRESSION: Main thread at 8MB ceiling (where native stack is 16MB)
const c8MB = child_process.spawn(process.argv[0], [
  "--max-stack=8MB",
  "-e",
  "function r(n) { return r(n + 1); } try { r(0); } catch (e) { console.log(e.name); }",
]);
const w8MB = await c8MB.wait();
check("main thread at 8MB ceiling exits 0", w8MB.code === 0);
check("main thread at 8MB ceiling has null signal (no SIGSEGV/SIGBUS)", w8MB.signal === null);
check("main thread at 8MB ceiling outputs RangeError", childOutput(c8MB).trim() === "RangeError");

// 6. REGRESSION: Worker thread 2x growth path (worker stack grows to 16MB at 8MB JS limit)
const cWorker8MB = child_process.spawn(process.argv[0], [
  "--max-stack=8MB",
  "-e",
  "const w = new Worker('./test/fixtures/stack_probe_worker.js'); w.onmessage = (e) => { console.log(JSON.stringify(e.data)); w.terminate(); };",
]);
const wWorker8MB = await cWorker8MB.wait();
check("worker at 8MB JS limit (16MB native stack growth) exits 0", wWorker8MB.code === 0);
check("worker at 8MB JS limit has null signal (no SIGSEGV/SIGBUS)", wWorker8MB.signal === null);
const worker8Out = childOutput(cWorker8MB).trim();
let worker8Data = {};
try {
  worker8Data = JSON.parse(worker8Out);
} catch {}
check("worker at 8MB JS limit receives catchable RangeError", worker8Data.ok === true && worker8Data.name === "RangeError");

// 7. Startup failure when --max-stack exceeds safe threshold
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

// 8. Startup failure when --max-stack is below floor (128KB)
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

// 9. Format error distinction: non-numeric or fractional byte formats must fail as byte format errors
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

// 10. Missing value hint: --max-stack without value must report "requires a value"
const cNoVal = child_process.spawn(process.argv[0], [
  "--max-stack",
  "-e",
  "console.log('unreachable')",
]);
const wNoVal = await cNoVal.wait();
check("child with --max-stack (no value) exits non-zero", wNoVal.code !== 0);
const noValErr = decoder.decode(cNoVal.stderr);
check("error indicates --max-stack requires a value", noValErr.includes("--max-stack requires a value"));

const cEmptyVal = child_process.spawn(process.argv[0], [
  "--max-stack=",
  "-e",
  "console.log('unreachable')",
]);
const wEmptyVal = await cEmptyVal.wait();
check("child with --max-stack= (empty value) exits non-zero", wEmptyVal.code !== 0);
const emptyValErr = decoder.decode(cEmptyVal.stderr);
check("error indicates --max-stack= requires a value", emptyValErr.includes("--max-stack requires a value"));

done("stack_limit");
