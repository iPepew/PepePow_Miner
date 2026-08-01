#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_ROOT="${ROOT_DIR}/build-profiles-v052"
LINK_BUILD_DIR="${ROOT_DIR}/build-rtx3080-v052"
VERSION="$(head -n1 "${ROOT_DIR}/VERSION" | tr -d '[:space:]')"
[[ "${VERSION}" == "0.5.2-PR" ]] || { echo "Expected VERSION=0.5.2-PR, found ${VERSION}" >&2; exit 1; }
PACKAGE_NAME="pepepowminer-v${VERSION}"
PACKAGE_DIR="${ROOT_DIR}/dist/${PACKAGE_NAME}"
ARCHIVE_PATH="${ROOT_DIR}/dist/${PACKAGE_NAME}-hiveos.tar.gz"
ARCHIVE_LIST="${ROOT_DIR}/dist/${PACKAGE_NAME}-archive-contents.txt"
JOBS="${JOBS:-$(nproc)}"
DEPS_DIR="${ROOT_DIR}/.deps-v052"
PREPARE_SCRIPT="${ROOT_DIR}/hiveos/prepare-v052-source.py"
EXPECTED_EDITION="PepeW Exact Conversion Edition"
BENCH_NONCES="${BENCH_NONCES:-4194304}"
BENCH_RUNS="${BENCH_RUNS:-3}"
TARGET_HPS="${TARGET_HPS:-2000000}"

for command_name in nvidia-smi python3 cmake awk sort sha256sum; do
  command -v "${command_name}" >/dev/null 2>&1 || { echo "${command_name} is required" >&2; exit 1; }
done

echo "== NVIDIA validation target =="
nvidia-smi --query-gpu=name,compute_cap,driver_version,memory.total,clocks.current.sm,clocks.current.memory,power.limit --format=csv,noheader
if ! nvidia-smi --query-gpu=compute_cap --format=csv,noheader | grep -qx '8.6'; then
  echo "WARNING: this profile is tuned for RTX 3080 / sm_86" >&2
fi

