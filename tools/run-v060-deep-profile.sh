#!/usr/bin/env bash
set -euo pipefail
umask 077

OUT_ROOT="${OUT_ROOT:-/root/pepepow-tests}"
NONCES="${NONCES:-16777216}"
RUNS="${RUNS:-9}"
NCU_NONCES="${NCU_NONCES:-262144}"
SOURCE_ROOT="${SOURCE_ROOT:-}"
PROFILE="${PROFILE:-}"
STAMP="$(date +%Y%m%d_%H%M%S)"
NAME="v060-deep-profile-${STAMP}"
STAGE="${OUT_ROOT}/${NAME}"
ARCHIVE="${OUT_ROOT}/${NAME}.tar.gz"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}
for cmd in bash awk sed grep sort sha256sum tar python3 nvidia-smi; do need "$cmd"; done

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
    readlink -f "${candidate}"
    return 0
  done
  return 1
}

SOURCE_ROOT="$(find_source_root || true)"
[[ -n "${SOURCE_ROOT}" ]] || {
  echo "ERROR: v0.6.0 source tree was not found." >&2
  echo "Set SOURCE_ROOT=/path/to/v0.6.0/source and retry." >&2
  exit 1
}

if [[ -z "${PROFILE}" ]]; then
  for meta in \
    /hive/miners/custom/pepepowminer-v0.6.0-PR/BUILD_PROFILE \
    "${SOURCE_ROOT}/dist/pepepowminer-v0.6.0-PR/BUILD_PROFILE"; do
    [[ -f "${meta}" ]] || continue
    PROFILE="$(sed -n 's/^selected_profile=//p' "${meta}" | head -n1)"
    [[ -n "${PROFILE}" ]] && break
  done
fi

build_dir=""
for candidate in \
  "${SOURCE_ROOT}/build-profiles-v060/${PROFILE}" \
  "${SOURCE_ROOT}/build-profiles-v060/v060-t64-b2-r96" \
  "${SOURCE_ROOT}/build-profiles-v060/best-t64-b2" \
  "${SOURCE_ROOT}/build-rtx3080-v060"; do
  [[ -n "${candidate}" && -x "${candidate}/pepepow_header80_benchmark" ]] || continue
  build_dir="${candidate}"
  break
done
[[ -n "${build_dir}" ]] || {
  echo "ERROR: v0.6.0 benchmark executable was not found under ${SOURCE_ROOT}." >&2
  exit 1
}
PROFILE="$(basename "${build_dir}")"
BENCHMARK="${build_dir}/pepepow_header80_benchmark"
MINER_BIN="${build_dir}/pepepowminer"

GPU_APPS="$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null || true)"
if [[ -n "${GPU_APPS//[[:space:]]/}" ]]; then
  echo "ERROR: GPU is busy. Deep profiling requires an idle GPU." >&2
  echo "Stop all miners/CUDA workloads, then rerun this script." >&2
  echo >&2
  echo "Active CUDA processes:" >&2
  echo "${GPU_APPS}" >&2
  exit 2
fi

mkdir -p "${STAGE}"/{benchmark,nvidia,binary,nsight,source,build}

{
  echo "name=${NAME}"
  echo "source_root=${SOURCE_ROOT}"
  echo "profile=${PROFILE}"
  echo "build_dir=${build_dir}"
  echo "benchmark=${BENCHMARK}"
  echo "nonces=${NONCES}"
  echo "runs=${RUNS}"
  echo "ncu_nonces=${NCU_NONCES}"
  echo "started_at=$(date --iso-8601=seconds)"
} > "${STAGE}/MANIFEST.txt"

[[ -x "${MINER_BIN}" ]] && "${MINER_BIN}" --version > "${STAGE}/build/version.txt" 2>&1 || true
[[ -f "${build_dir}/profile.meta" ]] && cp -f "${build_dir}/profile.meta" "${STAGE}/build/"
[[ -f "${build_dir}/profile.hps" ]] && cp -f "${build_dir}/profile.hps" "${STAGE}/build/"
[[ -f "${build_dir}/CMakeCache.txt" ]] && cp -f "${build_dir}/CMakeCache.txt" "${STAGE}/build/"
[[ -f "${build_dir}.build.log" ]] && cp -f "${build_dir}.build.log" "${STAGE}/build/"

for src in \
  "${SOURCE_ROOT}/VERSION" \
  "${SOURCE_ROOT}/native/CMakeLists.txt" \
  "${SOURCE_ROOT}/native/src/cuda/header80_backend_v060.cu" \
  "${SOURCE_ROOT}/native/tests/cuda_header80_validation.cpp" \
  "${SOURCE_ROOT}/hiveos/prepare-v060-source.py" \
  "${SOURCE_ROOT}/hiveos/build-v060-critical-path.sh"; do
  [[ -f "${src}" ]] && cp -f "${src}" "${STAGE}/source/$(basename "${src}")"
done

nvidia-smi -q > "${STAGE}/nvidia/nvidia-smi-before.txt" 2>&1 || true
nvidia-smi --query-gpu=name,uuid,driver_version,compute_cap,pstate,temperature.gpu,power.draw,power.limit,clocks.current.sm,clocks.current.memory,utilization.gpu,utilization.memory,memory.used,memory.total --format=csv,noheader \
  > "${STAGE}/nvidia/gpu-before.csv" 2>&1 || true

