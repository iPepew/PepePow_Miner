#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build-rtx3080"
FILE_VERSION="$(head -n1 "${ROOT_DIR}/VERSION" | tr -d '[:space:]')"
VERSION="${VERSION:-${FILE_VERSION}}"
if [[ "${VERSION}" != "${FILE_VERSION}" ]]; then
  echo "VERSION mismatch: argument=${VERSION} file=${FILE_VERSION}" >&2
  exit 1
fi
PACKAGE_NAME="pepepowminer-v${VERSION}"
PACKAGE_DIR="${ROOT_DIR}/dist/${PACKAGE_NAME}"
ARCHIVE_PATH="${ROOT_DIR}/dist/${PACKAGE_NAME}-hiveos.tar.gz"
JOBS="${JOBS:-$(nproc)}"
CUDA_IMAGE="${CUDA_IMAGE:-nvidia/cuda:12.6.3-devel-ubuntu22.04}"

command -v nvidia-smi >/dev/null 2>&1 || { echo "nvidia-smi is required" >&2; exit 1; }

echo "== NVIDIA device =="
nvidia-smi --query-gpu=name,compute_cap,driver_version,memory.total --format=csv,noheader
if ! nvidia-smi --query-gpu=compute_cap --format=csv,noheader | grep -qx '8.6'; then
  echo "Warning: validation target is RTX 3080 / compute capability 8.6" >&2
fi

find_nvcc() {
  if command -v nvcc >/dev/null 2>&1; then command -v nvcc; return 0; fi
  local candidate
  for candidate in /usr/local/cuda/bin/nvcc /usr/local/cuda-12/bin/nvcc /usr/local/cuda-12.6/bin/nvcc /usr/local/cuda-12.5/bin/nvcc /usr/local/cuda-12.4/bin/nvcc /usr/local/cuda-11.8/bin/nvcc; do
    if [[ -x "${candidate}" ]]; then printf '%s\n' "${candidate}"; return 0; fi
  done
  return 1
}

configure_and_build_native() {
  local nvcc_path="$1"
  command -v cmake >/dev/null 2>&1 || { echo "cmake is required" >&2; exit 1; }
  export PATH="$(dirname "${nvcc_path}"):${PATH}"
  echo "== Native CUDA build =="
  "${nvcc_path}" --version
  cmake -S "${ROOT_DIR}/native" -B "${BUILD_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DPEPEPOW_ENABLE_CUDA=ON \
    -DPEPEPOW_BUILD_TESTS=ON \
    -DPEPEPOW_CUDA_PTXAS_VERBOSE=ON \
    -DCMAKE_CUDA_ARCHITECTURES=86 \
    -DCMAKE_CUDA_COMPILER="${nvcc_path}"
  cmake --build "${BUILD_DIR}" --config Release --parallel "${JOBS}"
}

configure_and_build_docker() {
  command -v docker >/dev/null 2>&1 || { echo "CUDA compiler not found and Docker unavailable" >&2; exit 1; }
  docker pull "${CUDA_IMAGE}"
  docker run --rm -e DEBIAN_FRONTEND=noninteractive -e JOBS="${JOBS}" \
    -v "${ROOT_DIR}:/workspace" -w /workspace "${CUDA_IMAGE}" bash -lc '
      set -euo pipefail
      apt-get update
      apt-get install -y --no-install-recommends cmake git build-essential ca-certificates
      rm -rf /var/lib/apt/lists/* /workspace/build-rtx3080
      cmake -S /workspace/native -B /workspace/build-rtx3080 \
        -DCMAKE_BUILD_TYPE=Release -DPEPEPOW_ENABLE_CUDA=ON -DPEPEPOW_BUILD_TESTS=ON \
        -DPEPEPOW_CUDA_PTXAS_VERBOSE=ON -DCMAKE_CUDA_ARCHITECTURES=86 \
        -DCMAKE_CUDA_RUNTIME_LIBRARY=Static
      cmake --build /workspace/build-rtx3080 --config Release --parallel "${JOBS}"
    '
}

rm -rf "${BUILD_DIR}" "${PACKAGE_DIR}" "${ARCHIVE_PATH}"
if NVCC_PATH="$(find_nvcc)"; then configure_and_build_native "${NVCC_PATH}"; else configure_and_build_docker; fi

ctest --test-dir "${BUILD_DIR}" --output-on-failure
"${BUILD_DIR}/pepepow_cuda_header80_validation"
"${BUILD_DIR}/pepepowminer" --list-gpu

BUILD_ID="$("${BUILD_DIR}/pepepowminer" --version)"
echo "BUILD_ID=${BUILD_ID}"
[[ "${BUILD_ID}" == *"${VERSION}"* ]] || { echo "Binary version mismatch: ${BUILD_ID}" >&2; exit 1; }
[[ "${BUILD_ID}" == *"PepePow Debug Edition"* ]] || { echo "Wrong binary edition: ${BUILD_ID}" >&2; exit 1; }

mkdir -p "${PACKAGE_DIR}"
install -m 0755 "${BUILD_DIR}/pepepowminer" "${PACKAGE_DIR}/pepepowminer"
install -m 0755 "${ROOT_DIR}/hiveos/h-run.sh" "${PACKAGE_DIR}/h-run.sh"
install -m 0755 "${ROOT_DIR}/hiveos/h-config.sh" "${PACKAGE_DIR}/h-config.sh"
install -m 0755 "${ROOT_DIR}/hiveos/h-stats.sh" "${PACKAGE_DIR}/h-stats.sh"
install -m 0755 "${ROOT_DIR}/hiveos/diagnostic-summary.sh" "${PACKAGE_DIR}/diagnostic-summary.sh"
install -m 0644 "${ROOT_DIR}/hiveos/h-manifest.conf" "${PACKAGE_DIR}/h-manifest.conf"
install -m 0644 "${ROOT_DIR}/VERSION" "${PACKAGE_DIR}/VERSION"

sed -i "s/^CUSTOM_VERSION=.*/CUSTOM_VERSION=${VERSION}/" "${PACKAGE_DIR}/h-manifest.conf"
sed -i "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=/hive/miners/custom/${PACKAGE_NAME}/config.txt#" "${PACKAGE_DIR}/h-manifest.conf"

PACKAGED_ID="$("${PACKAGE_DIR}/pepepowminer" --version)"
[[ "${PACKAGED_ID}" == "${BUILD_ID}" ]] || { echo "Packaged binary identity mismatch" >&2; exit 1; }
grep -qx "CUSTOM_VERSION=${VERSION}" "${PACKAGE_DIR}/h-manifest.conf"
grep -qx "CUSTOM_CONFIG_FILENAME=/hive/miners/custom/${PACKAGE_NAME}/config.txt" "${PACKAGE_DIR}/h-manifest.conf"
grep -qx "${VERSION}" "${PACKAGE_DIR}/VERSION"

strip "${PACKAGE_DIR}/pepepowminer" 2>/dev/null || true
tar -C "${ROOT_DIR}/dist" -czf "${ARCHIVE_PATH}" "${PACKAGE_NAME}"

echo "== HiveOS archive contents =="
tar -tzf "${ARCHIVE_PATH}"
for entry in pepepowminer h-run.sh h-config.sh h-stats.sh h-manifest.conf diagnostic-summary.sh VERSION; do
  tar -tzf "${ARCHIVE_PATH}" | grep -qx "${PACKAGE_NAME}/${entry}" || { echo "Missing ${entry}" >&2; exit 1; }
done

sha256sum "${ARCHIVE_PATH}"
echo "PASS: PepePow Debug Edition ${VERSION} package completed"
