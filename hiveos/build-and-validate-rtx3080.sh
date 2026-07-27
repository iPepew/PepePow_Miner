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
command -v python3 >/dev/null 2>&1 || { echo "python3 is required for the passive Stratum proxy" >&2; exit 1; }

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
      apt-get install -y --no-install-recommends cmake git build-essential ca-certificates python3
      rm -rf /var/lib/apt/lists/* /workspace/build-rtx3080
      cmake -S /workspace/native -B /workspace/build-rtx3080 \
        -DCMAKE_BUILD_TYPE=Release -DPEPEPOW_ENABLE_CUDA=ON -DPEPEPOW_BUILD_TESTS=ON \
        -DPEPEPOW_CUDA_PTXAS_VERBOSE=ON -DCMAKE_CUDA_ARCHITECTURES=86 \
        -DCMAKE_CUDA_RUNTIME_LIBRARY=Static
      cmake --build /workspace/build-rtx3080 --config Release --parallel "${JOBS}"
    '
}

# Static consensus guards fail before the expensive CUDA build.
grep -Fq 'write_be32(header, 76, job.nonce);' "${ROOT_DIR}/native/src/core/header_builder.cpp" || {
  echo "Header80 nonce bytes are not BE32" >&2; exit 1;
}
grep -Fq 'store_be32(header + 76, nonce);' "${ROOT_DIR}/native/src/cuda/header80_backend.cu" || {
  echo "CUDA Header80 nonce bytes are not BE32" >&2; exit 1;
}
grep -Fq 'const Hash256 matrix_seed = blake3_hash(masked_header);' "${ROOT_DIR}/native/src/crypto/pow.cpp" || {
  echo "CPU matrix seed is not BLAKE3(masked Header80)" >&2; exit 1;
}
grep -Fq 'const crypto::Hash256 matrix_seed = crypto::blake3_hash(masked_header);' "${ROOT_DIR}/native/src/cuda/header80_backend.cu" || {
  echo "CUDA matrix seed is not BLAKE3(masked Header80)" >&2; exit 1;
}
grep -Fq 'const std::uint32_t mix_nonce = load_le32(header.data() + 76);' "${ROOT_DIR}/native/src/crypto/pow.cpp" || {
  echo "CPU HooHash nonce is not LE32 from Header80" >&2; exit 1;
}
grep -Fq 'const std::uint32_t mix_nonce = load_le32(header + 76);' "${ROOT_DIR}/native/src/cuda/header80_backend.cu" || {
  echo "CUDA HooHash nonce is not LE32 from Header80" >&2; exit 1;
}

# HooHash uses large FP64 operands. Parentheses here change rounding and are
# consensus-critical; x + 1 + factor is not equivalent.
grep -Fq 'return fn(x + (1.0 + two));' "${ROOT_DIR}/native/src/crypto/hoohash_reference.cpp" || {
  echo "CPU HooHash addition does not preserve consensus parentheses" >&2; exit 1;
}
grep -Fq 'return fn(x - (1.0 + two));' "${ROOT_DIR}/native/src/crypto/hoohash_reference.cpp" || {
  echo "CPU HooHash subtraction does not preserve consensus parentheses" >&2; exit 1;
}
grep -Fq 'if (two < 0.25) y = x + (1.0 + two);' "${ROOT_DIR}/native/src/cuda/header80_backend.cu" || {
  echo "CUDA HooHash addition does not preserve consensus parentheses" >&2; exit 1;
}
grep -Fq 'else if (two < 0.50) y = x - (1.0 + two);' "${ROOT_DIR}/native/src/cuda/header80_backend.cu" || {
  echo "CUDA HooHash subtraction does not preserve consensus parentheses" >&2; exit 1;
}

grep -Fq 'const auto pool_reference_hash' "${ROOT_DIR}/native/tests/core_tests.cpp" || {
  echo "Pool-reference regression test is missing" >&2; exit 1;
}
grep -Fq 'encode_u32_le_hex(job.nonce) == "00ffeedd"' "${ROOT_DIR}/native/tests/core_tests.cpp" || {
  echo "Stratum submit nonce LE regression test is missing" >&2; exit 1;
}
grep -Fq '7eca26c772b9ba046d0166ba569ef980ef9177b6a5c39a4aeac846bb6b5392cf' "${ROOT_DIR}/native/tests/core_tests.cpp" || {
  echo "Live CPU consensus vectors are missing" >&2; exit 1;
}
grep -Fq 'PASS: 5 consensus HooHash vectors match on CPU/CUDA' "${ROOT_DIR}/native/tests/cuda_header80_validation.cpp" || {
  echo "Live CUDA consensus vector gate is missing" >&2; exit 1;
}
if grep -Fq -- '--rewrite-submit-nonce' "${ROOT_DIR}/hiveos/h-run.sh"; then
  echo "h-run.sh must keep the Stratum proxy passive" >&2
  exit 1
fi

rm -rf "${BUILD_DIR}" "${PACKAGE_DIR}" "${ARCHIVE_PATH}" "${ARCHIVE_LIST}"
if NVCC_PATH="$(find_nvcc)"; then configure_and_build_native "${NVCC_PATH}"; else configure_and_build_docker; fi

ctest --test-dir "${BUILD_DIR}" --output-on-failure
"${BUILD_DIR}/pepepow_cuda_header80_validation"
"${BUILD_DIR}/pepepowminer" --list-gpu

BUILD_ID="$("${BUILD_DIR}/pepepowminer" --version)"
echo "BUILD_ID=${BUILD_ID}"
[[ "${BUILD_ID}" == *"${VERSION}"* ]] || { echo "Binary version mismatch: ${BUILD_ID}" >&2; exit 1; }
[[ "${BUILD_ID}" == *"PepePow Pool Reference Edition"* ]] || { echo "Wrong binary edition: ${BUILD_ID}" >&2; exit 1; }

mkdir -p "${PACKAGE_DIR}"
install -m 0755 "${BUILD_DIR}/pepepowminer" "${PACKAGE_DIR}/pepepowminer"
for script in h-run.sh h-config.sh h-stats.sh diagnostic-summary.sh forensic-audit.sh collect-forensics.sh collect-and-serve.sh capture-stratum.sh; do
  install -m 0755 "${ROOT_DIR}/hiveos/${script}" "${PACKAGE_DIR}/${script}"
done
install -m 0755 "${ROOT_DIR}/hiveos/stratum-replay-proxy.py" "${PACKAGE_DIR}/stratum-replay-proxy.py"
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
[[ "${stats}" == *'"ver":""'* ]] || { echo "h-stats must suppress duplicate HiveOS version suffix: ${stats}" >&2; exit 1; }
[[ "${stats}" != *"${VERSION}"* ]] || { echo "h-stats must not duplicate package version in HiveOS UI: ${stats}" >&2; exit 1; }
[[ "${stats}" == *'"hs":[0]'* ]] || { echo "h-stats must explicitly reset stale hashrate: ${stats}" >&2; exit 1; }
if grep -R --line-number -E '0\.1\.4|/hive/miners/custom/pepepow-debug\.log|/hive/miners/custom/diagnostic-summary\.txt|Submit nonce rewrite' "${PACKAGE_DIR}"; then
  echo "Stale version, unsafe path or obsolete rewrite text found in package" >&2
  exit 1
fi

for script in "${PACKAGE_DIR}"/*.sh; do bash -n "${script}"; done
python3 -m py_compile "${PACKAGE_DIR}/stratum-replay-proxy.py"
rm -rf "${PACKAGE_DIR}/__pycache__"
"${PACKAGE_DIR}/pepepowminer" --help | grep -q -- '--diagnostic-log'
"${PACKAGE_DIR}/forensic-audit.sh" "${PACKAGE_DIR}/build-forensic-audit.txt"
grep -q "Expected package dir: ${PACKAGE_DIR}" "${PACKAGE_DIR}/build-forensic-audit.txt"
rm -f "${PACKAGE_DIR}/build-forensic-audit.txt"

strip "${PACKAGE_DIR}/pepepowminer" 2>/dev/null || true
tar -C "${ROOT_DIR}/dist" -czf "${ARCHIVE_PATH}" "${PACKAGE_NAME}"
tar -tzf "${ARCHIVE_PATH}" > "${ARCHIVE_LIST}"

echo "== HiveOS archive contents =="
cat "${ARCHIVE_LIST}"
for entry in pepepowminer h-run.sh h-config.sh h-stats.sh h-manifest.conf diagnostic-summary.sh forensic-audit.sh collect-forensics.sh collect-and-serve.sh capture-stratum.sh stratum-replay-proxy.py VERSION; do
  if ! grep -Fxq "${PACKAGE_NAME}/${entry}" "${ARCHIVE_LIST}"; then
    echo "Missing ${entry}" >&2
    exit 1
  fi
done
if grep -Fq '__pycache__' "${ARCHIVE_LIST}"; then
  echo "Python cache files must not be packaged" >&2
  exit 1
fi

rm -f "${ARCHIVE_LIST}"
SHA256="$(sha256sum "${ARCHIVE_PATH}" | awk '{print $1}')"
printf '\nPASS: PepePow Consensus Math Edition %s package completed\n' "${VERSION}"
printf 'ARCHIVE=%s\n' "${ARCHIVE_PATH}"
printf 'SHA256=%s\n' "${SHA256}"
printf 'DOWNLOAD_COMMAND=cd %q && python3 -m http.server 8080 --bind 0.0.0.0\n' "${ROOT_DIR}/dist"
