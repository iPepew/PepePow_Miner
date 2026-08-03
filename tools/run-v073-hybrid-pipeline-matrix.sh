#!/usr/bin/env bash
set -euo pipefail
umask 077

SOURCE_ROOT="${SOURCE_ROOT:-}"
OUT_ROOT="${OUT_ROOT:-/root/pepepow-tests}"
NONCES="${NONCES:-16777216}"
RUNS="${RUNS:-9}"
JOBS="${JOBS:-$(nproc)}"
STAMP="$(date +%Y%m%d_%H%M%S)"
NAME="v073-hybrid-pipeline-${STAMP}"
STAGE="${OUT_ROOT}/${NAME}"
ARCHIVE="${OUT_ROOT}/${NAME}.tar.gz"
RESULTS="${STAGE}/results.csv"
PUBLISHER_URL="https://raw.githubusercontent.com/iPepew/PepePow_Miner/experiment/v0.7.0-8h-autotune/tools/publish-test-results.sh"
PUBLISHER="/root/publish-pepepow-test-results.sh"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}
for cmd in bash awk sed grep sort sha256sum tar python3 nvidia-smi cmake ctest curl; do
  need "$cmd"
done

find_source_root() {
  local candidate
  if [[ -n "${SOURCE_ROOT}" &&
        -f "${SOURCE_ROOT}/native/CMakeLists.txt" &&
        -f "${SOURCE_ROOT}/native/src/cuda/header80_backend_v060.cu" ]]; then
    readlink -f "${SOURCE_ROOT}"
    return 0
  fi
  for candidate in \
    /root/pepepow-v060-8h-src \
    /root/pepepow-v060-src \
    /root/pepepow-v0.6.0-src \
    /root/PepePow_Miner; do
    [[ -f "${candidate}/native/CMakeLists.txt" ]] || continue
    [[ -f "${candidate}/native/src/cuda/header80_backend_v060.cu" ]] || continue
    readlink -f "${candidate}"
    return 0
  done
  return 1
}

find_nvcc() {
  if command -v nvcc >/dev/null 2>&1; then
    command -v nvcc
    return 0
  fi
  local candidate
  for candidate in /usr/local/cuda/bin/nvcc /usr/local/cuda-12.4/bin/nvcc /usr/local/cuda-12/bin/nvcc; do
    [[ -x "${candidate}" ]] && { printf '%s\n' "${candidate}"; return 0; }
  done
  return 1
}

SOURCE_ROOT="$(find_source_root || true)"
[[ -n "${SOURCE_ROOT}" ]] || { echo "ERROR: v0.6.0 source tree not found" >&2; exit 1; }
NVCC="$(find_nvcc || true)"
[[ -n "${NVCC}" ]] || { echo "ERROR: nvcc not found" >&2; exit 1; }
export PATH="$(dirname "${NVCC}"):${PATH}"

SOURCE_FILE="${SOURCE_ROOT}/native/src/cuda/header80_backend_v060.cu"
BACKUP_FILE="${SOURCE_FILE}.v073-hybrid-backup-${STAMP}"
BUILD_ROOT="${SOURCE_ROOT}/build-v073-hybrid-pipeline"
DEPS_DIR="${SOURCE_ROOT}/.deps-v060"

GPU_APPS="$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null || true)"
if [[ -n "${GPU_APPS//[[:space:]]/}" ]]; then
  echo "ERROR: GPU is busy. Use an empty flight sheet and stop all CUDA workloads." >&2
  echo "${GPU_APPS}" >&2
  exit 2
fi

mkdir -p "${STAGE}"/{profiles,nvidia,source}
cp -f "${SOURCE_FILE}" "${BACKUP_FILE}"
cp -f "${SOURCE_FILE}" "${STAGE}/source/header80_backend_v060.original.cu"

restore_source() {
  if [[ -f "${BACKUP_FILE}" ]]; then
    cp -f "${BACKUP_FILE}" "${SOURCE_FILE}"
    rm -f "${BACKUP_FILE}"
  fi
}
trap restore_source EXIT INT TERM

PROFILE_IDS=(mono-t64-b2 full-split-t64-b2 first-split-t64-b2 final-split-t64-b2)
PROFILE_MODES=(mono full first-split final-split)
PROFILE_KERNELS=(header80_pow_kernel hoohash_mix_kernel header80_mix_final_kernel header80_first_mix_kernel)
TOTAL="${#PROFILE_IDS[@]}"

