#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_ROOT="${ROOT_DIR}/build-profiles-v055"
LINK_BUILD_DIR="${ROOT_DIR}/build-rtx3080-v055"
VERSION="$(head -n1 "${ROOT_DIR}/VERSION" | tr -d '[:space:]')"
PACKAGE_NAME="pepepowminer-v${VERSION}"
PACKAGE_DIR="${ROOT_DIR}/dist/${PACKAGE_NAME}"
ARCHIVE_PATH="${ROOT_DIR}/dist/${PACKAGE_NAME}-hiveos.tar.gz"
JOBS="${JOBS:-$(nproc)}"
DEPS_DIR="${ROOT_DIR}/.deps-v055"
PREPARE_SCRIPT="${ROOT_DIR}/hiveos/prepare-v055-source.py"
EXPECTED_EDITION="PepeW ILP Edition"
BENCH_NONCES="${BENCH_NONCES:-4194304}"
BENCH_RUNS="${BENCH_RUNS:-3}"
TARGET_HPS="${TARGET_HPS:-2000000}"

for command_name in nvidia-smi python3 cmake awk sort sha256sum; do
  command -v "${command_name}" >/dev/null 2>&1 || { echo "${command_name} is required" >&2; exit 1; }
done
chmod +x "${PREPARE_SCRIPT}"
python3 "${PREPARE_SCRIPT}"
VERSION="$(head -n1 "${ROOT_DIR}/VERSION" | tr -d '[:space:]')"
[[ "${VERSION}" == "0.5.5-PR" ]] || { echo "Expected VERSION=0.5.5-PR, found ${VERSION}" >&2; exit 1; }
PACKAGE_NAME="pepepowminer-v${VERSION}"
PACKAGE_DIR="${ROOT_DIR}/dist/${PACKAGE_NAME}"
ARCHIVE_PATH="${ROOT_DIR}/dist/${PACKAGE_NAME}-hiveos.tar.gz"

for marker in PEPEPOW_CUDA_ILP_NONCES matrix_row_ilp hoohash_mix_kernel_ilp; do
  grep -Fq "${marker}" "${ROOT_DIR}/native/src/cuda/header80_backend_v055.cu" || {
    echo "Missing v0.5.5 CUDA marker: ${marker}" >&2; exit 1;
  }
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
median_hps() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END {if (NR%2) print a[(NR+1)/2]; else print int((a[NR/2]+a[NR/2+1])/2)}'; }
profile_registers() { awk '/Used [0-9]+ registers/ {for (i=1;i<=NF;i++) if ($i=="Used") {v=$(i+1)+0; if (v>m)m=v}} END {print m+0}' "$1"; }
profile_spills() { awk '/bytes spill stores/ {for (i=1;i<=NF;i++) if ($(i+1)=="bytes" && $(i+2)=="spill") {v=$i+0; if (v>m)m=v}} END {print m+0}' "$1"; }

NVCC_PATH="$(find_nvcc)" || { echo "CUDA nvcc compiler not found" >&2; exit 1; }
export PATH="$(dirname "${NVCC_PATH}"):${PATH}"
"${NVCC_PATH}" --version

rm -rf "${PROFILE_ROOT}" "${LINK_BUILD_DIR}" "${PACKAGE_DIR}" "${ARCHIVE_PATH}" "${ARCHIVE_PATH}.sha256"
mkdir -p "${PROFILE_ROOT}" "${ROOT_DIR}/dist"

