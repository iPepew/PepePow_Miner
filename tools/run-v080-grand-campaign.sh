#!/usr/bin/env bash
set -euo pipefail
umask 077

SOURCE_ROOT="${SOURCE_ROOT:-}"
OUT_ROOT="${OUT_ROOT:-/root/pepepow-tests}"
NONCES="${NONCES:-16777216}"
RUNS="${RUNS:-7}"
STRESS_RUNS="${STRESS_RUNS:-20}"
JOBS="${JOBS:-$(nproc)}"
STAMP="$(date +%Y%m%d_%H%M%S)"
NAME="v080-grand-${STAMP}"
STAGE="${OUT_ROOT}/${NAME}"
ARCHIVE="${OUT_ROOT}/${NAME}.tar.gz"
RESULTS="${STAGE}/results.csv"
PATCHER="${PATCHER:-/root/prepare-v080-grand-source.py}"
PUBLISHER_URL="https://raw.githubusercontent.com/iPepew/PepePow_Miner/experiment/v0.8.0-grand/tools/publish-test-results.sh"
PUBLISHER="/root/publish-pepepow-test-results.sh"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}
for cmd in bash awk sed grep sha256sum tar python3 nvidia-smi cmake ctest curl; do
  need "$cmd"
done
[[ -f "${PATCHER}" ]] || {
  echo "ERROR: source generator is missing: ${PATCHER}" >&2
  exit 1
}

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
  for candidate in \
    /usr/local/cuda/bin/nvcc \
    /usr/local/cuda-12.4/bin/nvcc \
    /usr/local/cuda-12/bin/nvcc; do
    if [[ -x "${candidate}" ]]; then
      echo "${candidate}"
      return 0
    fi
  done
  return 1
}

SOURCE_ROOT="$(find_source_root || true)"
[[ -n "${SOURCE_ROOT}" ]] || {
  echo "ERROR: prepared v0.6.0 source tree not found" >&2
  exit 1
}
NVCC="$(find_nvcc || true)"
[[ -n "${NVCC}" ]] || {
  echo "ERROR: nvcc not found" >&2
  exit 1
}
export PATH="$(dirname "${NVCC}"):${PATH}"

SOURCE_FILE="${SOURCE_ROOT}/native/src/cuda/header80_backend_v060.cu"
BACKUP_FILE="${SOURCE_FILE}.v080-grand-backup-${STAMP}"
BUILD_ROOT="${SOURCE_ROOT}/build-v080-grand"
DEPS_DIR="${SOURCE_ROOT}/.deps-v060"

GPU_APPS="$(nvidia-smi --query-compute-apps=pid,process_name,used_memory \
  --format=csv,noheader,nounits 2>/dev/null || true)"
if [[ -n "${GPU_APPS//[[:space:]]/}" ]]; then
  echo "ERROR: GPU is busy. Use an empty flight sheet and stop all CUDA workloads." >&2
  echo "Active CUDA processes:" >&2
  echo "${GPU_APPS}" >&2
  exit 2
fi

mkdir -p "${STAGE}"/{profiles,nvidia,source,stress}
cp -f "${SOURCE_FILE}" "${BACKUP_FILE}"
cp -f "${SOURCE_FILE}" "${STAGE}/source/header80_backend_v060.original.cu"
cp -f "${PATCHER}" "${STAGE}/source/prepare-v080-grand-source.py"

restore_source() {
  if [[ -f "${BACKUP_FILE}" ]]; then
    cp -f "${BACKUP_FILE}" "${SOURCE_FILE}"
    rm -f "${BACKUP_FILE}"
  fi
}
trap restore_source EXIT INT TERM

PROFILE_IDS=(
  baseline-t64-b2
  selector-t64-b2
  dual-seq-t64-b1
  dual-seq-t64-b2
  dual-ilp-t64-b1
  dual-ilp-t64-b2
  selector-dual-ilp-t64-b1
  selector-dual-ilp-t64-b2
  dual-ilp-t128-b1
  selector-dual-ilp-t128-b1
)
PROFILE_MODES=(
  baseline
  selector
  dual-seq
  dual-seq
  dual-ilp
  dual-ilp
  selector-dual-ilp
  selector-dual-ilp
  dual-ilp
  selector-dual-ilp
)
PROFILE_THREADS=(64 64 64 64 64 64 64 64 128 128)
PROFILE_BLOCKS=(2 2 1 2 1 2 1 2 1 1)
TOTAL="${#PROFILE_IDS[@]}"