{
  echo "name=${NAME}"
  echo "source_root=${SOURCE_ROOT}"
  echo "nonces=${NONCES}"
  echo "runs=${RUNS}"
  echo "profiles_total=${TOTAL}"
  printf 'profiles='; printf ' %s' "${PROFILE_IDS[@]}"; echo
  echo "started_at=$(date --iso-8601=seconds)"
} > "${STAGE}/MANIFEST.txt"

nvidia-smi -q > "${STAGE}/nvidia/nvidia-smi-before.txt" 2>&1 || true
"${NVCC}" --version > "${STAGE}/nvcc-version.txt" 2>&1 || true

printf '%s\n' \
  'profile,valid,mode,kernel,registers,stack_bytes,spill_store_bytes,spill_load_bytes,min_hps,median_hps,mean_hps,max_hps,stdev_hps,median_mhs,reason' \
  > "${RESULTS}"

patch_source() {
  local mode="${1:?missing mode}"
  cp -f "${BACKUP_FILE}" "${SOURCE_FILE}"
  [[ "${mode}" == "mono" || "${mode}" == "full" ]] && return 0

  python3 - "${SOURCE_FILE}" "${mode}" <<'PY'
from pathlib import Path
import sys

path=Path(sys.argv[1])
mode=sys.argv[2]
text=path.read_text(encoding="utf-8")

marker='''__global__ __launch_bounds__(PEPEPOW_CUDA_THREADS, PEPEPOW_CUDA_MIN_BLOCKS)
void header80_final_kernel('''

hybrid_kernels=r'''__global__ __launch_bounds__(PEPEPOW_CUDA_THREADS, PEPEPOW_CUDA_MIN_BLOCKS)
void header80_first_mix_kernel(
    std::uint32_t first_nonce,
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    std::uint32_t* __restrict__ work_words,
    std::size_t count) {
    const std::size_t index =
        static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (index >= count) return;
    const std::uint32_t nonce =
        first_nonce + static_cast<std::uint32_t>(index);
    std::uint32_t first_pass[8];
    std::uint32_t mixed[8];
    blake3_header80_words(nonce, first_pass);
    hoohash_mix_words(matrix, scaled_nibble_table, byte_swap32(nonce),
                      first_pass, mixed);
    std::uint32_t* output = work_words + index * 8U;
    #pragma unroll
    for (int i = 0; i < 8; ++i) output[i] = mixed[i];
}

__global__ __launch_bounds__(PEPEPOW_CUDA_THREADS, PEPEPOW_CUDA_MIN_BLOCKS)
void header80_mix_final_kernel(
    std::uint32_t first_nonce,
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    const std::uint32_t* __restrict__ work_words,
    DeviceShareResult* __restrict__ result,
    std::size_t count) {
    const std::size_t index =
        static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (index >= count) return;
    const std::uint32_t nonce =
        first_nonce + static_cast<std::uint32_t>(index);
    const std::uint32_t* input = work_words + index * 8U;
    std::uint32_t first_pass[8];
    std::uint32_t mixed[8];
    std::uint32_t final_hash[8];
    #pragma unroll
    for (int i = 0; i < 8; ++i) first_pass[i] = input[i];
    hoohash_mix_words(matrix, scaled_nibble_table, byte_swap32(nonce),
                      first_pass, mixed);
    blake3_32_words(mixed, final_hash);
    if (!hash_words_meet_target(final_hash)) return;
    if (atomicCAS(&result->found, 0U, 1U) == 0U) {
        result->nonce = nonce;
        #pragma unroll
        for (int i = 0; i < 8; ++i) result->hash_words[i] = final_hash[i];
    }
}

'''
if text.count(marker) != 1:
    raise SystemExit(f"ERROR: final-kernel marker count={text.count(marker)}")
text=text.replace(marker, hybrid_kernels + marker, 1)

old=r'''    static thread_local bool cache_configured = false;
    if (!cache_configured) {
        check_cuda_header80(
            cudaFuncSetCacheConfig(hoohash_mix_kernel, cudaFuncCachePreferL1),
            "cudaFuncSetCacheConfig(hoohash mix)");
        cache_configured = true;
    }
    auto* work_words = static_cast<std::uint32_t*>(device_work_);
    header80_first_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin), work_words, count);
    check_cuda_header80(cudaGetLastError(), "header80_first_kernel launch");
    hoohash_mix_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_),
        static_cast<const double*>(device_scaled_nibble_), work_words, count);
    check_cuda_header80(cudaGetLastError(), "hoohash_mix_kernel launch");
    header80_final_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin), work_words,
        static_cast<DeviceShareResult*>(device_result_), count);
    check_cuda_header80(cudaGetLastError(), "header80_final_kernel launch");'''

first_split=r'''    static thread_local bool cache_configured = false;
    if (!cache_configured) {
        check_cuda_header80(
            cudaFuncSetCacheConfig(header80_mix_final_kernel,
                                   cudaFuncCachePreferL1),
            "cudaFuncSetCacheConfig(header80 mix-final)");
        cache_configured = true;
    }
    auto* work_words = static_cast<std::uint32_t*>(device_work_);
    header80_first_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin), work_words, count);
    check_cuda_header80(cudaGetLastError(), "header80_first_kernel launch");
    header80_mix_final_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_),
        static_cast<const double*>(device_scaled_nibble_),
        work_words, static_cast<DeviceShareResult*>(device_result_), count);
    check_cuda_header80(cudaGetLastError(),
                        "header80_mix_final_kernel launch");'''

final_split=r'''    static thread_local bool cache_configured = false;
    if (!cache_configured) {
        check_cuda_header80(
            cudaFuncSetCacheConfig(header80_first_mix_kernel,
                                   cudaFuncCachePreferL1),
            "cudaFuncSetCacheConfig(header80 first-mix)");
        cache_configured = true;
    }
    auto* work_words = static_cast<std::uint32_t*>(device_work_);
    header80_first_mix_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_),
        static_cast<const double*>(device_scaled_nibble_),
        work_words, count);
    check_cuda_header80(cudaGetLastError(),
                        "header80_first_mix_kernel launch");
    header80_final_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin), work_words,
        static_cast<DeviceShareResult*>(device_result_), count);
    check_cuda_header80(cudaGetLastError(),
                        "header80_final_kernel launch");'''

if text.count(old) != 1:
    raise SystemExit(f"ERROR: split launch block count={text.count(old)}")
replacement=first_split if mode=="first-split" else final_split
text=text.replace(old, replacement, 1)
path.write_text(text, encoding="utf-8")
PY
}

