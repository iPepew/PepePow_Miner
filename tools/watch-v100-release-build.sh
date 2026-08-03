#!/usr/bin/env bash
set -euo pipefail
LOG="${1:-/root/v100-release-build.log}"
STATUS="${STATUS_FILE:-/root/pepew-v1-release/status.env}"
REFRESH="${REFRESH:-5}"

while true; do
    clear 2>/dev/null || true
    echo "============================================================"
    echo " PEPEW MINER v1.0.0 — FINAL RELEASE BUILD"
    echo " Verified live target: 2.000 MH/s"
    echo "============================================================"
    echo "Log: $LOG"
    echo
    if [[ -f "$STATUS" ]]; then
        # shellcheck disable=SC1090
        source "$STATUS" || true
        printf 'State : %s\nStep  : %s\nDetail: %s\n' \
            "${STATE:-UNKNOWN}" "${STEP:-}" "${DETAIL:-}"
    elif screen -ls 2>/dev/null | grep -q '\.v100-release-build'; then
        echo "State : STARTING"
    else
        echo "State : UNKNOWN"
    fi
    echo
    echo "---------------- LAST LOG LINES ----------------"
    tail -n 45 "$LOG" 2>/dev/null || echo "Waiting for log..."
    echo
    echo "Ctrl+C closes only this panel. The build continues in screen."

    if grep -aq 'RELEASE_STAGE=.*FAILED\|^ERROR:' "$LOG" 2>/dev/null; then
        exit 1
    fi
    if grep -aq 'PEPEW MINER v1.0.0 RELEASE BUILD COMPLETE' "$LOG" 2>/dev/null; then
        exit 0
    fi
    sleep "$REFRESH"
done
