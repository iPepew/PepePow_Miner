#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_ROOT="${ROOT_DIR}/build-profiles-v053"
LINK_BUILD_DIR="${ROOT_DIR}/build-rtx3080-v053"
VERSION="$(head -n1 "${ROOT_DIR}/VERSION" | tr -d '[:space:]')"
[[ "${VERSION}" == "0.5.3-PR" ]] || { echo "Expected VERSION=0.5.3-PR, found ${VERSION}" >&2; exit 1; }
PACKAGE_NAME="pepepowminer-v${VERSION}"
PACKAGE_DIR="${ROOT_DIR}/dist/${PACKAGE_NAME}"
ARCHIVE_PATH="${ROOT_DIR}/dist/${PACKAGE_NAME}-hiveos.tar.gz"
JOBS="${JOBS:-$(nproc)}"
DEPS_DIR="${ROOT_DIR}/.deps-v053"
PREPARE_SCRIPT="${ROOT_DIR}/hiveos/prepare-v053-source.py"
EXPECTED_EDITION="PepeW Bit Fraction Edition"
BENCH_NONCES="${BENCH_NONCES:-4194304}"
BENCH_RUNS="${BENCH_RUNS:-3}"
TARGET_HPS="${TARGET_HPS:-2000000}"

for command_name in nvidia-smi python3 cmake awk sort sha256sum; do
  command -v "${command_name}" >/dev/null 2>&1 || { echo "${command_name} is required" >&2; exit 1; }
done

echo "== NVIDIA validation target =="
nvidia-smi --query-gpu=name,compute_cap,driver_version,memory.total,clocks.current.sm,clocks.current.memory,power.limit --format=csv,noheader
if ! nvidia-smi --query-gpu=compute_cap --format=csv,noheader | grep -qx '8.6'; then
  echo "WARNING: this autotuner is designed for RTX 3080 / sm_86" >&2
fi

find_nvcc() {
  if command -v nvcc >/dev/null 2>&1; then command -v nvcc; return 0; fi
  local candidate
  for candidate in /usr/local/cuda/bin/nvcc /usr/local/cuda-12.4/bin/nvcc /usr/local/cuda-12/bin/nvcc; do
    [[ -x "${candidate}" ]] && { printf '%s\n' "${candidate}"; return 0; }
  done
  return 1
}

profile_hps() { sed -n 's/.* hps=\([0-9][0-9]*\).*/\1/p' <<<"$1" | tail -n1; }
profile_registers() { awk '/Used [0-9]+ registers/ {for (i=1;i<=NF;i++) if ($i=="Used") {v=$(i+1)+0; if (v>m)m=v}} END {print m+0}' "$1"; }
profile_spills() { awk '/bytes spill stores/ {for (i=1;i<=NF;i++) if ($(i+1)=="bytes" && $(i+2)=="spill") {v=$i+0; if (v>m)m=v}} END {print m+0}' "$1"; }
median_hps() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END {if (NR%2) print a[(NR+1)/2]; else print int((a[NR/2]+a[NR/2+1])/2)}'; }

chmod +x "${PREPARE_SCRIPT}"
python3 "${PREPARE_SCRIPT}"
CUDA_SOURCE="${ROOT_DIR}/native/src/cuda/header80_backend_v053.cu"
for marker in positive_fraction_div1024_bits doubled_one nibble_to_double PEPEPOW_CUDA_BIT_SW_FRACTION; do
  grep -Fq "${marker}" "${CUDA_SOURCE}" || { echo "Missing v0.5.3 CUDA marker: ${marker}" >&2; exit 1; }
done
if grep -Fq 'if (value == 0.0) return;' "${CUDA_SOURCE}"; then
  echo "Unsafe zero-nibble early return is present" >&2
  exit 1
fi
grep -Fq 'PASS: 8192 bit-fraction CPU/CUDA samples match' "${ROOT_DIR}/native/tests/cuda_header80_validation.cpp" || { echo "8192-sample validation gate missing" >&2; exit 1; }

NVCC_PATH="$(find_nvcc)" || { echo "CUDA nvcc compiler not found" >&2; exit 1; }
export PATH="$(dirname "${NVCC_PATH}"):${PATH}"
"${NVCC_PATH}" --version
rm -rf "${PROFILE_ROOT}" "${LINK_BUILD_DIR}" "${PACKAGE_DIR}" "${ARCHIVE_PATH}"
mkdir -p "${PROFILE_ROOT}" "${ROOT_DIR}/dist"

