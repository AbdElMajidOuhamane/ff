import { check, done } from "./lib.mjs";

// --- ctor + CRUD ---
const fd = new FormData();
fd.append("a", "1");
fd.append("a", "2");
fd.append("b", "3");
check("size", fd.size() === 3);
check("get-first", fd.get("a") === "1");
check("getAll", JSON.stringify(fd.getAll("a")) === '["1","2"]');
check("has", fd.has("b") === true);
check("missing", fd.get("zzz") === null);
check("has-missing", fd.has("zzz") === false);

fd.set("a", "9");
check("set", fd.get("a") === "9" && fd.getAll("a").length === 1);
fd.delete("b");
check("delete", fd.has("b") === false && fd.size() === 1);

// --- keys/values/entries/forEach ---
const fd2 = new FormData();
fd2.append("x", "1");
fd2.append("y", "2");
check("keys", JSON.stringify(fd2.keys()) === '["x","y"]');
check("values", JSON.stringify(fd2.values()) === '["1","2"]');
check("entries", JSON.stringify(fd2.entries()) === '[["x","1"],["y","2"]]');
let seen = [];
fd2.forEach((v, k) => seen.push(k + "=" + v));
check("forEach", seen.join(",") === "x=1,y=2");

// --- Blob value round-trips as Blob ---
const fdb = new FormData();
fdb.append("file", new Blob(["abc"], { type: "text/plain" }), "a.txt");
const gv = fdb.get("file");
check("blob-val", gv instanceof Blob && (await gv.text()) === "abc");

// --- urlencoded parse via Request ---
const q = new Request("https://x.test/", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: "a=1&b=hello+world&c=%26%3D",
});
const qf = await q.formData();
check("url-a", qf.get("a") === "1");
check("url-plus", qf.get("b") === "hello world");
check("url-pct", qf.get("c") === "&=");

// --- multipart parse via Response ---
const boundary = "----fftest123";
const mp = "--" + boundary + "\r\n" +
    'Content-Disposition: form-data; name="field1"\r\n\r\n' +
    "value1\r\n" +
    "--" + boundary + "\r\n" +
    'Content-Disposition: form-data; name="file1"; filename="hello.txt"\r\n' +
    "Content-Type: text/plain\r\n\r\n" +
    "file-bytes\r\n" +
    "--" + boundary + "--\r\n";
const r = new Response(mp, { headers: { "content-type": "multipart/form-data; boundary=" + boundary } });
const rf = await r.formData();
check("mp-field", rf.get("field1") === "value1");
const mf = rf.get("file1");
check("mp-file", mf instanceof Blob && (await mf.text()) === "file-bytes");

// --- unsupported type rejects ---
let rejected = false;
try {
    await new Response("{}", { headers: { "content-type": "application/json" } }).formData();
} catch (e) { rejected = true; }
check("rejects-json", rejected === true);

done("formdata");
