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
  .then((h) => {
    let s = "";
    for (const x of new Uint8Array(h)) s += x.toString(16).padStart(2, "0");
    check(
      "sha256 abc",
      s === "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    );
    done("crypto");
  })
  .catch((e) => {
    console.log("digest error:", e);
    check("sha256 abc", false);
    done("crypto");
  });