build_profile() {
  local name="$1" threads="$2" min_blocks="$3" bit_sw="$4" derive_two="$5" nibble_table="$6" max_regs="$7"
  local dir="${PROFILE_ROOT}/${name}"
  local build_log="${dir}.build.log"
  rm -rf "${dir}" "${build_log}"
  echo "== PROFILE ${name}: threads=${threads} min_blocks=${min_blocks} bit_sw=${bit_sw} derive_two=${derive_two} nibble_table=${nibble_table} max_regs=${max_regs:-auto} =="
  local cmake_args=(
    -S "${ROOT_DIR}/native" -B "${dir}"
    -DCMAKE_BUILD_TYPE=Release
    -DPEPEPOW_ENABLE_CUDA=ON
    -DPEPEPOW_BUILD_TESTS=ON
    -DPEPEPOW_CUDA_PTXAS_VERBOSE=ON
    -DPEPEPOW_CUDA_THREADS="${threads}"
    -DPEPEPOW_CUDA_MIN_BLOCKS="${min_blocks}"
    -DPEPEPOW_CUDA_SCALED_MATRIX=ON
    -DPEPEPOW_CUDA_SPLIT_PIPELINE=OFF
    -DPEPEPOW_CUDA_FAST_FRACTION=ON
    -DPEPEPOW_CUDA_EXACT_BIT_CONVERSIONS=ON
    -DPEPEPOW_CUDA_BIT_SW_FRACTION="${bit_sw}"
    -DPEPEPOW_CUDA_DERIVE_TWO="${derive_two}"
    -DPEPEPOW_CUDA_NIBBLE_TABLE="${nibble_table}"
    -DPEPEPOW_CUDA_BYTE_UNROLL=1
    -DCMAKE_CUDA_ARCHITECTURES=86
    -DCMAKE_CUDA_COMPILER="${NVCC_PATH}"
    -DFETCHCONTENT_BASE_DIR="${DEPS_DIR}"
  )
  [[ -n "${max_regs}" ]] && cmake_args+=( -DPEPEPOW_CUDA_MAX_REGISTERS="${max_regs}" )
  if command -v ccache >/dev/null 2>&1; then
    cmake_args+=( -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache -DCMAKE_CUDA_COMPILER_LAUNCHER=ccache )
  fi
  cmake "${cmake_args[@]}"
  cmake --build "${dir}" --parallel "${JOBS}" --target pepepow_cuda_header80_validation pepepow_header80_benchmark pepepowminer 2>&1 | tee "${build_log}"

  if ! ctest --test-dir "${dir}" --output-on-failure; then
    printf 'name=%s\nvalid=0\nreason=ctest_failed\nthreads=%s\nmin_blocks=%s\nbit_sw=%s\nderive_two=%s\nnibble_table=%s\nmax_regs=%s\n' \
      "${name}" "${threads}" "${min_blocks}" "${bit_sw}" "${derive_two}" "${nibble_table}" "${max_regs:-auto}" > "${dir}/profile.meta"
    printf 'PROFILE_INVALID name=%s reason=ctest_failed\n' "${name}"
    return 0
  fi
  if ! "${dir}/pepepow_cuda_header80_validation"; then
    printf 'name=%s\nvalid=0\nreason=validation_failed\nthreads=%s\nmin_blocks=%s\nbit_sw=%s\nderive_two=%s\nnibble_table=%s\nmax_regs=%s\n' \
      "${name}" "${threads}" "${min_blocks}" "${bit_sw}" "${derive_two}" "${nibble_table}" "${max_regs:-auto}" > "${dir}/profile.meta"
    printf 'PROFILE_INVALID name=%s reason=validation_failed\n' "${name}"
    return 0
  fi

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
  printf 'name=%s\nvalid=1\nthreads=%s\nmin_blocks=%s\nbit_sw=%s\nderive_two=%s\nnibble_table=%s\nmax_regs=%s\nregisters=%s\nmax_spill_bytes=%s\nbenchmark_runs=%s\nbenchmark_hps=%s\nmedian_hps=%s\n' \
    "${name}" "${threads}" "${min_blocks}" "${bit_sw}" "${derive_two}" "${nibble_table}" "${max_regs:-auto}" "${regs}" "${spills}" "${BENCH_RUNS}" "${speeds[*]}" "${selected_hps}" > "${dir}/profile.meta"
  printf 'PROFILE_RESULT name=%s threads=%s min_blocks=%s bit_sw=%s derive_two=%s nibble_table=%s max_regs=%s registers=%s spills=%s median_hps=%s\n' \
    "${name}" "${threads}" "${min_blocks}" "${bit_sw}" "${derive_two}" "${nibble_table}" "${max_regs:-auto}" "${regs}" "${spills}" "${selected_hps}"
}

