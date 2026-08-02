#!/usr/bin/env bash
set -euo pipefail
umask 077

SOURCE_ROOT="${SOURCE_ROOT:-}"
OUT_ROOT="${OUT_ROOT:-/root/pepepow-tests}"
NONCES="${NONCES:-8388608}"
RUNS="${RUNS:-5}"
JOBS="${JOBS:-$(nproc)}"
CAPS="${CAPS:-96 88 84 80 76 72 68 64}"
STAMP="$(date +%Y%m%d_%H%M%S)"
NAME="v070-real-regcap-${STAMP}"
STAGE="${OUT_ROOT}/${NAME}"
ARCHIVE="${OUT_ROOT}/${NAME}.tar.gz"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}
for cmd in bash awk sed grep sort sha256sum tar python3 nvidia-smi cmake ctest; do need "$cmd"; done

find_source_root() {
  local candidate
  if [[ -n "${SOURCE_ROOT}" && -f "${SOURCE_ROOT}/native/CMakeLists.txt" ]]; then
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
  if command -v nvcc >/dev/null 2>&1; then command -v nvcc; return 0; fi
  local candidate
  for candidate in /usr/local/cuda/bin/nvcc /usr/local/cuda-12.4/bin/nvcc /usr/local/cuda-12/bin/nvcc; do
    [[ -x "${candidate}" ]] && { printf '%s\n' "${candidate}"; return 0; }
  done
  return 1
}

SOURCE_ROOT="$(find_source_root || true)"
[[ -n "${SOURCE_ROOT}" ]] || {
  echo "ERROR: v0.6.0 source tree with header80_backend_v060.cu was not found." >&2
  exit 1
}
NVCC_PATH="$(find_nvcc || true)"
[[ -n "${NVCC_PATH}" ]] || { echo "ERROR: nvcc not found" >&2; exit 1; }
export PATH="$(dirname "${NVCC_PATH}"):${PATH}"

SOURCE_FILE="${SOURCE_ROOT}/native/src/cuda/header80_backend_v060.cu"
BACKUP_FILE="${SOURCE_FILE}.v070-regcap-backup-${STAMP}"
BUILD_ROOT="${SOURCE_ROOT}/build-v070-real-regcap"
DEPS_DIR="${SOURCE_ROOT}/.deps-v060"

GPU_APPS="$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null || true)"
if [[ -n "${GPU_APPS//[[:space:]]/}" ]]; then
  echo "ERROR: GPU is busy. Use an empty flight sheet and stop all CUDA workloads." >&2
  echo "Active CUDA processes:" >&2
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

python3 - "${SOURCE_FILE}" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); t=p.read_text()
needle='__global__ __launch_bounds__(PEPEPOW_CUDA_THREADS, PEPEPOW_CUDA_MIN_BLOCKS)\nvoid header80_pow_kernel('
if t.count(needle) != 1:
    raise SystemExit(f'ERROR: expected exactly one pow-kernel qualifier, found {t.count(needle)}')
PY

{
  echo "name=${NAME}"
  echo "source_root=${SOURCE_ROOT}"
  echo "source_file=${SOURCE_FILE}"
  echo "nvcc=${NVCC_PATH}"
  echo "nonces=${NONCES}"
  echo "runs=${RUNS}"
  echo "caps=${CAPS}"
  echo "started_at=$(date --iso-8601=seconds)"
} > "${STAGE}/MANIFEST.txt"

nvidia-smi --query-gpu=name,uuid,driver_version,compute_cap,pstate,temperature.gpu,power.draw,power.limit,clocks.current.sm,clocks.current.memory,utilization.gpu,utilization.memory,memory.used,memory.total --format=csv,noheader \
  > "${STAGE}/nvidia/gpu-before.csv" 2>&1 || true
"${NVCC_PATH}" --version > "${STAGE}/nvcc-version.txt" 2>&1 || true

RESULTS="${STAGE}/results.csv"
printf 'profile,qualifier,requested_cap,valid,pow_registers,pow_stack_bytes,pow_spill_store_bytes,pow_spill_load_bytes,min_hps,median_hps,mean_hps,max_hps,stdev_hps,median_mhs,reason\n' > "${RESULTS}"

profile_hps() {
  sed -n 's/.* hps=\([0-9][0-9]*\).*/\1/p' <<<"$1" | tail -n1
}

patch_source() {
  local cap="$1"
  cp -f "${BACKUP_FILE}" "${SOURCE_FILE}"
  if [[ "${cap}" == "baseline" ]]; then
    return 0
  fi
  python3 - "${SOURCE_FILE}" "${cap}" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); cap=int(sys.argv[2]); t=p.read_text()
old='__global__ __launch_bounds__(PEPEPOW_CUDA_THREADS, PEPEPOW_CUDA_MIN_BLOCKS)\nvoid header80_pow_kernel('
new=f'__global__ __maxnreg__({cap})\nvoid header80_pow_kernel('
if t.count(old) != 1:
    raise SystemExit(f'expected one qualifier, found {t.count(old)}')
p.write_text(t.replace(old,new,1))
PY
}

