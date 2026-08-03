#!/usr/bin/env bash
set -euo pipefail
LOG="${1:-/root/v200-warp-service.log}"
REFRESH="${REFRESH:-10}"

while true; do
  clear 2>/dev/null || true
  echo "======================================================================"
  echo " PEPEPOW v2.0.0 — BLOCK-COMPACTED COLD SERVICE"
  echo " Target: verified live >= 2.000 MH/s"
  echo "======================================================================"
  echo "Log: $LOG"
  echo
  if [[ ! -f "$LOG" ]]; then
    echo "WAITING: log file not created yet"
  else
    grep -aE '^(PROFILE_INDEX|PROFILE_TOTAL|PROFILE=|PROFILE_CONFIG|STATUS=|PROFILE_RESULT|STRESS_RUN|ARCHIVE=|SHA256_FILE=|DOWNLOAD_URL=|PUBLIC_ARCHIVE_URL=)' "$LOG" | tail -n 34 || true
    echo
    if grep -aq 'V2.0.0 WARP SERVICE COMPLETE' "$LOG"; then
      echo "------------------------------ FINAL -------------------------------"
      awk '/^========== V2.0.0 WARP SERVICE COMPLETE ==========$/{show=1;next} show{print}' "$LOG" | tail -n 45
      exit 0
    fi
  fi
  echo
  echo "Ctrl+C closes only this panel. The campaign continues in screen."
  sleep "$REFRESH"
done