profiles=()
# Stage 1: isolate arithmetic transformations on the proven 64-thread/u1 geometry.
build_profile baseline-v052       64 1 OFF OFF OFF ""; profiles+=(baseline-v052)
build_profile sw64                64 1 ON  OFF OFF ""; profiles+=(sw64)
build_profile derive64            64 1 OFF ON  OFF ""; profiles+=(derive64)
build_profile sw-derive64         64 1 ON  ON  OFF ""; profiles+=(sw-derive64)
build_profile sw-table64          64 1 ON  OFF ON  ""; profiles+=(sw-table64)
build_profile sw-derive-table64   64 1 ON  ON  ON  ""; profiles+=(sw-derive-table64)

stage1_best=""; stage1_hps=0
for profile in "${profiles[@]}"; do
  [[ -s "${PROFILE_ROOT}/${profile}/profile.hps" ]] || continue
  hps="$(cat "${PROFILE_ROOT}/${profile}/profile.hps")"
  if (( hps > stage1_hps )); then stage1_hps="${hps}"; stage1_best="${profile}"; fi
done
[[ -n "${stage1_best}" ]] || { echo "No valid stage-1 profile" >&2; exit 1; }
# shellcheck disable=SC1090
source <(sed -n -E 's/^(bit_sw|derive_two|nibble_table)=(.*)$/BEST_\1=\2/p' "${PROFILE_ROOT}/${stage1_best}/profile.meta")
: "${BEST_bit_sw:?}" "${BEST_derive_two:?}" "${BEST_nibble_table:?}"
printf 'STAGE1_SELECTED profile=%s hps=%s bit_sw=%s derive_two=%s nibble_table=%s\n' \
  "${stage1_best}" "${stage1_hps}" "${BEST_bit_sw}" "${BEST_derive_two}" "${BEST_nibble_table}"

# Stage 2: geometry/register experiments only for the best arithmetic feature set.
build_profile best-96             96 1 "${BEST_bit_sw}" "${BEST_derive_two}" "${BEST_nibble_table}" ""; profiles+=(best-96)
build_profile best-128           128 1 "${BEST_bit_sw}" "${BEST_derive_two}" "${BEST_nibble_table}" ""; profiles+=(best-128)
build_profile best-320           320 1 "${BEST_bit_sw}" "${BEST_derive_two}" "${BEST_nibble_table}" ""; profiles+=(best-320)
build_profile best-64-r80         64 1 "${BEST_bit_sw}" "${BEST_derive_two}" "${BEST_nibble_table}" 80; profiles+=(best-64-r80)

best_profile=""; best_hps=0
for profile in "${profiles[@]}"; do
  [[ -s "${PROFILE_ROOT}/${profile}/profile.hps" ]] || continue
  hps="$(cat "${PROFILE_ROOT}/${profile}/profile.hps")"
  if (( hps > best_hps )); then best_hps="${hps}"; best_profile="${profile}"; fi
done
[[ -n "${best_profile}" ]] || { echo "No valid CUDA profile selected" >&2; exit 1; }
[[ -s "${PROFILE_ROOT}/baseline-v052/profile.hps" ]] || { echo "Consensus baseline failed; refusing to package" >&2; exit 1; }
baseline_hps="$(cat "${PROFILE_ROOT}/baseline-v052/profile.hps")"
uplift_pct="$(awk -v best="${best_hps}" -v base="${baseline_hps}" 'BEGIN {if (base>0) printf "%.2f", (best/base-1.0)*100.0; else print "0.00"}')"
SELECTED_BUILD_DIR="${PROFILE_ROOT}/${best_profile}"
ln -s "${SELECTED_BUILD_DIR}" "${LINK_BUILD_DIR}"
printf 'AUTOTUNE_SELECTED profile=%s hps=%s baseline_hps=%s uplift_pct=%s build=%s\n' "${best_profile}" "${best_hps}" "${baseline_hps}" "${uplift_pct}" "${SELECTED_BUILD_DIR}"
if (( best_hps >= TARGET_HPS )); then echo "TARGET_2MH=PASS measured_hps=${best_hps}"; else echo "TARGET_2MH=PENDING measured_hps=${best_hps}"; fi

"${SELECTED_BUILD_DIR}/pepepowminer" --list-gpu
BUILD_ID="$("${SELECTED_BUILD_DIR}/pepepowminer" --version)"
echo "BUILD_ID=${BUILD_ID}"
[[ "${BUILD_ID}" == *"${VERSION}"* && "${BUILD_ID}" == *"${EXPECTED_EDITION}"* ]] || { echo "Binary identity mismatch: ${BUILD_ID}" >&2; exit 1; }