build_profile() {
  local name="$1" threads="$2" min_blocks="$3" split="$4" ilp="$5" max_regs="$6"
  local dir="${PROFILE_ROOT}/${name}" build_log="${PROFILE_ROOT}/${name}.build.log"
  rm -rf "${dir}" "${build_log}"
  echo "== PROFILE ${name}: threads=${threads} min_blocks=${min_blocks} split=${split} ilp=${ilp} max_regs=${max_regs:-auto} =="
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
    -DPEPEPOW_CUDA_FAST_FRACTION=ON
    -DPEPEPOW_CUDA_EXACT_BIT_CONVERSIONS=ON
    -DPEPEPOW_CUDA_BIT_SW_FRACTION=ON
    -DPEPEPOW_CUDA_DERIVE_TWO=OFF
    -DPEPEPOW_CUDA_NIBBLE_TABLE=OFF
    -DPEPEPOW_CUDA_SCALED_NIBBLE_TABLE=ON
    -DPEPEPOW_CUDA_ASSUME_FINITE=ON
    -DPEPEPOW_CUDA_ILP_NONCES="${ilp}"
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
  cmake --build "${dir}" --parallel "${JOBS}" \
    --target pepepow_core_tests pepepow_cuda_tests pepepow_cuda_header80_validation pepepow_header80_benchmark pepepowminer \
    2>&1 | tee "${build_log}"

  if ! ctest --test-dir "${dir}" --output-on-failure; then
    printf 'name=%s\nvalid=0\nreason=ctest_failed\nthreads=%s\nmin_blocks=%s\nsplit=%s\nilp=%s\nmax_regs=%s\n' \
      "${name}" "${threads}" "${min_blocks}" "${split}" "${ilp}" "${max_regs:-auto}" > "${dir}/profile.meta"
    echo "PROFILE_INVALID name=${name} reason=ctest_failed"
    return 0
  fi
  if ! "${dir}/pepepow_cuda_header80_validation"; then
    printf 'name=%s\nvalid=0\nreason=validation_failed\nthreads=%s\nmin_blocks=%s\nsplit=%s\nilp=%s\nmax_regs=%s\n' \
      "${name}" "${threads}" "${min_blocks}" "${split}" "${ilp}" "${max_regs:-auto}" > "${dir}/profile.meta"
    echo "PROFILE_INVALID name=${name} reason=validation_failed"
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

  local selected_hps regs spills resource_file pow_regs mix_regs ilp_regs
  selected_hps="$(median_hps "${speeds[@]}")"
  regs="$(profile_registers "${build_log}")"
  spills="$(profile_spills "${build_log}")"
  resource_file="${dir}/cuobjdump-resource-usage.txt"
  if command -v cuobjdump >/dev/null 2>&1; then
    cuobjdump --dump-resource-usage "${dir}/pepepowminer" > "${resource_file}" 2>&1 || true
  fi
  pow_regs="$(awk '/Function .*header80_pow_kernel/{f=1;next} f && /REG:/{line=$0; sub(/^.*REG:/,"",line); sub(/[^0-9].*$/,"",line); print line; exit}' "${resource_file}" 2>/dev/null || true)"
  mix_regs="$(awk '/Function .*hoohash_mix_kernel[^_i]/{f=1;next} f && /REG:/{line=$0; sub(/^.*REG:/,"",line); sub(/[^0-9].*$/,"",line); print line; exit}' "${resource_file}" 2>/dev/null || true)"
  ilp_regs="$(awk '/Function .*hoohash_mix_kernel_ilp/{f=1;next} f && /REG:/{line=$0; sub(/^.*REG:/,"",line); sub(/[^0-9].*$/,"",line); print line; exit}' "${resource_file}" 2>/dev/null || true)"
  pow_regs="${pow_regs:-0}"; mix_regs="${mix_regs:-0}"; ilp_regs="${ilp_regs:-0}"
  printf '%s\n' "${selected_hps}" > "${dir}/profile.hps"
  printf 'name=%s\nvalid=1\nthreads=%s\nmin_blocks=%s\nsplit=%s\nilp=%s\nmax_regs=%s\nmax_registers=%s\npow_registers=%s\nmix_registers=%s\nilp_registers=%s\nmax_spill_bytes=%s\nbenchmark_runs=%s\nbenchmark_hps=%s\nmedian_hps=%s\n' \
    "${name}" "${threads}" "${min_blocks}" "${split}" "${ilp}" "${max_regs:-auto}" "${regs}" \
    "${pow_regs}" "${mix_regs}" "${ilp_regs}" "${spills}" "${BENCH_RUNS}" "${speeds[*]}" "${selected_hps}" > "${dir}/profile.meta"
  printf 'PROFILE_RESULT name=%s threads=%s min_blocks=%s split=%s ilp=%s max_regs=%s registers=%s pow_regs=%s mix_regs=%s ilp_regs=%s spills=%s median_hps=%s\n' \
    "${name}" "${threads}" "${min_blocks}" "${split}" "${ilp}" "${max_regs:-auto}" "${regs}" \
    "${pow_regs}" "${mix_regs}" "${ilp_regs}" "${spills}" "${selected_hps}"
}

