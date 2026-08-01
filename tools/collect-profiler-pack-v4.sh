#!/usr/bin/env bash
# PepePow Profiler Pack v4
# Runs the proven read-only v3 collector, then adds source/build discovery,
# derived performance summaries, safe NVIDIA field queries and optional
# Nsight profiling of the standalone benchmark.

set -euo pipefail
umask 077

SCRIPT_VERSION="4.0.0"
DURATION="${DURATION:-600}"
INTERVAL="${INTERVAL:-1}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp}"
INCLUDE_SOURCE="${INCLUDE_SOURCE:-1}"
MAX_SOURCE_MB="${MAX_SOURCE_MB:-250}"
DEEP_PROFILE="${DEEP_PROFILE:-0}"
ALLOW_CONTENTION="${ALLOW_CONTENTION:-0}"
DEEP_NONCES="${DEEP_NONCES:-262144}"
SOURCE_ROOT="${SOURCE_ROOT:-}"
BASE_COLLECTOR_URL="${BASE_COLLECTOR_URL:-https://raw.githubusercontent.com/iPepew/PepePow_Miner/diagnostics/profiler-pack-v3/tools/collect-profiler-pack.sh}"

mkdir -p "${OUTPUT_DIR}"
tmp="$(mktemp -d /tmp/pepepow-profiler-v4.XXXXXX)"
base_script="${tmp}/base-v3.sh"
before="${tmp}/before.txt"
after="${tmp}/after.txt"
cleanup() { rm -rf "${tmp}"; }
trap cleanup EXIT

find "${OUTPUT_DIR}" -maxdepth 1 -type f -name 'pepepow-profiler-*.tar.gz' -printf '%p\n' 2>/dev/null | sort > "${before}" || true
curl -fsSL "${BASE_COLLECTOR_URL}" -o "${base_script}"
chmod +x "${base_script}"
env DURATION="${DURATION}" INTERVAL="${INTERVAL}" OUTPUT_DIR="${OUTPUT_DIR}" INCLUDE_SOURCE=0 \
  bash "${base_script}"
find "${OUTPUT_DIR}" -maxdepth 1 -type f -name 'pepepow-profiler-*.tar.gz' -printf '%p\n' 2>/dev/null | sort > "${after}" || true
archive="$(comm -13 "${before}" "${after}" | tail -n1)"
if [[ -z "${archive}" || ! -f "${archive}" ]]; then
  archive="$(find "${OUTPUT_DIR}" -maxdepth 1 -type f -name 'pepepow-profiler-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
fi
[[ -n "${archive}" && -f "${archive}" ]] || { echo "ERROR: base profiler archive was not created" >&2; exit 1; }

tar -xzf "${archive}" -C "${tmp}"
pack_root="$(find "${tmp}" -mindepth 1 -maxdepth 1 -type d -name 'pepepow-profiler-*' | head -n1)"
[[ -n "${pack_root}" && -d "${pack_root}" ]] || { echo "ERROR: invalid base profiler archive" >&2; exit 1; }
mkdir -p "${pack_root}/analysis" "${pack_root}/deep" "${pack_root}/build" "${pack_root}/package"

manifest="${pack_root}/MANIFEST.txt"
miner_pid="$(sed -n 's/^miner_pid=//p' "${manifest}" | head -n1)"
miner_exe="$(sed -n 's/^miner_exe=//p' "${manifest}" | head -n1)"
miner_dir=""
[[ -n "${miner_exe}" && "${miner_exe}" != "not_detected" ]] && miner_dir="$(dirname "${miner_exe}")"

# Package metadata and logs.
if [[ -n "${miner_dir}" && -d "${miner_dir}" ]]; then
  for name in VERSION BUILD_PROFILE h-manifest.conf h-run.sh h-config.sh h-stats.sh runtime-diagnostics.txt run.txt miner-exit-status.txt; do
    [[ -f "${miner_dir}/${name}" ]] && cp -a "${miner_dir}/${name}" "${pack_root}/package/${name}"
  done
fi
for log in /root/v053-build.log /root/v052-build.log /tmp/v053-build.log /tmp/v052-build.log; do
  if [[ -f "${log}" ]]; then
    tail -c $((80 * 1024 * 1024)) "${log}" > "${pack_root}/package/$(basename "${log}")"
  fi
done

