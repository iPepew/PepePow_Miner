#!/usr/bin/env bash
set -euo pipefail
umask 077

SOURCE_ROOT="${SOURCE_ROOT:-/root/pepepow-v053-src}"
SELECTED_PROFILE="${SELECTED_PROFILE:-best-64-r80}"
BENCHMARK_EXE="${BENCHMARK_EXE:-${SOURCE_ROOT}/build-profiles-v053/${SELECTED_PROFILE}/pepepow_header80_benchmark}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp}"
DEEP_NONCES="${DEEP_NONCES:-262144}"
ALLOW_CONTENTION="${ALLOW_CONTENTION:-0}"
NCU_TIMEOUT="${NCU_TIMEOUT:-1800}"
NSYS_TIMEOUT="${NSYS_TIMEOUT:-600}"

case "${DEEP_NONCES}" in ''|*[!0-9]*) echo "ERROR: DEEP_NONCES must be an integer" >&2; exit 2;; esac
[[ -x "${BENCHMARK_EXE}" ]] || { echo "ERROR: benchmark not executable: ${BENCHMARK_EXE}" >&2; exit 1; }
mkdir -p "${OUTPUT_DIR}"

active_apps="$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null || true)"
if [[ "${ALLOW_CONTENTION}" != "1" && -n "${active_apps//[[:space:]]/}" ]]; then
  echo "ERROR: active CUDA process detected:" >&2
  echo "${active_apps}" >&2
  exit 1
fi

host="$(hostname 2>/dev/null | tr -cs 'A-Za-z0-9._-' '_' | sed 's/^_//;s/_$//' || true)"
host="${host:-rig}"
ts="$(date +%Y%m%d_%H%M%S)"
work="/tmp/pepepow-v053-deep-${host}-${ts}"
archive="${OUTPUT_DIR%/}/pepepow-v053-deep-${host}-${ts}.tar.gz"
mkdir -p "${work}/deep" "${work}/build" "${work}/system" "${work}/binary"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "${work}/collector.log"; }
run_capture() {
  local timeout_s="$1" out="$2"; shift 2
  {
    printf '$'; printf ' %q' "$@"; printf '\n\n'
    timeout "${timeout_s}" "$@"
  } > "${out}" 2>&1 || return $?
}

{
  echo "collector=collect-v053-deep-direct"
  echo "timestamp=$(date --iso-8601=seconds 2>/dev/null || date)"
  echo "source_root=${SOURCE_ROOT}"
  echo "selected_profile=${SELECTED_PROFILE}"
  echo "benchmark=${BENCHMARK_EXE}"
  echo "deep_nonces=${DEEP_NONCES}"
  echo "driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)"
  echo "gpu=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)"
  echo "kernel=$(uname -r)"
} > "${work}/MANIFEST.txt"

log "Direct deep profile for ${SELECTED_PROFILE}"
log "Benchmark: ${BENCHMARK_EXE}"

nvidia-smi -q > "${work}/system/nvidia-smi-before.txt" 2>&1 || true
nvidia-smi topo -m > "${work}/system/nvidia-topology.txt" 2>&1 || true
nvidia-smi --query-gpu=timestamp,name,driver_version,pstate,temperature.gpu,temperature.memory,power.draw,power.limit,clocks.current.sm,clocks.current.memory,utilization.gpu,utilization.memory,pcie.link.gen.current,pcie.link.width.current --format=csv > "${work}/system/gpu-before.csv" 2>&1 || true

sha256sum "${BENCHMARK_EXE}" > "${work}/binary/benchmark.sha256" 2>&1 || true
file "${BENCHMARK_EXE}" > "${work}/binary/file.txt" 2>&1 || true
ldd "${BENCHMARK_EXE}" > "${work}/binary/ldd.txt" 2>&1 || true
readelf -h -d -n "${BENCHMARK_EXE}" > "${work}/binary/readelf.txt" 2>&1 || true

if command -v cuobjdump >/dev/null 2>&1; then
  timeout 300 cuobjdump --dump-resource-usage "${BENCHMARK_EXE}" > "${work}/binary/cuobjdump-resource-usage.txt" 2>&1 || true
  timeout 600 cuobjdump --dump-sass "${BENCHMARK_EXE}" > "${work}/binary/cuobjdump-sass.txt" 2>&1 || true
  timeout 300 cuobjdump --dump-ptx "${BENCHMARK_EXE}" > "${work}/binary/cuobjdump-ptx.txt" 2>&1 || true
fi