: > "${STAGE}/benchmark/runs.log"
for ((run=1; run<=RUNS; run++)); do
  output="$("${BENCHMARK}" "${NONCES}" 2>&1)"
  printf 'RUN=%02d %s\n' "${run}" "${output}" | tee -a "${STAGE}/benchmark/runs.log"
done

python3 - "${STAGE}/benchmark/runs.log" "${STAGE}/benchmark/stats.txt" <<'PY'
import re, statistics, sys
src, dst = sys.argv[1:]
text = open(src, encoding='utf-8', errors='replace').read()
values = [int(x) for x in re.findall(r'\bhps=([0-9]+)', text)]
if not values:
    raise SystemExit('benchmark parser found no hps values')
with open(dst, 'w', encoding='utf-8') as f:
    f.write(f'samples={len(values)}\n')
    f.write(f'min_hps={min(values)}\n')
    f.write(f'median_hps={int(statistics.median(values))}\n')
    f.write(f'mean_hps={statistics.mean(values):.2f}\n')
    f.write(f'max_hps={max(values)}\n')
    f.write(f'stdev_hps={statistics.pstdev(values):.2f}\n')
    f.write(f'median_mhs={statistics.median(values)/1_000_000:.6f}\n')
PY
cat "${STAGE}/benchmark/stats.txt"

if command -v cuobjdump >/dev/null 2>&1 && [[ -x "${MINER_BIN}" ]]; then
  cuobjdump --dump-resource-usage "${MINER_BIN}" > "${STAGE}/binary/resource-usage.txt" 2>&1 || true
  cuobjdump --dump-sass "${MINER_BIN}" > "${STAGE}/binary/sass.txt" 2>&1 || true
  cuobjdump --dump-ptx "${MINER_BIN}" > "${STAGE}/binary/ptx.txt" 2>&1 || true
else
  echo "cuobjdump or miner binary unavailable" > "${STAGE}/binary/SKIPPED.txt"
fi

if command -v ncu >/dev/null 2>&1; then
  set +e
  timeout 3600 ncu --target-processes all --kernel-name-base demangled \
    --kernel-name 'regex:header80_pow_kernel|hoohash_mix_kernel|header80_first_kernel|header80_final_kernel' \
    --launch-count 1 \
    --section SpeedOfLight --section LaunchStats --section Occupancy \
    --section WarpStateStats --section InstructionStats --section MemoryWorkloadAnalysis \
    --export "${STAGE}/nsight/v060-hotpath" --force-overwrite \
    "${BENCHMARK}" "${NCU_NONCES}" > "${STAGE}/nsight/ncu-console.txt" 2>&1
  NCU_RC=$?
  set -e
  echo "ncu_rc=${NCU_RC}" > "${STAGE}/nsight/ncu-status.txt"
  if [[ -f "${STAGE}/nsight/v060-hotpath.ncu-rep" ]]; then
    ncu --import "${STAGE}/nsight/v060-hotpath.ncu-rep" --page raw --csv \
      > "${STAGE}/nsight/ncu-raw.csv" 2>&1 || true
    ncu --import "${STAGE}/nsight/v060-hotpath.ncu-rep" --page details \
      > "${STAGE}/nsight/ncu-details.txt" 2>&1 || true
  fi
else
  echo "ncu=NOT_INSTALLED" > "${STAGE}/nsight/ncu-status.txt"
fi

if command -v nsys >/dev/null 2>&1; then
  set +e
  timeout 1200 nsys profile --trace=cuda,nvtx,osrt --sample=cpu --force-overwrite=true \
    --output="${STAGE}/nsight/v060-timeline" "${BENCHMARK}" "${NCU_NONCES}" \
    > "${STAGE}/nsight/nsys-console.txt" 2>&1
  NSYS_RC=$?
  set -e
  echo "nsys_rc=${NSYS_RC}" > "${STAGE}/nsight/nsys-status.txt"
  [[ -f "${STAGE}/nsight/v060-timeline.nsys-rep" ]] && \
    nsys stats "${STAGE}/nsight/v060-timeline.nsys-rep" \
      > "${STAGE}/nsight/nsys-stats.txt" 2>&1 || true
else
  echo "nsys=NOT_INSTALLED" > "${STAGE}/nsight/nsys-status.txt"
fi

nvidia-smi -q > "${STAGE}/nvidia/nvidia-smi-after.txt" 2>&1 || true
dmesg -T 2>/dev/null | grep -Ei 'NVRM|Xid|CUDA|nvidia' | tail -n200 \
  > "${STAGE}/nvidia/kernel-events.txt" || true

echo "finished_at=$(date --iso-8601=seconds)" >> "${STAGE}/MANIFEST.txt"
tar -C "${OUT_ROOT}" -czf "${ARCHIVE}" "${NAME}"
sha256sum "${ARCHIVE}" > "${ARCHIVE}.sha256"

echo
echo "========== V0.6.0 DEEP PROFILE COMPLETE =========="
echo "PROFILE=${PROFILE}"
cat "${STAGE}/benchmark/stats.txt"
echo "ARCHIVE=${ARCHIVE}"
echo "SHA256_FILE=${ARCHIVE}.sha256"
ls -lh "${ARCHIVE}" "${ARCHIVE}.sha256"
