#!/bin/sh
# Runs every JS smoke test through the runtime.
# Green = all files exit 0 with no FAIL lines.
#
# --allow-all is passed to every file: the suite covers fs, net, env, run,
# FFI, and the permission-denial matrix itself. test/permissions.test.js
# spawns child ff processes with narrower flags, so allow-all on the parent
# does not hide a missing check. Without --allow-all every other test now
# fails closed by design.
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
    if out=$("$FF" "$t" --allow-all 2>&1); then
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