# Discover source root from explicit input, CUDA identifier, build logs and common paths.
discover_source() {
  local candidate identifier build_path
  if [[ -n "${SOURCE_ROOT}" && -f "${SOURCE_ROOT}/native/CMakeLists.txt" ]]; then
    readlink -f "${SOURCE_ROOT}"; return 0
  fi
  identifier="$(grep -m1 -oE 'identifier = /[^ ]+/native/src/cuda/[^ ]+' "${pack_root}/binary/cuobjdump-resource-usage.txt" 2>/dev/null | sed -E 's#^identifier = (.*)/native/src/cuda/[^/]+$#\1#' || true)"
  [[ -n "${identifier}" && -f "${identifier}/native/CMakeLists.txt" ]] && { readlink -f "${identifier}"; return 0; }
  for log in "${pack_root}"/package/*build.log; do
    [[ -f "${log}" ]] || continue
    build_path="$(grep -Eo 'build=/[^ ]+/build-profiles-v[0-9]+/[^ ]+' "${log}" | tail -n1 | sed -E 's#^build=##;s#/build-profiles-v[0-9]+/.*$##' || true)"
    [[ -n "${build_path}" && -f "${build_path}/native/CMakeLists.txt" ]] && { readlink -f "${build_path}"; return 0; }
  done
  for candidate in /root/pepepow-v*-src /root/PepePow* /root/pepepow-* /opt/pepepow* /hive/miners/custom/*; do
    [[ -f "${candidate}/native/CMakeLists.txt" ]] || continue
    readlink -f "${candidate}"; return 0
  done
  return 1
}

source_root="$(discover_source || true)"
{
  echo "profiler_v4=${SCRIPT_VERSION}"
  echo "base_collector_url=${BASE_COLLECTOR_URL}"
  echo "miner_pid=${miner_pid:-not_detected}"
  echo "miner_dir=${miner_dir:-not_detected}"
  echo "source_root=${source_root:-not_detected}"
  echo "deep_profile=${DEEP_PROFILE}"
  echo "allow_contention=${ALLOW_CONTENTION}"
} > "${pack_root}/analysis/V4_MANIFEST.txt"

if [[ "${INCLUDE_SOURCE}" == "1" && -n "${source_root}" ]]; then
  snapshot="${pack_root}/build/source-snapshot.tar.gz"
  tar -C "${source_root}" -czf "${snapshot}" \
    --exclude='.git' --exclude='dist' --exclude='.deps*' --exclude='build*' \
    --exclude='*.tar.gz' --exclude='*.ncu-rep' --exclude='*.nsys-rep' \
    native hiveos tools docs VERSION .github 2>"${pack_root}/build/source-snapshot-errors.txt" || true
  size_mb="$(( ($(stat -c %s "${snapshot}" 2>/dev/null || echo 0) + 1048575) / 1048576 ))"
  if (( size_mb > MAX_SOURCE_MB )); then
    rm -f "${snapshot}"
    echo "source snapshot exceeded MAX_SOURCE_MB=${MAX_SOURCE_MB}; measured=${size_mb}" > "${pack_root}/build/source-snapshot-skipped.txt"
  fi
  find "${source_root}" -maxdepth 3 -type f \( -name 'profile.meta' -o -name '*.build.log' -o -name 'CMakeCache.txt' \) -size -50M -print0 2>/dev/null \
    | tar --null -T - -czf "${pack_root}/build/profile-metadata.tar.gz" 2>/dev/null || true
fi

# Safe per-field NVIDIA query. One unsupported field no longer destroys all output.
if command -v nvidia-smi >/dev/null 2>&1; then
  fields=(timestamp index uuid name driver_version vbios_version pci.bus_id pstate persistence_mode compute_mode temperature.gpu temperature.memory fan.speed power.draw power.limit power.default_limit power.max_limit clocks.current.graphics clocks.current.sm clocks.current.memory clocks.max.graphics clocks.max.sm clocks.max.memory utilization.gpu utilization.memory memory.total memory.used pcie.link.gen.current pcie.link.gen.max pcie.link.width.current pcie.link.width.max)
  : > "${pack_root}/nvidia/gpu-static-safe.txt"
  for field in "${fields[@]}"; do
    echo "### ${field}" >> "${pack_root}/nvidia/gpu-static-safe.txt"
    nvidia-smi --query-gpu="${field}" --format=csv,noheader 2>&1 >> "${pack_root}/nvidia/gpu-static-safe.txt" || echo "UNSUPPORTED" >> "${pack_root}/nvidia/gpu-static-safe.txt"
  done
fi

# Derived live miner and GPU statistics.
python3 - "${pack_root}" <<'PY'
from __future__ import annotations
import csv, json, math, re, statistics, sys
from pathlib import Path
root = Path(sys.argv[1])
ansi = re.compile(r'\x1b\[[0-9;]*m')

def pct(values, q):
    if not values: return None
    s=sorted(values); pos=(len(s)-1)*q; lo=int(math.floor(pos)); hi=int(math.ceil(pos))
    return s[lo] if lo==hi else s[lo]*(hi-pos)+s[hi]*(pos-lo)

def stats(values):
    if not values: return {}
    return {"count":len(values),"mean":statistics.mean(values),"median":statistics.median(values),"p05":pct(values,.05),"p95":pct(values,.95),"min":min(values),"max":max(values),"stdev":statistics.pstdev(values)}

logs=list((root/'logs').glob('*miner-console.log')) + list((root/'logs').glob('process-fd1-*'))
best=max(logs, key=lambda p:p.stat().st_size) if logs else None
miner={"log":str(best.relative_to(root)) if best else None}
if best:
    text=ansi.sub('',best.read_text(errors='replace'))
    samples=[]
    for m in re.finditer(r'\[MINING\]\s*\|\s*([0-9.]+)\s+MH/s\s*\|\s*A\s+(\d+)\s*\|\s*R\s+(\d+)\s*\|\s*Uptime\s+([0-9:]+)',text):
        samples.append((float(m.group(1)),int(m.group(2)),int(m.group(3)),m.group(4)))
    rates=[x[0] for x in samples]
    warm=rates[min(5,len(rates)):]
    miner.update({"hashrate_all_mhs":stats(rates),"hashrate_warm_mhs":stats(warm),"accepted_lines":len(re.findall(r'\[ACCEPTED\]',text)),"rejected_lines":len(re.findall(r'\[REJECTED\]',text)),"jobs":len(re.findall(r'\[JOB\]',text)),"last_sample":samples[-1] if samples else None})

gpu={}
csv_path=root/'telemetry/gpu-timeseries.csv'
if csv_path.exists():
    rows=[]
    with csv_path.open(errors='replace',newline='') as f: rows=list(csv.DictReader(f,skipinitialspace=True))
    def number(v):
        m=re.search(r'-?[0-9]+(?:\.[0-9]+)?',v or '')
        return float(m.group()) if m else None
    for key in ['utilization.gpu [%]','utilization.memory [%]','power.draw [W]','clocks.current.sm [MHz]','clocks.current.memory [MHz]','temperature.gpu','temperature.memory','fan.speed [%]','memory.used [MiB]']:
        vals=[number(r.get(key)) for r in rows]; vals=[x for x in vals if x is not None]
        if vals: gpu[key]=stats(vals)

result={"miner":miner,"gpu":gpu}
mean_h=miner.get('hashrate_warm_mhs',{}).get('mean')
mean_w=gpu.get('power.draw [W]',{}).get('mean')
if mean_h and mean_w: result['efficiency_kh_per_w']=mean_h*1000.0/mean_w
(root/'analysis/live-summary.json').write_text(json.dumps(result,indent=2,sort_keys=True),encoding='utf-8')
with (root/'analysis/live-summary.txt').open('w',encoding='utf-8') as f:
    f.write('Profiler Pack v4 derived summary\n')
    if mean_h: f.write(f'warm_hashrate_mean_mhs={mean_h:.6f}\n')
    med=miner.get('hashrate_warm_mhs',{}).get('median')
    if med: f.write(f'warm_hashrate_median_mhs={med:.6f}\n')
    f.write(f"accepted={miner.get('accepted_lines',0)}\nrejected={miner.get('rejected_lines',0)}\njobs={miner.get('jobs',0)}\n")
    if mean_w: f.write(f'power_mean_w={mean_w:.3f}\n')
    if mean_h and mean_w: f.write(f'efficiency_kh_per_w={mean_h*1000.0/mean_w:.3f}\n')
PY

# Static SASS/resource summaries focused on the production kernel.
python3 - "${pack_root}" <<'PY'
import collections, re, sys
from pathlib import Path
root=Path(sys.argv[1])
sass=root/'binary/cuobjdump-sass.txt'
if sass.exists():
    text=sass.read_text(errors='replace')
    out=[]
    for part in re.split(r'(?=Function : )',text):
        if 'header80_pow_kernel' not in part and 'hoohash_mix_kernel' not in part: continue
        first=part.splitlines()[0] if part.splitlines() else 'unknown'
        ops=[]
        for line in part.splitlines():
            m=re.search(r'/\*[^*]+\*/\s+([A-Z][A-Z0-9_.]*)',line)
            if m: ops.append(m.group(1).split('.')[0])
        counts=collections.Counter(ops)
        out.append(first); out.append(f'instruction_count={len(ops)}')
        out.extend(f'{op}={count}' for op,count in counts.most_common())
        out.append('')
    (root/'analysis/sass-instruction-histogram.txt').write_text('\n'.join(out),encoding='utf-8')
PY

# Locate selected benchmark executable for optional Nsight analysis.
benchmark=""
selected_profile=""
if [[ -f "${pack_root}/package/BUILD_PROFILE" ]]; then
  selected_profile="$(sed -n 's/^selected_profile=//p' "${pack_root}/package/BUILD_PROFILE" | head -n1)"
fi
if [[ -n "${source_root}" ]]; then
  for candidate in \
    "${source_root}/build-profiles-v053/${selected_profile}/pepepow_header80_benchmark" \
    "${source_root}/build-profiles-v052/${selected_profile}/pepepow_header80_benchmark" \
    "${source_root}/build-rtx3080-v053/pepepow_header80_benchmark" \
    "${source_root}/build-rtx3080-v052/pepepow_header80_benchmark"; do
    [[ -x "${candidate}" ]] && { benchmark="${candidate}"; break; }
  done
fi
printf 'source_root=%s\nselected_profile=%s\nbenchmark=%s\n' "${source_root:-not_detected}" "${selected_profile:-not_detected}" "${benchmark:-not_detected}" > "${pack_root}/deep/discovery.txt"

active_compute=0
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null | grep -Eq '^[[:space:]]*[0-9]+'; then active_compute=1; fi
if [[ "${DEEP_PROFILE}" == "1" ]]; then
  if [[ -z "${benchmark}" ]]; then
    echo "SKIPPED: standalone benchmark not found" > "${pack_root}/deep/STATUS.txt"
  elif [[ "${active_compute}" == "1" && "${ALLOW_CONTENTION}" != "1" ]]; then
    echo "SKIPPED: active CUDA process detected; stop miner or set ALLOW_CONTENTION=1" > "${pack_root}/deep/STATUS.txt"
  else
    echo "RUNNING" > "${pack_root}/deep/STATUS.txt"
    "${benchmark}" "${DEEP_NONCES}" > "${pack_root}/deep/benchmark.txt" 2>&1 || true
    if command -v ncu >/dev/null 2>&1; then
      timeout 1800 ncu --target-processes all --kernel-name-base demangled \
        --kernel-name 'regex:header80_pow_kernel' --launch-count 1 \
        --section SpeedOfLight --section LaunchStats --section Occupancy \
        --section WarpStateStats --section InstructionStats --section MemoryWorkloadAnalysis \
        --export "${pack_root}/deep/header80" --force-overwrite \
        "${benchmark}" "${DEEP_NONCES}" > "${pack_root}/deep/ncu-console.txt" 2>&1 || true
      [[ -f "${pack_root}/deep/header80.ncu-rep" ]] && ncu --import "${pack_root}/deep/header80.ncu-rep" --page raw --csv > "${pack_root}/deep/ncu-raw.csv" 2>&1 || true
    fi
    if command -v nsys >/dev/null 2>&1; then
      timeout 600 nsys profile --trace=cuda,nvtx,osrt --sample=cpu --force-overwrite=true \
        --output="${pack_root}/deep/header80-timeline" "${benchmark}" "${DEEP_NONCES}" > "${pack_root}/deep/nsys-console.txt" 2>&1 || true
      [[ -f "${pack_root}/deep/header80-timeline.nsys-rep" ]] && nsys stats "${pack_root}/deep/header80-timeline.nsys-rep" > "${pack_root}/deep/nsys-stats.txt" 2>&1 || true
    fi
    echo "DONE" > "${pack_root}/deep/STATUS.txt"
  fi
else
  echo "SKIPPED: DEEP_PROFILE=0" > "${pack_root}/deep/STATUS.txt"
fi

# Refresh manifest and archive.
{
  echo
  echo "profiler_v4=${SCRIPT_VERSION}"
  echo "v4_source_root=${source_root:-not_detected}"
  echo "v4_selected_profile=${selected_profile:-not_detected}"
  echo "v4_deep_profile=${DEEP_PROFILE}"
} >> "${pack_root}/MANIFEST.txt"
rm -f "${archive}" "${archive}.sha256"
tar -C "${tmp}" -czf "${archive}" "$(basename "${pack_root}")"
sha256sum "${archive}" > "${archive}.sha256"
printf 'DONE_ARCHIVE=%s\nDONE_SHA256=%s\n' "${archive}" "${archive}.sha256"
ls -lh "${archive}" "${archive}.sha256"