profiles=()
build_profile baseline-mono1 64 1 OFF 1 80; profiles+=(baseline-mono1)
build_profile split-ilp1-64  64 1 ON  1 ""; profiles+=(split-ilp1-64)
build_profile split-ilp2-64  64 1 ON  2 ""; profiles+=(split-ilp2-64)
build_profile split-ilp3-64  64 1 ON  3 ""; profiles+=(split-ilp3-64)
build_profile split-ilp4-64  64 1 ON  4 ""; profiles+=(split-ilp4-64)

best_ilp=1; best_ilp_profile=split-ilp1-64; best_ilp_hps=0
for profile in split-ilp1-64 split-ilp2-64 split-ilp3-64 split-ilp4-64; do
  [[ -s "${PROFILE_ROOT}/${profile}/profile.hps" ]] || continue
  hps="$(cat "${PROFILE_ROOT}/${profile}/profile.hps")"
  if (( hps > best_ilp_hps )); then
    best_ilp_hps="${hps}"; best_ilp_profile="${profile}"
    best_ilp="$(sed -n 's/^ilp=//p' "${PROFILE_ROOT}/${profile}/profile.meta")"
  fi
done
printf 'ILP_SELECTED profile=%s ilp=%s hps=%s\n' "${best_ilp_profile}" "${best_ilp}" "${best_ilp_hps}"

for threads in 32 96 128 192; do
  name="best-ilp${best_ilp}-t${threads}"
  build_profile "${name}" "${threads}" 1 ON "${best_ilp}" ""; profiles+=("${name}")
done
build_profile "best-ilp${best_ilp}-t64-b2" 64 2 ON "${best_ilp}" ""; profiles+=("best-ilp${best_ilp}-t64-b2")

if (( best_ilp > 1 )); then
  for cap in 128 112 96; do
    name="best-ilp${best_ilp}-t64-r${cap}"
    build_profile "${name}" 64 1 ON "${best_ilp}" "${cap}"; profiles+=("${name}")
  done
fi

best_profile=""; best_hps=0
for profile in "${profiles[@]}"; do
  [[ -s "${PROFILE_ROOT}/${profile}/profile.hps" ]] || continue
  hps="$(cat "${PROFILE_ROOT}/${profile}/profile.hps")"
  if (( hps > best_hps )); then best_hps="${hps}"; best_profile="${profile}"; fi
done
[[ -n "${best_profile}" ]] || { echo "No valid CUDA profile selected" >&2; exit 1; }
[[ -s "${PROFILE_ROOT}/baseline-mono1/profile.hps" ]] || { echo "Consensus baseline failed; refusing to package" >&2; exit 1; }
baseline_hps="$(cat "${PROFILE_ROOT}/baseline-mono1/profile.hps")"
uplift_pct="$(awk -v best="${best_hps}" -v base="${baseline_hps}" 'BEGIN {if(base>0) printf "%.2f",(best/base-1.0)*100.0; else print "0.00"}')"
SELECTED_BUILD_DIR="${PROFILE_ROOT}/${best_profile}"
ln -s "${SELECTED_BUILD_DIR}" "${LINK_BUILD_DIR}"
printf 'AUTOTUNE_SELECTED profile=%s hps=%s baseline_hps=%s uplift_pct=%s build=%s\n' \
  "${best_profile}" "${best_hps}" "${baseline_hps}" "${uplift_pct}" "${SELECTED_BUILD_DIR}"
if (( best_hps >= TARGET_HPS )); then echo "TARGET_2MH=PASS measured_hps=${best_hps}"; else echo "TARGET_2MH=PENDING measured_hps=${best_hps}"; fi

BUILD_ID="$("${SELECTED_BUILD_DIR}/pepepowminer" --version | head -n1)"
echo "BUILD_ID=${BUILD_ID}"
[[ "${BUILD_ID}" == *"${VERSION}"* && "${BUILD_ID}" == *"${EXPECTED_EDITION}"* ]] || {
  echo "Binary identity mismatch: ${BUILD_ID}" >&2; exit 1;
}

