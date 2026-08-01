#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="${SOURCE_ROOT:-/root/pepepow-v053-src}"
SELECTED_PROFILE="${SELECTED_PROFILE:-best-64-r80}"
BUILD_DIR="${SOURCE_ROOT}/build-profiles-v053/${SELECTED_PROFILE}"
BENCHMARK_EXE="${BUILD_DIR}/pepepow_header80_benchmark"
DIRECT_URL="${DIRECT_URL:-https://raw.githubusercontent.com/iPepew/PepePow_Miner/optimize/v0.5.3-bitfraction-profiler-v4/tools/collect-v053-deep-direct.sh}"

if [[ ! -x "${BENCHMARK_EXE}" ]]; then
  echo "Benchmark is missing; rebuilding only pepepow_header80_benchmark in ${BUILD_DIR}"
  [[ -f "${BUILD_DIR}/CMakeCache.txt" ]] || {
    echo "ERROR: ${BUILD_DIR}/CMakeCache.txt is missing; selected profile build directory cannot be recovered" >&2
    exit 1
  }
  command -v cmake >/dev/null 2>&1 || { echo "ERROR: cmake is required" >&2; exit 1; }
  export PATH="/usr/local/bin:/usr/local/cuda-12.4/bin:${PATH}"
  export LD_LIBRARY_PATH="/usr/local/cuda-12.4/lib64:${LD_LIBRARY_PATH:-}"
  cmake --build "${BUILD_DIR}" --parallel "${JOBS:-$(nproc)}" --target pepepow_header80_benchmark
fi

[[ -x "${BENCHMARK_EXE}" ]] || { echo "ERROR: benchmark rebuild failed: ${BENCHMARK_EXE}" >&2; exit 1; }

tmp="$(mktemp /tmp/pepepow-v053-deep-direct.XXXXXX.sh)"
trap 'rm -f "${tmp}"' EXIT
curl -fsSL "${DIRECT_URL}" -o "${tmp}"
chmod +x "${tmp}"
exec env \
  SOURCE_ROOT="${SOURCE_ROOT}" \
  SELECTED_PROFILE="${SELECTED_PROFILE}" \
  BENCHMARK_EXE="${BENCHMARK_EXE}" \
  OUTPUT_DIR="${OUTPUT_DIR:-/tmp}" \
  DEEP_NONCES="${DEEP_NONCES:-262144}" \
  ALLOW_CONTENTION="${ALLOW_CONTENTION:-0}" \
  NCU_TIMEOUT="${NCU_TIMEOUT:-1800}" \
  NSYS_TIMEOUT="${NSYS_TIMEOUT:-600}" \
  bash "${tmp}"
