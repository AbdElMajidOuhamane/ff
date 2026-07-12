#!/usr/bin/env bash

set -e

GREEN="\033[1;32m"
BLUE="\033[1;34m"
YELLOW="\033[1;33m"
RESET="\033[0m"

clear

echo -e "${BLUE}"
echo "======================================================"
echo "         FF Runtime Benchmark Suite"
echo "======================================================"
echo -e "${RESET}"

for file in *.js; do
    name=$(basename "$file" .js)

    echo
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${YELLOW}Benchmark:${RESET} $name"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

    hyperfine \
        --warmup 5 \
        --runs 100 \
        --style full \
        --command-name Node "node $file" \
        --command-name Bun "bun $file" \
        --command-name Deno "deno run $file" \
        --command-name FF "ff $file"

    echo
done

echo -e "${BLUE}======================================================"
echo "                 Benchmarks Complete"
echo -e "======================================================${RESET}"
