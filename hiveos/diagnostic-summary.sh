#!/usr/bin/env bash
set -euo pipefail

MINER_DIR="${MINER_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
LOG_FILE="${1:-/var/log/miner/custom/pepepowminer/pepepowminer.log}"
OUT_FILE="${2:-$MINER_DIR/diagnostic-summary.txt}"

{
  echo "PepePow Miner diagnostic summary"
  date -u +"UTC: %Y-%m-%dT%H:%M:%SZ"
  echo "Miner directory: $MINER_DIR"
  echo "Log file: $LOG_FILE"
  echo
  echo "== Build identity =="
  "$MINER_DIR/pepepowminer" --version 2>&1 || true
  echo
  echo "== GPU =="
  nvidia-smi --query-gpu=index,name,uuid,driver_version,compute_cap,pci.bus_id --format=csv,noheader 2>&1 || true
  echo
  echo "== HiveOS package =="
  cat "$MINER_DIR/h-manifest.conf" 2>&1 || true
  echo
  echo "== Runtime config =="
  cat "$MINER_DIR/config.txt" 2>&1 || true
  echo
  echo "== Key runtime records =="
  grep -E 'BUILD_ID|JOB_DIAG|TARGET_DIAG|SHARE_DIAG|SUBMIT_DIAG|Share accepted|Share rejected|CUDA candidate|Worker error|Fatal' "$LOG_FILE" 2>/dev/null | tail -n 500 || true
} > "$OUT_FILE"

echo "$OUT_FILE"
