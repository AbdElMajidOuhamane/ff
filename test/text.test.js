import { check, done } from "./lib.mjs";

const e = new TextEncoder();
const d = new TextDecoder();

check("encoding", e.encoding === "utf-8");
const b = e.encode("héllo");
check("encode length", b.length === 6); // é = 2 bytes
check("decode", d.decode(b) === "héllo");
check("decode empty", d.decode(e.encode("")) === "");
check("multi-byte", d.decode(e.encode("日本語")) === "日本語");

const bad = new Uint8Array([0x68, 0xff, 0x69]); // h, invalid, i
check("lossy decode", d.decode(bad) === "h\uFFFDi");

const big = e.encode("abc".repeat(1000));
check("large round-trip", d.decode(big) === "abc".repeat(1000));

done("text");
