let pass = 0, fail = 0;
const ok = (label) => { console.log("OK  " + label); pass++; };
const no = (label, got) => { console.log("FAIL " + label + (got !== undefined ? "  got=" + JSON.stringify(got) : "")); fail++; };
const eq = (a, b, label) => { if (a === b) ok(label); else no(label, a + " != " + b); };

async function main() {
    const b1 = new Blob(["hello"]);
    eq(b1.size, 5, "Blob size");
    eq(b1.type, "", "Blob type empty");
    eq(await b1.text(), "hello", "Blob text");
    eq((await b1.arrayBuffer()).byteLength, 5, "Blob arrayBuffer byteLength");

    const b2 = new Blob([new Uint8Array([104, 105, 116])], { type: "text/plain" });
    eq(b2.size, 3, "Blob Uint8Array part size");
    eq(b2.type, "text/plain", "Blob type from options");
    eq(await b2.text(), "hit", "Blob bytes from Uint8Array");

    const b3 = new Blob(["0123456789"]);
    eq(await b3.slice(2, 5).text(), "234", "Blob slice(2,5)");
    eq(await b3.slice(-4).text(), "6789", "Blob slice(-4)");
    eq(await b3.slice(0, 100).text(), "0123456789", "Blob slice overflow clamp");

    const f = new File(["data"], "x.txt", { lastModified: 123, type: "text/plain" });
    eq(f.name, "x.txt", "File name");
    eq(f.size, 4, "File size");
    eq(f.lastModified, 123, "File lastModified");
    eq(f.type, "text/plain", "File type");

    const fd = new FormData();
    fd.append("a", "1");
    fd.append("a", "2");
    fd.append("b", "x");
    eq(fd.get("a"), "1", "FormData get first");
    eq(fd.get("c"), null, "FormData get missing");
    eq(fd.getAll("a").join(","), "1,2", "FormData getAll");
    eq(fd.has("b"), true, "FormData has");
    eq(fd.has("c"), false, "FormData has missing");
    const names = fd.keys();
    eq(names[0] + "|" + names[1], "a|b", "FormData keys unique order");
    const first = fd.entries()[0];
    eq(first[0] + "=" + first[1], "a=1", "FormData entries first");
    fd.set("a", "9");
    fd.delete("b");
    eq(fd.get("a"), "9", "FormData set replaces");
    eq(fd.getAll("a").join(","), "9", "FormData set drops extra");
    eq(fd.has("b"), false, "FormData delete");

    const r1 = await fetch("http://httpbingo.org/bytes/100");
    eq(r1.ok, true, "bytes fetch ok");
    const bl = await r1.blob();
    eq(bl.size, 100, "response.blob size");
    eq(bl.type, "application/octet-stream", "response.blob type from header");

    const r2 = await fetch("http://httpbingo.org/bytes/16");
    eq(r2.bytes() instanceof Promise, true, "bytes returns Promise");
    const bs = await r2.bytes();
    eq(bs instanceof Uint8Array, true, "bytes resolves Uint8Array");
    eq(bs.length, 16, "bytes length");

    const bnd = "xyz123";
    const mp = "--" + bnd + "\r\n" +
        "Content-Disposition: form-data; name=\"foo\"\r\n\r\n" +
        "bar\r\n" +
        "--" + bnd + "\r\n" +
        "Content-Disposition: form-data; name=\"up\"; filename=\"note.txt\"\r\n\r\n" +
        "file-content\r\n" +
        "--" + bnd + "--\r\n";
    const r3 = new Response(mp, { headers: { "content-type": "multipart/form-data; boundary=" + bnd } });
    const fdm = await r3.formData();
    eq(fdm.get("foo"), "bar", "formData multipart field");
    eq(fdm.get("up"), "note.txt", "formData multipart file (filename subset)");

    const r4 = new Response("a=1&b=hello+world", { headers: { "content-type": "application/x-www-form-urlencoded" } });
    const fdu = await r4.formData();
    eq(fdu.get("a"), "1", "formData urlencoded field");
    eq(fdu.get("b"), "hello world", "formData urlencoded decode plus");

    const r5 = new Response("plain", { headers: { "content-type": "text/plain" } });
    const rej = r5.formData();
    try {
        await rej;
        no("formData rejects on unsupported type");
    } catch (e) { ok("formData rejects on unsupported type"); }

    const bresp = new Response("hello blob", { headers: { "content-type": "text/plain" } });
    eq((await bresp.blob()).type, "text/plain", "new Response blob type");
    eq(await (await bresp.blob()).text(), "hello blob", "new Response blob text");

    if (fail === 0) console.log("ALL PASS");
    else console.log("FAILURES: " + fail);
}
main();
