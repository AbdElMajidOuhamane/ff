let pass = 0, fail = 0;
const ok = (label) => { console.log("OK  " + label); pass++; };
const no = (label, got) => { console.log("FAIL " + label + (got !== undefined ? "  got=" + JSON.stringify(got) : "")); fail++; };
const eq = (a, b, label) => { if (a === b) ok(label); else no(label, a + " != " + b); };
const jeq = (a, b, label) => { if (JSON.stringify(a) === JSON.stringify(b)) ok(label); else no(label, JSON.stringify(a) + " != " + JSON.stringify(b)); };

function pigeonhole(label, fn) {
    let threw = false, name = "";
    try { fn(); } catch (e) { threw = true; name = (e && e.name) || ""; }
    eq(threw, true, label);
    return name;
}

function main() {
    // ---- primitives (incl. zero-arg = clone of undefined) ----
    eq(structuredClone(), undefined, "no-arg = undefined");
    eq(structuredClone(42), 42, "number");
    eq(structuredClone("hi"), "hi", "string");
    eq(structuredClone(true), true, "boolean");
    eq(structuredClone(null), null, "null");
    eq(structuredClone(undefined), undefined, "undefined");
    eq(structuredClone(2n ** 64n), 2n ** 64n, "bigint");
    eq(structuredClone(1.5), 1.5, "float");

    // ---- plain objects / arrays / deep non-identity ----
    const src = { a: 1, b: { c: [1, 2, 3], d: "x" }, e: [true, null, 4], f: "", g: 0 };
    const c = structuredClone(src);
    jeq(c, src, "deep object equal");
    eq(c !== src, true, "clone is new object");
    eq(c.b !== src.b, true, "nested object distinct");
    eq(c.b.c !== src.b.c, true, "nested array distinct");
    eq(c.b.c.join(","), "1,2,3", "array contents");

    const arr = [1, [2, 3], { k: 9 }];
    const ca = structuredClone(arr);
    eq(Array.isArray(ca), true, "array clone is array");
    jeq(ca, arr, "array clone equal");
    eq(ca !== arr && ca[1] !== arr[1] && ca[2] !== arr[2], true, "array clone non-identity");

    // ---- identity graph (self + mutual cycles) ----
    const cy = { name: "me" }; cy.self = cy;
    const cc = structuredClone(cy);
    eq(cc !== cy, true, "cycle root distinct");
    eq(cc.self === cc, true, "self cycle preserved");

    const a0 = {}; const b0 = { a: a0 }; a0.b = b0;
    const root = structuredClone(a0);
    eq(root !== a0 && root.b !== b0, true, "mutual cycle roots distinct");
    eq(root.b.a === root, true, "mutual cycle preserved");

    // ---- Date ----
    const d = new Date(1700000000000);
    const cd = structuredClone(d);
    eq(cd instanceof Date, true, "Date instance");
    eq(cd.getTime(), d.getTime(), "Date time");
    eq(cd !== d, true, "Date distinct");

    // ---- Map / Set ----
    const m = new Map([["k", 1], [2, "two"]]);
    const cm = structuredClone(m);
    eq(cm instanceof Map && cm.size === 2, true, "Map size");
    eq(cm.get("k"), 1, "Map string key");
    eq(cm.get(2), "two", "Map number key");

    const s = new Set([1, 2, 3]);
    const cs = structuredClone(s);
    eq(cs instanceof Set && cs.size === 3 && cs.has(2), true, "Set size+membership");

    // ---- RegExp ----
    const re = /ab+c/gi;
    const cre = structuredClone(re);
    eq(cre instanceof RegExp && cre.source === re.source, true, "RegExp clone");

    // ---- ArrayBuffer / typed array copy ----
    const ab = new ArrayBuffer(8);
    new Uint8Array(ab)[0] = 7;
    const cab = structuredClone(ab);
    eq(cab.byteLength, 8, "ArrayBuffer length");
    eq(cab !== ab, true, "ArrayBuffer distinct");
    eq(new Uint8Array(cab)[0], 7, "ArrayBuffer contents");

    const u8 = new Uint8Array([10, 20, 30]);  // standalone copy
    const cu = structuredClone(u8);
    eq(cu instanceof Uint8Array && cu.length === 3, true, "Uint8Array instance+length");
    eq(Array.from(cu).join(","), Array.from(u8).join(","), "Uint8Array bytes");
    eq(cu !== u8 && cu.buffer !== u8.buffer, true, "Uint8Array not shared");

    const view = new Uint8Array(new ArrayBuffer(16), 4, 3);  // view into a bigger buffer
    view.set([7, 8, 9]);
    const cv = structuredClone(view);
    eq(cv.byteLength, 3, "view byteLength preserved");
    eq(cv.byteOffset, 0, "view byteOffset reset to standalone");
    eq(Array.from(cv).join(","), "7,8,9", "view contents copied");
    eq(cv.buffer !== view.buffer, true, "view buffer is fresh copy");

    // ---- options dictionary coercion ----
    const cdict = structuredClone({ a: 1 }, 5);
    eq(cdict.a, 1, "primitive options coerced to empty dict");

    // ---- transfer: move a buffer into the clone + detach source ----
    const t = new ArrayBuffer(4);
    new Uint8Array(t).set([1, 2, 3, 4]);
    const tclone = structuredClone(t, { transfer: [t] });
    eq(tclone.byteLength, 4, "transfer clone length");
    eq(Array.from(new Uint8Array(tclone)).join(","), "1,2,3,4", "transfer clone contents");
    eq(t.byteLength, 0, "source detached after transfer");

    // transfer of a buffer referenced from nested props: same object moves
    const tb = new Uint8Array([5, 6, 7]).buffer;
    const obj0 = { n: 1, b: tb };
    const c0 = structuredClone(obj0, { transfer: [tb] });
    eq(c0 !== obj0 && c0.n === 1, true, "non-transfer props copied");
    eq(c0.b === tb, true, "transferred buffer moved as same object");
    eq(tb.byteLength, 0, "nested transferred source detached");

    // transfer of a buffer NOT referenced by the value: only detached
    const tx = new ArrayBuffer(2);
    const cempty = structuredClone({}, { transfer: [tx] });
    jeq(cempty, {}, "unreferenced transfer leaves empty clone");
    eq(tx.byteLength, 0, "unreferenced transferred source detached");

    // ---- negatives ----
    eq(pigeonhole("function clone throws", () => structuredClone(() => 1)) ,"", "function throws (any error)");
    eq(pigeonhole("symbol clone throws", () => structuredClone(Symbol("x"))), "", "symbol throws (any error)");

    let nm = pigeonhole("duplicate transfer throws", () => {
        const d = new ArrayBuffer(1);
        structuredClone({ _d: d }, { transfer: [d, d] });
    });
    eq(nm, "DataCloneError", "duplicate transfer is DataCloneError");

    nm = pigeonhole("non-ArrayBuffer transfer throws", () => structuredClone({}, { transfer: [{}] }));
    eq(nm, "DataCloneError", "non-ArrayBuffer transfer is DataCloneError");

    nm = pigeonhole("options.transfer non-array throws", () => structuredClone({}, { transfer: {} }));
    eq(nm, "TypeError", "options.transfer non-array is TypeError");

    // ---- summary ----
    console.log("PASS=" + pass + " FAIL=" + fail);
    if (fail === 0) console.log("ALL PASS");
    else console.log("FAILURES: " + fail);
}
main();
