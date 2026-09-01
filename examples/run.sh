#!/bin/bash
# bench.sh - Memory benchmark runner with Hyprland measurement
# Usage: chmod +x bench.sh && ./bench.sh
# Works on: Linux (Hyprland) + macOS

JSFILE="mem.js"
REPORT="benchmark_$(date +%Y%m%d_%H%M%S).txt"
RESULTS_DIR="/tmp/bench_results"
mkdir -p "$RESULTS_DIR"

clear
echo "╔══════════════════════════════════════════════╗"
echo "║     HYPRLAND MEMORY BENCHMARK SUITE         ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "JS File:    $JSFILE"
echo "Report:     $REPORT"
echo "Start:      $(date '+%Y-%m-%d %H:%M:%S')"
echo "Platform:   $(uname -s) $(uname -m)"
echo ""

if [ ! -f "$JSFILE" ]; then
    echo "✗ Error: $JSFILE not found in $(pwd)"
    exit 1
fi
echo "✓ Found $JSFILE"

# ─── CHECK RUNTIMES ──────────────────────────────────────
echo ""
echo "Checking available runtimes..."
RUNTIMES=""
for r in node bun ff; do
    if command -v "$r" &>/dev/null; then
        ver=$($r --version 2>/dev/null || echo "?")
        echo "  ✓ $r ($ver)"
        RUNTIMES="$RUNTIMES $r"
    else
        echo "  ✗ $r (not found)"
    fi
done

if [ -z "$RUNTIMES" ]; then
    echo "✗ No runtimes found."
    exit 1
fi

# ─── PLATFORM-SPECIFIC MEMORY FUNCTION ───────────────────
get_system_memory() {
    if [ -f "/proc/meminfo" ]; then
        # Linux
        cat /proc/meminfo | head -5
    elif command -v vm_stat &>/dev/null; then
        # macOS
        echo "Physical Memory:"
        hw_memsize=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
        echo "  Total: $((hw_memsize / 1024 / 1024)) MB"
        vm_stat | head -5
    else
        echo "  Memory info not available on this platform"
    fi
}

get_process_memory() {
    local pid=$1
    if [ -f "/proc/$pid/status" ]; then
        # Linux
        awk '/VmRSS/{print "    RSS:  "$2" kB"}' /proc/$pid/status 2>/dev/null || echo "    RSS:  N/A"
        awk '/VmSize/{print "    VSZ:  "$2" kB"}' /proc/$pid/status 2>/dev/null || echo "    VSZ:  N/A"
    else
        # macOS (use ps)
        ps -o rss=,vsz= -p $pid 2>/dev/null | awk '{printf "    RSS:  %s kB\n    VSZ:  %s kB\n", $1, $2}' || echo "    Memory: N/A"
    fi
}

get_rss() {
    local pid=$1
    if [ -f "/proc/$pid/status" ]; then
        awk '/VmRSS/{print $2}' /proc/$pid/status 2>/dev/null || echo "0"
    else
        ps -o rss= -p $pid 2>/dev/null | tr -d ' ' || echo "0"
    fi
}

# ─── SYSTEM MEMORY SNAPSHOT ─────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " SYSTEM MEMORY (before any run)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
get_system_memory

# ─── RUN EACH BENCHMARK ─────────────────────────────────
echo "" > "$RESULTS_DIR/summary.csv"