extract_resource() {
  local resource="$1" key="$2"
  awk -v key="$key" '
    /Function .*header80_pow_kernel/ {f=1; next}
    f && /REG:/ {
      if (key=="reg") {line=$0; sub(/^.*REG:/,"",line); sub(/[^0-9].*$/, "", line); print line+0}
      else if (key=="stack") {line=$0; sub(/^.*STACK:/,"",line); sub(/[^0-9].*$/, "", line); print line+0}
      exit
    }' "$resource"
}

extract_ptxas_spill() {
  local log="$1" which="$2"
  awk -v which="$which" '
    /Compiling entry function .*header80_pow_kernel/ {f=1; next}
    f && /bytes stack frame, .* bytes spill stores, .* bytes spill loads/ {
      if (which=="store") {for(i=1;i<=NF;i++) if($(i+1)=="bytes" && $(i+2)=="spill" && $(i+3)=="stores,") {print $i+0; exit}}
      if (which=="load")  {for(i=1;i<=NF;i++) if($(i+1)=="bytes" && $(i+2)=="spill" && $(i+3)=="loads")  {print $i+0; exit}}
    }' "$log"
}

run_profile() {
  local cap="$1" profile qualifier requested
  if [[ "${cap}" == "baseline" ]]; then
    profile="baseline-launch-bounds"
    qualifier="launch_bounds"
    requested="auto"
  else
    profile="maxnreg-${cap}"
    qualifier="maxnreg"
    requested="${cap}"
  fi
  local dir="${BUILD_ROOT}/${profile}"
  local out="${STAGE}/profiles/${profile}"
  local build_log="${out}/build.log"
  mkdir -p "${out}"
  rm -rf "${dir}"

  echo
  echo "============================================================"
  echo "PROFILE=${profile}"
  echo "QUALIFIER=${qualifier}"
  echo "REQUESTED_CAP=${requested}"
  echo "STATUS=PATCHING"
  echo "============================================================"
  patch_source "${cap}"
  cp -f "${SOURCE_FILE}" "${out}/header80_backend_v060.cu"

  local cmake_args=(
    -S "${SOURCE_ROOT}/native" -B "${dir}"
    -DCMAKE_BUILD_TYPE=Release
    -DPEPEPOW_ENABLE_CUDA=ON
    -DPEPEPOW_BUILD_TESTS=ON
    -DPEPEPOW_CUDA_PTXAS_VERBOSE=ON
    -DPEPEPOW_CUDA_THREADS=64
    -DPEPEPOW_CUDA_MIN_BLOCKS=2
    -DPEPEPOW_CUDA_MAX_REGISTERS=
    -DPEPEPOW_CUDA_SCALED_MATRIX=ON
    -DPEPEPOW_CUDA_SPLIT_PIPELINE=OFF
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
    -DCMAKE_CUDA_COMPILER="${NVCC_PATH}"
    -DFETCHCONTENT_BASE_DIR="${DEPS_DIR}"
  )
  if command -v ccache >/dev/null 2>&1; then
    cmake_args+=(
      -DCMAKE_C_COMPILER_LAUNCHER=ccache
      -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
      -DCMAKE_CUDA_COMPILER_LAUNCHER=ccache)
  fi

  echo "STATUS=BUILDING"
  if ! {
    cmake "${cmake_args[@]}" &&
    cmake --build "${dir}" --parallel "${JOBS}" \
      --target pepepow_core_tests pepepow_cuda_tests pepepow_cuda_header80_validation \
               pepepow_header80_benchmark pepepowminer
  } >"${build_log}" 2>&1; then
    echo "PROFILE_RESULT profile=${profile} valid=0 reason=build_failed"
    tail -n 80 "${build_log}" || true
    printf '%s,%s,%s,0,0,0,0,0,0,0,0,0,0,0,build_failed\n' \
      "${profile}" "${qualifier}" "${requested}" >> "${RESULTS}"
    return 0
  fi

  echo "STATUS=VALIDATING"
  if ! ctest --test-dir "${dir}" --output-on-failure >"${out}/ctest.log" 2>&1; then
    echo "PROFILE_RESULT profile=${profile} valid=0 reason=ctest_failed"
    cat "${out}/ctest.log"
    printf '%s,%s,%s,0,0,0,0,0,0,0,0,0,0,0,ctest_failed\n' \
      "${profile}" "${qualifier}" "${requested}" >> "${RESULTS}"
    return 0
  fi
  if ! "${dir}/pepepow_cuda_header80_validation" >"${out}/validation.log" 2>&1; then
    echo "PROFILE_RESULT profile=${profile} valid=0 reason=consensus_failed"
    cat "${out}/validation.log"
    printf '%s,%s,%s,0,0,0,0,0,0,0,0,0,0,0,consensus_failed\n' \
      "${profile}" "${qualifier}" "${requested}" >> "${RESULTS}"
    return 0
  fi

  local resource="${out}/resource-usage.txt"
  if command -v cuobjdump >/dev/null 2>&1; then
    cuobjdump --dump-resource-usage "${dir}/pepepowminer" > "${resource}" 2>&1 || true
  else
    : > "${resource}"
  fi
  local regs stack spill_store spill_load
  regs="$(extract_resource "${resource}" reg || true)"; regs="${regs:-0}"
  stack="$(extract_resource "${resource}" stack || true)"; stack="${stack:-0}"
  spill_store="$(extract_ptxas_spill "${build_log}" store || true)"; spill_store="${spill_store:-0}"
  spill_load="$(extract_ptxas_spill "${build_log}" load || true)"; spill_load="${spill_load:-0}"

  echo "STATUS=BENCHMARKING REGISTERS=${regs} STACK=${stack} SPILL_STORE=${spill_store} SPILL_LOAD=${spill_load}"
  local run output hps
  local speeds=()
  : > "${out}/benchmark.log"
  for ((run=1; run<=RUNS; run++)); do
    output="$("${dir}/pepepow_header80_benchmark" "${NONCES}" 2>&1)"
    hps="$(profile_hps "${output}")"
    if [[ ! "${hps}" =~ ^[1-9][0-9]*$ ]]; then
      echo "PROFILE_RESULT profile=${profile} valid=0 reason=benchmark_parse_failed"
      printf '%s,%s,%s,0,%s,%s,%s,%s,0,0,0,0,0,0,benchmark_parse_failed\n' \
        "${profile}" "${qualifier}" "${requested}" "${regs}" "${stack}" "${spill_store}" "${spill_load}" >> "${RESULTS}"
      return 0
    fi
    speeds+=("${hps}")
    printf 'RUN=%02d %s\n' "${run}" "${output}" | tee -a "${out}/benchmark.log"
  done

  local stats min median mean max stdev median_mhs
  stats="$(printf '%s\n' "${speeds[@]}" | python3 -c 'import sys,statistics as s; v=[int(x) for x in sys.stdin if x.strip()]; print(min(v),int(s.median(v)),f"{s.mean(v):.2f}",max(v),f"{s.pstdev(v):.2f}",f"{s.median(v)/1e6:.6f}")')"
  read -r min median mean max stdev median_mhs <<<"${stats}"
  printf '%s,%s,%s,1,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,ok\n' \
    "${profile}" "${qualifier}" "${requested}" "${regs}" "${stack}" "${spill_store}" "${spill_load}" \
    "${min}" "${median}" "${mean}" "${max}" "${stdev}" "${median_mhs}" >> "${RESULTS}"
  echo "PROFILE_RESULT profile=${profile} valid=1 requested_cap=${requested} pow_regs=${regs} stack=${stack} spill_store=${spill_store} spill_load=${spill_load} median_hps=${median} median_mhs=${median_mhs}"
}

