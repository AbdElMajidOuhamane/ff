#!/bin/sh
# Runs every JS smoke test through the runtime.
# Green = all files exit 0 with no FAIL lines.
#
# --allow-ffi is passed to every file: it only unlocks ffi.dlopen, so the
# non-FFI tests are unaffected, while test/ffi.test.js runs its full
# contract (§1–§12) instead of silently skipping. Do not remove it —
# without the flag ffi.test.js prints "skipped" and exits 0, which the
# harness would report as a pass.
cd "$(dirname "$0")/.." || exit 1
FF=./zig-out/bin/ff
[ -x "$FF" ] || { echo "ff not built — run make build"; exit 1; }

# `make test` / `make ci` build the fixture first; build it here only when
# run.sh is invoked on its own (fresh checkout, no make).
if [ ! -f test/fixtures/libaddon_probe.dylib ] && [ ! -f test/fixtures/libaddon_probe.so ]; then
    sh test/fixtures/build.sh || exit 1
fi

fail=0
for t in test/*.test.js; do
    if out=$("$FF" "$t" --allow-ffi 2>&1); then
        if echo "$out" | grep -q "FAIL"; then
            echo "FAIL $t (assertion)"
            echo "$out" | grep FAIL
            fail=1
        else
            echo "OK   $t"
        fi
    else
        echo "FAIL $t (exit code)"
        echo "$out"
        fail=1
    fi
done
if [ $fail -eq 0 ]; then
    echo "all tests passed"
fi
exit $fail
