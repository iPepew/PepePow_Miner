#!/usr/bin/env bash
set -euo pipefail
umask 077

BENCHMARK_EXE="${BENCHMARK_EXE:-/root/pepepow-v054-src/build-profiles-v054/lookup-finite-mono64/pepepow_header80_benchmark}"
SOURCE_ROOT="${SOURCE_ROOT:-/root/pepepow-v054-src}"
PROFILE_NAME="${PROFILE_NAME:-lookup-finite-mono64}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp}"
DEEP_NONCES="${DEEP_NONCES:-262144}"
BENCH_NONCES="${BENCH_NONCES:-4194304}"
BENCH_RUNS="${BENCH_RUNS:-3}"
ALLOW_CONTENTION="${ALLOW_CONTENTION:-0}"

host="$(hostname -s 2>/dev/null || hostname)"
stamp="$(date +%Y%m%d_%H%M%S)"
work="${OUTPUT_DIR}/pepepow-v054-deep-${host}-${stamp}"
archive="${work}.tar.gz"
mkdir -p "${work}"/{system,nvidia,build,binary,benchmark,ncu,nsys,source}

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
run_capture() {
  local out="$1"; shift
  set +e
  "$@" >"${out}" 2>&1
  local rc=$?
  set -e
  printf '%s\n' "${rc}" >"${out}.rc"
  return 0
}

log "Direct v0.5.4 deep profile"
log "benchmark=${BENCHMARK_EXE}"
log "profile=${PROFILE_NAME}"

[[ -x "${BENCHMARK_EXE}" ]] || { echo "ERROR: benchmark not executable: ${BENCHMARK_EXE}" >&2; exit 1; }
[[ -d "${SOURCE_ROOT}" ]] || { echo "ERROR: source root missing: ${SOURCE_ROOT}" >&2; exit 1; }

active="$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null || true)"
if [[ "${ALLOW_CONTENTION}" != "1" && -n "${active//[[:space:]]/}" ]]; then
  echo "ERROR: active CUDA process detected:" >&2
  echo "${active}" >&2
  exit 1
fi

{
  echo "profile=${PROFILE_NAME}"
  echo "benchmark=${BENCHMARK_EXE}"
  echo "source_root=${SOURCE_ROOT}"
  echo "deep_nonces=${DEEP_NONCES}"
  echo "bench_nonces=${BENCH_NONCES}"
  echo "bench_runs=${BENCH_RUNS}"
  echo "created=$(date --iso-8601=seconds)"
} >"${work}/MANIFEST.txt"

run_capture "${work}/system/uname.txt" uname -a
run_capture "${work}/system/os-release.txt" cat /etc/os-release
run_capture "${work}/system/cpuinfo.txt" lscpu
run_capture "${work}/system/memory.txt" free -h
run_capture "${work}/system/lsmod-nvidia.txt" bash -lc "lsmod | grep -E 'nvidia|nouveau'"
run_capture "${work}/system/kernel-log-nvidia.txt" bash -lc "dmesg -T 2>/dev/null | grep -Ei 'NVRM|Xid|CUDA|nvidia' | tail -300"

run_capture "${work}/nvidia/nvidia-smi.txt" nvidia-smi
run_capture "${work}/nvidia/nvidia-smi-q.txt" nvidia-smi -q
run_capture "${work}/nvidia/gpu-query.csv" nvidia-smi --query-gpu=timestamp,index,uuid,name,driver_version,vbios_version,pci.bus_id,pstate,temperature.gpu,temperature.memory,fan.speed,power.draw,power.limit,clocks.current.graphics,clocks.current.sm,clocks.current.memory,clocks.max.graphics,clocks.max.sm,clocks.max.memory,utilization.gpu,utilization.memory,memory.total,memory.used,pcie.link.gen.current,pcie.link.width.current --format=csv
run_capture "${work}/nvidia/compute-apps.csv" nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv

command -v nvcc >/dev/null 2>&1 && run_capture "${work}/build/nvcc-version.txt" nvcc --version
command -v cmake >/dev/null 2>&1 && run_capture "${work}/build/cmake-version.txt" cmake --version
command -v gcc >/dev/null 2>&1 && run_capture "${work}/build/gcc-version.txt" gcc --version
command -v g++ >/dev/null 2>&1 && run_capture "${work}/build/gxx-version.txt" g++ --version

build_dir="$(dirname "${BENCHMARK_EXE}")"
for file in profile.meta profile.hps CMakeCache.txt; do
  [[ -f "${build_dir}/${file}" ]] && cp -a "${build_dir}/${file}" "${work}/build/${file}"