extract_hps() {
  sed -n 's/.* hps=\([0-9][0-9]*\).*/\1/p' <<<"$1" | tail -n1
}

extract_resource() {
  local resource_file="$1" kernel="$2" key="$3"
  awk -v kernel="${kernel}" -v key="${key}" '
    $0 ~ "Function .*" kernel {in_kernel=1; next}
    in_kernel && /REG:/ {
      line=$0
      if (key=="reg") sub(/^.*REG:/, "", line)
      else sub(/^.*STACK:/, "", line)
      sub(/[^0-9].*$/, "", line)
      print line+0
      exit
    }' "${resource_file}"
}

extract_spill() {
  local build_log="$1" kernel="$2" which="$3"
  awk -v kernel="${kernel}" -v which="${which}" '
    $0 ~ "Compiling entry function .*" kernel {in_kernel=1; next}
    in_kernel && /bytes stack frame, .* bytes spill stores, .* bytes spill loads/ {
      if (which=="store") {
        for(i=1;i<=NF;i++) if($(i+1)=="bytes" && $(i+2)=="spill" && $(i+3)=="stores,"){print $i+0;exit}
      } else {
        for(i=1;i<=NF;i++) if($(i+1)=="bytes" && $(i+2)=="spill" && $(i+3)=="loads"){print $i+0;exit}
      }
    }' "${build_log}"
}