for RUNTIME in $RUNTIMES; do
    MEM_LOG="$RESULTS_DIR/${RUNTIME}_memory.csv"
    echo "timestamp,rss_kb" > "$MEM_LOG"

    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  BENCHMARKING: $RUNTIME"
    echo "╚══════════════════════════════════════════════╝"

    START_TIME=$(date +%s%N)
    $RUNTIME $JSFILE > "$RESULTS_DIR/${RUNTIME}_output.txt" 2>&1 &
    PID=$!
    echo "  Process started: PID $PID"

    sleep 2

    # Hyprland client info (Linux only, graceful on macOS)
    echo ""
    echo "  [Hyprland Client Info]"
    if command -v hyprctl &>/dev/null; then
        hyprctl clients 2>/dev/null | grep -A 6 "pid: $PID" | sed 's/^/    /' || echo "    No Hyprland data for this PID"
    else
        echo "    hyprctl not available (not on Hyprland?)"
    fi

    # Process memory
    echo ""
    echo "  [Initial Memory]"
    get_process_memory $PID

    # Memory timeline
    echo ""
    echo "  [Memory Timeline]"
    echo "    TIME       RSS (kB)"
    echo "    ────────   ────────"

    while kill -0 $PID 2>/dev/null; do
        RSS=$(get_rss $PID)
        TS=$(date +%H:%M:%S)
        printf "    %s   %s\n" "$TS" "$RSS"
        echo "$TS,$RSS" >> "$MEM_LOG"
        sleep 1
    done

    wait $PID 2>/dev/null
    EXIT_CODE=$?
    END_TIME=$(date +%s%N)
    ELAPSED=$(( (END_TIME - START_TIME) / 1000000 ))

    echo ""
    echo "  [JS Output]"
    sed 's/^/    /' "$RESULTS_DIR/${RUNTIME}_output.txt" 2>/dev/null | head -10

    # Stats
    MAX_RSS=$(tail -n +2 "$MEM_LOG" | cut -d',' -f2 | sort -n | tail -1)
    MIN_RSS=$(tail -n +2 "$MEM_LOG" | cut -d',' -f2 | sort -n | head -1)
    AVG_RSS=$(tail -n +2 "$MEM_LOG" | cut -d',' -f2 | awk '{s+=$1; n++} END {printf "%.0f", s/n}')

    echo "$RUNTIME,$EXIT_CODE,$ELAPSED,$MIN_RSS,$MAX_RSS,$AVG_RSS" >> "$RESULTS_DIR/summary.csv"

    echo ""
    echo "  ┌─────────────────────────────────────┐"
    echo "  │ Exit Code:     $EXIT_CODE"
    echo "  │ Duration:      ${ELAPSED}ms"
    echo "  │ Min RSS:       ${MIN_RSS} kB"
    echo "  │ Max RSS:       ${MAX_RSS} kB"
    echo "  │ Avg RSS:       ${AVG_RSS} kB"
    echo "  └─────────────────────────────────────┘"
done

# ─── FINAL COMPARISON ───────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                  FINAL COMPARISON                           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Runtime   Exit  Duration   Min RSS    Max RSS    Avg RSS"
echo "────────  ────  ─────────  ─────────  ─────────  ─────────"

while IFS=',' read -r runtime exitcode duration minrss maxrss avgrss; do
    [ -z "$runtime" ] && continue
    printf "%-9s %-4s %-10s %-10s %-10s %-10s\n" "$runtime" "$exitcode" "${duration}ms" "${minrss}kB" "${maxrss}kB" "${avgrss}kB"
done < "$RESULTS_DIR/summary.csv"

# ─── ANALYSIS ────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " ANALYSIS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

RUNTIME_COUNT=$(grep -c '[a-z]' "$RESULTS_DIR/summary.csv" 2>/dev/null || echo 0)

if [ "$RUNTIME_COUNT" -ge 2 ]; then
    FASTEST=$(sort -t',' -k3 -n "$RESULTS_DIR/summary.csv" | grep '[a-z]' | head -1 | cut -d',' -f1)
    LOWMEM=$(sort -t',' -k5 -n "$RESULTS_DIR/summary.csv" | grep '[a-z]' | head -1 | cut -d',' -f1)

    echo "  Fastest:       $FASTEST"
    echo "  Lowest Peak:   $LOWMEM"
    echo ""

    echo "  Differences:"
    while IFS=',' read -r r1 e1 d1 mn1 mx1 a1; do
        [ -z "$r1" ] && continue
        while IFS=',' read -r r2 e2 d2 mn2 mx2 a2; do
            [ -z "$r2" ] && continue
            [ "$r1" = "$r2" ] && continue
            DUR_DIFF=$((d1 - d2))
            MEM_DIFF=$((mx1 - mx2))
            echo "    $r1 vs $r2:"
            if [ $DUR_DIFF -gt 0 ]; then
                echo "      Duration: $r1 was ${DUR_DIFF}ms slower"
            else
                echo "      Duration: $r1 was ${DUR_DIFF#-}ms faster"
            fi
            if [ $MEM_DIFF -gt 0 ]; then
                echo "      Memory:   $r1 used ${MEM_DIFF}kB more peak RSS"
            else
                echo "      Memory:   $r1 used ${MEM_DIFF#-}kB less peak RSS"
            fi
        done
    done < "$RESULTS_DIR/summary.csv"
else
    echo "  Only one runtime found, no comparison possible"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " FILES"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Report:      $REPORT"
echo "  CSV data:    $RESULTS_DIR/*.csv"
echo "  JS outputs:  $RESULTS_DIR/*_output.txt"
echo ""
echo "Done: $(date '+%Y-%m-%d %H:%M:%S')"