find_nvcc() {
  if command -v nvcc >/dev/null 2>&1; then command -v nvcc; return 0; fi
  local candidate
  for candidate in /usr/local/cuda/bin/nvcc /usr/local/cuda-13/bin/nvcc /usr/local/cuda-12/bin/nvcc /usr/local/cuda-12.9/bin/nvcc /usr/local/cuda-12.8/bin/nvcc /usr/local/cuda-12.6/bin/nvcc /usr/local/cuda-12.5/bin/nvcc /usr/local/cuda-12.4/bin/nvcc; do
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
CUDA_SOURCE="${ROOT_DIR}/native/src/cuda/header80_backend_v052.cu"
for marker in PEPEPOW_CUDA_EXACT_BIT_CONVERSIONS u32_to_double_exact positive_fraction_bits positive_double_to_u64_rz 'if (value == 0.0) return;' 'hash_mod_fp64 = u32_to_double_exact(hash_mod)'; do
  grep -Fq "${marker}" "${CUDA_SOURCE}" || { echo "Missing v0.5.2 CUDA marker: ${marker}" >&2; exit 1; }
done
grep -Fq 'PASS: 4096 exact-conversion CPU/CUDA samples match' "${ROOT_DIR}/native/tests/cuda_header80_validation.cpp" || { echo "4096-sample validation gate missing" >&2; exit 1; }
grep -Fq 'constexpr std::uint64_t chunk_size = 524288;' "${ROOT_DIR}/native/src/app/main.cpp" || { echo "524288 runtime batch missing" >&2; exit 1; }

NVCC_PATH="$(find_nvcc)" || { echo "CUDA nvcc compiler not found" >&2; exit 1; }
export PATH="$(dirname "${NVCC_PATH}"):${PATH}"
"${NVCC_PATH}" --version
rm -rf "${PROFILE_ROOT}" "${LINK_BUILD_DIR}" "${PACKAGE_DIR}" "${ARCHIVE_PATH}" "${ARCHIVE_LIST}"
mkdir -p "${PROFILE_ROOT}" "${ROOT_DIR}/dist"

build_profile() {
  local name="$1" threads="$2" min_blocks="$3" split="$4" exact_bits="$5" unroll="$6" max_regs="$7"
  local dir="${PROFILE_ROOT}/${name}"
  local build_log="${dir}.build.log"
  rm -rf "${dir}" "${build_log}"
  echo "== PROFILE ${name}: threads=${threads} min_blocks=${min_blocks} split=${split} exact_bits=${exact_bits} unroll=${unroll} max_regs=${max_regs:-auto} =="
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
    -DPEPEPOW_CUDA_EXACT_BIT_CONVERSIONS="${exact_bits}"
    -DPEPEPOW_CUDA_BYTE_UNROLL="${unroll}"
    -DCMAKE_CUDA_ARCHITECTURES=86
    -DCMAKE_CUDA_COMPILER="${NVCC_PATH}"
    -DFETCHCONTENT_BASE_DIR="${DEPS_DIR}"
  )
  [[ -n "${max_regs}" ]] && cmake_args+=( -DPEPEPOW_CUDA_MAX_REGISTERS="${max_regs}" )
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
  printf 'name=%s\nthreads=%s\nmin_blocks=%s\nsplit=%s\nexact_bit_conversions=%s\nunroll=%s\nmax_regs=%s\nregisters=%s\nmax_spill_bytes=%s\nbenchmark_runs=%s\nbenchmark_hps=%s\nmedian_hps=%s\n' \
    "${name}" "${threads}" "${min_blocks}" "${split}" "${exact_bits}" "${unroll}" "${max_regs:-auto}" "${regs}" "${spills}" "${BENCH_RUNS}" "${speeds[*]}" "${selected_hps}" > "${dir}/profile.meta"
  printf 'PROFILE_RESULT name=%s exact_bits=%s threads=%s min_blocks=%s split=%s unroll=%s max_regs=%s registers=%s spills=%s median_hps=%s\n' \
    "${name}" "${exact_bits}" "${threads}" "${min_blocks}" "${split}" "${unroll}" "${max_regs:-auto}" "${regs}" "${spills}" "${selected_hps}"
}

profiles=()
build_profile baseline-mono64-u2      64 1 OFF OFF 2 ""; profiles+=(baseline-mono64-u2)
build_profile exact-mono64-u1         64 1 OFF ON  1 ""; profiles+=(exact-mono64-u1)
build_profile exact-mono64-u2         64 1 OFF ON  2 ""; profiles+=(exact-mono64-u2)
build_profile exact-mono64-u4         64 1 OFF ON  4 ""; profiles+=(exact-mono64-u4)
build_profile exact-mono128-u2       128 1 OFF ON  2 ""; profiles+=(exact-mono128-u2)
build_profile exact-mono256-u2       256 1 OFF ON  2 ""; profiles+=(exact-mono256-u2)
build_profile exact-mono320-u2       320 1 OFF ON  2 ""; profiles+=(exact-mono320-u2)
build_profile exact-mono64-b2-u2      64 2 OFF ON  2 ""; profiles+=(exact-mono64-b2-u2)
build_profile exact-mono64-r96-u2     64 1 OFF ON  2 96; profiles+=(exact-mono64-r96-u2)
build_profile exact-split320-u2      320 1 ON  ON  2 ""; profiles+=(exact-split320-u2)

best_profile=""; best_hps=0
for profile in "${profiles[@]}"; do
  hps="$(cat "${PROFILE_ROOT}/${profile}/profile.hps")"
  if (( hps > best_hps )); then best_hps="${hps}"; best_profile="${profile}"; fi
done
[[ -n "${best_profile}" ]] || { echo "No CUDA profile selected" >&2; exit 1; }

