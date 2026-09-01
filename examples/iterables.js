// P1 #8 iterables — for..of / spread over host collection objects.
let pass = 0, fail = 0;
const ok = (label) => { console.log("OK  " + label); pass++; };
const no = (label, got) => { console.log("FAIL " + label + (got !== undefined ? "  got=" + JSON.stringify(got) : "")); fail++; };
const eq = (a, b, label) => { if (a === b) ok(label); else no(label, a + " != " + b); };

function main() {
    // FormData
    const fd = new FormData();
    fd.append("a", "1");
    fd.append("a", "2");
    fd.append("b", "x");
    let s = "";
    for (const [k, v] of fd) s += k + "=" + v + ";";
    eq(s, "a=1;a=2;b=x;", "FormData for..of yields [name,value]");
    eq([...fd].length, 3, "FormData spread length");
    const first = fd.entries()[0];
    eq(first[0] + "=" + first[1], "a=1", "FormData entries() still an array");

    let e = "";
    for (const [k] of fd) { e += k; break; }
    eq(e, "a", "FormData early break");

    let nested = "";
    for (const [k1] of fd) for (const [k2] of fd) { nested += k1 + k2; }
    eq(nested, "aaaaabaaaaabbababb", "FormData nested concurrent iterators");

    // iterator protocol
    const it = fd[Symbol.iterator]();
    eq(typeof it.next, "function", "iterator has next");
    const r0 = it.next();
    eq(r0.done, false, "next first not done");
    eq(JSON.stringify(r0.value), '["a","1"]', "next first value");
    it.next(); it.next();
    eq(it.next().done, true, "next done at end");
    eq(it.next().done, true, "next stays done");

    // Headers
    const h = new Headers();
    h.append("content-type", "text/plain");
    h.append("x-one", "1");
    s = "";
    for (const [k, v] of h) s += k + "=" + v + ";";
    eq(s, "content-type=text/plain;x-one=1;", "Headers for..of");
    eq(h.entries()[0][0], "content-type", "Headers entries()[0]");

    // URLSearchParams (standalone)
    const sp = new URLSearchParams("x=1&x=2&y=z");
    s = "";
    for (const [k, v] of sp) s += k + ":" + v + " ";
    eq(s, "x:1 x:2 y:z ", "URLSearchParams for..of");
    eq(JSON.stringify(sp.entries()[0]), '["x","1"]', "URLSearchParams entries()[0]");

    // URL.searchParams
    const u = new URL("https://example.com/p?q=1&r=2");
    s = "";
    for (const [k, v] of u.searchParams) s += k + "=" + v + ";";
    eq(s, "q=1;r=2;", "URL.searchParams for..of");

    if (fail === 0) console.log("ALL PASS");
    else console.log("FAILURES: " + fail);
}
main();