{
  echo "name=${NAME}"
  echo "source_root=${SOURCE_ROOT}"
  echo "nonces=${NONCES}"
  echo "runs=${RUNS}"
  echo "stress_runs=${STRESS_RUNS}"
  echo "profiles_total=${TOTAL}"
  printf 'profiles='; printf ' %s' "${PROFILE_IDS[@]}"; echo
  echo "target_internal_hps=2000000"
  echo "started_at=$(date --iso-8601=seconds)"
} > "${STAGE}/MANIFEST.txt"

nvidia-smi -q > "${STAGE}/nvidia/nvidia-smi-before.txt" 2>&1 || true
"${NVCC}" --version > "${STAGE}/nvcc-version.txt" 2>&1 || true
dmesg 2>/dev/null | grep -E 'NVRM|Xid' > "${STAGE}/nvidia/xid-before.txt" || true

printf '%s\n' \
  'profile,valid,mode,threads,min_blocks,kernel,registers,stack_bytes,spill_store_bytes,spill_load_bytes,min_hps,median_hps,mean_hps,max_hps,stdev_hps,median_mhs,clock_mean_mhz,power_mean_w,temp_mean_c,reason' \
  > "${RESULTS}"

extract_hps() {
  sed -n 's/.* hps=\([0-9][0-9]*\).*/\1/p' <<<"$1" | tail -n1
}

