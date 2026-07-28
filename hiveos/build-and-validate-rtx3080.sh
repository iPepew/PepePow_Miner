#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_ROOT="${ROOT_DIR}/build-profiles-v040"
LINK_BUILD_DIR="${ROOT_DIR}/build-rtx3080"
FILE_VERSION="$(head -n1 "${ROOT_DIR}/VERSION" | tr -d '[:space:]')"
VERSION="${VERSION:-${FILE_VERSION}}"
[[ "${VERSION}" == "${FILE_VERSION}" ]] || { echo "VERSION mismatch: argument=${VERSION} file=${FILE_VERSION}" >&2; exit 1; }
PACKAGE_NAME="pepepowminer-v${VERSION}"
PACKAGE_DIR="${ROOT_DIR}/dist/${PACKAGE_NAME}"
ARCHIVE_PATH="${ROOT_DIR}/dist/${PACKAGE_NAME}-hiveos.tar.gz"
ARCHIVE_LIST="${ROOT_DIR}/dist/${PACKAGE_NAME}-archive-contents.txt"
JOBS="${JOBS:-$(nproc)}"
CUDA_IMAGE="${CUDA_IMAGE:-nvidia/cuda:12.6.3-devel-ubuntu22.04}"
DEPS_DIR="${ROOT_DIR}/.deps-v040"

if [[ "${VERSION}" == "0.4.1-PR" ]]; then
  PREPARE_SCRIPT="${ROOT_DIR}/hiveos/prepare-v041-source.py"
  EXPECTED_EDITION="PepeW Matrix Cache Edition"
  RELEASE_EDITION="PepeW Matrix Cache Autotune Edition"
else
  PREPARE_SCRIPT="${ROOT_DIR}/hiveos/prepare-v040-source.py"
  EXPECTED_EDITION="PepeW Performance & Stability Edition"
  RELEASE_EDITION="PepeW RTX 3080 Autotune Edition"
fi

