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
ARCHIVE_LIST="${ROOT_DIR}/dist/${PACKAGE_NAME}-archive-contents.txt"
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

rm -rf "${BUILD_DIR}" "${PACKAGE_DIR}" "${ARCHIVE_PATH}" "${ARCHIVE_LIST}"
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
for script in h-run.sh h-config.sh h-stats.sh diagnostic-summary.sh forensic-audit.sh collect-forensics.sh capture-stratum.sh; do
  install -m 0755 "${ROOT_DIR}/hiveos/${script}" "${PACKAGE_DIR}/${script}"
done
install -m 0644 "${ROOT_DIR}/hiveos/h-manifest.conf" "${PACKAGE_DIR}/h-manifest.conf"
install -m 0644 "${ROOT_DIR}/VERSION" "${PACKAGE_DIR}/VERSION"

sed -i "s/^CUSTOM_VERSION=.*/CUSTOM_VERSION=${VERSION}/" "${PACKAGE_DIR}/h-manifest.conf"
sed -i "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=/hive/miners/custom/${PACKAGE_NAME}/config.txt#" "${PACKAGE_DIR}/h-manifest.conf"

PACKAGED_ID="$("${PACKAGE_DIR}/pepepowminer" --version)"
[[ "${PACKAGED_ID}" == "${BUILD_ID}" ]] || { echo "Packaged binary identity mismatch" >&2; exit 1; }
grep -qx "CUSTOM_VERSION=${VERSION}" "${PACKAGE_DIR}/h-manifest.conf"
grep -qx "CUSTOM_CONFIG_FILENAME=/hive/miners/custom/${PACKAGE_NAME}/config.txt" "${PACKAGE_DIR}/h-manifest.conf"
grep -qx "${VERSION}" "${PACKAGE_DIR}/VERSION"

MINER_DIR="${PACKAGE_DIR}" source "${PACKAGE_DIR}/h-stats.sh"
[[ "${stats}" == *"\"ver\":\"${VERSION}\""* ]] || { echo "h-stats version mismatch: ${stats}" >&2; exit 1; }
[[ "${stats}" == *'"hs":[0]'* ]] || { echo "h-stats must explicitly reset stale hashrate: ${stats}" >&2; exit 1; }
if grep -R --line-number -E '0\.1\.4|/hive/miners/custom/pepepow-debug\.log|/hive/miners/custom/diagnostic-summary\.txt' "${PACKAGE_DIR}"; then
  echo "Stale version or unsafe parent-directory path found in package" >&2
  exit 1
fi

for script in "${PACKAGE_DIR}"/*.sh; do bash -n "${script}"; done
"${PACKAGE_DIR}/pepepowminer" --help | grep -q -- '--diagnostic-log'
"${PACKAGE_DIR}/forensic-audit.sh" "${PACKAGE_DIR}/build-forensic-audit.txt"
grep -q "Expected package dir: ${PACKAGE_DIR}" "${PACKAGE_DIR}/build-forensic-audit.txt"
rm -f "${PACKAGE_DIR}/build-forensic-audit.txt"

strip "${PACKAGE_DIR}/pepepowminer" 2>/dev/null || true
tar -C "${ROOT_DIR}/dist" -czf "${ARCHIVE_PATH}" "${PACKAGE_NAME}"
tar -tzf "${ARCHIVE_PATH}" > "${ARCHIVE_LIST}"

echo "== HiveOS archive contents =="
cat "${ARCHIVE_LIST}"
for entry in pepepowminer h-run.sh h-config.sh h-stats.sh h-manifest.conf diagnostic-summary.sh forensic-audit.sh collect-forensics.sh capture-stratum.sh VERSION; do
  if ! grep -Fxq "${PACKAGE_NAME}/${entry}" "${ARCHIVE_LIST}"; then
    echo "Missing ${entry}" >&2
    exit 1
  fi
done

rm -f "${ARCHIVE_LIST}"
sha256sum "${ARCHIVE_PATH}"
echo "PASS: PepePow Forensic Debug Edition ${VERSION} package completed"
