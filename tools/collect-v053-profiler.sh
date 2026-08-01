#!/usr/bin/env bash
set -euo pipefail

DURATION="${DURATION:-600}"
INTERVAL="${INTERVAL:-1}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp}"
INCLUDE_SOURCE="${INCLUDE_SOURCE:-1}"
DEEP_PROFILE="${DEEP_PROFILE:-0}"
ALLOW_CONTENTION="${ALLOW_CONTENTION:-0}"
SOURCE_ROOT="${SOURCE_ROOT:-/root/pepepow-v053-src}"
V4_URL="${V4_URL:-https://raw.githubusercontent.com/iPepew/PepePow_Miner/optimize/v0.5.3-bitfraction-profiler-v4/tools/collect-profiler-pack-v4.sh}"

# Profiler Pack v4 can use a stable fallback benchmark path. When profiling a
# completed autotune before the package is installed, derive the selected
# profile from the build log and expose its exact benchmark through that path.
if [[ "${DEEP_PROFILE}" == "1" && -f "${SOURCE_ROOT}/native/CMakeLists.txt" ]]; then
  selected="${SELECTED_PROFILE:-}"
  if [[ -z "${selected}" && -r /root/v053-build.log ]]; then
    selected="$(sed -n 's/^AUTOTUNE_PROFILE=//p' /root/v053-build.log | tail -n1)"
    if [[ -z "${selected}" ]]; then
      selected="$(sed -n 's/^AUTOTUNE_SELECTED profile=\([^ ]*\).*/\1/p' /root/v053-build.log | tail -n1)"
    fi
  fi
  benchmark="${SOURCE_ROOT}/build-profiles-v053/${selected}/pepepow_header80_benchmark"
  if [[ -n "${selected}" && -x "${benchmark}" ]]; then
    mkdir -p "${SOURCE_ROOT}/build-rtx3080-v053"
    ln -sfn "${benchmark}" "${SOURCE_ROOT}/build-rtx3080-v053/pepepow_header80_benchmark"
    printf 'selected_profile=%s\nbenchmark=%s\n' "${selected}" "${benchmark}" \
      > "${SOURCE_ROOT}/build-rtx3080-v053/PROFILER_SELECTION.txt"
  fi
fi

tmp="$(mktemp /tmp/pepepow-profiler-v4.XXXXXX.sh)"
trap 'rm -f "${tmp}"' EXIT
curl -fsSL "${V4_URL}" -o "${tmp}"
chmod +x "${tmp}"
exec env DURATION="${DURATION}" INTERVAL="${INTERVAL}" OUTPUT_DIR="${OUTPUT_DIR}" \
  INCLUDE_SOURCE="${INCLUDE_SOURCE}" DEEP_PROFILE="${DEEP_PROFILE}" \
  ALLOW_CONTENTION="${ALLOW_CONTENTION}" SOURCE_ROOT="${SOURCE_ROOT}" bash "${tmp}"
