// p2d.js — isolate the TextEncoder/TextDecoder round-trip failure
const enc = new TextEncoder();
const dec = new TextDecoder();
const hex = (a) => [...a].map(b => b.toString(16).padStart(2, "0")).join(" ");

const ref = dec.decode(new Uint8Array([104, 101, 108, 108, 111]));
console.log("A ref decode fresh bytes:", hex(ref), "len=", ref.length, "eq=", ref === "hello");

const e = enc.encode("hello");
console.log("B encode bytes:           ", hex(e), "len=", e.length, "byteLen=", e.byteLength, "byteOff=", e.byteOffset);

const s1 = dec.decode(e);
console.log("C decode(encode) hello:   ", hex(s1), "len=", s1.length, "eq=", s1 === "hello");

const s2 = dec.decode(new Uint8Array(e));
console.log("D decode(copy) hello:     ", hex(s2), "len=", s2.length, "eq=", s2 === "hello");

console.log("E emoji:", dec.decode(enc.encode("\u{1F600}")) === "\u{1F600}", " hi:", dec.decode(enc.encode("hi")) === "hi");
