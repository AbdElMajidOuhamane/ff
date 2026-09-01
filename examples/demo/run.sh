#!/usr/bin/env bash
# Usage: bash examples/demo/run.sh [port]
set -euo pipefail
PORT="${1:-3000}"
cd "$(dirname "$0")"

echo "[1/3] building/starting fairyfly server on :$PORT"
../../zig-out/bin/ff http_demo.js &   # or: zig build -Doptimize=ReleaseFast && ../../zig-out/bin/ff http_demo.js
SERV=$!
trap 'kill $SERV 2>/dev/null || true' EXIT

for _ in $(seq 1 50); do
  if curl -s -o /dev/null "http://127.0.0.1:$PORT/health"; then break; fi
  sleep 0.1
done

echo "[2/3] running client checks (node)"
node client.mjs

echo "[3/3] optional keep-alive sanity"
ab -n 10000 -c 100 -k "http://127.0.0.1:$PORT/health" 2>/dev/null | awk '/Req\/sec/{print "  "$0}'
