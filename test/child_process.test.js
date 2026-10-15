import { check, done } from "./lib.mjs";

const decoder = new TextDecoder();

try {
  // exec: capture stdout + exit code
  const r1 = await child_process.exec("printf hello");
  check("exec stdout", r1.stdout === "hello");
  check("exec exit 0", r1.code === 0);

  // exec: stderr and non-zero exit still resolve
  const r2 = await child_process.exec("printf err >&2; exit 3");
  check("exec stderr", r2.stderr === "err");
  check("exec code 3", r2.code === 3);

  // exec: shell pipeline
  const r3 = await child_process.exec("printf a | tr a-z A-Z");
  check("exec pipeline", r3.stdout === "A");

  // spawn: capture + wait
  const c1 = child_process.spawn("/bin/echo", ["hi"]);
  check("spawn pid", Number.isInteger(c1.pid) && c1.pid > 0);
  const w1 = await c1.wait();
  check("spawn wait code", w1.code === 0 && w1.signal === null);
  check("spawn stdout", decoder.decode(c1.stdout) === "hi\n");

  // spawn: launch failure throws synchronously
  let threw = false;
  try { child_process.spawn("/definitely/not/a/binary"); } catch { threw = true; }
  check("spawn ENOENT throws", threw);

  // kill: signal reported precisely, kill is idempotent
  const c2 = child_process.spawn("/bin/sleep", ["30"]);
  check("kill returns true", c2.kill() === true);
  const w2 = await c2.wait();
  check("killed signal", w2.signal === "SIGTERM" && w2.code === null);
  check("kill after exit", c2.kill() === false);

  // cwd option
  const c3 = child_process.spawn("/bin/pwd", [], { cwd: "/" });
  await c3.wait();
  check("cwd option", decoder.decode(c3.stdout) === "/\n");

  // env replaces the environment
  const c4 = child_process.spawn("/bin/sh", ["-c", "printf $FOO"], { env: { FOO: "bar" } });
  await c4.wait();
  check("env option", decoder.decode(c4.stdout) === "bar");

  // maxBuffer: exec rejects
  let overflowed = false;
  try { await child_process.exec("head -c 2000000 /dev/zero", { maxBuffer: 1024 }); } catch { overflowed = true; }
  check("exec maxBuffer rejects", overflowed);

  // maxBuffer: spawn truncates and flags
  const c5 = child_process.spawn("/bin/sh", ["-c", "head -c 200000 /dev/zero"], { maxBuffer: 4096 });
  const w5 = await c5.wait();
  check("spawn truncated flag", c5.truncated === true);
  check("spawn truncated size", c5.stdout.length <= 4096);
  check("spawn truncated exited", w5.signal !== null || w5.code !== null);

  // stdio inherit: no capture
  const c6 = child_process.spawn("/bin/sh", ["-c", "exit 0"], { stdio: "inherit" });
  const w6 = await c6.wait();
  check("inherit exit", w6.code === 0);
  check("inherit no capture", c6.stdout === undefined);

  // execSync
  const s1 = child_process.execSync("printf sync");
  check("execSync stdout", s1.stdout === "sync");
  check("execSync code", s1.code === 0);

  // sequential reuse: slot release + generation guard
  let seqOk = true;
  for (let i = 0; i < 12; i++) {
    const rr = await child_process.exec("true");
    if (rr.code !== 0) { seqOk = false; break; }
  }
  check("sequential slot reuse", seqOk);

  // concurrency cap: 9th throws, 8 run
  const liveKids = [];
  for (let i = 0; i < 8; i++) liveKids.push(child_process.spawn("/bin/sleep", ["30"]));
  let ninthThrew = false;
  try { child_process.spawn("/bin/sleep", ["30"]); } catch { ninthThrew = true; }
  check("ninth child throws", ninthThrew);
  for (const ch of liveKids) ch.kill();
  for (const ch of liveKids) await ch.wait();
} catch (err) {
  // Without this, a rejected top-level await is silent (no unhandled-rejection
  // reporting yet) and the rest of the file would be skipped as a false pass.
  check("unexpected error: " + (err && err.message ? err.message : String(err)), false);
}

done("child-process");
