#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

VERSION=1.0.4
ROOT_NAME="PepeW-Miner-v${VERSION}-HiveOS"
ASSET_NAME="${ROOT_NAME}-${VERSION}.tar.gz"
REPO_URL="${REPO_URL:-https://github.com/iPepew/PepePow_Miner.git}"
RELEASE_REF="${RELEASE_REF:-release/v1.0.4}"
WORK_ROOT="${WORK_ROOT:-/root/pepew-v104-universal}"
OUT_DIR="${OUT_DIR:-/root/pepepow-tests}"
SRC="${WORK_ROOT}/src"
BUILD="${WORK_ROOT}/build"
STAGE="${WORK_ROOT}/stage"
PACKAGE_DIR="${STAGE}/${ROOT_NAME}"
ARCHIVE="${OUT_DIR}/${ASSET_NAME}"
SHA_FILE="${ARCHIVE}.sha256"
ARCH_LIST="61-real;75-real;86-real;89-real;120"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

for command_name in bash git python3 sha256sum tar awk sed grep nvidia-smi; do
  command -v "${command_name}" >/dev/null 2>&1 || fail "missing command: ${command_name}"
done

CUDA_HOME="${CUDA_HOME:-/usr/local/cuda-12.8}"
if [[ ! -x "${CUDA_HOME}/bin/nvcc" && -x /usr/local/cuda/bin/nvcc ]]; then
  CUDA_HOME=/usr/local/cuda
fi
NVCC="${NVCC:-${CUDA_HOME}/bin/nvcc}"
CUOBJDUMP="${CUOBJDUMP:-${CUDA_HOME}/bin/cuobjdump}"
CMAKE="${CMAKE_COMMAND:-$(command -v cmake || true)}"
CTEST="${CTEST_COMMAND:-$(command -v ctest || true)}"

[[ -x "${NVCC}" ]] || fail "CUDA nvcc not found; install CUDA Toolkit 12.8.x"
[[ -x "${CUOBJDUMP}" ]] || fail "cuobjdump not found in ${CUDA_HOME}/bin"
[[ -x "${CMAKE}" ]] || fail "cmake not found"
[[ -x "${CTEST}" ]] || fail "ctest not found"

CUDA_RELEASE="$(${NVCC} --version | sed -nE 's/.*release ([0-9]+\.[0-9]+).*/\1/p' | tail -n1)"
[[ "${CUDA_RELEASE}" == "12.8" ]] || fail "universal GTX10-RTX50 package must be built with CUDA 12.8.x; found ${CUDA_RELEASE:-unknown}"

CMAKE_VERSION="$(${CMAKE} --version | awk 'NR==1 {print $3}')"
python3 - "${CMAKE_VERSION}" <<'PY'
import sys
parts=[]
for item in sys.argv[1].split('.'):
    digits=''.join(ch for ch in item if ch.isdigit())
    parts.append(int(digits or 0))
while len(parts) < 3:
    parts.append(0)
if tuple(parts[:3]) < (3, 24, 0):
    raise SystemExit(f"ERROR: CMake >= 3.24 required; found {sys.argv[1]}")
PY

