#!/usr/bin/env bash
set -euo pipefail
URL="${V4_URL:-https://raw.githubusercontent.com/iPepew/PepePow_Miner/optimize/v0.5.6-cold-path/tools/collect-profiler-pack-v4.sh}"
tmp="$(mktemp /tmp/pepepow-profiler-v4.XXXXXX.sh)"
trap 'rm -f "$tmp"' EXIT
curl -fsSL "$URL" -o "$tmp"
chmod +x "$tmp"
exec env \
  DURATION="${DURATION:-600}" \
  INTERVAL="${INTERVAL:-1}" \
  OUTPUT_DIR="${OUTPUT_DIR:-/tmp}" \
  INCLUDE_SOURCE="${INCLUDE_SOURCE:-1}" \
  SOURCE_ROOT="${SOURCE_ROOT:-/root/pepepow-v056-src}" \
  DEEP_PROFILE="${DEEP_PROFILE:-0}" \
  ALLOW_CONTENTION="${ALLOW_CONTENTION:-0}" \
  bash "$tmp"