run_profile() {
  local index="${1:?missing profile index}"
  local profile mode kernel split dir out build_log resource
  local regs stack spill_store spill_load run output hps stats
  local min_hps median_hps mean_hps max_hps stdev_hps median_mhs
  local -a speeds cmake_args

  profile="${PROFILE_IDS[$index]}"
  mode="${PROFILE_MODES[$index]}"
  kernel="${PROFILE_KERNELS[$index]}"
  if [[ "${mode}" == "mono" ]]; then split="OFF"; else split="ON"; fi

  dir="${BUILD_ROOT}/${profile}"
  out="${STAGE}/profiles/${profile}"
  build_log="${out}/build.log"
  mkdir -p "${out}"
  rm -rf "${dir}"

  echo
  echo "======================================================================"
  echo "PROFILE_INDEX=$((index+1))"
  echo "PROFILE_TOTAL=${TOTAL}"
  echo "PROFILE=${profile}"
  echo "PROFILE_CONFIG mode=${mode} split_pipeline=${split} threads=64 min_blocks=2 kernel=${kernel}"
  echo "STATUS=PATCHING"
  echo "======================================================================"

  patch_source "${mode}"
  cp -f "${SOURCE_FILE}" "${out}/header80_backend_v060.cu"

  cmake_args=(
    -S "${SOURCE_ROOT}/native" -B "${dir}"
    -DCMAKE_BUILD_TYPE=Release
    -DPEPEPOW_ENABLE_CUDA=ON
    -DPEPEPOW_BUILD_TESTS=ON
    -DPEPEPOW_CUDA_PTXAS_VERBOSE=ON
    -DPEPEPOW_CUDA_THREADS=64
    -DPEPEPOW_CUDA_MIN_BLOCKS=2
    -DPEPEPOW_CUDA_MAX_REGISTERS=
    -DPEPEPOW_CUDA_SCALED_MATRIX=ON
    -DPEPEPOW_CUDA_SPLIT_PIPELINE="${split}"
    -DPEPEPOW_CUDA_FAST_FRACTION=ON
    -DPEPEPOW_CUDA_EXACT_BIT_CONVERSIONS=ON
    -DPEPEPOW_CUDA_BIT_SW_FRACTION=ON
    -DPEPEPOW_CUDA_DERIVE_TWO=OFF
    -DPEPEPOW_CUDA_NIBBLE_TABLE=OFF
    -DPEPEPOW_CUDA_SCALED_NIBBLE_TABLE=ON
    -DPEPEPOW_CUDA_ASSUME_FINITE=ON
    -DPEPEPOW_CUDA_SW_STATE_MODE=3
    -DPEPEPOW_CUDA_BYTE_UNROLL=1
    -DCMAKE_CUDA_ARCHITECTURES=86
    -DCMAKE_CUDA_COMPILER="${NVCC}"
    -DFETCHCONTENT_BASE_DIR="${DEPS_DIR}"
  )
  if command -v ccache >/dev/null 2>&1; then
    cmake_args+=(
      -DCMAKE_C_COMPILER_LAUNCHER=ccache
      -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
      -DCMAKE_CUDA_COMPILER_LAUNCHER=ccache
    )
  fi

  echo "STATUS=BUILDING"
  if ! {
    cmake "${cmake_args[@]}"
    cmake --build "${dir}" --parallel "${JOBS}" \
      --target pepepow_core_tests pepepow_cuda_tests \
               pepepow_cuda_header80_validation \
               pepepow_header80_benchmark pepepowminer
  } >"${build_log}" 2>&1; then
    echo "PROFILE_RESULT profile=${profile} valid=0 reason=build_failed"
    tail -n100 "${build_log}" || true
    printf '%s,0,%s,%s,0,0,0,0,0,0,0,0,0,0,build_failed\n' \
      "${profile}" "${mode}" "${kernel}" >>"${RESULTS}"
    return 0
  fi

  echo "STATUS=VALIDATING"
  if ! ctest --test-dir "${dir}" --output-on-failure >"${out}/ctest.log" 2>&1; then
    echo "PROFILE_RESULT profile=${profile} valid=0 reason=ctest_failed"
    cat "${out}/ctest.log" || true
    printf '%s,0,%s,%s,0,0,0,0,0,0,0,0,0,0,ctest_failed\n' \
      "${profile}" "${mode}" "${kernel}" >>"${RESULTS}"
    return 0
  fi
  if ! "${dir}/pepepow_cuda_header80_validation" >"${out}/validation.log" 2>&1; then
    echo "PROFILE_RESULT profile=${profile} valid=0 reason=consensus_failed"
    cat "${out}/validation.log" || true
    printf '%s,0,%s,%s,0,0,0,0,0,0,0,0,0,0,consensus_failed\n' \
      "${profile}" "${mode}" "${kernel}" >>"${RESULTS}"
    return 0
  fi

  resource="${out}/resource-usage.txt"
  if command -v cuobjdump >/dev/null 2>&1; then
    cuobjdump --dump-resource-usage "${dir}/pepepowminer" >"${resource}" 2>&1 || true
  else
    : >"${resource}"
  fi
  regs="$(extract_resource "${resource}" "${kernel}" reg || true)"
  stack="$(extract_resource "${resource}" "${kernel}" stack || true)"
  spill_store="$(extract_spill "${build_log}" "${kernel}" store || true)"
  spill_load="$(extract_spill "${build_log}" "${kernel}" load || true)"
  regs="${regs:-0}"; stack="${stack:-0}"; spill_store="${spill_store:-0}"; spill_load="${spill_load:-0}"

  echo "STATUS=BENCHMARKING REGISTERS=${regs} STACK=${stack} SPILL_STORE=${spill_store} SPILL_LOAD=${spill_load}"
  : >"${out}/benchmark.log"
  speeds=()
  for ((run=1; run<=RUNS; run++)); do
    output="$("${dir}/pepepow_header80_benchmark" "${NONCES}" 2>&1)"
    hps="$(extract_hps "${output}")"
    if [[ ! "${hps}" =~ ^[1-9][0-9]*$ ]]; then
      echo "PROFILE_RESULT profile=${profile} valid=0 reason=benchmark_parse_failed"
      printf '%s,0,%s,%s,%s,%s,%s,%s,0,0,0,0,0,0,benchmark_parse_failed\n' \
        "${profile}" "${mode}" "${kernel}" "${regs}" "${stack}" "${spill_store}" "${spill_load}" >>"${RESULTS}"
      return 0
    fi
    speeds+=("${hps}")
    printf 'BENCH_RUN profile=%s run=%02d/%02d hps=%s %s\n' \
      "${profile}" "${run}" "${RUNS}" "${hps}" "${output}" | tee -a "${out}/benchmark.log"
  done

  stats="$(printf '%s\n' "${speeds[@]}" | python3 -c '
import statistics as s, sys
v=[int(x) for x in sys.stdin if x.strip()]
print(min(v), int(s.median(v)), f"{s.mean(v):.2f}", max(v), f"{s.pstdev(v):.2f}", f"{s.median(v)/1e6:.6f}")
')"
  read -r min_hps median_hps mean_hps max_hps stdev_hps median_mhs <<<"${stats}"

  printf '%s,1,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,ok\n' \
    "${profile}" "${mode}" "${kernel}" "${regs}" "${stack}" "${spill_store}" "${spill_load}" \
    "${min_hps}" "${median_hps}" "${mean_hps}" "${max_hps}" "${stdev_hps}" "${median_mhs}" >>"${RESULTS}"

  echo "PROFILE_RESULT profile=${profile} valid=1 mode=${mode} kernel=${kernel} registers=${regs} stack=${stack} spill_store=${spill_store} spill_load=${spill_load} median_hps=${median_hps} median_mhs=${median_mhs}"
}