JOBS="${JOBS:-$(nproc)}"
[[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] || fail "JOBS must be a positive integer"
(( JOBS > 12 )) && JOBS=12

rm -rf "${WORK_ROOT}"
mkdir -p "${WORK_ROOT}" "${OUT_DIR}"

echo "RELEASE_STAGE=CLONE"
git clone --depth 1 --branch "${RELEASE_REF}" "${REPO_URL}" "${SRC}"
SOURCE_COMMIT="$(git -C "${SRC}" rev-parse HEAD)"

[[ "$(tr -d '\r\n' < "${SRC}/VERSION")" == "${VERSION}" ]] || fail "source VERSION mismatch"

echo "RELEASE_STAGE=CONFIGURE"
export CUDACXX="${NVCC}"
"${CMAKE}" -S "${SRC}/native" -B "${BUILD}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CUDA_COMPILER="${NVCC}" \
  -DPEPEPOW_ENABLE_CUDA=ON \
  -DPEPEPOW_BUILD_TESTS=ON \
  -DPEPEPOW_CUDA_PTXAS_VERBOSE=ON \
  -DPEPEPOW_CUDA_ARCHITECTURES="${ARCH_LIST}" \
  -DPEPEPOW_CUDA_THREADS=768 \
  -DPEPEPOW_CUDA_MIN_BLOCKS=1 \
  2>&1 | tee "${WORK_ROOT}/configure.log"

echo "RELEASE_STAGE=BUILD"
"${CMAKE}" --build "${BUILD}" --parallel "${JOBS}" --target \
  pepepowminer pepepow_core_tests pepepow_cuda_tests pepepow_cuda_header80_validation \
  pepepow_header80_benchmark \
  2>&1 | tee "${WORK_ROOT}/build.log"

[[ -x "${BUILD}/pepepowminer" ]] || fail "pepepowminer was not built"

BINARY_VERSION="$(${BUILD}/pepepowminer --version)"
grep -Fq "PepeW Miner v${VERSION}" <<<"${BINARY_VERSION}" || fail "binary identity mismatch: ${BINARY_VERSION}"

echo "RELEASE_STAGE=CTEST"
"${CTEST}" --test-dir "${BUILD}" --output-on-failure \
  2>&1 | tee "${WORK_ROOT}/ctest.log"

echo "RELEASE_STAGE=FATBIN_VERIFY"
"${CUOBJDUMP}" --list-elf "${BUILD}/pepepowminer" > "${WORK_ROOT}/fatbin-elf.txt"
"${CUOBJDUMP}" --list-ptx "${BUILD}/pepepowminer" > "${WORK_ROOT}/fatbin-ptx.txt"
for arch in sm_61 sm_75 sm_86 sm_89 sm_120; do
  grep -Fq "${arch}" "${WORK_ROOT}/fatbin-elf.txt" || fail "missing native cubin: ${arch}"
  echo "FATBIN_CUBIN=${arch}:PASS"
done
if ! grep -Eq 'compute_120|sm_120' "${WORK_ROOT}/fatbin-ptx.txt"; then
  fail "missing compute_120 PTX"
fi
echo "FATBIN_PTX=compute_120:PASS"

"${BUILD}/pepepowminer" --list-gpu | tee "${WORK_ROOT}/gpu-list.txt"

rm -rf "${STAGE}"
mkdir -p "${PACKAGE_DIR}"
install -m 0755 "${BUILD}/pepepowminer" "${PACKAGE_DIR}/pepepowminer"
install -m 0755 "${SRC}/hiveos/h-config.sh" "${PACKAGE_DIR}/h-config.sh"
install -m 0755 "${SRC}/hiveos/h-run.sh" "${PACKAGE_DIR}/h-run.sh"
install -m 0755 "${SRC}/hiveos/h-stats.sh" "${PACKAGE_DIR}/h-stats.sh"
install -m 0755 "${SRC}/hiveos/stratum-replay-proxy.py" "${PACKAGE_DIR}/stratum-replay-proxy.py"
install -m 0644 "${SRC}/hiveos/h-manifest.conf" "${PACKAGE_DIR}/h-manifest.conf"
install -m 0644 "${SRC}/LICENSE" "${PACKAGE_DIR}/LICENSE"
install -m 0644 "${SRC}/README.md" "${PACKAGE_DIR}/README.md"
install -m 0644 "${SRC}/RELEASE_NOTES_v1.0.4.md" "${PACKAGE_DIR}/RELEASE_NOTES_v1.0.4.md"
printf '%s\n' "${VERSION}" > "${PACKAGE_DIR}/VERSION"

BINARY_SHA="$(sha256sum "${PACKAGE_DIR}/pepepowminer" | awk '{print $1}')"
(
  cd "${PACKAGE_DIR}"
  printf '%s  %s\n' "${BINARY_SHA}" pepepowminer > pepepowminer.sha256
)

cat > "${PACKAGE_DIR}/BUILD_PROFILE" <<PROFILE
release=PepeW Miner v${VERSION}
source_commit=${SOURCE_COMMIT}
build_type=Release
cuda_toolkit=${CUDA_RELEASE}
cuda_compiler=${NVCC}
cmake=${CMAKE_VERSION}
cuda_architectures=${ARCH_LIST}
cuda_native=sm_61,sm_75,sm_86,sm_89,sm_120
cuda_ptx=compute_120
cuda_profile=service768
multi_gpu=process-per-GPU
binary_sha256=${BINARY_SHA}
PROFILE

cat > "${PACKAGE_DIR}/RELEASE_MANIFEST.txt" <<MANIFEST
PepeW Miner v${VERSION}
Package: ${ROOT_NAME}
Asset: ${ASSET_NAME}
Archive root: ${ROOT_NAME}/
Install path: /hive/miners/custom/${ROOT_NAME}
Algorithm: PEPEPOW HooHash V110
CUDA profile: service768 universal fat binary
CUDA native: sm_61; sm_75; sm_86; sm_89; sm_120
CUDA PTX: compute_120
Multi-GPU: one isolated miner and Stratum proxy process per selected NVIDIA GPU
Binary SHA256: ${BINARY_SHA}
Telemetry: aggregate khs and Accepted/Rejected; per-GPU hs[], temp[], fan[], bus_numbers[]
MANIFEST

required=(
  BUILD_PROFILE LICENSE README.md RELEASE_MANIFEST.txt RELEASE_NOTES_v1.0.4.md
  VERSION h-config.sh h-manifest.conf h-run.sh h-stats.sh pepepowminer
  pepepowminer.sha256 stratum-replay-proxy.py
)
for file in "${required[@]}"; do
  [[ -s "${PACKAGE_DIR}/${file}" ]] || fail "missing package file: ${file}"
done

bash -n "${PACKAGE_DIR}/h-config.sh"
bash -n "${PACKAGE_DIR}/h-run.sh"
bash -n "${PACKAGE_DIR}/h-stats.sh"
python3 -m py_compile "${PACKAGE_DIR}/stratum-replay-proxy.py"
rm -rf "${PACKAGE_DIR}/__pycache__"

(cd "${PACKAGE_DIR}" && sha256sum -c pepepowminer.sha256)
grep -Fqx "CUSTOM_NAME=${ROOT_NAME}" "${PACKAGE_DIR}/h-manifest.conf" || fail "manifest name mismatch"
grep -Fqx "CUSTOM_VERSION=${VERSION}" "${PACKAGE_DIR}/h-manifest.conf" || fail "manifest version mismatch"

echo "RELEASE_STAGE=CONFIG_SELFTEST"
CONFIG_TEST="${WORK_ROOT}/config-selftest.txt"
CUSTOM_URL="stratum+tcp://example.invalid:1234" \
CUSTOM_TEMPLATE="wallet.worker" \
CUSTOM_PASS="x" \
CUSTOM_CONFIG_FILENAME="${CONFIG_TEST}" \
PEPEW_DEVICES="0,2" \
  bash -c 'source "$1"' _ "${PACKAGE_DIR}/h-config.sh"
# shellcheck disable=SC1090
source "${CONFIG_TEST}"
[[ "${PEPEPOW_DEVICES}" == "0,2" ]] || fail "device selection config self-test failed"
[[ "${#PEPEPOW_EXTRA_ARGS[@]}" -eq 0 ]] || fail "empty extra args self-test failed"
rm -f "${CONFIG_TEST}" "${PACKAGE_DIR}/setup.txt"
echo "HIVEOS_CONFIG_GATE=PASS"

echo "RELEASE_STAGE=TELEMETRY_SELFTEST"
FIXTURE="${WORK_ROOT}/telemetry-fixture"
mkdir -p "${FIXTURE}/gpu0" "${FIXTURE}/gpu1"
NOW="$(date +%s)"
cat > "${FIXTURE}/nvidia.csv" <<CSV
0, 00000000:01:00.0, 66, 71
1, 00000000:02:00.0, 62, 55
CSV
cat > "${FIXTURE}/gpu0/miner-status.env" <<STATUS0
HPS=1500000
ACCEPTED=7
REJECTED=0
UPTIME=120
UPDATED_EPOCH=${NOW}
PID=1
STATE=mining
STATUS0
cat > "${FIXTURE}/gpu1/miner-status.env" <<STATUS1
HPS=1700000
ACCEPTED=5
REJECTED=1
UPTIME=118
UPDATED_EPOCH=${NOW}
PID=1
STATE=mining
STATUS1
TELEMETRY_OUTPUT="$(
  PEPEW_STATUS_ROOT="${FIXTURE}" \
  PEPEW_NVIDIA_SMI_FILE="${FIXTURE}/nvidia.csv" \
  PEPEW_STATS_SELFTEST=1 \
  PEPEW_NOW_EPOCH="${NOW}" \
    bash -c 'source "$1"; printf "%s\n%s\n" "$khs" "$stats"' _ "${PACKAGE_DIR}/h-stats.sh"
)"
TELEMETRY_KHS="$(sed -n '1p' <<<"${TELEMETRY_OUTPUT}")"
TELEMETRY_JSON="$(sed -n '2p' <<<"${TELEMETRY_OUTPUT}")"
[[ "${TELEMETRY_KHS}" == "3200" ]] || fail "aggregate khs self-test failed: ${TELEMETRY_KHS}"
grep -Fq '"hs":[1500,1700]' <<<"${TELEMETRY_JSON}" || fail "per-GPU hs self-test failed: ${TELEMETRY_JSON}"
grep -Fq '"temp":[66,62]' <<<"${TELEMETRY_JSON}" || fail "temperature self-test failed"
grep -Fq '"fan":[71,55]' <<<"${TELEMETRY_JSON}" || fail "fan self-test failed"
grep -Fq '"ar":[12,1,0]' <<<"${TELEMETRY_JSON}" || fail "share aggregation self-test failed"
grep -Fq '"bus_numbers":[1,2]' <<<"${TELEMETRY_JSON}" || fail "PCI bus self-test failed"
grep -Fq '"ver":"1.0.4"' <<<"${TELEMETRY_JSON}" || fail "telemetry version self-test failed"
echo "HIVEOS_MULTI_GPU_TELEMETRY_GATE=PASS stats=${TELEMETRY_JSON}"

