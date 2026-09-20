#!/usr/bin/env bash
# FF Runtime Benchmark Suite — I/O-first framing.
#   Tier 1: system/I/O workloads (headline wins)
#   Tier 2: general JS workloads
#   Appendix: interpreter worst cases (QuickJS = no JIT) — labeled

set -e

GREEN="\033[1;32m"; BLUE="\033[1;34m"; YELLOW="\033[1;33m"; RESET="\033[0m"

run_group() {
    local title="$1"; shift
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${YELLOW}${title}${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    for name in "$@"; do
        local file="$name.js"
        [ -f "$file" ] || { echo "  (missing $file, skipped)"; continue; }
        echo
        echo -e "${GREEN}── $name ──${RESET}"
        hyperfine -N --warmup 5 --runs 100 --style basic \
            --command-name Node "node $file" \
            --command-name Bun  "bun $file" \
            --command-name Deno "deno run $file" \
            --command-name FF   "ff $file"
    done
}

echo -e "${BLUE}"
echo "======================================================"
echo "         FF Runtime Benchmark Suite"
echo "======================================================"
echo -e "${RESET}"

run_group "TIER 1 — System & I/O (headline)" api_micro fs array loop
run_group "TIER 2 — General JS workloads" closure object sort string fetch timer
run_group "APPENDIX — Interpreter worst case (QuickJS = no JIT; not representative of I/O workloads)" fib json

echo
echo -e "${BLUE}======================================================"
echo "                 Benchmarks Complete"
echo -e "======================================================${RESET}"