command -v nvidia-smi >/dev/null 2>&1 || { echo "nvidia-smi is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }

echo "== NVIDIA device =="
nvidia-smi --query-gpu=name,compute_cap,driver_version,memory.total --format=csv,noheader
if ! nvidia-smi --query-gpu=compute_cap --format=csv,noheader | grep -qx '8.6'; then
  echo "Warning: validation target is RTX 3080 / compute capability 8.6" >&2
fi

chmod +x "${PREPARE_SCRIPT}"
python3 "${PREPARE_SCRIPT}"

# Consensus and release-profile guards run before the expensive builds.
grep -Fq 'write_be32(header, 76, job.nonce);' "${ROOT_DIR}/native/src/core/header_builder.cpp" || { echo "Header80 nonce bytes are not BE32" >&2; exit 1; }
grep -Fq 'const Hash256 matrix_seed = blake3_hash(masked_header);' "${ROOT_DIR}/native/src/crypto/pow.cpp" || { echo "CPU matrix seed is not BLAKE3(masked Header80)" >&2; exit 1; }
grep -Fq 'const crypto::Hash256 matrix_seed = crypto::blake3_hash(masked_header);' "${ROOT_DIR}/native/src/cuda/header80_backend.cu" || { echo "CUDA matrix seed is not BLAKE3(masked Header80)" >&2; exit 1; }
grep -Fq 'const std::uint32_t mix_nonce = load_le32(header.data() + 76);' "${ROOT_DIR}/native/src/crypto/pow.cpp" || { echo "CPU HooHash nonce is not LE32 from Header80" >&2; exit 1; }
grep -Fq 'const std::uint32_t mix_nonce = byte_swap32(nonce);' "${ROOT_DIR}/native/src/cuda/header80_backend.cu" || { echo "CUDA HooHash nonce does not match Header80 byte order" >&2; exit 1; }
grep -Fq 'return fn(x + (1.0 + two));' "${ROOT_DIR}/native/src/crypto/hoohash_reference.cpp" || { echo "CPU HooHash addition order is not canonical" >&2; exit 1; }
grep -Fq 'return fn(x - (1.0 + two));' "${ROOT_DIR}/native/src/crypto/hoohash_reference.cpp" || { echo "CPU HooHash subtraction order is not canonical" >&2; exit 1; }
grep -Fq 'if (two < 0.25) y = x + (1.0 + two);' "${ROOT_DIR}/native/src/cuda/header80_backend.cu" || { echo "CUDA HooHash addition order is not canonical" >&2; exit 1; }
grep -Fq 'else if (two < 0.50) y = x - (1.0 + two);' "${ROOT_DIR}/native/src/cuda/header80_backend.cu" || { echo "CUDA HooHash subtraction order is not canonical" >&2; exit 1; }
grep -Fq 'PASS: 5 consensus HooHash vectors match on CPU/CUDA' "${ROOT_DIR}/native/tests/cuda_header80_validation.cpp" || { echo "CUDA consensus-vector gate is missing" >&2; exit 1; }
grep -Fq 'PASS: live nBits share-target boundaries matched' "${ROOT_DIR}/native/tests/core_tests.cpp" || { echo "Live target-boundary tests are missing" >&2; exit 1; }

grep -Fq 'constexpr std::uint64_t chunk_size = 524288;' "${ROOT_DIR}/native/src/app/main.cpp" || { echo "524K runtime batch is missing" >&2; exit 1; }
grep -Fq 'GPU_COUNT=1' "${ROOT_DIR}/native/src/app/main.cpp" || { echo "Per-GPU status count is missing" >&2; exit 1; }
grep -Fq 'GPU0_HPS=' "${ROOT_DIR}/native/src/app/main.cpp" || { echo "Per-GPU hashrate status is missing" >&2; exit 1; }
grep -Fq 'PEPEPOW_CUDA_THREADS' "${ROOT_DIR}/native/src/cuda/header80_backend.cu" || { echo "CUDA launch-width profile is missing" >&2; exit 1; }
grep -Fq 'PEPEPOW_CUDA_THREADS=${PEPEPOW_CUDA_THREADS}' "${ROOT_DIR}/native/CMakeLists.txt" || { echo "CUDA launch-width CMake definition is missing" >&2; exit 1; }
grep -Fq 'bus_numbers' "${ROOT_DIR}/hiveos/h-stats.sh" || { echo "HiveOS PCI bus mapping is missing" >&2; exit 1; }
grep -Fq '"temp":%s' "${ROOT_DIR}/hiveos/h-stats.sh" || { echo "HiveOS temperature array is missing" >&2; exit 1; }
grep -Fq '"fan":%s' "${ROOT_DIR}/hiveos/h-stats.sh" || { echo "HiveOS fan array is missing" >&2; exit 1; }
grep -Fq 'proxy-console.log' "${ROOT_DIR}/hiveos/h-run.sh" || { echo "Proxy console isolation is missing" >&2; exit 1; }

if [[ "${VERSION}" == "0.4.1-PR" ]]; then
  grep -Fq 'PEPEPOW_CUDA_CHEAP_LUT' "${ROOT_DIR}/native/CMakeLists.txt" || { echo "Matrix-cache CMake option is missing" >&2; exit 1; }
  grep -Fq 'device_cheap_table_' "${ROOT_DIR}/native/src/cuda/header80_backend.cu" || { echo "Persistent matrix-cache buffer is missing" >&2; exit 1; }
  grep -Fq 'PASS: 256 deterministic CPU/CUDA samples match' "${ROOT_DIR}/native/tests/cuda_header80_validation.cpp" || { echo "Deterministic CUDA validation gate is missing" >&2; exit 1; }
  grep -Fq 'cheap_matrix_lut=autotune' "${ROOT_DIR}/native/src/app/main.cpp" || { echo "Matrix-cache telemetry marker is missing" >&2; exit 1; }
fi

if grep -Pq '[\x{1F300}-\x{1FAFF}]|•' "${ROOT_DIR}/native/src/app/main.cpp"; then
  echo "Unsupported terminal emoji or bullet remains in main.cpp" >&2
  exit 1
fi
if grep -Eq 'pepepowminer .*\|[[:space:]]*tee|\.\/pepepowminer .*\|[[:space:]]*tee' "${ROOT_DIR}/hiveos/h-run.sh"; then
  echo "Miner output must not be piped through tee" >&2
  exit 1
fi

find_nvcc() {
  if command -v nvcc >/dev/null 2>&1; then command -v nvcc; return 0; fi
  local candidate
  for candidate in /usr/local/cuda/bin/nvcc /usr/local/cuda-12/bin/nvcc /usr/local/cuda-12.6/bin/nvcc /usr/local/cuda-12.5/bin/nvcc /usr/local/cuda-12.4/bin/nvcc /usr/local/cuda-11.8/bin/nvcc; do
    [[ -x "${candidate}" ]] && { printf '%s\n' "${candidate}"; return 0; }
  done
  return 1
}

profile_hps() {
  sed -n 's/.* hps=\([0-9][0-9]*\).*/\1/p' <<<"$1" | tail -n1
}

build_native_profile() {
  local name="$1" threads="$2" max_regs="$3" nvcc_path="$4"
  local dir="${PROFILE_ROOT}/${name}"
  rm -rf "${dir}"
  echo "== CUDA profile ${name}: threads=${threads} max_regs=${max_regs:-auto} =="
  local cmake_args=(
    -S "${ROOT_DIR}/native" -B "${dir}"
    -DCMAKE_BUILD_TYPE=Release
    -DPEPEPOW_ENABLE_CUDA=ON
    -DPEPEPOW_BUILD_TESTS=ON
    -DPEPEPOW_CUDA_PTXAS_VERBOSE=ON
    -DPEPEPOW_CUDA_THREADS="${threads}"
    -DCMAKE_CUDA_ARCHITECTURES=86
    -DCMAKE_CUDA_COMPILER="${nvcc_path}"
    -DFETCHCONTENT_BASE_DIR="${DEPS_DIR}"
  )
  if [[ -n "${max_regs}" ]]; then
    cmake_args+=( -DPEPEPOW_CUDA_MAX_REGISTERS="${max_regs}" )
  fi
  cmake "${cmake_args[@]}"
  cmake --build "${dir}" --config Release --parallel "${JOBS}"
  ctest --test-dir "${dir}" --output-on-failure
  "${dir}/pepepow_cuda_header80_validation"
  local output
  output="$("${dir}/pepepow_header80_benchmark" 1048576)"
  printf '%s\n' "${output}"
  local hps
  hps="$(profile_hps "${output}")"
  [[ "${hps}" =~ ^[1-9][0-9]*$ ]] || { echo "Cannot parse benchmark for ${name}" >&2; exit 1; }
  printf '%s\n' "${hps}" > "${dir}/profile.hps"
  printf 'PROFILE_RESULT name=%s threads=%s max_regs=%s hps=%s\n' "${name}" "${threads}" "${max_regs:-auto}" "${hps}"
}

build_docker_fallback() {
  local name="t128-auto" dir="${PROFILE_ROOT}/t128-auto"
  command -v docker >/dev/null 2>&1 || { echo "CUDA compiler not found and Docker unavailable" >&2; exit 1; }
  rm -rf "${dir}"
  docker pull "${CUDA_IMAGE}"
  docker run --rm -e DEBIAN_FRONTEND=noninteractive -e JOBS="${JOBS}" \
    -v "${ROOT_DIR}:/workspace" -w /workspace "${CUDA_IMAGE}" bash -lc '
      set -euo pipefail
      apt-get update
      apt-get install -y --no-install-recommends cmake git build-essential ca-certificates python3
      rm -rf /var/lib/apt/lists/* /workspace/build-profiles-v040/t128-auto
      cmake -S /workspace/native -B /workspace/build-profiles-v040/t128-auto \
        -DCMAKE_BUILD_TYPE=Release -DPEPEPOW_ENABLE_CUDA=ON -DPEPEPOW_BUILD_TESTS=ON \
        -DPEPEPOW_CUDA_PTXAS_VERBOSE=ON -DPEPEPOW_CUDA_THREADS=128 \
        -DCMAKE_CUDA_ARCHITECTURES=86 -DCMAKE_CUDA_RUNTIME_LIBRARY=Static \
        -DFETCHCONTENT_BASE_DIR=/workspace/.deps-v040
      cmake --build /workspace/build-profiles-v040/t128-auto --config Release --parallel "${JOBS}"
    '
  ctest --test-dir "${dir}" --output-on-failure
  "${dir}/pepepow_cuda_header80_validation"
  local output hps
  output="$("${dir}/pepepow_header80_benchmark" 1048576)"
  printf '%s\n' "${output}"
  hps="$(profile_hps "${output}")"
  [[ "${hps}" =~ ^[1-9][0-9]*$ ]] || { echo "Cannot parse fallback benchmark" >&2; exit 1; }
  printf '%s\n' "${hps}" > "${dir}/profile.hps"
  printf 'PROFILE_RESULT name=%s threads=128 max_regs=auto hps=%s\n' "${name}" "${hps}"
}

rm -rf "${PROFILE_ROOT}" "${LINK_BUILD_DIR}" "${PACKAGE_DIR}" "${ARCHIVE_PATH}" "${ARCHIVE_LIST}"
mkdir -p "${PROFILE_ROOT}" "${ROOT_DIR}/dist"

profiles=()
if NVCC_PATH="$(find_nvcc)"; then
  export PATH="$(dirname "${NVCC_PATH}"):${PATH}"
  "${NVCC_PATH}" --version
  build_native_profile t64-auto 64 "" "${NVCC_PATH}"
  profiles+=(t64-auto)
  build_native_profile t128-auto 128 "" "${NVCC_PATH}"
  profiles+=(t128-auto)
  build_native_profile t128-r80 128 80 "${NVCC_PATH}"
  profiles+=(t128-r80)
else
  build_docker_fallback
  profiles+=(t128-auto)
fi

best_profile=""
best_hps=0
for profile in "${profiles[@]}"; do
  hps="$(cat "${PROFILE_ROOT}/${profile}/profile.hps")"
  if (( hps > best_hps )); then
    best_hps="${hps}"
    best_profile="${profile}"
  fi
done
[[ -n "${best_profile}" ]] || { echo "No CUDA profile selected" >&2; exit 1; }
SELECTED_BUILD_DIR="${PROFILE_ROOT}/${best_profile}"
ln -s "${SELECTED_BUILD_DIR}" "${LINK_BUILD_DIR}"
printf 'AUTOTUNE_SELECTED profile=%s hps=%s build=%s\n' "${best_profile}" "${best_hps}" "${SELECTED_BUILD_DIR}"

"${SELECTED_BUILD_DIR}/pepepowminer" --list-gpu
BUILD_ID="$("${SELECTED_BUILD_DIR}/pepepowminer" --version)"
echo "BUILD_ID=${BUILD_ID}"
[[ "${BUILD_ID}" == *"${VERSION}"* ]] || { echo "Binary version mismatch: ${BUILD_ID}" >&2; exit 1; }
[[ "${BUILD_ID}" == *"${EXPECTED_EDITION}"* ]] || { echo "Wrong binary edition: expected=${EXPECTED_EDITION} actual=${BUILD_ID}" >&2; exit 1; }

mkdir -p "${PACKAGE_DIR}"
install -m 0755 "${SELECTED_BUILD_DIR}/pepepowminer" "${PACKAGE_DIR}/pepepowminer"
for script in h-run.sh h-config.sh h-stats.sh diagnostic-summary.sh forensic-audit.sh collect-forensics.sh collect-and-serve.sh capture-stratum.sh; do
  install -m 0755 "${ROOT_DIR}/hiveos/${script}" "${PACKAGE_DIR}/${script}"
done
install -m 0755 "${ROOT_DIR}/hiveos/stratum-replay-proxy.py" "${PACKAGE_DIR}/stratum-replay-proxy.py"
install -m 0644 "${ROOT_DIR}/hiveos/h-manifest.conf" "${PACKAGE_DIR}/h-manifest.conf"
install -m 0644 "${ROOT_DIR}/VERSION" "${PACKAGE_DIR}/VERSION"

{
  echo "selected_profile=${best_profile}"
  echo "selected_hps=${best_hps}"
  echo "edition=${EXPECTED_EDITION}"
  for profile in "${profiles[@]}"; do
    echo "${profile}_hps=$(cat "${PROFILE_ROOT}/${profile}/profile.hps")"
  done
} > "${PACKAGE_DIR}/BUILD_PROFILE"

sed -i "s/^CUSTOM_VERSION=.*/CUSTOM_VERSION=${VERSION}/" "${PACKAGE_DIR}/h-manifest.conf"
sed -i "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=/hive/miners/custom/${PACKAGE_NAME}/config.txt#" "${PACKAGE_DIR}/h-manifest.conf"

PACKAGED_ID="$("${PACKAGE_DIR}/pepepowminer" --version)"
[[ "${PACKAGED_ID}" == "${BUILD_ID}" ]] || { echo "Packaged binary identity mismatch" >&2; exit 1; }
grep -qx "CUSTOM_VERSION=${VERSION}" "${PACKAGE_DIR}/h-manifest.conf"
grep -qx "CUSTOM_CONFIG_FILENAME=/hive/miners/custom/${PACKAGE_NAME}/config.txt" "${PACKAGE_DIR}/h-manifest.conf"
grep -qx "${VERSION}" "${PACKAGE_DIR}/VERSION"

MINER_DIR="${PACKAGE_DIR}" source "${PACKAGE_DIR}/h-stats.sh"
[[ "${stats}" == *'"ver":""'* ]] || { echo "h-stats duplicate version field: ${stats}" >&2; exit 1; }
[[ "${stats}" == *'"hs":[0]'* ]] || { echo "h-stats must reset stopped hashrate: ${stats}" >&2; exit 1; }
[[ "${stats}" == *'"temp":['* ]] || { echo "h-stats temperature output missing: ${stats}" >&2; exit 1; }
[[ "${stats}" == *'"fan":['* ]] || { echo "h-stats fan output missing: ${stats}" >&2; exit 1; }
[[ "${stats}" == *'"bus_numbers":['* ]] || { echo "h-stats bus mapping missing: ${stats}" >&2; exit 1; }

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
for entry in pepepowminer h-run.sh h-config.sh h-stats.sh h-manifest.conf diagnostic-summary.sh forensic-audit.sh collect-forensics.sh collect-and-serve.sh capture-stratum.sh stratum-replay-proxy.py VERSION BUILD_PROFILE; do
  grep -Fxq "${PACKAGE_NAME}/${entry}" "${ARCHIVE_LIST}" || { echo "Missing ${entry}" >&2; exit 1; }
done
if grep -Fq '__pycache__' "${ARCHIVE_LIST}"; then
  echo "Python cache files must not be packaged" >&2
  exit 1
fi

rm -f "${ARCHIVE_LIST}"
SHA256="$(sha256sum "${ARCHIVE_PATH}" | awk '{print $1}')"
printf '\nPASS: %s %s package completed\n' "${RELEASE_EDITION}" "${VERSION}"
printf 'AUTOTUNE_PROFILE=%s\n' "${best_profile}"
printf 'AUTOTUNE_HPS=%s\n' "${best_hps}"
printf 'ARCHIVE=%s\n' "${ARCHIVE_PATH}"
printf 'SHA256=%s\n' "${SHA256}"
printf 'DOWNLOAD_COMMAND=cd %q && python3 -m http.server 8080 --bind 0.0.0.0\n' "${ROOT_DIR}/dist"