# The runtime launcher must isolate workers by UUID and produce per-GPU status paths.
grep -Fq 'CUDA_VISIBLE_DEVICES="${gpu_uuid}"' "${PACKAGE_DIR}/h-run.sh" || fail "CUDA UUID worker isolation missing"
grep -Fq 'worker_dir="${miner_dir}/gpu${gpu_index}"' "${PACKAGE_DIR}/h-run.sh" || fail "per-GPU worker directory missing"
grep -Fq 'PEPEPOW_PROXY_PORT_BASE + position' "${PACKAGE_DIR}/h-run.sh" || fail "per-GPU proxy port allocation missing"
echo "HIVEOS_MULTI_GPU_LAUNCHER_GATE=PASS"

rm -f "${ARCHIVE}" "${SHA_FILE}"
tar --sort=name --owner=0 --group=0 --numeric-owner \
  -C "${STAGE}" -cf - "${ROOT_NAME}" | gzip -n > "${ARCHIVE}"
(
  cd "${OUT_DIR}"
  sha256sum "${ASSET_NAME}" > "$(basename "${SHA_FILE}")"
)

ARCHIVE_BASE="${ASSET_NAME%.tar.gz}"
DETECTED_VERSION="$(awk -F- '{print $NF}' <<<"${ARCHIVE_BASE}")"
DETECTED_MINER="${ARCHIVE_BASE%-${DETECTED_VERSION}}"
[[ "${DETECTED_VERSION}" == "${VERSION}" ]] || fail "custom-get version parse mismatch"
[[ "${DETECTED_MINER}" == "${ROOT_NAME}" ]] || fail "custom-get miner parse mismatch"