run_profile baseline
for cap in ${CAPS}; do
  run_profile "${cap}"
done

restore_source
trap - EXIT INT TERM

echo "finished_at=$(date --iso-8601=seconds)" >> "${STAGE}/MANIFEST.txt"
nvidia-smi --query-gpu=name,pstate,temperature.gpu,power.draw,power.limit,clocks.current.sm,clocks.current.memory,utilization.gpu,utilization.memory --format=csv,noheader \
  > "${STAGE}/nvidia/gpu-after.csv" 2>&1 || true

python3 - "${RESULTS}" "${STAGE}/summary.txt" <<'PY'
import csv,sys
src,dst=sys.argv[1:]
rows=list(csv.DictReader(open(src,encoding='utf-8')))
valid=[r for r in rows if r['valid']=='1']
base=next((r for r in valid if r['profile']=='baseline-launch-bounds'),None)
best=max(valid,key=lambda r:int(r['median_hps'])) if valid else None
with open(dst,'w',encoding='utf-8') as f:
    f.write(f'profiles_total={len(rows)}\nprofiles_valid={len(valid)}\n')
    if base: f.write(f'baseline_hps={base["median_hps"]}\nbaseline_regs={base["pow_registers"]}\n')
    if best:
        f.write(f'best_profile={best["profile"]}\nbest_hps={best["median_hps"]}\nbest_mhs={best["median_mhs"]}\nbest_regs={best["pow_registers"]}\nbest_stack={best["pow_stack_bytes"]}\nbest_spill_store={best["pow_spill_store_bytes"]}\nbest_spill_load={best["pow_spill_load_bytes"]}\n')
        if base:
            uplift=(int(best['median_hps'])/int(base['median_hps'])-1)*100
            f.write(f'uplift_pct={uplift:.4f}\n')
PY

cat "${STAGE}/summary.txt"
tar -C "${OUT_ROOT}" -czf "${ARCHIVE}" "${NAME}"
sha256sum "${ARCHIVE}" > "${ARCHIVE}.sha256"

echo
echo "========== V0.7.0 REAL REGISTER-CAP MATRIX COMPLETE =========="
cat "${STAGE}/summary.txt"
echo "RESULTS=${RESULTS}"
echo "ARCHIVE=${ARCHIVE}"
echo "SHA256_FILE=${ARCHIVE}.sha256"
ls -lh "${ARCHIVE}" "${ARCHIVE}.sha256"
