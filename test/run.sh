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

TIMEOUT_SEC="${FF_TEST_TIMEOUT:-60}"
TIMEOUT_BIN=""
TIMEOUT_KILL_FLAG=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN=gtimeout
fi
if [ -n "$TIMEOUT_BIN" ]; then
    if "$TIMEOUT_BIN" -k 5 1 true >/dev/null 2>&1; then
        TIMEOUT_KILL_FLAG="-k 5"
    fi
fi

TMP_OUT=$(mktemp "${TMPDIR:-/tmp}/ff-test.XXXXXX") || exit 1
TMP_TO="${TMP_OUT}.to"
trap 'rm -f "$TMP_OUT" "$TMP_TO"' EXIT HUP INT TERM

# Redirect to a regular file rather than `out=$(...)`: command substitution
# waits for pipe EOF, so any orphaned grandchild keeping stdout/stderr open
# would hang the runner even after the test process exits or times out.
run_suite() {
    suite=$1
    rm -f "$TMP_TO"
    if [ -n "$TIMEOUT_BIN" ]; then
        if [ -n "$TIMEOUT_KILL_FLAG" ]; then
            "$TIMEOUT_BIN" $TIMEOUT_KILL_FLAG "$TIMEOUT_SEC" "$FF" "$suite" --allow-all > "$TMP_OUT" 2>&1
        else
            "$TIMEOUT_BIN" "$TIMEOUT_SEC" "$FF" "$suite" --allow-all > "$TMP_OUT" 2>&1
        fi
        return $?
    fi

    "$FF" "$suite" --allow-all > "$TMP_OUT" 2>&1 &
    pid=$!
    (
        trap - EXIT HUP INT
        sleep "$TIMEOUT_SEC" &
        spid=$!
        trap 'kill "$spid" 2>/dev/null; exit 0' TERM
        wait "$spid" 2>/dev/null || exit 0
        : > "$TMP_TO"
        pkill -TERM -P "$pid" 2>/dev/null
        kill -TERM "$pid" 2>/dev/null
        sleep 5 &
        spid=$!
        wait "$spid" 2>/dev/null || exit 0
        pkill -KILL -P "$pid" 2>/dev/null
        kill -KILL "$pid" 2>/dev/null
    ) </dev/null >/dev/null 2>&1 &
    wpid=$!
    wait "$pid" 2>/dev/null
    rc=$?
    kill -TERM "$wpid" 2>/dev/null
    wait "$wpid" 2>/dev/null
    if [ -f "$TMP_TO" ]; then
        return 124
    fi
    return "$rc"
}

fail=0
for t in test/*.test.js; do
    run_suite "$t"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        if grep -q "FAIL" "$TMP_OUT"; then
            echo "FAIL $t (assertion)"
            grep FAIL "$TMP_OUT"
            fail=1
        else
            echo "OK   $t"
        fi
    elif [ "$rc" -eq 124 ]; then
        echo "TIMEOUT $t (${TIMEOUT_SEC}s)"
        cat "$TMP_OUT"
        fail=1
    else
        echo "FAIL $t (exit code $rc)"
        cat "$TMP_OUT"
        fail=1
    fi
done
if [ $fail -eq 0 ]; then
    echo "all tests passed"
fi
exit $fail
