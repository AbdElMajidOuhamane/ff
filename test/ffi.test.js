export {};
// ── ffi.test.js — the FFI behavior contract ──────────────────────────
// Phase 1:  dlopen, scalars, buffers, cstrings, pointers, lifecycle.
// Phase 2a: memory read/write/copyBytes/writeBytes, FfiPtr view getters,
//           struct-by-value (layout, returns via libc div/ldiv, and
//           parameters via the test/fixtures C fixture).
// Nested:   struct-in-struct layout, depth cap, nested round-trip.
// Phase 2b: JS→C callbacks (§10), nonblocking + cross-thread bridge (§11).
// Phase 2c: unions (§12).
//
// Run:   ff test --allow-ffi    (or: ff test/ffi.test.js --allow-ffi)
// Without the flag the file logs a skip and passes. The fixture contract
// (§8, §10–§12) is test/fixtures/addon_probe.c, built once:
//   cd test/fixtures && ./build.sh
// With --allow-ffi a missing fixture or missing probe is a hard failure,
// never a silent skip.

function assert(cond, msg) {
  if (!cond) throw new Error("ffi test: " + msg);
}

const enc = new TextEncoder();

function openLib(symbols) {
  const candidates = [
    "libSystem.B.dylib",
    "/usr/lib/libSystem.B.dylib",
    "libc.so.6",
    "libc.so",
    "libm.so.6",
  ];
  for (const name of candidates) {
    try {
      return { lib: ffi.dlopen(name, symbols), name };
    } catch (e) {}
  }
  return null;
}

function openFixture(symbols) {
  const FIXTURES = [
    "test/fixtures/libaddon_probe.dylib",
    "../test/fixtures/libaddon_probe.dylib",
    "test/fixtures/libaddon_probe.so",
    "../test/fixtures/libaddon_probe.so",
  ];
  for (const name of FIXTURES) {
    try {
      return ffi.dlopen(name, symbols);
    } catch (e) {}
  }
  return null;
}

