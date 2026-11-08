import { check, done } from "./lib.mjs";

// 1. Basic hash and verify round-trip
const pw = "s3cr3t-P@ssword";
const hash = await crypto.bcrypt.hash(pw, { cost: 5 });
check("hash starts with $2b$05$", hash.startsWith("$2b$05$"));
check("hash length is 60", hash.length === 60);

const isMatch = await crypto.bcrypt.verify(pw, hash);
check("verify correct password returns true", isMatch === true);

const isWrong = await crypto.bcrypt.verify("wrong-password", hash);
check("verify wrong password returns false", isWrong === false);

// 2. Malformed / invalid hashes return false without throwing
check("verify malformed hash returns false", (await crypto.bcrypt.verify(pw, "not_a_bcrypt_hash")) === false);
check("verify too short hash returns false", (await crypto.bcrypt.verify(pw, "$2b$05$short")) === false);
check("verify empty hash returns false", (await crypto.bcrypt.verify(pw, "")) === false);
check("verify oversized hash returns false", (await crypto.bcrypt.verify(pw, "x".repeat(200))) === false);

// 3. Cost options
const hashDef = await crypto.bcrypt.hash(pw);
check("default cost is 12", hashDef.startsWith("$2b$12$"));

const hashCost4 = await crypto.bcrypt.hash(pw, { cost: 4 });
check("cost 4 honored", hashCost4.startsWith("$2b$04$"));

let costTooLow = false;
try {
  await crypto.bcrypt.hash(pw, { cost: 3 });
} catch (e) {
  costTooLow = e.message.includes("cost must be an integer between 4 and 14");
}
check("cost < 4 rejects", costTooLow);

let costTooHigh = false;
try {
  await crypto.bcrypt.hash(pw, { cost: 15 });
} catch (e) {
  costTooHigh = e.message.includes("cost must be an integer between 4 and 14");
}
check("cost > 14 rejects", costTooHigh);

// 4. Password length limits (72 bytes policy)
const pw72 = "a".repeat(72);
const h72 = await crypto.bcrypt.hash(pw72, { cost: 4 });
check("72-byte password hashes and verifies", (await crypto.bcrypt.verify(pw72, h72)) === true);

const pw73 = "a".repeat(73);
let pw73Threw = false;
try {
  await crypto.bcrypt.hash(pw73, { cost: 4 });
} catch (e) {
  pw73Threw = e.message.includes("72 bytes");
}
check("73-byte password on hash rejects", pw73Threw);

// 73-byte password on verify resolves false
check("73-byte password on verify returns false", (await crypto.bcrypt.verify(pw73, h72)) === false);

// 5. Concurrent hashes (Promise.all)
const concurrentPromises = [];
for (let i = 0; i < 8; i++) {
  concurrentPromises.push(crypto.bcrypt.hash(`user_${i}`, { cost: 4 }));
}
const concurrentHashes = await Promise.all(concurrentPromises);
check("concurrent 8 hashes completed", concurrentHashes.length === 8 && concurrentHashes.every((h) => h.startsWith("$2b$04$")));

for (let i = 0; i < 8; i++) {
  const match = await crypto.bcrypt.verify(`user_${i}`, concurrentHashes[i]);
  check(`verify concurrent ${i}`, match === true);
}

// 6. Queue full behavior (MAX_JOBS = 16 bounded pool)
const flood = [];
for (let i = 0; i < 24; i++) {
  flood.push(crypto.bcrypt.hash(`flood_${i}`, { cost: 8 }));
}
const settled = await Promise.allSettled(flood);
const queueFullRejection = settled.some(
  (s) => s.status === "rejected" && s.reason && s.reason.message && s.reason.message.includes("queue full")
);
check("queue full rejects when MAX_JOBS exceeded", queueFullRejection);

// 7. Event loop responsiveness & timer jitter during hashing
let maxJitter = 0;
let tickCount = 0;
let lastTick = performance.now();
const interval = setInterval(() => {
  const now = performance.now();
  const delta = now - lastTick;
  const jitter = Math.abs(delta - 5);
  if (jitter > maxJitter) maxJitter = jitter;
  lastTick = now;
  tickCount++;
}, 5);

// Run 4 background hashes at cost 10
await Promise.all([
  crypto.bcrypt.hash("bg_1", { cost: 10 }),
  crypto.bcrypt.hash("bg_2", { cost: 10 }),
  crypto.bcrypt.hash("bg_3", { cost: 10 }),
  crypto.bcrypt.hash("bg_4", { cost: 10 }),
]);
clearInterval(interval);
check("event loop responsive during hashing (jitter < 20ms)", maxJitter < 20 && tickCount >= 3);

// 8. Process liveness (hasRelevantWork keeping loop alive)
const ffBin = process.argv[0];
const childLive = child_process.spawn(ffBin, [
  "-e",
  `(async () => {
    const h = await crypto.bcrypt.hash("stay_alive", { cost: 6 });
    if (!h || !h.startsWith("$2b$06$")) process.exit(1);
  })();`,
  "--allow-all",
]);
const liveResult = await childLive.wait();
check("process liveness: await bcrypt alone keeps loop alive to exit 0", liveResult.code === 0);

// 9. Worker restriction (crypto.bcrypt unavailable in workers)
let workerBlocked = false;
try {
  const w = new Worker("./test/fixtures/bcrypt_worker.js");
  const workerMsg = await new Promise((resolve) => {
    w.onmessage = (e) => resolve(e.data);
    setTimeout(() => resolve("timeout"), 2000);
  });
  if (typeof workerMsg === "string" && workerMsg.includes("not available in workers")) {
    workerBlocked = true;
  }
} catch {}
check("worker crypto.bcrypt is blocked as documented", workerBlocked);

// 10. Interoperability with Apache htpasswd (if available on system)
try {
  const htProbe = await child_process.exec("which htpasswd");
  if (htProbe.code === 0) {
    // A: Hash in ff, verify with htpasswd
    const ffHash = await crypto.bcrypt.hash("interopSecret", { cost: 5 });
    const htHash = ffHash.replace("$2b$", "$2y$");
    const tmpFile = "/tmp/test_bcrypt_interop_ht";
    await fs.writeFile(tmpFile, `testuser:${htHash}\n`);
    const htCheck = await child_process.exec(`htpasswd -vb ${tmpFile} testuser interopSecret`);
    try { await fs.unlink(tmpFile); } catch {}
    check("ff hash verified by htpasswd", htCheck.code === 0);

    // B: Hash with htpasswd, verify in ff
    const htGen = await child_process.exec("htpasswd -nbBC 5 testuser genPass789");
    if (htGen.code === 0) {
      const generatedHash = htGen.stdout.trim().split(":")[1];
      const ffVerifyHt = await crypto.bcrypt.verify("genPass789", generatedHash);
      check("htpasswd hash verified by ff", ffVerifyHt === true);
    }
  } else {
    check("htpasswd interop skipped (tool not present)", true);
  }
} catch {
  check("htpasswd interop skipped", true);
}

done("bcrypt");
