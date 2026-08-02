#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_ROOT="${ROOT_DIR}/build-profiles-v060"
LINK_BUILD_DIR="${ROOT_DIR}/build-rtx3080-v060"
VERSION="$(head -n1 "${ROOT_DIR}/VERSION" | tr -d '[:space:]')"
PACKAGE_NAME="pepepowminer-v${VERSION}"
PACKAGE_DIR="${ROOT_DIR}/dist/${PACKAGE_NAME}"
ARCHIVE_PATH="${ROOT_DIR}/dist/${PACKAGE_NAME}-hiveos.tar.gz"
JOBS="${JOBS:-$(nproc)}"
DEPS_DIR="${ROOT_DIR}/.deps-v060"
PREPARE_SCRIPT="${ROOT_DIR}/hiveos/prepare-v060-source.py"
EXPECTED_EDITION="PepeW Critical Path Edition"
BENCH_NONCES="${BENCH_NONCES:-4194304}"
BENCH_RUNS="${BENCH_RUNS:-3}"
TARGET_HPS="${TARGET_HPS:-2000000}"
PROFILE_TOTAL=10
PROFILE_INDEX=0

for command_name in nvidia-smi python3 cmake ctest awk sed sort sha256sum; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "ERROR: ${command_name} is required" >&2
    exit 1
  }
done

GPU_APPS="$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null || true)"
if [[ -n "${GPU_APPS//[[:space:]]/}" ]]; then
  echo "ERROR: GPU is busy. Stop the miner and all CUDA workloads before autotuning:" >&2
  echo "${GPU_APPS}" >&2
  exit 1
fi

chmod +x "${PREPARE_SCRIPT}"
python3 "${PREPARE_SCRIPT}"
VERSION="$(head -n1 "${ROOT_DIR}/VERSION" | tr -d '[:space:]')"
[[ "${VERSION}" == "0.6.0-PR" ]] || {
  echo "ERROR: expected VERSION=0.6.0-PR, found ${VERSION}" >&2
  exit 1
}
PACKAGE_NAME="pepepowminer-v${VERSION}"
PACKAGE_DIR="${ROOT_DIR}/dist/${PACKAGE_NAME}"
ARCHIVE_PATH="${ROOT_DIR}/dist/${PACKAGE_NAME}-hiveos.tar.gz"

for marker in PEPEPOW_CUDA_SW_STATE_MODE positive_fraction_div1024_le_002_exact positive_fraction_div1024_le_002_finite HooHashSwState; do
  grep -Fq "${marker}" "${ROOT_DIR}/native/src/cuda/header80_backend_v060.cu" || {
    echo "ERROR: missing v0.6.0 CUDA marker: ${marker}" >&2
    exit 1
  }
done
grep -Fq 'PASS: 32768 critical-path CPU/CUDA samples match' \
  "${ROOT_DIR}/native/tests/cuda_header80_validation.cpp" || {
  echo "ERROR: 32768-sample critical-path validation gate missing" >&2
  exit 1
}

echo "============================================================"
echo "PepeW Miner v0.6.0-PR RTX 3080 autotune"
echo "Profiles : ${PROFILE_TOTAL}"
echo "Runs     : ${BENCH_RUNS} per profile"
echo "Nonces   : ${BENCH_NONCES} per run"
echo "Target   : ${TARGET_HPS} H/s"
echo "============================================================"
nvidia-smi --query-gpu=name,compute_cap,driver_version,memory.total,clocks.current.sm,clocks.current.memory,power.limit --format=csv,noheader
if ! nvidia-smi --query-gpu=compute_cap --format=csv,noheader | grep -qx '8.6'; then
  echo "WARNING: this autotuner is calibrated for RTX 3080 / sm_86" >&2
fi

find_nvcc() {
  if command -v nvcc >/dev/null 2>&1; then command -v nvcc; return 0; fi
  local candidate
  for candidate in /usr/local/cuda/bin/nvcc /usr/local/cuda-12.4/bin/nvcc /usr/local/cuda-12/bin/nvcc; do
    [[ -x "${candidate}" ]] && { printf '%s\n' "${candidate}"; return 0; }
  done
  return 1
}