extract_resource() {
  local resource_file="$1"
  local kernel="$2"
  local key="$3"
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
  local build_log="$1"
  local kernel="$2"
  local which="$3"
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

append_invalid() {
  local profile="$1" mode="$2" threads="$3" blocks="$4" kernel="$5" reason="$6"
  printf '%s,0,%s,%s,%s,%s,0,0,0,0,0,0,0,0,0,0,0,0,0,%s\n' \
    "${profile}" "${mode}" "${threads}" "${blocks}" "${kernel}" "${reason}" >> "${RESULTS}"
}

run_profile() {
  local index="$1"
  local profile mode threads blocks kernel dir out build_log resource
  local regs stack spill_store spill_load run output hps stats
  local min_hps median_hps mean_hps max_hps stdev_hps median_mhs
  local clock_mean power_mean temp_mean sampler_pid stop_file gpu_stats
  local -a speeds cmake_args

  profile="${PROFILE_IDS[$index]}"
  mode="${PROFILE_MODES[$index]}"
  threads="${PROFILE_THREADS[$index]}"
  blocks="${PROFILE_BLOCKS[$index]}"
  if [[ "${mode}" == *dual* ]]; then
    kernel="header80_pow2_kernel"
  else
    kernel="header80_pow_kernel"
  fi

  dir="${BUILD_ROOT}/${profile}"
  out="${STAGE}/profiles/${profile}"
  build_log="${out}/build.log"
  mkdir -p "${out}"
  rm -rf "${dir}"

  echo
  echo "================================================================================"
  echo "PROFILE_INDEX=$((index + 1))"
  echo "PROFILE_TOTAL=${TOTAL}"
  echo "PROFILE=${profile}"
  echo "PROFILE_CONFIG mode=${mode} threads=${threads} min_blocks=${blocks} kernel=${kernel}"
  echo "STATUS=PATCHING"
  echo "================================================================================"

  cp -f "${BACKUP_FILE}" "${SOURCE_FILE}"
  if [[ "${mode}" != "baseline" ]]; then
    if ! python3 "${PATCHER}" "${SOURCE_FILE}" "${mode}" >"${out}/patch.log" 2>&1; then
      echo "PROFILE_RESULT profile=${profile} valid=0 mode=${mode} reason=patch_failed"
      cat "${out}/patch.log" || true
      append_invalid "${profile}" "${mode}" "${threads}" "${blocks}" "${kernel}" patch_failed
      return 0
    fi
  fi
  cp -f "${SOURCE_FILE}" "${out}/header80_backend_v060.cu"

  cmake_args=(
    -S "${SOURCE_ROOT}/native"
    -B "${dir}"
    -DCMAKE_BUILD_TYPE=Release
    -DPEPEPOW_ENABLE_CUDA=ON
    -DPEPEPOW_BUILD_TESTS=ON
    -DPEPEPOW_CUDA_PTXAS_VERBOSE=ON
    -DPEPEPOW_CUDA_THREADS="${threads}"
    -DPEPEPOW_CUDA_MIN_BLOCKS="${blocks}"
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
               pepepow_header80_benchmark pepepowminer \
               pepepow_cuda_warp_probe
  } >"${build_log}" 2>&1; then
    echo "PROFILE_RESULT profile=${profile} valid=0 mode=${mode} reason=build_failed"
    tail -n 120 "${build_log}" || true
    append_invalid "${profile}" "${mode}" "${threads}" "${blocks}" "${kernel}" build_failed
    return 0
  fi

  echo "STATUS=VALIDATING"
  if ! ctest --test-dir "${dir}" --output-on-failure >"${out}/ctest.log" 2>&1; then
    echo "PROFILE_RESULT profile=${profile} valid=0 mode=${mode} reason=ctest_failed"
    cat "${out}/ctest.log" || true
    append_invalid "${profile}" "${mode}" "${threads}" "${blocks}" "${kernel}" ctest_failed
    return 0
  fi
  if ! "${dir}/pepepow_cuda_header80_validation" >"${out}/validation.log" 2>&1; then
    echo "PROFILE_RESULT profile=${profile} valid=0 mode=${mode} reason=consensus_failed"
    cat "${out}/validation.log" || true
    append_invalid "${profile}" "${mode}" "${threads}" "${blocks}" "${kernel}" consensus_failed
    return 0
  fi

  if [[ "${profile}" == "baseline-t64-b2" ]]; then
    "${dir}/pepepow_cuda_warp_probe" 65536 0 64 \
      >"${STAGE}/warp-divergence-probe.txt" 2>&1 || true
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
  regs="${regs:-0}"; stack="${stack:-0}"
  spill_store="${spill_store:-0}"; spill_load="${spill_load:-0}"

  echo "STATUS=BENCHMARKING REGISTERS=${regs} STACK=${stack} SPILL_STORE=${spill_store} SPILL_LOAD=${spill_load}"
  : >"${out}/benchmark.log"
  : >"${out}/gpu-samples.csv"
  echo 'timestamp,temperature_c,util_pct,clock_mhz,power_w' >"${out}/gpu-samples.csv"
  stop_file="${out}/stop-sampler"
  rm -f "${stop_file}"
  (
    while [[ ! -f "${stop_file}" ]]; do
      printf '%s,' "$(date +%s)" >>"${out}/gpu-samples.csv"
      nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,clocks.current.sm,power.draw \
        --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' >>"${out}/gpu-samples.csv" || true
      sleep 2
    done
  ) &
  sampler_pid=$!

  speeds=()
  for ((run=1; run<=RUNS; run++)); do
    output="$("${dir}/pepepow_header80_benchmark" "${NONCES}" 2>&1)"
    hps="$(extract_hps "${output}")"
    if [[ ! "${hps}" =~ ^[1-9][0-9]*$ ]]; then
      touch "${stop_file}"; wait "${sampler_pid}" 2>/dev/null || true
      echo "PROFILE_RESULT profile=${profile} valid=0 mode=${mode} reason=benchmark_parse_failed"
      append_invalid "${profile}" "${mode}" "${threads}" "${blocks}" "${kernel}" benchmark_parse_failed
      return 0
    fi
    speeds+=("${hps}")
    printf 'BENCH_RUN profile=%s run=%02d/%02d hps=%s %s\n' \
      "${profile}" "${run}" "${RUNS}" "${hps}" "${output}" | tee -a "${out}/benchmark.log"
  done
  touch "${stop_file}"
  wait "${sampler_pid}" 2>/dev/null || true

  stats="$(printf '%s\n' "${speeds[@]}" | python3 -c '
import statistics as s
import sys
v=[int(x) for x in sys.stdin if x.strip()]
print(min(v), int(s.median(v)), f"{s.mean(v):.2f}", max(v), f"{s.pstdev(v):.2f}", f"{s.median(v)/1e6:.6f}")
')"
  read -r min_hps median_hps mean_hps max_hps stdev_hps median_mhs <<<"${stats}"

  gpu_stats="$(python3 - "${out}/gpu-samples.csv" <<'PY'
import csv,statistics,sys
rows=[]
with open(sys.argv[1], newline='') as f:
    for row in csv.DictReader(f):
        try:
            if float(row['util_pct']) >= 80.0:
                rows.append(row)
        except Exception:
            pass
if not rows:
    print('0 0 0')
else:
    clock=statistics.mean(float(r['clock_mhz']) for r in rows)
    power=statistics.mean(float(r['power_w']) for r in rows)
    temp=statistics.mean(float(r['temperature_c']) for r in rows)
    print(f'{clock:.2f} {power:.2f} {temp:.2f}')
PY
)"
  read -r clock_mean power_mean temp_mean <<<"${gpu_stats}"

  printf '%s,1,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,ok\n' \
    "${profile}" "${mode}" "${threads}" "${blocks}" "${kernel}" \
    "${regs}" "${stack}" "${spill_store}" "${spill_load}" \
    "${min_hps}" "${median_hps}" "${mean_hps}" "${max_hps}" \
    "${stdev_hps}" "${median_mhs}" "${clock_mean}" "${power_mean}" "${temp_mean}" \
    >>"${RESULTS}"

  echo "PROFILE_RESULT profile=${profile} valid=1 mode=${mode} threads=${threads} min_blocks=${blocks} kernel=${kernel} registers=${regs} stack=${stack} spill_store=${spill_store} spill_load=${spill_load} median_hps=${median_hps} median_mhs=${median_mhs} clock_mean_mhz=${clock_mean} power_mean_w=${power_mean} temp_mean_c=${temp_mean}"
}