mkdir -p "${PACKAGE_DIR}"
install -m 0755 "${SELECTED_BUILD_DIR}/pepepowminer" "${PACKAGE_DIR}/pepepowminer"
for script in h-run.sh h-config.sh h-stats.sh diagnostic-summary.sh forensic-audit.sh collect-forensics.sh collect-and-serve.sh capture-stratum.sh; do
  [[ -f "${ROOT_DIR}/hiveos/${script}" ]] && install -m 0755 "${ROOT_DIR}/hiveos/${script}" "${PACKAGE_DIR}/${script}"
done
install -m 0755 "${ROOT_DIR}/hiveos/stratum-replay-proxy.py" "${PACKAGE_DIR}/stratum-replay-proxy.py"
install -m 0644 "${ROOT_DIR}/hiveos/h-manifest.conf" "${PACKAGE_DIR}/h-manifest.conf"
install -m 0644 "${ROOT_DIR}/VERSION" "${PACKAGE_DIR}/VERSION"
[[ -f "${ROOT_DIR}/tools/collect-profiler-pack-v4.sh" ]] && install -m 0755 "${ROOT_DIR}/tools/collect-profiler-pack-v4.sh" "${PACKAGE_DIR}/collect-profiler-pack-v4.sh"
[[ -f "${ROOT_DIR}/tools/collect-v053-profiler.sh" ]] && install -m 0755 "${ROOT_DIR}/tools/collect-v053-profiler.sh" "${PACKAGE_DIR}/collect-v053-profiler.sh"

{
  echo "version=${VERSION}"
  echo "selected_profile=${best_profile}"
  echo "selected_hps=${best_hps}"
  echo "baseline_profile=baseline-v052"
  echo "baseline_hps=${baseline_hps}"
  echo "uplift_pct=${uplift_pct}"
  echo "target_hps=${TARGET_HPS}"
  echo "edition=${EXPECTED_EDITION}"
  echo "benchmark_nonces=${BENCH_NONCES}"
  echo "benchmark_runs=${BENCH_RUNS}"
  echo "driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 | xargs)"
  echo "gpu=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1 | xargs)"
  echo "git_commit=$(git -C "${ROOT_DIR}" rev-parse HEAD 2>/dev/null || true)"
  for profile in "${profiles[@]}"; do
    echo "--- ${profile} ---"
    if [[ -s "${PROFILE_ROOT}/${profile}/profile.meta" ]]; then cat "${PROFILE_ROOT}/${profile}/profile.meta"; else echo "valid=0"; echo "reason=missing_profile_metadata"; fi
  done
} > "${PACKAGE_DIR}/BUILD_PROFILE"

sed -i "s/^CUSTOM_VERSION=.*/CUSTOM_VERSION=${VERSION}/" "${PACKAGE_DIR}/h-manifest.conf"
sed -i "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=/hive/miners/custom/${PACKAGE_NAME}/config.txt#" "${PACKAGE_DIR}/h-manifest.conf"
for script in "${PACKAGE_DIR}"/*.sh; do bash -n "${script}"; done
python3 -m py_compile "${PACKAGE_DIR}/stratum-replay-proxy.py"
rm -rf "${PACKAGE_DIR}/__pycache__"
strip "${PACKAGE_DIR}/pepepowminer" 2>/dev/null || true

tar -C "${ROOT_DIR}/dist" -czf "${ARCHIVE_PATH}" "${PACKAGE_NAME}"
SHA256="$(sha256sum "${ARCHIVE_PATH}" | awk '{print $1}')"
printf '\nPASS: %s v%s package completed\n' "${EXPECTED_EDITION}" "${VERSION}"
printf 'AUTOTUNE_PROFILE=%s\nAUTOTUNE_HPS=%s\nAUTOTUNE_BASELINE_HPS=%s\nAUTOTUNE_UPLIFT_PCT=%s\n' "${best_profile}" "${best_hps}" "${baseline_hps}" "${uplift_pct}"
if (( best_hps >= TARGET_HPS )); then printf 'TARGET_2MH=PASS\n'; else printf 'TARGET_2MH=PENDING\n'; fi
printf 'ARCHIVE=%s\nSHA256=%s\n' "${ARCHIVE_PATH}" "${SHA256}"
printf 'DOWNLOAD_COMMAND=cd %q && python3 -m http.server 8080 --bind 0.0.0.0\n' "${ROOT_DIR}/dist"