baseline_hps="$(cat "${PROFILE_ROOT}/baseline-mono64-u2/profile.hps")"
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
  install -m 0755 "${ROOT_DIR}/hiveos/${script}" "${PACKAGE_DIR}/${script}"
done
install -m 0755 "${ROOT_DIR}/hiveos/stratum-replay-proxy.py" "${PACKAGE_DIR}/stratum-replay-proxy.py"
install -m 0644 "${ROOT_DIR}/hiveos/h-manifest.conf" "${PACKAGE_DIR}/h-manifest.conf"
install -m 0644 "${ROOT_DIR}/VERSION" "${PACKAGE_DIR}/VERSION"

{
  echo "version=${VERSION}"
  echo "selected_profile=${best_profile}"
  echo "selected_hps=${best_hps}"
  echo "baseline_profile=baseline-mono64-u2"
  echo "baseline_hps=${baseline_hps}"
  echo "uplift_pct=${uplift_pct}"
  echo "target_hps=${TARGET_HPS}"
  echo "edition=${EXPECTED_EDITION}"
  echo "benchmark_nonces=${BENCH_NONCES}"
  echo "benchmark_runs=${BENCH_RUNS}"
  echo "driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 | xargs)"
  echo "gpu=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1 | xargs)"
  echo "git_commit=$(git -C "${ROOT_DIR}" rev-parse HEAD 2>/dev/null || true)"
  for profile in "${profiles[@]}"; do echo "--- ${profile} ---"; cat "${PROFILE_ROOT}/${profile}/profile.meta"; done
} > "${PACKAGE_DIR}/BUILD_PROFILE"

sed -i "s/^CUSTOM_VERSION=.*/CUSTOM_VERSION=${VERSION}/" "${PACKAGE_DIR}/h-manifest.conf"
sed -i "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=/hive/miners/custom/${PACKAGE_NAME}/config.txt#" "${PACKAGE_DIR}/h-manifest.conf"
for script in "${PACKAGE_DIR}"/*.sh; do bash -n "${script}"; done
python3 -m py_compile "${PACKAGE_DIR}/stratum-replay-proxy.py"
rm -rf "${PACKAGE_DIR}/__pycache__"
strip "${PACKAGE_DIR}/pepepowminer" 2>/dev/null || true

tar -C "${ROOT_DIR}/dist" -czf "${ARCHIVE_PATH}" "${PACKAGE_NAME}"
tar -tzf "${ARCHIVE_PATH}" > "${ARCHIVE_LIST}"
for entry in pepepowminer h-run.sh h-config.sh h-stats.sh h-manifest.conf VERSION BUILD_PROFILE; do
  grep -Fxq "${PACKAGE_NAME}/${entry}" "${ARCHIVE_LIST}" || { echo "Missing package entry: ${entry}" >&2; exit 1; }
done
rm -f "${ARCHIVE_LIST}"
SHA256="$(sha256sum "${ARCHIVE_PATH}" | awk '{print $1}')"

printf '\nPASS: %s v%s package completed\n' "${EXPECTED_EDITION}" "${VERSION}"
printf 'AUTOTUNE_PROFILE=%s\nAUTOTUNE_HPS=%s\nAUTOTUNE_BASELINE_HPS=%s\nAUTOTUNE_UPLIFT_PCT=%s\n' "${best_profile}" "${best_hps}" "${baseline_hps}" "${uplift_pct}"
if (( best_hps >= TARGET_HPS )); then printf 'TARGET_2MH=PASS\n'; else printf 'TARGET_2MH=PENDING\n'; fi
printf 'ARCHIVE=%s\nSHA256=%s\n' "${ARCHIVE_PATH}" "${SHA256}"
printf 'DOWNLOAD_COMMAND=cd %q && python3 -m http.server 8080 --bind 0.0.0.0\n' "${ROOT_DIR}/dist"
