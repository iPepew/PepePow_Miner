#!/usr/bin/env bash
set -euo pipefail

DURATION="${DURATION:-600}"
INTERVAL="${INTERVAL:-1}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp}"
INCLUDE_SOURCE="${INCLUDE_SOURCE:-1}"
DEEP_PROFILE="${DEEP_PROFILE:-0}"
ALLOW_CONTENTION="${ALLOW_CONTENTION:-0}"
SOURCE_ROOT="${SOURCE_ROOT:-}"
V4_URL="${V4_URL:-https://raw.githubusercontent.com/iPepew/PepePow_Miner/optimize/v0.5.3-bitfraction-profiler-v4/tools/collect-profiler-pack-v4.sh}"

tmp="$(mktemp /tmp/pepepow-profiler-v4.XXXXXX.sh)"
trap 'rm -f "${tmp}"' EXIT
curl -fsSL "${V4_URL}" -o "${tmp}"
chmod +x "${tmp}"
exec env DURATION="${DURATION}" INTERVAL="${INTERVAL}" OUTPUT_DIR="${OUTPUT_DIR}" \
  INCLUDE_SOURCE="${INCLUDE_SOURCE}" DEEP_PROFILE="${DEEP_PROFILE}" \
  ALLOW_CONTENTION="${ALLOW_CONTENTION}" SOURCE_ROOT="${SOURCE_ROOT}" bash "${tmp}"