for ((index=0; index<TOTAL; index++)); do
  run_profile "${index}"
done
restore_source
trap - EXIT INT TERM

echo "finished_at=$(date --iso-8601=seconds)" >>"${STAGE}/MANIFEST.txt"
nvidia-smi -q >"${STAGE}/nvidia/nvidia-smi-after.txt" 2>&1 || true
dmesg 2>/dev/null | grep -E 'NVRM|Xid' >"${STAGE}/nvidia/xid-after.txt" || true

python3 - "${RESULTS}" "${STAGE}/summary.txt" "${BUILD_ROOT}" <<'PY'
import csv,sys
rows=list(csv.DictReader(open(sys.argv[1],encoding='utf-8')))
valid=[r for r in rows if r['valid']=='1']
base=next((r for r in valid if r['profile']=='baseline-t64-b2'),None)
best=max(valid,key=lambda r:int(r['median_hps'])) if valid else None
with open(sys.argv[2],'w',encoding='utf-8') as f:
    f.write(f'profiles_total={len(rows)}\n')
    f.write(f'profiles_valid={len(valid)}\n')
    if base:
        f.write(f"baseline_hps={base['median_hps']}\n")
        f.write(f"baseline_mhs={base['median_mhs']}\n")
    if best:
        f.write(f"best_profile={best['profile']}\n")
        f.write(f"best_mode={best['mode']}\n")
        f.write(f"best_threads={best['threads']}\n")
        f.write(f"best_min_blocks={best['min_blocks']}\n")
        f.write(f"best_kernel={best['kernel']}\n")
        f.write(f"best_registers={best['registers']}\n")
        f.write(f"best_stack={best['stack_bytes']}\n")
        f.write(f"best_spill_store={best['spill_store_bytes']}\n")
        f.write(f"best_spill_load={best['spill_load_bytes']}\n")
        f.write(f"best_hps={best['median_hps']}\n")
        f.write(f"best_mhs={best['median_mhs']}\n")
        f.write(f"best_clock_mean_mhz={best['clock_mean_mhz']}\n")
        f.write(f"best_power_mean_w={best['power_mean_w']}\n")
        if base and int(base['median_hps']):
            uplift=(int(best['median_hps'])/int(base['median_hps'])-1)*100
            f.write(f'uplift_pct={uplift:.4f}\n')
        gap=(2000000-int(best['median_hps']))/2000000*100
        f.write(f'target_2mh_gap_pct={gap:.4f}\n')
        clock=float(best['clock_mean_mhz'] or 0)
        if clock>0:
            projected=int(int(best['median_hps'])*1950.0/clock)
            f.write(f'projected_hps_at_1950mhz={projected}\n')
            f.write(f'projected_mhs_at_1950mhz={projected/1e6:.6f}\n')
        f.write(f"best_build_dir={sys.argv[3]}/{best['profile']}\n")
