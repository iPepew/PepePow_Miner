#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_ROOT="${ROOT_DIR}/build-profiles-v051"
LINK_BUILD_DIR="${ROOT_DIR}/build-rtx3080"
VERSION="$(head -n1 "${ROOT_DIR}/VERSION" | tr -d '[:space:]')"
[[ "${VERSION}" == "0.5.1-PR" ]] || { echo "Expected VERSION=0.5.1-PR, found ${VERSION}" >&2; exit 1; }
PACKAGE_NAME="pepepowminer-v${VERSION}"
PACKAGE_DIR="${ROOT_DIR}/dist/${PACKAGE_NAME}"
ARCHIVE_PATH="${ROOT_DIR}/dist/${PACKAGE_NAME}-hiveos.tar.gz"
ARCHIVE_LIST="${ROOT_DIR}/dist/${PACKAGE_NAME}-archive-contents.txt"
JOBS="${JOBS:-$(nproc)}"
DEPS_DIR="${ROOT_DIR}/.deps-v051"
PREPARE_SCRIPT="${ROOT_DIR}/hiveos/prepare-v051-source.py"
EXPECTED_EDITION="PepeW Split Pipeline Edition"
RELEASE_EDITION="PepeW Split Pipeline Autotune Edition"
BENCH_NONCES="${BENCH_NONCES:-4194304}"
BENCH_RUNS="${BENCH_RUNS:-3}"
TARGET_HPS="${TARGET_HPS:-2000000}"

