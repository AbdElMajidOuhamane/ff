let pass = 0, fail = 0;
const ok = (label) => { console.log("OK  " + label); pass++; };
const no = (label, got) => { console.log("FAIL " + label + (got !== undefined ? "  got=" + JSON.stringify(got) : "")); fail++; };
const eq = (a, b, label) => { if (a === b) ok(label); else no(label, a + " != " + b); };

const readAll = async (reader) => {
    const out = [];
    for (;;) {
        const r = await reader.read();
        if (r.done) return out;
        out.push(r.value);
    }
};

async function main() {
    const s1 = new ReadableStream({
        start(c) { c.enqueue("a"); c.enqueue("b"); c.close(); },
    });
    const vals1 = await readAll(s1.getReader());
    eq(vals1.join(","), "a,b", "sync source enqueue+close readAll");

    const s2 = new ReadableStream({
        start(c) { c.enqueue("x"); c.close(); },
    });
    const r2 = s2.getReader();
    eq((await r2.read()).value, "x", "close keeps queued chunk");
    eq((await r2.read()).done, true, "read after close done");

    let ctrl;
    const s3 = new ReadableStream({ start(c) { ctrl = c; } });
    const p3 = s3.getReader().read();
    ctrl.enqueue("late");
    eq((await p3).value, "late", "parked read resolved by enqueue");

    let ctrl4;
    const s4 = new ReadableStream({ start(c) { ctrl4 = c; } });
    const p4 = s4.getReader().read();
    ctrl4.close();
    eq((await p4).done, true, "close resolves parked read done");

    let ctrl5;
    const s5 = new ReadableStream({ start(c) { ctrl5 = c; } });
    const p5 = s5.getReader().read();
    ctrl5.error(new Error("boom"));
    try { await p5; no("error rejects parked read"); }
    catch (e) { ok("error rejects parked read"); }

    let ctrl6;
    const s6 = new ReadableStream({ start(c) { ctrl6 = c; } });
    ctrl6.error("kaboom");
    try { await s6.getReader().read(); no("error rejects later read"); }
    catch (e) { ok("error rejects later read"); }

    const resp = new Response("hello stream");
    const rb = resp.body;
    eq(resp.bodyUsed, true, "response body used at access");
    const rv = rb.getReader();
    const rr = await rv.read();
    eq(rr.done, false, "response.body first read not done");
    eq(String.fromCharCode.apply(null, rr.value), "hello stream", "response.body bytes content");
    eq((await rv.read()).done, true, "response.body drained done");

    const bl = new Blob(["stream me"]);
    const br = bl.stream().getReader();
    const bv = await br.read();
    eq(bv.value instanceof Uint8Array, true, "blob.stream chunk is Uint8Array");
    eq(String.fromCharCode.apply(null, bv.value), "stream me", "blob.stream content");
    eq((await br.read()).done, true, "blob.stream done after chunk");

    if (fail === 0) console.log("ALL PASS");
    else console.log("FAILURES: " + fail);
}
main();
