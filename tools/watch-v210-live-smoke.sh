#!/usr/bin/env bash
set -euo pipefail
REFRESH="${REFRESH:-5}"
LOG="${1:-/root/v210-live-smoke.log}"
while true; do
  clear
  echo '============================================================'
  echo ' PEPEPOW v2.1.0 — SERVICE768 LIVE SMOKE'
  echo ' Target: live mean and median >= 2.000 MH/s'
  echo '============================================================'
  echo "Log: $LOG"
  echo

  STAGE="$(grep -a '^ARCHIVE=' "$LOG" 2>/dev/null | tail -n1 | cut -d= -f2- | sed 's/\.tar\.gz$//' || true)"
  if [[ -z "$STAGE" ]]; then
    CANDIDATE_STAGE="$(find /root/pepepow-tests -maxdepth 1 -type d -name 'v210-live-smoke-*' 2>/dev/null | sort | tail -n1 || true)"
    STAGE="$CANDIDATE_STAGE"
  fi

  if [[ -n "$STAGE" && -f "$STAGE/status.env" ]]; then
    # shellcheck disable=SC1090
    source "$STAGE/status.env"
    echo "State:    ${STATE:-UNKNOWN}"
    echo "Reason:   ${REASON:-}"
    echo "Progress: ${ELAPSED:-0}/${DURATION:-0} s"
    echo "Warmup:   ${WARMUP:-0} s"
    if [[ -f "$STAGE/logs/miner.raw.log" ]]; then
      echo
      echo 'Latest mining line:'
      grep -a '\[MINING\]' "$STAGE/logs/miner.raw.log" | tail -n1 || true
    elif [[ -f "$STAGE/logs/miner.log" ]]; then
      echo
      echo 'Latest mining line:'
      grep -a '\[MINING\]' "$STAGE/logs/miner.log" | tail -n1 || true
    fi
    if [[ -f "$STAGE/logs/gpu.csv" ]]; then
      echo
      echo 'GPU latest: elapsed,timestamp,temp,util,core,power'
      tail -n1 "$STAGE/logs/gpu.csv" || true
    fi
    if [[ -f "$STAGE/summary.txt" ]]; then
      echo
      echo '================ FINAL SUMMARY ================'
      cat "$STAGE/summary.txt"
    fi
  else
    echo 'Waiting for stage/status...'
  fi

  echo
  echo '---------------- Last runner lines ----------------'
  tail -n 20 "$LOG" 2>/dev/null || true
  echo
  echo 'Ctrl+C closes only this panel. The smoke test continues in screen.'

  if grep -aq '^ARCHIVE=' "$LOG" 2>/dev/null; then
    break
  fi
  sleep "$REFRESH"
done