profile_hps() {
  sed -n 's/.* hps=\([0-9][0-9]*\).*/\1/p' <<<"$1" | tail -n1
}
median_hps() {
  printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END {if (NR%2) print a[(NR+1)/2]; else print int((a[NR/2]+a[NR/2+1])/2)}'
}
profile_registers() {
  awk '/Used [0-9]+ registers/ {for (i=1;i<=NF;i++) if ($i=="Used") {v=$(i+1)+0; if (v>m)m=v}} END {print m+0}' "$1"
}
profile_spills() {
  awk '/bytes spill stores/ {for (i=1;i<=NF;i++) if ($(i+1)=="bytes" && $(i+2)=="spill") {v=$i+0; if (v>m)m=v}} END {print m+0}' "$1"
}

NVCC_PATH="$(find_nvcc)" || { echo "ERROR: CUDA nvcc compiler not found" >&2; exit 1; }
export PATH="$(dirname "${NVCC_PATH}"):${PATH}"
"${NVCC_PATH}" --version

rm -rf "${PROFILE_ROOT}" "${LINK_BUILD_DIR}" "${PACKAGE_DIR}" "${ARCHIVE_PATH}" "${ARCHIVE_PATH}.sha256"
mkdir -p "${PROFILE_ROOT}" "${ROOT_DIR}/dist"

profiles=()
state_profiles=()

mark_invalid() {
  local dir="$1" name="$2" reason="$3" description="$4" threads="$5" min_blocks="$6" state_mode="$7" max_regs="$8"
  mkdir -p "${dir}"
  cat > "${dir}/profile.meta" <<META
name=${name}
valid=0
reason=${reason}
description=${description}
threads=${threads}
min_blocks=${min_blocks}
state_mode=${state_mode}
max_regs=${max_regs:-auto}
META
  echo "------------------------------------------------------------"
  printf '[PROFILE %02d/%02d] FAILED: %s\n' "${PROFILE_INDEX}" "${PROFILE_TOTAL}" "${name}"
  echo "Reason   : ${reason}"
  echo "------------------------------------------------------------"
  printf 'PROFILE_INVALID index=%s total=%s name=%s reason=%s\n' \
    "${PROFILE_INDEX}" "${PROFILE_TOTAL}" "${name}" "${reason}"
}