for ((i=0; i<TOTAL; i++)); do run_profile "${i}"; done

restore_source
trap - EXIT INT TERM
echo "finished_at=$(date --iso-8601=seconds)" >>"${STAGE}/MANIFEST.txt"
nvidia-smi -q >"${STAGE}/nvidia/nvidia-smi-after.txt" 2>&1 || true

python3 - "${RESULTS}" "${STAGE}/summary.txt" <<'PY'
import csv,sys
rows=list(csv.DictReader(open(sys.argv[1],encoding="utf-8")))
valid=[r for r in rows if r["valid"]=="1"]
baseline=next((r for r in valid if r["profile"]=="mono-t64-b2"),None)
best=max(valid,key=lambda r:int(r["median_hps"])) if valid else None
with open(sys.argv[2],"w",encoding="utf-8") as f:
    f.write(f"profiles_total={len(rows)}\n")
    f.write(f"profiles_valid={len(valid)}\n")
    if baseline:
        f.write(f"baseline_hps={baseline['median_hps']}\n")
        f.write(f"baseline_mhs={baseline['median_mhs']}\n")
    if best:
        for key in ("profile","mode","kernel","registers","stack_bytes","spill_store_bytes","spill_load_bytes","median_hps","median_mhs"):
            f.write(f"best_{key}={best[key]}\n")
        if baseline and int(baseline["median_hps"]):
            uplift=(int(best["median_hps"])/int(baseline["median_hps"])-1.0)*100.0
            f.write(f"uplift_pct={uplift:.4f}\n")
PY

tar -C "${OUT_ROOT}" -czf "${ARCHIVE}" "${NAME}"
sha256sum "${ARCHIVE}" >"${ARCHIVE}.sha256"

echo
echo "========== V0.7.3 HYBRID PIPELINE MATRIX COMPLETE =========="
cat "${STAGE}/summary.txt"
echo "RESULTS=${RESULTS}"
echo "ARCHIVE=${ARCHIVE}"
echo "SHA256_FILE=${ARCHIVE}.sha256"

if curl -fsSL "${PUBLISHER_URL}" -o "${PUBLISHER}"; then
  chmod +x "${PUBLISHER}"
  PUBLIC_UPLOAD="${PUBLIC_UPLOAD:-1}" "${PUBLISHER}" "${ARCHIVE}" || true
fi
