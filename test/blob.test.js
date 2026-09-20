import { check, done } from "./lib.mjs";

// ctor + snapshot props
const b1 = new Blob(["hello ", "world"], { type: "text/plain;charset=utf-8" });
check("size", b1.size === 11);
check("type-normalized", b1.type === "text/plain");

const b2 = await b1.arrayBuffer();
check("arrayBuffer-len", b2.byteLength === 11);
check("text", (await b1.text()) === "hello world");
check("bytes", (await b1.bytes()) instanceof Uint8Array);

const s = b1.slice(6, 11);
check("slice-text", (await s.text()) === "world");

const empty = new Blob([]);
check("empty-size", empty.size === 0);

// binary part
const bin = new Blob([new Uint8Array([1, 2, 3])]);
check("bin-size", bin.size === 3);

// Response.blob() — content-type sniffed
const r = new Response("hi", { headers: { "content-type": "text/html" } });
const rb = await r.blob();
check("res-blob-type", rb.type === "text/html");
check("res-blob-text", (await rb.text()) === "hi");

// Request.blob()
const q = new Request("https://x.test/", { method: "POST", body: "payload" });
const qb = await q.blob();
check("req-blob-text", (await qb.text()) === "payload");

done("blob");