build_profile() {
  local name="$1" description="$2" threads="$3" min_blocks="$4" state_mode="$5" max_regs="$6"
  PROFILE_INDEX=$((PROFILE_INDEX + 1))
  profiles+=("${name}")

  local dir="${PROFILE_ROOT}/${name}"
  local build_log="${dir}.build.log"
  rm -rf "${dir}" "${build_log}"

  echo
  echo "============================================================"
  printf '[PROFILE %02d/%02d] %s\n' "${PROFILE_INDEX}" "${PROFILE_TOTAL}" "${name}"
  echo "Description : ${description}"
  echo "Threads     : ${threads}"
  echo "Min blocks  : ${min_blocks}"
  echo "State mode  : ${state_mode}"
  echo "Max regs    : ${max_regs:-auto}"
  echo "Status      : BUILDING"
  echo "============================================================"

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
    -DPEPEPOW_CUDA_BIT_SW_FRACTION=ON
    -DPEPEPOW_CUDA_DERIVE_TWO=OFF
    -DPEPEPOW_CUDA_NIBBLE_TABLE=OFF
    -DPEPEPOW_CUDA_SCALED_NIBBLE_TABLE=ON
    -DPEPEPOW_CUDA_ASSUME_FINITE=ON
    -DPEPEPOW_CUDA_SW_STATE_MODE="${state_mode}"
    -DPEPEPOW_CUDA_BYTE_UNROLL=1
    -DCMAKE_CUDA_ARCHITECTURES=86
    -DCMAKE_CUDA_COMPILER="${NVCC_PATH}"
    -DFETCHCONTENT_BASE_DIR="${DEPS_DIR}"
  )
  [[ -n "${max_regs}" ]] && cmake_args+=( -DPEPEPOW_CUDA_MAX_REGISTERS="${max_regs}" )
  if command -v ccache >/dev/null 2>&1; then
    cmake_args+=(
      -DCMAKE_C_COMPILER_LAUNCHER=ccache
      -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
      -DCMAKE_CUDA_COMPILER_LAUNCHER=ccache)
  fi

  if ! {
    cmake "${cmake_args[@]}" &&
    cmake --build "${dir}" --parallel "${JOBS}" \
      --target pepepow_core_tests pepepow_cuda_tests pepepow_cuda_header80_validation \
               pepepow_header80_benchmark pepepowminer
  } 2>&1 | tee "${build_log}"; then
    mark_invalid "${dir}" "${name}" build_failed "${description}" "${threads}" "${min_blocks}" "${state_mode}" "${max_regs}"
    return 0
  fi

  echo "[PROFILE $(printf '%02d' "${PROFILE_INDEX}")/${PROFILE_TOTAL}] Status: VALIDATING"
  if ! ctest --test-dir "${dir}" --output-on-failure; then
    mark_invalid "${dir}" "${name}" ctest_failed "${description}" "${threads}" "${min_blocks}" "${state_mode}" "${max_regs}"
    return 0
  fi
  if ! "${dir}/pepepow_cuda_header80_validation"; then
    mark_invalid "${dir}" "${name}" validation_failed "${description}" "${threads}" "${min_blocks}" "${state_mode}" "${max_regs}"
    return 0
  fi

  echo "[PROFILE $(printf '%02d' "${PROFILE_INDEX}")/${PROFILE_TOTAL}] Status: BENCHMARKING"
  local speeds=() output hps run
  for ((run=1; run<=BENCH_RUNS; ++run)); do
    output="$("${dir}/pepepow_header80_benchmark" "${BENCH_NONCES}")"
    printf 'BENCH_RUN profile=%s run=%s/%s %s\n' "${name}" "${run}" "${BENCH_RUNS}" "${output}"
    hps="$(profile_hps "${output}")"
    [[ "${hps}" =~ ^[1-9][0-9]*$ ]] || {
      mark_invalid "${dir}" "${name}" benchmark_parse_failed "${description}" "${threads}" "${min_blocks}" "${state_mode}" "${max_regs}"
      return 0
    }
    speeds+=("${hps}")
  done

  local selected_hps regs spills resource_file pow_regs mix_regs
  selected_hps="$(median_hps "${speeds[@]}")"
  regs="$(profile_registers "${build_log}")"
  spills="$(profile_spills "${build_log}")"
  resource_file="${dir}/cuobjdump-resource-usage.txt"
  if command -v cuobjdump >/dev/null 2>&1; then
    cuobjdump --dump-resource-usage "${dir}/pepepowminer" > "${resource_file}" 2>&1 || true
  fi
  pow_regs="$(awk '/Function .*header80_pow_kernel/{f=1;next} f && /REG:/{line=$0; sub(/^.*REG:/, "", line); sub(/[^0-9].*$/, "", line); print line; exit}' "${resource_file}" 2>/dev/null || true)"
  mix_regs="$(awk '/Function .*hoohash_mix_kernel/{f=1;next} f && /REG:/{line=$0; sub(/^.*REG:/, "", line); sub(/[^0-9].*$/, "", line); print line; exit}' "${resource_file}" 2>/dev/null || true)"
  pow_regs="${pow_regs:-0}"
  mix_regs="${mix_regs:-0}"

  printf '%s\n' "${selected_hps}" > "${dir}/profile.hps"
  cat > "${dir}/profile.meta" <<META
name=${name}
valid=1
description=${description}
threads=${threads}
min_blocks=${min_blocks}
state_mode=${state_mode}
max_regs=${max_regs:-auto}
max_registers=${regs}
pow_registers=${pow_regs}
mix_registers=${mix_regs}
max_spill_bytes=${spills}
benchmark_runs=${BENCH_RUNS}
benchmark_hps=${speeds[*]}
median_hps=${selected_hps}
META

  echo "------------------------------------------------------------"
  printf '[PROFILE %02d/%02d] PASSED: %s\n' "${PROFILE_INDEX}" "${PROFILE_TOTAL}" "${name}"
  printf 'Hashrate : %s H/s (%s MH/s)\n' "${selected_hps}" "$(awk -v h="${selected_hps}" 'BEGIN {printf "%.3f", h/1000000}')"
  echo "Registers: ${regs} (pow=${pow_regs}, mix=${mix_regs})"
  echo "Spills   : ${spills} bytes"
  echo "------------------------------------------------------------"
  printf 'PROFILE_RESULT index=%s total=%s name=%s threads=%s min_blocks=%s state_mode=%s max_regs=%s registers=%s pow_regs=%s mix_regs=%s spills=%s median_hps=%s\n' \
    "${PROFILE_INDEX}" "${PROFILE_TOTAL}" "${name}" "${threads}" "${min_blocks}" "${state_mode}" "${max_regs:-auto}" \
    "${regs}" "${pow_regs}" "${mix_regs}" "${spills}" "${selected_hps}"
}

