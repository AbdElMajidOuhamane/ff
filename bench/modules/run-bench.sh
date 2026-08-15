#!/usr/bin/env bash

set -e

GREEN="\033[1;32m"
BLUE="\033[1;34m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
RESET="\033[0m"

clear

echo -e "${BLUE}"
echo "======================================================"
echo "       Module System Benchmark (6-level chain)"
echo "======================================================"
echo -e "${RESET}"

echo -e "  Chain: main → a → b → c → d → e"
echo -e "  Entry: bench/modules/main.js"
echo

# Verify all runtimes can produce the correct result first
echo -e "${YELLOW}Verifying correct output from each runtime...${RESET}"
echo

verify() {
    local name="$1"
    local cmd="$2"
    local result
    result=$(eval "$cmd" 2>&1) || true
    if echo "$result" | grep -q "RESULT=54"; then
        echo -e "  ${GREEN}✓${RESET} $name → RESULT=54"
    else
        echo -e "  ${RED}✗${RESET} $name → got: $result"
    fi
}

verify "Node" "node main.js"
verify "Bun"  "bun main.js"
verify "Deno" "deno run --allow-read main.js"
verify "FF"   "ff main.js"

echo
echo -e "${YELLOW}Running benchmarks (hyperfine)...${RESET}"
echo

# Check if hyperfine is installed
if ! command -v hyperfine &>/dev/null; then
    echo -e "${RED}Error: hyperfine not installed.${RESET}"
    echo "  Install with: brew install hyperfine"
    echo
    echo "  Falling back to manual timing..."
    echo

    run_manual() {
        local name="$1"
        local cmd="$2"
        local start end elapsed
        start=$(date +%s%N)
        for i in $(seq 1 20); do
            eval "$cmd" > /dev/null 2>&1
        done
        end=$(date +%s%N)
        elapsed=$(( (end - start) / 1000000 ))
        local avg=$((elapsed / 20))
        echo -e "  ${GREEN}${name}:${RESET} ${avg}ms avg (20 runs, ${elapsed}ms total)"
    }

    echo
    run_manual "Node " "node main.js"
    run_manual "Bun  " "bun main.js"
    run_manual "Deno " "deno run --allow-read main.js"
    run_manual "FF   " "ff main.js"
    echo
else
    hyperfine \
        --warmup 3 \
        --runs 50 \
        --style full \
        --command-name "Node (node main.js)"       "node main.js" \
        --command-name "Bun  (bun main.js)"         "bun main.js" \
        --command-name "Deno (deno run main.js)"    "deno run --allow-read main.js" \
        --command-name "FF   (ff main.js)"          "ff main.js"
fi

echo
echo -e "${BLUE}======================================================"
echo "              Module Benchmarks Complete"
echo -e "======================================================${RESET}"
