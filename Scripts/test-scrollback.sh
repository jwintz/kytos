#!/usr/bin/env bash
# Scripts/test-scrollback.sh
#
# Visual scrollback test for Kytos.
#
# Run this inside a Kytos terminal pane, then scroll up with the trackpad or
# ⌥↑ / Page Up. You should see all numbered lines from 1 to TOTAL.
#
# Usage:
#   bash Scripts/test-scrollback.sh          # 200 lines (default)
#   bash Scripts/test-scrollback.sh 500      # custom line count

set -euo pipefail

TOTAL="${1:-200}"
COLS="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"

# --- header ---
printf '\033[1;36m=== Kytos scrollback test: %d lines ===\033[0m\n' "$TOTAL"
printf 'Terminal width: %d cols\n' "$COLS"
printf 'After this script finishes, scroll UP to verify all lines are visible.\n'
printf '\033[2m(You should see lines 1 through %d in scrollback.)\033[0m\n\n' "$TOTAL"

# --- emit numbered lines ---
for i in $(seq 1 "$TOTAL"); do
    # Every 10th line gets a highlighted marker so content is easy to spot.
    if (( i % 10 == 0 )); then
        printf '\033[1;33m[%4d/%d] *** MARKER line %d — scroll up to find these ***\033[0m\n' \
            "$i" "$TOTAL" "$i"
    else
        # Pad to a predictable width so wrap-related truncation would be obvious.
        printf '[%4d/%d] scrollback line %d: the quick brown fox jumps over the lazy dog\n' \
            "$i" "$TOTAL" "$i"
    fi
done

# --- footer on visible screen ---
printf '\n\033[1;32m=== Done. Scroll UP now — you should see all %d lines above. ===\033[0m\n' "$TOTAL"
printf '\033[2mTip: use two-finger trackpad scroll, or Page Up / ⌥↑ in Kytos.\033[0m\n'