# Stage 1: exact state representation at the proven v0.5.4 launch geometry.
build_profile baseline-state0 "v0.5.4-compatible double fraction state" 64 1 0 80; state_profiles+=(baseline-state0)
build_profile bool-fraction-state1 "Boolean state via validated fraction helper" 64 1 1 80; state_profiles+=(bool-fraction-state1)
build_profile exact-defensive-state2 "Defensive exact IEEE-754 threshold predicate" 64 1 2 80; state_profiles+=(exact-defensive-state2)
build_profile exact-finite-state3 "Positive-finite exact IEEE-754 threshold predicate" 64 1 3 80; state_profiles+=(exact-finite-state3)

best_state_profile=""
best_state_hps=0
for profile in "${state_profiles[@]}"; do
  [[ -s "${PROFILE_ROOT}/${profile}/profile.hps" ]] || continue
  hps="$(cat "${PROFILE_ROOT}/${profile}/profile.hps")"
  if (( hps > best_state_hps )); then
    best_state_hps="${hps}"
    best_state_profile="${profile}"
  fi
done
[[ -n "${best_state_profile}" ]] || { echo "ERROR: no valid state profile" >&2; exit 1; }
BEST_STATE_MODE="$(awk -F= '$1=="state_mode"{print $2}' "${PROFILE_ROOT}/${best_state_profile}/profile.meta")"
printf 'STATE_MODE_SELECTED profile=%s state_mode=%s hps=%s\n' \
  "${best_state_profile}" "${BEST_STATE_MODE}" "${best_state_hps}"

# Stage 2: geometry sweep for the best consensus-valid state representation.
build_profile best-t64-auto "Selected state mode, 64 threads, automatic register cap" 64 1 "${BEST_STATE_MODE}" ""
build_profile best-t96 "Selected state mode, 96 threads" 96 1 "${BEST_STATE_MODE}" ""
build_profile best-t128 "Selected state mode, 128 threads" 128 1 "${BEST_STATE_MODE}" ""
build_profile best-t160 "Selected state mode, 160 threads" 160 1 "${BEST_STATE_MODE}" ""
build_profile best-t192 "Selected state mode, 192 threads" 192 1 "${BEST_STATE_MODE}" ""
build_profile best-t64-b2 "Selected state mode, 64 threads, min_blocks=2" 64 2 "${BEST_STATE_MODE}" ""

[[ "${PROFILE_INDEX}" -eq "${PROFILE_TOTAL}" ]] || {
  echo "ERROR: profile accounting mismatch: ${PROFILE_INDEX}/${PROFILE_TOTAL}" >&2
  exit 1
}

best_profile=""
best_hps=0
for profile in "${profiles[@]}"; do
  [[ -s "${PROFILE_ROOT}/${profile}/profile.hps" ]] || continue
  hps="$(cat "${PROFILE_ROOT}/${profile}/profile.hps")"
  if (( hps > best_hps )); then
    best_hps="${hps}"
    best_profile="${profile}"
  fi
done
[[ -n "${best_profile}" ]] || { echo "ERROR: no valid CUDA profile selected" >&2; exit 1; }
[[ -s "${PROFILE_ROOT}/baseline-state0/profile.hps" ]] || {
  echo "ERROR: consensus baseline failed; refusing to package" >&2
  exit 1
}
baseline_hps="$(cat "${PROFILE_ROOT}/baseline-state0/profile.hps")"
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
[[ "${BUILD_ID}" == *"${VERSION}"* && "${BUILD_ID}" == *"${EXPECTED_EDITION}"* ]] || {
  echo "ERROR: binary identity mismatch: ${BUILD_ID}" >&2
  exit 1
}

mkdir -p "${PACKAGE_DIR}"
install -m 0755 "${SELECTED_BUILD_DIR}/pepepowminer" "${PACKAGE_DIR}/pepepowminer"
for script in h-run.sh h-config.sh h-stats.sh diagnostic-summary.sh forensic-audit.sh collect-forensics.sh collect-and-serve.sh capture-stratum.sh; do
  [[ -f "${ROOT_DIR}/hiveos/${script}" ]] && install -m 0755 "${ROOT_DIR}/hiveos/${script}" "${PACKAGE_DIR}/${script}"
