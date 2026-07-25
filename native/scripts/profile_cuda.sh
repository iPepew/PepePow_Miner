#!/usr/bin/env bash
set -euo pipefail

ARCH="${1:-70}"
REGS="${2:-}"
BUILD_DIR="build-cuda-sm${ARCH}"

case "${ARCH}" in
  70|75|80|86|89) ;;
  *) echo "unsupported architecture: ${ARCH}" >&2; exit 2 ;;
esac

cmake_args=(
  -S .
  -B "${BUILD_DIR}"
  -DPEPEPOW_ENABLE_CUDA=ON
  -DPEPEPOW_BUILD_TESTS=ON
  -DPEPEPOW_CUDA_PTXAS_VERBOSE=ON
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_CUDA_ARCHITECTURES="${ARCH}"
)

if [[ -n "${REGS}" ]]; then
  cmake_args+=("-DPEPEPOW_CUDA_MAX_REGISTERS=${REGS}")
fi

cmake "${cmake_args[@]}"
cmake --build "${BUILD_DIR}" --config Release --parallel 2>&1 | tee "${BUILD_DIR}/ptxas.log"

echo
echo "ptxas summary:"
grep -E "ptxas info.*(Used|stack frame|spill stores|spill loads)" "${BUILD_DIR}/ptxas.log" || true