command -v nvidia-smi >/dev/null 2>&1 || { echo "nvidia-smi is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
command -v cmake >/dev/null 2>&1 || { echo "cmake is required" >&2; exit 1; }
command -v awk >/dev/null 2>&1 || { echo "awk is required" >&2; exit 1; }

echo "== NVIDIA device =="
nvidia-smi --query-gpu=name,compute_cap,driver_version,memory.total,clocks.current.sm,clocks.current.memory,power.limit --format=csv,noheader
if ! nvidia-smi --query-gpu=compute_cap --format=csv,noheader | grep -qx '8.6'; then
  echo "Warning: validation target is RTX 3080 / compute capability 8.6" >&2
fi

chmod +x "${PREPARE_SCRIPT}"
python3 "${PREPARE_SCRIPT}"

# Consensus and v0.5.1 performance guards before expensive compilation.
grep -Fq 'write_be32(header, 76, job.nonce);' "${ROOT_DIR}/native/src/core/header_builder.cpp" || { echo "Header80 nonce bytes are not BE32" >&2; exit 1; }
grep -Fq 'return fn(x + (1.0 + two));' "${ROOT_DIR}/native/src/crypto/hoohash_reference.cpp" || { echo "CPU HooHash addition order is not canonical" >&2; exit 1; }
grep -Fq 'return fn(x - (1.0 + two));' "${ROOT_DIR}/native/src/crypto/hoohash_reference.cpp" || { echo "CPU HooHash subtraction order is not canonical" >&2; exit 1; }
CUDA_SOURCE="${ROOT_DIR}/native/src/cuda/header80_backend_v051.cu"
grep -Fq 'positive_fraction' "${CUDA_SOURCE}" || { echo "Exact positive-fraction path is missing" >&2; exit 1; }
grep -Fq 'header80_first_kernel' "${CUDA_SOURCE}" || { echo "Split first BLAKE3 kernel is missing" >&2; exit 1; }
grep -Fq 'hoohash_mix_kernel' "${CUDA_SOURCE}" || { echo "Split HooHash kernel is missing" >&2; exit 1; }
grep -Fq 'header80_final_kernel' "${CUDA_SOURCE}" || { echo "Split final BLAKE3 kernel is missing" >&2; exit 1; }
grep -Fq 'cudaFuncCachePreferL1' "${CUDA_SOURCE}" || { echo "L1 cache preference is missing" >&2; exit 1; }
grep -Fq 'device_work_capacity_' "${CUDA_SOURCE}" || { echo "Persistent split work buffer is missing" >&2; exit 1; }
grep -Fq 'PASS: 1024 split-pipeline CPU/CUDA samples match' "${ROOT_DIR}/native/tests/cuda_header80_validation.cpp" || { echo "1024-sample validation gate is missing" >&2; exit 1; }
grep -Fq 'https://t.me/pepepow_ru' "${ROOT_DIR}/native/src/app/main.cpp" || { echo "Telegram group link is missing" >&2; exit 1; }
grep -Fq 'constexpr std::uint64_t chunk_size = 348160;' "${ROOT_DIR}/native/src/app/main.cpp" || { echo "348160 runtime batch is missing" >&2; exit 1; }
grep -Fq 'bus_numbers' "${ROOT_DIR}/hiveos/h-stats.sh" || { echo "HiveOS PCI bus mapping is missing" >&2; exit 1; }

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

profile_registers() {
  local log="$1"
  awk '/Used [0-9]+ registers/ {for (i=1;i<=NF;i++) if ($i=="Used") {v=$(i+1)+0; if (v>m)m=v}} END {print m+0}' "${log}"
}

profile_spills() {
  local log="$1"
  awk '/bytes spill stores/ {for (i=1;i<=NF;i++) if ($(i+1)=="bytes" && $(i+2)=="spill") {v=$i+0; if (v>m)m=v}} END {print m+0}' "${log}"
}

median_hps() {
  printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END {if (NR%2) print a[(NR+1)/2]; else print int((a[NR/2]+a[NR/2+1])/2)}'
}

build_profile() {
  local name="$1" threads="$2" min_blocks="$3" split="$4" fast_fraction="$5" unroll="$6" max_regs="$7" nvcc_path="$8"
  local dir="${PROFILE_ROOT}/${name}"
  local build_log="${dir}.build.log"
  rm -rf "${dir}" "${build_log}"
  echo "== CUDA profile ${name}: threads=${threads} min_blocks=${min_blocks} split=${split} fast_fraction=${fast_fraction} unroll=${unroll} max_regs=${max_regs:-auto} =="
  local cmake_args=(
    -S "${ROOT_DIR}/native" -B "${dir}"
    -DCMAKE_BUILD_TYPE=Release
    -DPEPEPOW_ENABLE_CUDA=ON
    -DPEPEPOW_BUILD_TESTS=ON
    -DPEPEPOW_CUDA_PTXAS_VERBOSE=ON
    -DPEPEPOW_CUDA_THREADS="${threads}"
    -DPEPEPOW_CUDA_MIN_BLOCKS="${min_blocks}"
    -DPEPEPOW_CUDA_SCALED_MATRIX=ON
    -DPEPEPOW_CUDA_SPLIT_PIPELINE="${split}"
    -DPEPEPOW_CUDA_FAST_FRACTION="${fast_fraction}"
    -DPEPEPOW_CUDA_BYTE_UNROLL="${unroll}"
    -DCMAKE_CUDA_ARCHITECTURES=86
    -DCMAKE_CUDA_COMPILER="${nvcc_path}"
    -DFETCHCONTENT_BASE_DIR="${DEPS_DIR}"
  )
  if [[ -n "${max_regs}" ]]; then
    cmake_args+=( -DPEPEPOW_CUDA_MAX_REGISTERS="${max_regs}" )
  fi
  cmake "${cmake_args[@]}"
  cmake --build "${dir}" --config Release --parallel "${JOBS}" 2>&1 | tee "${build_log}"
  ctest --test-dir "${dir}" --output-on-failure
  "${dir}/pepepow_cuda_header80_validation"

  local speeds=() output hps
  for ((run=1; run<=BENCH_RUNS; ++run)); do
    output="$("${dir}/pepepow_header80_benchmark" "${BENCH_NONCES}")"
    printf 'BENCH_RUN profile=%s run=%s %s\n' "${name}" "${run}" "${output}"
    hps="$(profile_hps "${output}")"
    [[ "${hps}" =~ ^[1-9][0-9]*$ ]] || { echo "Cannot parse benchmark for ${name}" >&2; exit 1; }
    speeds+=("${hps}")
  done

  local selected_hps regs spills
  selected_hps="$(median_hps "${speeds[@]}")"
  regs="$(profile_registers "${build_log}")"
  spills="$(profile_spills "${build_log}")"
  printf '%s\n' "${selected_hps}" > "${dir}/profile.hps"
  printf 'name=%s\nthreads=%s\nmin_blocks=%s\nsplit=%s\nfast_fraction=%s\nunroll=%s\nmax_regs=%s\nregisters=%s\nmax_spill_bytes=%s\nbenchmark_runs=%s\nbenchmark_hps=%s\nmedian_hps=%s\n' \
    "${name}" "${threads}" "${min_blocks}" "${split}" "${fast_fraction}" "${unroll}" "${max_regs:-auto}" "${regs}" "${spills}" "${BENCH_RUNS}" "${speeds[*]}" "${selected_hps}" \
    > "${dir}/profile.meta"
  printf 'PROFILE_RESULT name=%s threads=%s min_blocks=%s split=%s fast_fraction=%s unroll=%s max_regs=%s registers=%s spills=%s median_hps=%s\n' \
    "${name}" "${threads}" "${min_blocks}" "${split}" "${fast_fraction}" "${unroll}" "${max_regs:-auto}" "${regs}" "${spills}" "${selected_hps}"
}

NVCC_PATH="$(find_nvcc)" || { echo "CUDA nvcc compiler not found" >&2; exit 1; }
export PATH="$(dirname "${NVCC_PATH}"):${PATH}"
"${NVCC_PATH}" --version

rm -rf "${PROFILE_ROOT}" "${LINK_BUILD_DIR}" "${PACKAGE_DIR}" "${ARCHIVE_PATH}" "${ARCHIVE_LIST}"
mkdir -p "${PROFILE_ROOT}" "${ROOT_DIR}/dist"

profiles=()
build_profile mono64-u2-fast        64 1 OFF ON 2 "" "${NVCC_PATH}"; profiles+=(mono64-u2-fast)
build_profile split128-u2-fast     128 1 ON  ON 2 "" "${NVCC_PATH}"; profiles+=(split128-u2-fast)
build_profile split256-u2-fast     256 1 ON  ON 2 "" "${NVCC_PATH}"; profiles+=(split256-u2-fast)
build_profile split320-u1-fast     320 1 ON  ON 1 "" "${NVCC_PATH}"; profiles+=(split320-u1-fast)
build_profile split320-u2-fast     320 1 ON  ON 2 "" "${NVCC_PATH}"; profiles+=(split320-u2-fast)
build_profile split320-b2-u2-fast  320 2 ON  ON 2 "" "${NVCC_PATH}"; profiles+=(split320-b2-u2-fast)
build_profile split320-r96-u2-fast 320 1 ON  ON 2 96 "${NVCC_PATH}"; profiles+=(split320-r96-u2-fast)
build_profile split384-u2-fast     384 1 ON  ON 2 "" "${NVCC_PATH}"; profiles+=(split384-u2-fast)

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

baseline_hps="$(cat "${PROFILE_ROOT}/mono64-u2-fast/profile.hps")"
uplift_pct="$(awk -v best="${best_hps}" -v base="${baseline_hps}" 'BEGIN {if (base>0) printf "%.2f", (best/base-1.0)*100.0; else print "0.00"}')"
SELECTED_BUILD_DIR="${PROFILE_ROOT}/${best_profile}"
ln -s "${SELECTED_BUILD_DIR}" "${LINK_BUILD_DIR}"
printf 'AUTOTUNE_SELECTED profile=%s hps=%s baseline_hps=%s uplift_pct=%s build=%s\n' \
  "${best_profile}" "${best_hps}" "${baseline_hps}" "${uplift_pct}" "${SELECTED_BUILD_DIR}"
if (( best_hps >= TARGET_HPS )); then
  echo "TARGET_2MH=PASS measured_hps=${best_hps}"
else
  echo "TARGET_2MH=PENDING measured_hps=${best_hps}"
fi

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
  echo "baseline_profile=mono64-u2-fast"
  echo "baseline_hps=${baseline_hps}"
  echo "uplift_pct=${uplift_pct}"
  echo "target_hps=${TARGET_HPS}"
  echo "edition=${EXPECTED_EDITION}"
  echo "benchmark_nonces=${BENCH_NONCES}"
  echo "benchmark_runs=${BENCH_RUNS}"
  for profile in "${profiles[@]}"; do
    echo "--- ${profile} ---"
    cat "${PROFILE_ROOT}/${profile}/profile.meta"
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
printf 'AUTOTUNE_BASELINE_HPS=%s\n' "${baseline_hps}"
printf 'AUTOTUNE_UPLIFT_PCT=%s\n' "${uplift_pct}"
if (( best_hps >= TARGET_HPS )); then printf 'TARGET_2MH=PASS\n'; else printf 'TARGET_2MH=PENDING\n'; fi
printf 'ARCHIVE=%s\n' "${ARCHIVE_PATH}"
printf 'SHA256=%s\n' "${SHA256}"
printf 'DOWNLOAD_COMMAND=cd %q && python3 -m http.server 8080 --bind 0.0.0.0\n' "${ROOT_DIR}/dist"
