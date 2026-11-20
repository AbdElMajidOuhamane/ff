#!/bin/sh
# Entry point for the ff · Deno · Bun HTTP benchmark.
# All flags are documented in README.md; everything is forwarded to bench.py.
set -eu
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec python3 "$DIR/bench.py" "$@"