PY

# Long offline stability gate for a genuinely faster non-baseline candidate.
source "${STAGE}/summary.txt"
STRESS_GATE="SKIPPED"
if [[ "${best_profile:-baseline-t64-b2}" != "baseline-t64-b2" ]]; then
  uplift_integer="$(awk -v u="${uplift_pct:-0}" 'BEGIN{print (u>=0.5)?1:0}')"
  if [[ "${uplift_integer}" == "1" && -x "${best_build_dir}/pepepow_header80_benchmark" ]]; then
    echo "STATUS=STRESS_TESTING PROFILE=${best_profile} RUNS=${STRESS_RUNS}"
    STRESS_GATE="PASS"
    : >"${STAGE}/stress/benchmark.log"
    for ((run=1; run<=STRESS_RUNS; run++)); do
      if ! output="$("${best_build_dir}/pepepow_header80_benchmark" 33554432 2>&1)"; then
        STRESS_GATE="FAILED"
        echo "STRESS_RUN run=${run}/${STRESS_RUNS} status=FAILED ${output}" | tee -a "${STAGE}/stress/benchmark.log"
        break
      fi
      hps="$(extract_hps "${output}")"
      echo "STRESS_RUN run=${run}/${STRESS_RUNS} status=PASS hps=${hps:-0} ${output}" | tee -a "${STAGE}/stress/benchmark.log"
    done
    if dmesg 2>/dev/null | tail -n 300 | grep -Eq 'NVRM: Xid|Xid \('; then
      STRESS_GATE="FAILED_XID"
    fi
  fi
fi

echo "stress_gate=${STRESS_GATE}" >>"${STAGE}/summary.txt"
if [[ "${STRESS_GATE}" == "PASS" && "${uplift_pct:-0}" != "" ]]; then
  if awk -v u="${uplift_pct}" 'BEGIN{exit !(u>=10.0)}'; then
    echo "grand_gate=LIVE_ABA_READY" >>"${STAGE}/summary.txt"
  else
    echo "grand_gate=ARCHITECTURE_GAIN_BUT_TARGET_NOT_REACHED" >>"${STAGE}/summary.txt"
  fi
else
  echo "grand_gate=NO_RELEASE_CANDIDATE" >>"${STAGE}/summary.txt"
fi

tar -C "${OUT_ROOT}" -czf "${ARCHIVE}" "${NAME}"
sha256sum "${ARCHIVE}" >"${ARCHIVE}.sha256"

echo
echo "========== V0.8.0 GRAND CAMPAIGN COMPLETE =========="
cat "${STAGE}/summary.txt"
echo "RESULTS=${RESULTS}"
echo "ARCHIVE=${ARCHIVE}"
echo "SHA256_FILE=${ARCHIVE}.sha256"

if curl -fsSL "${PUBLISHER_URL}" -o "${PUBLISHER}"; then
  chmod +x "${PUBLISHER}"
  PUBLIC_UPLOAD="${PUBLIC_UPLOAD:-1}" "${PUBLISHER}" "${ARCHIVE}" || true
fi