if (typeof globalThis.ffi === "undefined" || !ffi.allowed) {
  console.log("ffi.test.js: skipped (needs --allow-ffi)");
} else {
  // ══ 1. Library, symbols, lifecycle ══
  const S = {
    abs:    { parameters: ["i32"], result: "i32" },
    strlen: { parameters: ["cstring"], result: "usize" },
    strcmp: { parameters: ["cstring", "cstring"], result: "i32" },
    memcpy: { parameters: ["buffer", "buffer", "usize"], result: "pointer" },
    strdup: { parameters: ["cstring"], result: "pointer" },
    free:   { parameters: ["pointer"], result: "void" },
    getpid: { parameters: [], result: "i32" },
    div:    { parameters: ["i32", "i32"], result: { struct: [["quot", "i32"], ["rem", "i32"]] } },
    ldiv:   { parameters: ["isize", "isize"], result: { struct: [["quot", "isize"], ["rem", "isize"]] } },
    probe_absent: { parameters: [], result: "void", optional: true },
  };
  const opened = openLib(S);
  if (opened == null) throw new Error("ffi test: no system C library found");
  const s = opened.lib.symbols;

  assert(s.probe_absent === null, "optional missing symbol is null");
  assert(s.abs(-42) === 42, "i32 in/out");
  assert(s.strlen("hello") === 5n, "cstring arg + usize→BigInt result");
  assert(s.strcmp("a", "a") === 0 && s.strcmp("a", "b") !== 0, "two cstring args");
  assert(typeof s.getpid() === "number" && s.getpid() > 0, "no-arg call");

  // buffer round-trip (memcpy writes through the Uint8Array)
  const dst = new Uint8Array(4);
  const back = s.memcpy(dst, new Uint8Array([1, 2, 3, 4]), 3n);
  assert(dst[0] === 1 && dst[1] === 2 && dst[2] === 3 && dst[3] === 0, "buffer write-back");
  assert(!ffi.isNull(back), "buffer result → pointer");

  // pointer + native string: strdup → read → free
  const dup = s.strdup("hello");
  assert(!ffi.isNull(dup) && ffi.cstring(dup) === "hello", "pointer + ffi.cstring");
  assert(ffi.cstring(enc.encode("hi\0")) === "hi", "ffi.cstring from buffer");
  s.free(dup);

  // lifecycle / error paths
  let threw = false;
  try { s.abs(); } catch (e) { threw = true; }
  assert(threw, "too few arguments throws");

  threw = false;
  try { ffi.dlopen(opened.name, { definitely_missing_xyz: { parameters: [], result: "void" } }); } catch (e) { threw = true; }
  assert(threw, "missing non-optional symbol throws at dlopen");

  threw = false;
  try { ffi.dlopen("no_such_lib_ffi_test.dylib", {}); } catch (e) { threw = true; }
  assert(threw, "missing library throws");

  const lib2 = ffi.dlopen(opened.name, { abs: { parameters: ["i32"], result: "i32" } });
  lib2.close();
  threw = false;
  try { lib2.symbols.abs(1); } catch (e) { threw = true; }
  assert(threw, "call after close throws");
  lib2.close(); // idempotent

  // ══ 2. Narrow ints truncate silently (Deno rule); 64-bit = BigInt ══
  assert(s.abs(0x100000005) === 5, "i32 param truncates (0x100000005 → 5)");
  const lib3 = ffi.dlopen(opened.name, {
    labs:  { parameters: ["isize"], result: "isize" },
    llabs: { parameters: ["i64"], result: "i64" },
  });
  assert(lib3.symbols.labs(-5n) === 5n, "isize accepts BigInt");
  assert(lib3.symbols.llabs(-9007199254740993n) === 9007199254740993n, "i64 BigInt round-trip");
  lib3.close();

  // ══ 3. Memory read/write (phase 2a) — our own buffer, no native code ══
  const mem = new Uint8Array(64);
  const p = ffi.ptr(mem);
  assert(p.addr > 0n, "ffi.ptr address");

  ffi.write(p, "u32", 0xdeadbeef, 0);
  assert(ffi.read(p, "u32", 0) === 0xdeadbeef, "u32 round-trip");
  ffi.write(p, "i32", -7, 4);
  assert(ffi.read(p, "i32", 4) === -7, "i32 round-trip");
  ffi.write(p, "u8", 300, 8);
  assert(ffi.read(p, "u8", 8) === 44, "u8 truncates 300 → 44");
  ffi.write(p, "i64", 2n ** 63n - 1n, 16);
  assert(ffi.read(p, "i64", 16) === 2n ** 63n - 1n, "i64 round-trip");
  ffi.write(p, "u64", 2n ** 64n - 1n, 24);
  assert(ffi.read(p, "u64", 24) === 2n ** 64n - 1n, "u64 round-trip");
  ffi.write(p, "f64", 3.5, 32);
  assert(ffi.read(p, "f64", 32) === 3.5, "f64 round-trip");
  ffi.write(p, "f32", 1.25, 40);
  assert(ffi.read(p, "f32", 40) === 1.25, "f32 round-trip");
  ffi.write(p, "pointer", p, 48);
  assert(ffi.read(p, "pointer", 48).addr === p.addr, "pointer slot round-trip");

  // writeBytes / copyBytes
  const scratch = new Uint8Array(16);
  const ps = ffi.ptr(scratch);
  ffi.writeBytes(ps, new Uint8Array([9, 8, 7, 6]));
  const ab = ffi.copyBytes(ps, 4);
  assert(ab instanceof ArrayBuffer, "copyBytes → ArrayBuffer");
  assert(new Uint8Array(ab).join(",") === "9,8,7,6", "writeBytes/copyBytes round-trip");
  assert(new Uint8Array(ffi.copyBytes(ffi.ptr(ps, 2), 2)).join(",") === "7,6", "copyBytes honors offsets");

  // ══ 4. View getters (phase 2a) ══
  const v = ffi.view(p);
  assert(v.addr === p.addr, "ffi.view normalizes to a pointer");
  assert(v.getUint32(0) === 0xdeadbeef, "getUint32");
  assert(v.getInt32(4) === -7, "getInt32");
  assert(v.getUint8(8) === 44, "getUint8");
  assert(v.getBigInt64(16) === 2n ** 63n - 1n, "getBigInt64");
  assert(v.getBigUint64(24) === 2n ** 64n - 1n, "getBigUint64");
  assert(v.getFloat64(32) === 3.5, "getFloat64");
  assert(v.getFloat32(40) === 1.25, "getFloat32");
  assert(v.getPointer(48).addr === p.addr, "getPointer");
  ffi.writeBytes(ffi.ptr(p, 56), enc.encode("hi\0"));
  assert(v.getCString(56) === "hi", "getCString");
  assert(new Uint8Array(v.getArrayBuffer(3, 56)).join(",") === "104,105,0", "getArrayBuffer");
  const sink = new Uint8Array(3);
  v.copyInto(sink, 56);
  assert(sink.join(",") === "104,105,0", "copyInto");

  // memory error paths
  threw = false;
  try { ffi.read(p, "void"); } catch (e) { threw = true; }
  assert(threw, "read rejects void");
  threw = false;
  try { ffi.read(42, "i32"); } catch (e) { threw = true; }
  assert(threw, "read rejects a bare number as pointer");
  threw = false;
  try { ffi.read(p, "no_such_type"); } catch (e) { threw = true; }
  assert(threw, "unknown type name throws");
  threw = false;
  try { v.getInt32(-1); } catch (e) { threw = true; }
  assert(threw, "negative offset throws");
  threw = false;
  try { ffi.copyBytes(p, -1); } catch (e) { threw = true; }
  assert(threw, "negative length throws");

  // ══ 5. Struct layout (pure JS — C padding rules) ══
  const DivT = ffi.struct([["quot", "i32"], ["rem", "i32"]]);
  assert(DivT.size === 8 && DivT.offsets.quot === 0 && DivT.offsets.rem === 4, "div_t layout");
  const Blob = ffi.struct([["ptr", "pointer"], ["len", "i32"]]);
  assert(Blob.size === 16 && Blob.offsets.ptr === 0 && Blob.offsets.len === 8, "pointer+i32 pads to 16");
  const Mix = ffi.struct([["a", "u8"], ["b", "u32"]]);
  assert(Mix.size === 8 && Mix.offsets.b === 4, "u8+u32 padding");
  const TypeOnly = ffi.struct(["u8", "u64"]);
  assert(TypeOnly.size === 16 && TypeOnly.offsets.f0 === 0 && TypeOnly.offsets.f1 === 8, "Deno type-only form");
  const Wide = ffi.struct([["a", "i8"], ["b", "i64"]]);
  assert(Wide.size === 16 && Wide.offsets.b === 8, "i8+i64 aligns to 8");

  // ══ 6. Struct-by-value returns: div/ldiv (system libc) ══
  const t = s.div(7, 2);
  assert(t instanceof Uint8Array && t.byteLength === DivT.size, "div_t result is a sized Uint8Array");
  let tp = ffi.ptr(t);
  assert(ffi.read(tp, "i32", 0) === 3 && ffi.read(tp, "i32", 4) === 1, "div(7,2) → {3,1}");
  tp = ffi.ptr(s.div(-7, 2));
  assert(ffi.read(tp, "i32", 0) === -3 && ffi.read(tp, "i32", 4) === -1, "div(-7,2) → {-3,-1}");
  const ld = s.ldiv(7n, 2n);
  assert(ld.byteLength === 16, "ldiv_t is 16 bytes");
  const lp = ffi.ptr(ld);
  assert(ffi.read(lp, "isize", 0) === 3n && ffi.read(lp, "isize", 8) === 1n, "ldiv(7,2) → {3,1}");

  // named FfiStruct as a result spec (clone path)
  const lib4 = ffi.dlopen(opened.name, { div: { parameters: ["i32", "i32"], result: DivT } });
  assert(ffi.read(ffi.ptr(lib4.symbols.div(7, 2)), "i32", 4) === 1, "named FfiStruct as result spec");
  lib4.close();

  // ══ 7. Struct spec errors (message text checked — Patch A) ══
  let emsg = "";
  try { ffi.struct("nope"); } catch (e) { emsg = String(e && e.message ? e.message : e); }
  assert(emsg.indexOf("must be an array") !== -1, "ffi.struct rejects non-array");
  emsg = "";
  try { ffi.struct([["a", "nope"]]); } catch (e) { emsg = String(e && e.message ? e.message : e); }
  assert(emsg.indexOf("unknown type") !== -1, "unknown field type: clean TypeError");
  emsg = "";
  try { ffi.struct([["a", "void"]]); } catch (e) { emsg = String(e && e.message ? e.message : e); }
  assert(emsg.indexOf("must be scalar") !== -1, "void field: clean TypeError");
  emsg = "";
  try { ffi.struct(new Array(70).fill(["x", "u64"])); } catch (e) { emsg = String(e && e.message ? e.message : e); }
  assert(emsg.indexOf("field count") !== -1, "70 fields: clean TypeError (64-field cap)");
  const edge = ffi.struct(new Array(64).fill(["x", "u64"]));
  assert(edge.size === 512, "64 x u64 = 512 bytes passes (MAX_STRUCT boundary)");

  // ══ 8. Struct parameters (needs the C fixture) ══
  // Inner/Outer live here (not §9): the fixture table below references
  // Outer, and const TDZ forbids use-before-declaration.
  const Inner = ffi.struct([["x", "i32"], ["y", "i32"]]);
  const Outer = ffi.struct([["id", "i32"], ["inner", Inner]]);
  const FIXTURES = [
    "test/fixtures/libaddon_probe.dylib",
    "../test/fixtures/libaddon_probe.dylib",
    "test/fixtures/libaddon_probe.so",
    "../test/fixtures/libaddon_probe.so",
  ];
  let fx = null;
  for (const name of FIXTURES) {
    try {
      fx = ffi.dlopen(name, {
        probe_add_blob: { parameters: [Blob], result: Blob },
        probe_make_blob: { parameters: [], result: Blob },
        probe_sizeof_blob: { parameters: [], result: "u32" },
        probe_offsetof_len: { parameters: [], result: "u32" },
        probe_nested: { parameters: [Outer], result: Outer, optional: true },
      });
      break;
    } catch (e) {}
  }
  if (fx === null) throw new Error("ffi test: fixture not built — run: cd test/fixtures && ./build.sh");
  {
    // struct-by-value in both directions: pointer passes through, len doubles
    const payload = enc.encode("abcd");
    const img = new Uint8Array(Blob.size);
    const ip = ffi.view(img);
    ffi.write(ip, "pointer", ffi.ptr(payload), 0);
    ffi.write(ip, "i32", payload.byteLength, 8);
    const out = fx.symbols.probe_add_blob(img);
    const op = ffi.view(out);
    assert(ffi.read(op, "pointer", 0).addr === ffi.ptr(payload).addr, "struct param: pointer passes through");
    assert(ffi.read(op, "i32", 8) === 8, "struct param: len doubled");

    // struct result with no parameter — points at static fixture data
    const mb = fx.symbols.probe_make_blob();
    const mv = ffi.view(mb);
    assert(ffi.cstring(mv.getPointer(0)) === "addon-probe", "struct result: static string");
    assert(mv.getInt32(8) === 11, "struct result: length");

    // layout oracle: ffi.struct's hand-computed math vs the C compiler
    assert(fx.symbols.probe_sizeof_blob() === Blob.size, "oracle: sizeof matches Blob.size");
    assert(fx.symbols.probe_offsetof_len() === Blob.offsets.len, "oracle: offsetof(len) matches");

    // undersized image must be rejected before ffi_call
    threw = false;
    try { fx.symbols.probe_add_blob(new Uint8Array(4)); } catch (e) { threw = true; }
    assert(threw, "undersized struct image throws");

    // nested struct round-trip (fixture must have probe_nested)
    if (fx.symbols.probe_nested == null) throw new Error("ffi test: fixture predates probe_nested — rebuild: cd test/fixtures && ./build.sh");
    {
      const oimg = new Uint8Array(Outer.size);
      const ov = ffi.view(oimg);
      ffi.write(ov, "i32", 1, Outer.offsets.id);
      ffi.write(ov, "i32", 2, Outer.offsets.inner + Inner.offsets.x);
      ffi.write(ov, "i32", 3, Outer.offsets.inner + Inner.offsets.y);
      const oret = fx.symbols.probe_nested(oimg);
      const orv = ffi.view(oret);
      assert(ffi.read(orv, "i32", 0) === 2, "nested param: id+1");
      assert(ffi.read(orv, "i32", 4) === 12, "nested param: x+10");
      assert(ffi.read(orv, "i32", 8) === 103, "nested param: y+100");
    }
    fx.close();
  }

  // ══ 9. Nested structs (phase 2b) ══
  // Images stay flat: nested fields are bytes at parent.offsets.
  assert(Inner.size === 8, "Inner size");
  assert(Outer.size === 12, "Outer size (4 + 8)");
  assert(Outer.offsets.id === 0 && Outer.offsets.inner === 4, "Outer offsets");
  const Pad = ffi.struct([["a", "u8"], ["inner", Inner]]);
  assert(Pad.size === 12 && Pad.offsets.inner === 4, "padded nested field");
  const Deep3 = ffi.struct([["o", Outer]]);
  assert(Deep3.size === 12 && Deep3.offsets.o === 0, "nested-in-nested size");
  const MixN = ffi.struct(["i8", Inner]);
  assert(MixN.size === 12 && MixN.offsets.f0 === 0 && MixN.offsets.f1 === 4, "type-only list with nested spec");

  // nested error paths
  emsg = "";
  try { ffi.struct([["n", { struct: [["a", "void"]] }]]); } catch (e) { emsg = String(e && e.message ? e.message : e); }
  assert(emsg.indexOf("must be scalar") !== -1, "void nested field: clean TypeError");
  emsg = "";
  try {
    let deep = [["x", "i32"]];
    for (let i = 0; i < 10; i++) deep = [["n", { struct: deep }]];
    ffi.struct(deep);
  } catch (e) { emsg = String(e && e.message ? e.message : e); }
  assert(emsg.indexOf("too deep") !== -1, "depth cap: clean TypeError");
  emsg = "";
  try { ffi.struct(new Array(40).fill(["b", Blob])); } catch (e) { emsg = String(e && e.message ? e.message : e); }
  assert(emsg.indexOf("exceeds") !== -1, "nested oversize: clean TypeError");

  // ══ 10. JS→C callbacks (P2b.1) ══
  const cbFx = openFixture({
    probe_apply: { parameters: ["function", "i32", "i32"], result: "i32", optional: true },
  });
  if (cbFx === null || cbFx.symbols.probe_apply == null) throw new Error("ffi test: §10 needs probe_apply — rebuild the fixture: cd test/fixtures && ./build.sh");
  {
    const add = ffi.callback({ parameters: ["i32", "i32"], result: "i32" }, (a, b) => a + b);
    assert(add.pointer.addr > 0n, "callback exposes a pointer");
    assert(cbFx.symbols.probe_apply(add.pointer, 3, 4) === 7, "callback round-trip (3+4=7)");

    const boom = ffi.callback({ parameters: ["i32", "i32"], result: "i32" }, () => {
      throw new Error("cb-boom");
    });
    emsg = "";
    try { cbFx.symbols.probe_apply(boom.pointer, 1, 2); } catch (e) { emsg = String(e && e.message ? e.message : e); }
    assert(emsg.indexOf("cb-boom") !== -1, "callback throw rethrows to caller");

    add.close();
    assert(cbFx.symbols.probe_apply(add.pointer, 1, 2) === -1, "closed callback passes null");
    boom.close();

    emsg = "";
    try { ffi.callback({ parameters: ["void"], result: "void" }, () => {}); } catch (e) { emsg = String(e && e.message ? e.message : e); }
    assert(emsg.length > 0, "void param rejected at creation");
    cbFx.close();
  }

  // ══ 11. Nonblocking + cross-thread bridge (P2b.2/P2b.3) ══
  const nbFx = openFixture({
    probe_sleep_ms: { parameters: ["i32"], result: "void", nonblocking: true, optional: true },
    probe_fill: { parameters: ["buffer", "i32"], result: "i32", nonblocking: true, optional: true },
    probe_apply_on_thread: { parameters: ["function", "i32", "i32"], result: "i32", nonblocking: true, optional: true },
  });
  if (nbFx === null || nbFx.symbols.probe_sleep_ms == null || nbFx.symbols.probe_apply_on_thread == null) throw new Error("ffi test: §11 needs 2b.2 probes — rebuild the fixture: cd test/fixtures && ./build.sh");
  {
    const p11 = nbFx.symbols.probe_sleep_ms(50);
    assert(p11 && typeof p11.then === "function", "nonblocking returns a Promise");

    let ticked = false;
    setTimeout(() => { ticked = true; }, 10);
    const t0 = Date.now();
    await p11;
    assert(Date.now() - t0 >= 40, "sleep ran on the worker");
    assert(ticked, "timer fired during native sleep (loop stayed free)");

    const add2 = ffi.callback({ parameters: ["i32", "i32"], result: "i32" }, (a, b) => a + b);
    const r = await nbFx.symbols.probe_apply_on_thread(add2.pointer, 20, 22);
    assert(r === 42, "cross-thread callback round-trip (20+22=42)");

    const boom2 = ffi.callback({ parameters: ["i32", "i32"], result: "i32" }, () => {
      throw new Error("bridge-boom");
    });
    emsg = "";
    try { await nbFx.symbols.probe_apply_on_thread(boom2.pointer, 1, 2); } catch (e) { emsg = String(e && e.message ? e.message : e); }
    assert(emsg.indexOf("bridge-boom") !== -1, "bridged throw rejects the promise");

    if (nbFx.symbols.probe_fill) {
      const buf = new Uint8Array(8);
      const n = await nbFx.symbols.probe_fill(buf, 8);
      assert(n === 8, "probe_fill returned " + n);
      assert(buf[0] === 0 && buf[7] === 7, "buffer filled after settle");
    }

    add2.close();
    boom2.close();
    nbFx.close();
  }

  // ══ 12. Unions (P2c) ══
  const U4 = ffi.union([["i", "i32"], ["f", "f32"]]);
  assert(U4.size === 4, "u4 size (want 4, got " + U4.size + ")");
  assert(ffi.union([["c", "u8"], ["n", "u64"]]).size === 8, "u64 dominates");
  assert(ffi.union([["a", "u8"], ["b", "u16"]]).size === 2, "u16 dominates");
  assert(ffi.union([["x", "u8"], ["y", "u8"]]).size === 1, "all u8");
  assert(ffi.union([["p", "pointer"], ["n", "i32"]]).size === 8, "pointer dominates");

  emsg = "";
  try { ffi.union([["x", "void"]]); } catch (e) { emsg = String(e && e.message ? e.message : e); }
  assert(emsg.length > 0, "void union member rejected");

  const Tagged = ffi.struct([["tag", "i32"], ["val", { union: [["i", "i32"], ["f", "f32"]] }]]);
  assert(Tagged.size === 8, "tagged size (want 8, got " + Tagged.size + ")");
  assert(Tagged.offsets.tag === 0 && Tagged.offsets.val === 4, "tagged offsets");

  const unFx = openFixture({
    probe_union_identity: { parameters: [U4], result: U4, optional: true },
    probe_tagged_bump: { parameters: [Tagged], result: Tagged, optional: true },
    probe_call_union_i: { parameters: ["function", "i32"], result: "i32", optional: true },
  });
  if (unFx === null || unFx.symbols.probe_union_identity == null) throw new Error("ffi test: §12 needs 2c probes — rebuild the fixture: cd test/fixtures && ./build.sh");
  {
    const dv = (u8) => new DataView(u8.buffer, u8.byteOffset, u8.byteLength);
    const i32le = (u8, off) => dv(u8).getInt32(off, true);

    const uimg = new Uint8Array(4);
    dv(uimg).setInt32(0, 41, true);
    const uout = unFx.symbols.probe_union_identity(uimg);
    assert(uout instanceof Uint8Array && uout.length === 4, "union result is a 4-byte image");
    assert(i32le(uout, 0) === 42, "union round-trip (want 42, got " + i32le(uout, 0) + ")");

    const timg = new Uint8Array(8);
    dv(timg).setInt32(0, 7, true);
    dv(timg).setInt32(4, 100, true);
    const tout = unFx.symbols.probe_tagged_bump(timg);
    assert(i32le(tout, 0) === 8 && i32le(tout, 4) === 110, "tagged round-trip");

    const sumBytes = ffi.callback(
      { parameters: [{ union: [["i", "i32"], ["f", "f32"]] }], result: "i32" },
      (u) => u[0] + u[1] + u[2] + u[3]
    );
    assert(unFx.symbols.probe_call_union_i(sumBytes.pointer, 5) === 5, "union callback param");
    sumBytes.close();

    const unNb = openFixture({
      probe_union_identity: { parameters: [U4], result: U4, nonblocking: true },
    });
    const img3 = new Uint8Array(4);
    dv(img3).setInt32(0, 41, true);
    assert(i32le(await unNb.symbols.probe_union_identity(img3), 0) === 42, "nonblocking union");
    unNb.close();
    unFx.close();
  }

  console.log("ffi.test.js: ok");
}