for src in \
  /root/v053-build.log \
  "${SOURCE_ROOT}/build-profiles-v053/${SELECTED_PROFILE}/profile.meta" \
  "${SOURCE_ROOT}/build-profiles-v053/${SELECTED_PROFILE}/profile.hps" \
  "${SOURCE_ROOT}/build-profiles-v053/${SELECTED_PROFILE}/CMakeCache.txt" \
  "${SOURCE_ROOT}/build-profiles-v053/${SELECTED_PROFILE}/build.log"; do
  [[ -f "${src}" ]] && cp -a "${src}" "${work}/build/$(basename "${src}")"
done

if [[ -f "${SOURCE_ROOT}/native/CMakeLists.txt" ]]; then
  tar -C "${SOURCE_ROOT}" -czf "${work}/build/source-snapshot.tar.gz" \
    --exclude='.git' --exclude='dist' --exclude='.deps*' --exclude='build*' \
    native hiveos tools VERSION .github 2> "${work}/build/source-snapshot-errors.txt" || true
fi

log "Running standalone benchmark"
if run_capture 300 "${work}/deep/benchmark.txt" "${BENCHMARK_EXE}" "${DEEP_NONCES}"; then
  echo "benchmark=PASS" > "${work}/deep/STATUS.txt"
else
  rc=$?
  echo "benchmark=FAIL rc=${rc}" > "${work}/deep/STATUS.txt"
fi

if command -v ncu >/dev/null 2>&1; then
  ncu --version > "${work}/system/ncu-version.txt" 2>&1 || true
  log "Running Nsight Compute"
  set +e
  timeout "${NCU_TIMEOUT}" ncu \
    --target-processes all \
    --kernel-name-base demangled \
    --kernel-name 'regex:header80_pow_kernel' \
    --launch-count 1 \
    --section SpeedOfLight \
    --section LaunchStats \
    --section Occupancy \
    --section WarpStateStats \
    --section InstructionStats \
    --section MemoryWorkloadAnalysis \
    --export "${work}/deep/header80" \
    --force-overwrite \
    "${BENCHMARK_EXE}" "${DEEP_NONCES}" \
    > "${work}/deep/ncu-console.txt" 2>&1
  ncu_rc=$?
  set -e
  echo "ncu_rc=${ncu_rc}" >> "${work}/deep/STATUS.txt"
  if [[ -f "${work}/deep/header80.ncu-rep" ]]; then
    ncu --import "${work}/deep/header80.ncu-rep" --page raw --csv > "${work}/deep/ncu-raw.csv" 2>&1 || true
    ncu --import "${work}/deep/header80.ncu-rep" --page details > "${work}/deep/ncu-details.txt" 2>&1 || true
  fi
else
  echo "ncu=NOT_INSTALLED" >> "${work}/deep/STATUS.txt"
fi

if command -v nsys >/dev/null 2>&1; then
  nsys --version > "${work}/system/nsys-version.txt" 2>&1 || true
  log "Running Nsight Systems"
  set +e
  timeout "${NSYS_TIMEOUT}" nsys profile \
    --trace=cuda,nvtx,osrt \
    --sample=cpu \
    --force-overwrite=true \
    --output="${work}/deep/header80-timeline" \
    "${BENCHMARK_EXE}" "${DEEP_NONCES}" \
    > "${work}/deep/nsys-console.txt" 2>&1
  nsys_rc=$?
  set -e
  echo "nsys_rc=${nsys_rc}" >> "${work}/deep/STATUS.txt"
  if [[ -f "${work}/deep/header80-timeline.nsys-rep" ]]; then
    nsys stats "${work}/deep/header80-timeline.nsys-rep" > "${work}/deep/nsys-stats.txt" 2>&1 || true
  fi
else
  echo "nsys=NOT_INSTALLED" >> "${work}/deep/STATUS.txt"
fi

nvidia-smi -q > "${work}/system/nvidia-smi-after.txt" 2>&1 || true
nvidia-smi --query-gpu=timestamp,name,driver_version,pstate,temperature.gpu,temperature.memory,power.draw,power.limit,clocks.current.sm,clocks.current.memory,utilization.gpu,utilization.memory --format=csv > "${work}/system/gpu-after.csv" 2>&1 || true

tar -C /tmp -czf "${archive}" "$(basename "${work}")"
sha256sum "${archive}" > "${archive}.sha256"
log "Archive created: ${archive}"
printf 'DONE_ARCHIVE=%s\nDONE_SHA256=%s\n' "${archive}" "${archive}.sha256"
ls -lh "${archive}" "${archive}.sha256"