FIRST_ENTRY="$(tar -tzf "${ARCHIVE}" | sed -n '1p')"
[[ "${FIRST_ENTRY}" == "${ROOT_NAME}/" ]] || fail "invalid archive root: ${FIRST_ENTRY}"
tar -tzf "${ARCHIVE}" | grep -Fqx "${ROOT_NAME}/h-manifest.conf" || fail "manifest missing from archive"
if tar -tzf "${ARCHIVE}" | grep -Eq '(^|/)(config\.txt|setup\.txt|active-workers\.env|gpu[0-9]+|.*\.log(\.previous)?|.*\.pid|miner-status\.env)$'; then
  fail "runtime artifact detected in package"
fi

EXTRACT_TEST="${WORK_ROOT}/extract-test"
rm -rf "${EXTRACT_TEST}"
mkdir -p "${EXTRACT_TEST}"
tar -xzf "${ARCHIVE}" -C "${EXTRACT_TEST}"
[[ -x "${EXTRACT_TEST}/${ROOT_NAME}/pepepowminer" ]] || fail "manual extraction test failed"

ARCHIVE_SHA="$(sha256sum "${ARCHIVE}" | awk '{print $1}')"
echo "BUILD_TOOLCHAIN_GATE=PASS cuda=${CUDA_RELEASE} cmake=${CMAKE_VERSION}"
echo "FATBIN_ARCHITECTURE_GATE=PASS native=61,75,86,89,120 ptx=120"
echo "PACKAGE_NAME_GATE=PASS miner=${DETECTED_MINER} version=${DETECTED_VERSION}"
echo "PACKAGE_ROOT_GATE=PASS root=${ROOT_NAME}/"
echo "ARCHIVE_SHA256=${ARCHIVE_SHA}"
echo "BINARY_SHA256=${BINARY_SHA}"
echo "ARCHIVE=${ARCHIVE}"
echo "SHA256_FILE=${SHA_FILE}"
echo "RELEASE_STAGE=COMPLETE"
