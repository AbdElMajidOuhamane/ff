# Vendored QuickJS upgrade: 2024-01-13 → quickjs-ng v0.16.2

## Why
The vendored 2024-01-13 snapshot predates a long list of crash fixes:
- #1569 UAF of a suspended coroutine referenced only via a closure (hit by
  module-eval'd async test bodies — the crypto.test.js segfault)
- #1570-family risk: cycle GC doesn't mark a running async fn's operand stack
  (open upstream, but massively narrowed by later changes)
- #1613 promise resolving-func UAF, #1614 CallSite double free
- #1670 object leak in JS_NewCConstructor, #1638 getset exception propagation
- perf: inline mixed int/float arithmetic, faster parser column lookup

Unblocks: removing the `globalThis.__t` coroutine workaround in tests, and
making module-eval'd server projects (imports + async handlers) safe.

## Phase 1 — Vendor swap (pinned)
- Fetch `https://github.com/quickjs-ng/quickjs/archive/refs/tags/v0.16.2.tar.gz`
  (commit 1ab8676f4b6d6d669baeb5f21790fb9734636a20). Record the sha256 in
  `scripts/fetch_vendor.sh` (the shared Dockerfile/CI fetch script from the
  test plan).
- Replace `vendor/quickjs/` contents. Keep the same layout the build expects:
  `quickjs.h` at the root + the .c/.h files.
- Inspect the extracted file list: ng 0.16.x adds `xsum.c`/`xsum.h` (checksum)
  and may vendor `quickjs-c-atomics` — include whatever the tarball contains.

## Phase 2 — build.zig changes
- Update the `CONFIG_VERSION` define (ng 0.16.x reads its own version macro —
  inspect `quickjs.h` for what it expects; likely `-DJS_NG_VERSION=...` or a
  CONFIG_VERSION string).
- Drop `-DCONFIG_BIGNUM` (removed lineage-wide).
- Source list: add `xsum.c` (if present), keep quickjs/cutils/libregexp/
  libunicode/dtoa.
- **Drop `quickjs-libc.c`** — nothing references it (grep: no js_std/js_module
  loader use; we replicate import.meta ourselves). Less surface, fewer flags.
- Remove `-DCONFIG_CHECK_OPTIONS` if the new header dropped it (keep if it
  still exists — it enables extra checks, good for Debug).

## Phase 3 — Shim migration (compile-error-driven)
The shim re-exports ~150 symbols; the compiler enumerates the drift. Known
watch-items between 2024-01-13 → 0.16.2:
- `JS_SetModuleLoaderFunc` (v1) vs `JS_SetModuleLoaderFunc2` (attributes) —
  v0.16's libc uses Func2; check whether v1 still exists (it did in
  2024-01-13). If removed → migrate moduleNormalize/moduleLoader to the Func2
  signature (extra `JSValueConst attributes` param — pass through).
- `JS_GetPropertyInternal` — signature gained params in some versions; used
  by headers/request for proto lookups — fix if flagged.
- `JS_GetTypedArrayBuffer(ctx, obj, &off, &len, &bpe)` — same ng shape
  ✓ expected no change.
- `JS_EnqueueJob(ctx, JSJobFunc*, argc, argv)` — verify JSJobFunc shape
  (should be unchanged: fn(ctx, argc, argv)).
- Tags: `STRING_ROPE` exists in both ✓. `JS_GetClassID(JSValue)` ✓.
- New useful exports (optional adds): `JS_PromiseMarkAsHandled` (#1604 — use
  it in microtaskJob to mark swallowed rejections properly), `JS_PromiseThen`
  (#1605).
- `JS_NewCConstructor` leak fix (#1670) — no shim change needed, but our
  constructor pattern (create own object, return it) remains correct.
- Everything else (Eval flags, PromiseCapability, ClassID, Opaque, Atoms,
  TypedArray APIs) — expected unchanged; fix as the compiler reports.

## Phase 4 — Behavior verification (the test suite is the harness)
1. `make test` — Layer 1 (unit), Layer 2 (all 9 smoke files), Layer 3 runner.
2. Remove the `globalThis.__t` coroutine workaround in `test/crypto.test.js`
   and restore the async/await body (the UAF is fixed) — re-run.
3. Server self-fetch tests: http, 2-hop redirect, ws echo.
4. Server regression: `examples/async_handler.js` 5 routes + `wrk.sh`.
5. Perf comparison: `bench/api_micro.js` + `wrk.sh` vs the pre-upgrade
   numbers (46.3 ms / 3.6 MB RSS / 133k req/s) — ng 0.16 has parser + int/float
   perf work; record the delta in the commit message.
6. Crash-report check: `ls -t ~/Library/Logs/DiagnosticReports | grep ff` —
   zero new reports after the full suite.

## Phase 5 — Pins + docs
- Dockerfile: replace the QJS_COMMIT pin + fetch URL with the v0.16.2
  tarball + recorded sha256.
- `scripts/fetch_vendor.sh`: same pin (single source with CI).
- README: vendor version mention (Architecture section) + drop the
  "no async/await in module tests" caveat from the test plan docs.

## Rollback
vendor/ is untracked + pinned → the old 2024-01-13 is reproducible from its
own pin (git history of the Dockerfile). If v0.16.2 blocks (unresolvable API
gap), revert vendor + build.zig flags and file the specific blocker.

## Risks
- Shim drift unknowns — resolved compile-error-by-error; the shim's surface
  is narrow (direct re-exports, no wrappers), so fixes are one-liners.
- Behavior changes in module loading (import attributes #1603) — our loader
  ignores attributes; pass them through.
- Residual upstream risk: #1570 (async operand-stack GC UAF) remains open on
  master — rare trigger, hugely reduced exposure vs 2024-01-13.
- `JS_GetPropertyInternal` usage in headers/request may need the new
  signature.

## Order of work
Phase 1 → 2 → 3 (iterative compile) → 4 (suite green + workaround removal) →
5 (pins/docs) → commit. Estimate: half a day, mostly mechanical.
