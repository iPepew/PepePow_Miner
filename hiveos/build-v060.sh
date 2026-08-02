#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

export PATH="/usr/local/bin:/usr/local/cuda-12.4/bin:${PATH}"
export LD_LIBRARY_PATH="/usr/local/cuda-12.4/lib64:${LD_LIBRARY_PATH:-}"

exec env \
  BENCH_RUNS="${BENCH_RUNS:-3}" \
  BENCH_NONCES="${BENCH_NONCES:-4194304}" \
  TARGET_HPS="${TARGET_HPS:-2000000}" \
  JOBS="${JOBS:-$(nproc)}" \
  bash hiveos/build-v060-critical-path.sh