mkdir -p "${PACKAGE_DIR}"
install -m 0755 "${SELECTED_BUILD_DIR}/pepepowminer" "${PACKAGE_DIR}/pepepowminer"
for script in h-run.sh h-config.sh h-stats.sh diagnostic-summary.sh forensic-audit.sh collect-forensics.sh collect-and-serve.sh capture-stratum.sh; do
  [[ -f "${ROOT_DIR}/hiveos/${script}" ]] && install -m 0755 "${ROOT_DIR}/hiveos/${script}" "${PACKAGE_DIR}/${script}"
done
[[ -f "${ROOT_DIR}/hiveos/stratum-replay-proxy.py" ]] && install -m 0755 "${ROOT_DIR}/hiveos/stratum-replay-proxy.py" "${PACKAGE_DIR}/stratum-replay-proxy.py"
[[ -f "${ROOT_DIR}/hiveos/h-manifest.conf" ]] && install -m 0644 "${ROOT_DIR}/hiveos/h-manifest.conf" "${PACKAGE_DIR}/h-manifest.conf"
install -m 0644 "${ROOT_DIR}/VERSION" "${PACKAGE_DIR}/VERSION"
for tool in collect-profiler-pack-v4.sh collect-v054-profiler.sh collect-v055-profiler.sh; do
  [[ -f "${ROOT_DIR}/tools/${tool}" ]] && install -m 0755 "${ROOT_DIR}/tools/${tool}" "${PACKAGE_DIR}/${tool}"
done

{
  echo "version=${VERSION}"
  echo "selected_profile=${best_profile}"
  echo "selected_hps=${best_hps}"
  echo "baseline_profile=baseline-mono1"
  echo "baseline_hps=${baseline_hps}"
  echo "uplift_pct=${uplift_pct}"
  echo "target_hps=${TARGET_HPS}"
  if (( best_hps >= TARGET_HPS )); then echo "target_2mh=PASS"; else echo "target_2mh=PENDING"; fi
  echo "source_backend=header80_backend_v055.cu"
  echo "strategy=split_hoohash_interleaved_independent_nonces"
  for profile in "${profiles[@]}"; do
    echo
    echo "--- ${profile} ---"
    if [[ -f "${PROFILE_ROOT}/${profile}/profile.meta" ]]; then cat "${PROFILE_ROOT}/${profile}/profile.meta"; else echo "valid=0"; echo "reason=missing_profile_metadata"; fi
  done
} > "${PACKAGE_DIR}/BUILD_PROFILE"

cat > "${PACKAGE_DIR}/README-v055.txt" <<EOF
PepeW Miner ${VERSION}
Selected RTX 3080 profile: ${best_profile}
Measured internal benchmark: ${best_hps} H/s
Baseline v0.5.4-compatible profile: ${baseline_hps} H/s
Measured uplift: ${uplift_pct}%
Target: ${TARGET_HPS} H/s

This prerelease interleaves independent HooHash nonce chains inside the split
CUDA kernel to hide FP64/SFU scoreboard latency. Every candidate is consensus
gated before benchmarking. Do not claim 2 MH/s unless TARGET_2MH=PASS and a
live pool validation also exceeds the target.
EOF

rm -f "${ARCHIVE_PATH}" "${ARCHIVE_PATH}.sha256"
tar -C "${ROOT_DIR}/dist" -czf "${ARCHIVE_PATH}" "${PACKAGE_NAME}"
sha256sum "${ARCHIVE_PATH}" > "${ARCHIVE_PATH}.sha256"

echo "PASS: PepeW ILP Edition ${VERSION} package completed"
echo "AUTOTUNE_PROFILE=${best_profile}"
echo "AUTOTUNE_HPS=${best_hps}"
echo "AUTOTUNE_BASELINE_HPS=${baseline_hps}"
echo "AUTOTUNE_UPLIFT_PCT=${uplift_pct}"
if (( best_hps >= TARGET_HPS )); then echo "TARGET_2MH=PASS"; else echo "TARGET_2MH=PENDING"; fi
echo "ARCHIVE=${ARCHIVE_PATH}"
echo "SHA256=$(awk '{print $1}' "${ARCHIVE_PATH}.sha256")"
echo "DOWNLOAD_COMMAND=cd ${ROOT_DIR}/dist && python3 -m http.server 8080 --bind 0.0.0.0"
