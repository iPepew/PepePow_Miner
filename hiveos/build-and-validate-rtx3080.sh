#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build-rtx3080"
PACKAGE_DIR="${ROOT_DIR}/dist/pepepowminer-v0.1.1-rc1-hiveos"
JOBS="${JOBS:-$(nproc)}"

command -v cmake >/dev/null 2>&1 || { echo "cmake is required" >&2; exit 1; }
command -v nvcc >/dev/null 2>&1 || { echo "nvcc is required" >&2; exit 1; }
command -v nvidia-smi >/dev/null 2>&1 || { echo "nvidia-smi is required" >&2; exit 1; }

echo "== NVIDIA device =="
nvidia-smi --query-gpu=name,compute_cap,driver_version,memory.total --format=csv,noheader

if ! nvidia-smi --query-gpu=compute_cap --format=csv,noheader | grep -qx '8.6'; then
    echo "Warning: official release validation target is RTX 3080 / compute capability 8.6" >&2
fi

rm -rf "${BUILD_DIR}" "${PACKAGE_DIR}"

cmake -S "${ROOT_DIR}/native" -B "${BUILD_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DPEPEPOW_ENABLE_CUDA=ON \
    -DPEPEPOW_BUILD_TESTS=ON \
    -DPEPEPOW_CUDA_PTXAS_VERBOSE=ON \
    -DCMAKE_CUDA_ARCHITECTURES=86

cmake --build "${BUILD_DIR}" --config Release --parallel "${JOBS}"

ctest --test-dir "${BUILD_DIR}" --output-on-failure

"${BUILD_DIR}/pepepow_cuda_header80_validation"
"${BUILD_DIR}/pepepowminer" --list-gpu

mkdir -p "${PACKAGE_DIR}"
install -m 0755 "${BUILD_DIR}/pepepowminer" "${PACKAGE_DIR}/pepepowminer"
install -m 0755 "${ROOT_DIR}/hiveos/h-run.sh" "${PACKAGE_DIR}/h-run.sh"
install -m 0755 "${ROOT_DIR}/hiveos/h-config.sh" "${PACKAGE_DIR}/h-config.sh"
install -m 0644 "${ROOT_DIR}/hiveos/h-manifest.conf" "${PACKAGE_DIR}/h-manifest.conf"

strip "${PACKAGE_DIR}/pepepowminer" 2>/dev/null || true

tar -C "${ROOT_DIR}/dist" -czf \
    "${ROOT_DIR}/dist/pepepowminer-v0.1.1-rc1-hiveos-sm86.tar.gz" \
    "pepepowminer-v0.1.1-rc1-hiveos"

sha256sum "${ROOT_DIR}/dist/pepepowminer-v0.1.1-rc1-hiveos-sm86.tar.gz"
echo "PASS: RTX 3080 validation and HiveOS package completed"
