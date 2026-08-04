#!/usr/bin/env bash
set -euo pipefail

LOG="${1:-/root/v101-release-build.log}"
STATUS="${STATUS_FILE:-/root/pepew-v101-release/status.env}"
REFRESH="${REFRESH:-5}"

while true; do
    clear 2>/dev/null || true
    echo "============================================================"
    echo " PEPEW MINER v1.0.1 — HIVEOS TELEMETRY FIX RELEASE"
    echo " Target: live >= 2.000 MH/s and HiveOS dashboard hashrate"
    echo "============================================================"
    echo "Log: $LOG"
    echo

    if [[ -f "$STATUS" ]]; then
        # shellcheck disable=SC1090
        source "$STATUS" || true
        printf 'State : %s\nStep  : %s\nDetail: %s\n' \
            "${STATE:-UNKNOWN}" "${STEP:-}" "${DETAIL:-}"
    elif screen -ls 2>/dev/null | grep -q '\.v101-release-build'; then
        echo "State : STARTING"
    else
        echo "State : UNKNOWN"
    fi

    echo
    echo "---------------- LAST LOG LINES ----------------"
    tail -n 50 "$LOG" 2>/dev/null || echo "Waiting for log..."
    echo
    echo "Ctrl+C closes only this panel. The build continues in screen."

    if grep -aq '^ERROR:' "$LOG" 2>/dev/null; then
        exit 1
    fi
    if grep -aq 'PEPEW MINER v1.0.1 RELEASE BUILD COMPLETE' "$LOG" 2>/dev/null; then
        exit 0
    fi
    sleep "$REFRESH"
done
