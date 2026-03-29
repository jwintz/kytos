#!/bin/bash
# perf-baseline.sh — Record a 60s performance baseline for Kytos
#
# Usage:
#   ./Scripts/perf-baseline.sh [--compare FILE_A FILE_B]
#   ./Scripts/perf-baseline.sh [--pid PID]
#
# If PID is omitted, attaches to the first running Kytos process.
# Saves results to Scripts/perf-results-YYYYMMDD-HHMMSS.txt
#
# --compare FILE_A FILE_B   Diff two result files showing regression/improvement

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DURATION=60
APP_NAME="Kytos"
PID_ARG=""

# -- Compare mode ----------------------------------------------------------

compare_results() {
    local file_a="$1" file_b="$2"
    if [[ ! -f "$file_a" || ! -f "$file_b" ]]; then
        echo "Error: both files must exist."
        exit 1
    fi
    echo "=== Performance Comparison ==="
    echo "Baseline: $file_a"
    echo "Current:  $file_b"
    echo ""
    printf "%-30s %12s %12s %12s\n" "Metric" "Baseline" "Current" "Delta"
    printf "%-30s %12s %12s %12s\n" "------------------------------" "------------" "------------" "------------"
    while IFS=$'\t' read -r metric val_a; do
        val_b=$(awk -F'\t' -v m="$metric" '$1 == m {print $2; exit}' "$file_b" 2>/dev/null)
        val_b="${val_b:-n/a}"
        if [[ "$val_a" =~ ^-?[0-9]+$ && "$val_b" =~ ^-?[0-9]+$ ]]; then
            delta=$((val_b - val_a))
            sign=""; [[ $delta -gt 0 ]] && sign="+" 
            printf "%-30s %12s %12s %12s\n" "$metric" "$val_a" "$val_b" "${sign}${delta}"
        else
            printf "%-30s %12s %12s %12s\n" "$metric" "$val_a" "$val_b" "n/a"
        fi
    done < "$file_a"
    exit 0
}

# -- Argument parsing -------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --compare)
            shift
            compare_results "${1:-}" "${2:-}"
            ;;
        --pid)
            shift; PID_ARG="${1:-}"; shift ;;
        *)
            echo "Unknown argument: $1"; exit 1 ;;
    esac
done

# -- Resolve PID ------------------------------------------------------------

if [[ -n "$PID_ARG" ]]; then
    PID="$PID_ARG"
else
    PID=$(pgrep -x "$APP_NAME" | head -1 || true)
    if [[ -z "$PID" ]]; then
        echo "Error: $APP_NAME not running."
        echo "  Launch Kytos.app, then re-run this script."
        echo "  Or specify: $0 --pid <PID>"
        exit 1
    fi
fi

# Verify PID is alive
if ! kill -0 "$PID" 2>/dev/null; then
    echo "Error: PID $PID is not running."
    exit 1
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_FILE="${SCRIPT_DIR}/perf-results-${TIMESTAMP}.txt"

echo "=== $APP_NAME Performance Baseline ==="
echo "PID: $PID"
echo "Duration: ${DURATION}s"
echo ""

# -- Helper: collect snapshot -----------------------------------------------

collect_snapshot() {
    local label="$1"

    local rss_kb vsize_kb fd_count thread_count layer_count

    rss_kb=$(ps -o rss= -p "$PID" 2>/dev/null | tr -d ' ' || echo "0")
    vsize_kb=$(ps -o vsz= -p "$PID" 2>/dev/null | tr -d ' ' || echo "0")
    fd_count=$(lsof -p "$PID" 2>/dev/null | wc -l | tr -d ' ')
    thread_count=$(ps -M -p "$PID" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')

    # CALayer count approximation via heap (no sudo required)
    layer_count=$(heap "$PID" 2>/dev/null | grep -i 'CALayer' | awk '{sum += $1} END {print sum+0}' || echo "n/a")

    local rss_mb=$((rss_kb / 1024))
    local vsize_mb=$((vsize_kb / 1024))

    echo "--- ${label} ---"
    echo "  RSS:              ${rss_mb} MB (${rss_kb} KB)"
    echo "  Virtual memory:   ${vsize_mb} MB (${vsize_kb} KB)"
    echo "  File descriptors: ${fd_count}"
    echo "  Threads:          ${thread_count}"
    echo "  CALayer count:    ${layer_count}"

    # Export for caller
    eval "${label}_RSS_KB=$rss_kb"
    eval "${label}_VSIZE_KB=$vsize_kb"
    eval "${label}_FD=$fd_count"
    eval "${label}_THREADS=$thread_count"
    eval "${label}_LAYERS=$layer_count"
}

# -- Pre-trace snapshot -----------------------------------------------------

collect_snapshot "pre"

# -- Wait / observation period ----------------------------------------------

echo ""
echo "Observing for ${DURATION}s ..."
sleep "$DURATION"

# -- Post-trace snapshot ----------------------------------------------------

echo ""
collect_snapshot "post"

# -- Compute deltas ---------------------------------------------------------

RSS_DELTA=$(( post_RSS_KB - pre_RSS_KB ))
VSIZE_DELTA=$(( post_VSIZE_KB - pre_VSIZE_KB ))

echo ""
echo "--- Deltas ---"
echo "  RSS delta:    $((RSS_DELTA / 1024)) MB (${RSS_DELTA} KB)"
echo "  VSize delta:  $((VSIZE_DELTA / 1024)) MB (${VSIZE_DELTA} KB)"

# -- Write TSV results file -------------------------------------------------

cat > "$RESULT_FILE" <<EOF
rss_kb_before	${pre_RSS_KB}
rss_kb_after	${post_RSS_KB}
rss_delta_kb	${RSS_DELTA}
vsize_kb_before	${pre_VSIZE_KB}
vsize_kb_after	${post_VSIZE_KB}
vsize_delta_kb	${VSIZE_DELTA}
fd_count_before	${pre_FD}
fd_count_after	${post_FD}
thread_count_before	${pre_THREADS}
thread_count_after	${post_THREADS}
calayer_count_before	${pre_LAYERS}
calayer_count_after	${post_LAYERS}
pid	${PID}
process	${APP_NAME}
duration_s	${DURATION}
timestamp	$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF

echo ""
echo "Results saved to: $RESULT_FILE"
echo "Compare two runs:  $0 --compare <file_a> <file_b>"