done
[[ -f "${ROOT_DIR}/hiveos/stratum-replay-proxy.py" ]] && install -m 0755 "${ROOT_DIR}/hiveos/stratum-replay-proxy.py" "${PACKAGE_DIR}/stratum-replay-proxy.py"
[[ -f "${ROOT_DIR}/hiveos/h-manifest.conf" ]] && install -m 0644 "${ROOT_DIR}/hiveos/h-manifest.conf" "${PACKAGE_DIR}/h-manifest.conf"
install -m 0644 "${ROOT_DIR}/VERSION" "${PACKAGE_DIR}/VERSION"
for tool in collect-profiler-pack-v4.sh collect-v054-profiler.sh collect-v054-deep-direct.sh; do
  [[ -f "${ROOT_DIR}/tools/${tool}" ]] && install -m 0755 "${ROOT_DIR}/tools/${tool}" "${PACKAGE_DIR}/${tool}"
done

selected_state_mode="$(awk -F= '$1=="state_mode"{print $2}' "${PROFILE_ROOT}/${best_profile}/profile.meta")"
{
  echo "version=${VERSION}"
  echo "edition=${EXPECTED_EDITION}"
  echo "selected_profile=${best_profile}"
  echo "selected_state_mode=${selected_state_mode}"
  echo "selected_hps=${best_hps}"
  echo "baseline_profile=baseline-state0"
  echo "baseline_hps=${baseline_hps}"
  echo "uplift_pct=${uplift_pct}"
  echo "target_hps=${TARGET_HPS}"
  echo "target_2mh=$([[ ${best_hps} -ge ${TARGET_HPS} ]] && echo PASS || echo PENDING)"
  echo "source_backend=header80_backend_v060.cu"
  echo "profile_progress=${PROFILE_TOTAL}/${PROFILE_TOTAL}"
  echo
  for profile in "${profiles[@]}"; do
    echo "--- ${profile} ---"
    if [[ -s "${PROFILE_ROOT}/${profile}/profile.meta" ]]; then
      cat "${PROFILE_ROOT}/${profile}/profile.meta"
    else
      echo "valid=0"
      echo "reason=missing_profile_metadata"
    fi
  done
} > "${PACKAGE_DIR}/BUILD_PROFILE"

cat > "${PACKAGE_DIR}/README-v060.txt" <<README
PepeW Miner ${VERSION}
Edition: Critical Path
Selected RTX 3080 profile: ${best_profile}
Selected state mode: ${selected_state_mode}
Measured internal benchmark: ${best_hps} H/s
Baseline: ${baseline_hps} H/s
Measured uplift: ${uplift_pct}%
2 MH/s gate: $([[ ${best_hps} -ge ${TARGET_HPS} ]] && echo PASS || echo PENDING)

This prerelease is consensus-gated. The 2 MH/s claim is allowed only when both
TARGET_2MH=PASS and a sustained live-pool test exceed 2.000 MH/s with zero
rejected shares caused by the miner.
README

rm -f "${ARCHIVE_PATH}" "${ARCHIVE_PATH}.sha256"
tar -C "${ROOT_DIR}/dist" -czf "${ARCHIVE_PATH}" "${PACKAGE_NAME}"
sha256sum "${ARCHIVE_PATH}" > "${ARCHIVE_PATH}.sha256"

echo
echo "============================================================"
echo "v0.6.0-PR AUTOTUNE COMPLETE"
echo "============================================================"
echo "AUTOTUNE_PROFILE=${best_profile}"
echo "AUTOTUNE_STATE_MODE=${selected_state_mode}"
echo "AUTOTUNE_HPS=${best_hps}"
echo "AUTOTUNE_BASELINE_HPS=${baseline_hps}"
echo "AUTOTUNE_UPLIFT_PCT=${uplift_pct}"
if (( best_hps >= TARGET_HPS )); then echo "TARGET_2MH=PASS"; else echo "TARGET_2MH=PENDING"; fi
echo "ARCHIVE=${ARCHIVE_PATH}"
echo "SHA256=$(awk '{print $1}' "${ARCHIVE_PATH}.sha256")"
echo "DOWNLOAD_COMMAND=cd ${ROOT_DIR}/dist && python3 -m http.server 8080 --bind 0.0.0.0"