done
for file in \
  "${SOURCE_ROOT}/build-profiles-v054/${PROFILE_NAME}.build.log" \
  "${SOURCE_ROOT}/VERSION" \
  "${SOURCE_ROOT}/native/CMakeLists.txt" \
  "${SOURCE_ROOT}/native/src/cuda/header80_backend_v054.cu" \
  "${SOURCE_ROOT}/native/src/cuda/header80_backend_v053.cu"; do
  [[ -f "${file}" ]] && cp -a "${file}" "${work}/source/$(basename "${file}")"
done

run_capture "${work}/binary/file.txt" file "${BENCHMARK_EXE}"
run_capture "${work}/binary/ldd.txt" ldd "${BENCHMARK_EXE}"
if command -v cuobjdump >/dev/null 2>&1; then
  run_capture "${work}/binary/cuobjdump-resource-usage.txt" cuobjdump --dump-resource-usage "${BENCHMARK_EXE}"
  run_capture "${work}/binary/cuobjdump-sass.txt" cuobjdump --dump-sass "${BENCHMARK_EXE}"
  run_capture "${work}/binary/cuobjdump-ptx.txt" cuobjdump --dump-ptx "${BENCHMARK_EXE}"
fi

log "Running ${BENCH_RUNS} standalone benchmark passes"
: >"${work}/benchmark/runs.txt"
for ((run=1; run<=BENCH_RUNS; ++run)); do
  log "Benchmark run ${run}/${BENCH_RUNS}"
  set +e
  output="$("${BENCHMARK_EXE}" "${BENCH_NONCES}" 2>&1)"
  rc=$?
  set -e
  printf 'run=%d rc=%d %s\n' "${run}" "${rc}" "${output}" | tee -a "${work}/benchmark/runs.txt"
done

if command -v ncu >/dev/null 2>&1; then
  log "Running Nsight Compute"
  set +e
  timeout 1800 ncu \
    --target-processes all \
    --kernel-name-base demangled \
    --kernel-name 'regex:header80_pow_kernel|hoohash_mix_kernel' \
    --launch-count 1 \
    --section SpeedOfLight \
    --section LaunchStats \
    --section Occupancy \
    --section WarpStateStats \
    --section InstructionStats \
    --section MemoryWorkloadAnalysis \
    --export "${work}/ncu/header80" \
    --force-overwrite \
    "${BENCHMARK_EXE}" "${DEEP_NONCES}" \
    >"${work}/ncu/console.txt" 2>&1
  ncu_rc=$?
  set -e
  echo "ncu_rc=${ncu_rc}" | tee "${work}/ncu/STATUS.txt"
  if [[ -f "${work}/ncu/header80.ncu-rep" ]]; then
    ncu --import "${work}/ncu/header80.ncu-rep" --page raw --csv >"${work}/ncu/raw.csv" 2>&1 || true
    ncu --import "${work}/ncu/header80.ncu-rep" --page details >"${work}/ncu/details.txt" 2>&1 || true
  fi
else
  echo "ncu=NOT_INSTALLED" | tee "${work}/ncu/STATUS.txt"
fi

if command -v nsys >/dev/null 2>&1; then
  log "Running Nsight Systems"
  set +e
  timeout 600 nsys profile \
    --trace=cuda,nvtx,osrt \
    --sample=cpu \
    --force-overwrite=true \
    --output="${work}/nsys/header80-timeline" \
    "${BENCHMARK_EXE}" "${DEEP_NONCES}" \
    >"${work}/nsys/console.txt" 2>&1
  nsys_rc=$?
  set -e
  echo "nsys_rc=${nsys_rc}" | tee "${work}/nsys/STATUS.txt"
  if [[ -f "${work}/nsys/header80-timeline.nsys-rep" ]]; then
    nsys stats "${work}/nsys/header80-timeline.nsys-rep" >"${work}/nsys/stats.txt" 2>&1 || true
  fi
else
  echo "nsys=NOT_INSTALLED" | tee "${work}/nsys/STATUS.txt"
fi

log "Creating archive"
tar -C "$(dirname "${work}")" -czf "${archive}" "$(basename "${work}")"
sha256sum "${archive}" >"${archive}.sha256"
log "DONE"
echo "DONE_ARCHIVE=${archive}"
echo "DONE_SHA256=${archive}.sha256"
ls -lh "${archive}" "${archive}.sha256"
