import { check, done } from "./lib.mjs";

check(
  "uuid format",
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(
    crypto.randomUUID(),
  ),
);

const arr = new Uint8Array(8);
crypto.getRandomValues(arr);
check(
  "getRandomValues fills",
  arr.some((x) => x !== 0),
);

let cap_threw = false;
try {
  crypto.getRandomValues(new Uint8Array(65537));
} catch {
  cap_threw = true;
}
check("getRandomValues 65536 cap", cap_threw);

check("btoa", btoa("hello") === "aGVsbG8=");
check("atob", atob("aGVsbG8=") === "hello");

let atob_threw = false;
try {
  atob("!!!not base64!!!");
} catch {
  atob_threw = true;
}
check("atob invalid", atob_threw);

// NOTE: no async/await here — the vendored quickjs (2024-01-13) has known
// GC/coroutine UAFs (upstream quickjs-ng #1569, #1570). .then chains are
// safe; coroutine-based test bodies return after the vendor upgrade.
crypto.subtle
  .digest("SHA-256", new TextEncoder().encode("abc"))
  .then(async (h) => {
    let s = "";
    for (const x of new Uint8Array(h)) s += x.toString(16).padStart(2, "0");
    check(
      "sha256 abc",
      s === "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    );

    // Object algorithm descriptor for digest
    const hObj = await crypto.subtle.digest(
      { name: "SHA-256" },
      new TextEncoder().encode("abc"),
    );
    check("digest { name: SHA-256 }", hObj.byteLength === 32);

    // RFC 4231 Test Case 2: key = "Jefe", data = "what do ya want for nothing?"
    const enc = new TextEncoder();
    const key = await crypto.subtle.importKey(
      "raw",
      enc.encode("Jefe"),
      { name: "HMAC", hash: { name: "SHA-256" } },
      true,
      ["sign", "verify"],
    );
    check("CryptoKey properties", key.type === "secret" && key.extractable === true && key.algorithm.name === "HMAC" && key.algorithm.hash.name === "SHA-256");

    const data = enc.encode("what do ya want for nothing?");
    const sig = await crypto.subtle.sign("HMAC", key, data);
    let sigHex = "";
    for (const b of new Uint8Array(sig)) sigHex += b.toString(16).padStart(2, "0");
    check(
      "HMAC-SHA256 RFC 4231 vector",
      sigHex === "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
    );

    const valid = await crypto.subtle.verify({ name: "HMAC" }, key, sig, data);
    check("HMAC-SHA256 verify valid", valid === true);

    const invalid = await crypto.subtle.verify("HMAC", key, sig, enc.encode("tampered"));
    check("HMAC-SHA256 verify tampered", invalid === false);

    const raw = await crypto.subtle.exportKey("raw", key);
    check("HMAC exportKey raw", new TextDecoder().decode(raw) === "Jefe");

    // Non-extractable key must reject exportKey
    const lockedKey = await crypto.subtle.importKey(
      "raw",
      enc.encode("secret"),
      { name: "HMAC", hash: "SHA-512" },
      false,
      ["sign"],
    );
    let exportRejected = false;
    try {
      await crypto.subtle.exportKey("raw", lockedKey);
    } catch {
      exportRejected = true;
    }
    check("non-extractable key rejects exportKey", exportRejected);

    let verifyRejected = false;
    try {
      const sig512 = await crypto.subtle.sign("HMAC", lockedKey, data);
      check("HMAC-SHA512 length 64", sig512.byteLength === 64);
      await crypto.subtle.verify("HMAC", lockedKey, sig512, data);
    } catch {
      verifyRejected = true;
    }
    check("sign-only key rejects verify", verifyRejected);

    done("crypto");
  })
  .catch((e) => {
    console.log("crypto error:", e);
    check("sha256 abc", false);
    done("crypto");
  });
