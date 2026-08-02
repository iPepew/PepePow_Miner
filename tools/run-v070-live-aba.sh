#!/usr/bin/env bash
set -euo pipefail
umask 077

OUT_ROOT="${OUT_ROOT:-/root/pepepow-tests}"
STAGE_SECONDS="${STAGE_SECONDS:-720}"
WARMUP_SECONDS="${WARMUP_SECONDS:-120}"
SAMPLE_SECONDS="${SAMPLE_SECONDS:-5}"
STAMP="$(date +%Y%m%d_%H%M%S)"
NAME="v070-live-aba-${STAMP}"
STAGE_ROOT="${OUT_ROOT}/${NAME}"
ARCHIVE="${OUT_ROOT}/${NAME}.tar.gz"
RESULTS="${STAGE_ROOT}/results.csv"
STATUS_FILE="${STAGE_ROOT}/status.env"
PUBLISHER_URL="https://raw.githubusercontent.com/iPepew/PepePow_Miner/experiment/v0.7.0-8h-autotune/tools/publish-test-results.sh"
PUBLISHER="/root/publish-pepepow-test-results.sh"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}
for cmd in bash awk sed grep sha256sum tar python3 nvidia-smi curl; do need "$cmd"; done

if (( STAGE_SECONDS <= WARMUP_SECONDS + 60 )); then
  echo "ERROR: STAGE_SECONDS must exceed WARMUP_SECONDS by at least 60 seconds." >&2
  exit 1
fi

find_stable_dir() {
  local candidate
  for candidate in \
    /hive/miners/custom/pepepowminer-v0.6.0-PR \
    /hive/miners/custom/pepepowminer \
    /hive/miners/custom/pepepow; do
    [[ -x "${candidate}/pepepowminer" && -f "${candidate}/config.txt" &&
       -x "${candidate}/stratum-replay-proxy.py" ]] || continue
    readlink -f "${candidate}"
    return 0
  done
  return 1
}

find_candidate_dir() {
  local candidate
  for candidate in \
    /root/pepepow-v060-8h-src/build-v070-zero-nibble/lazy-zero-elide \
    /root/pepepow-v060-src/build-v070-zero-nibble/lazy-zero-elide \
    /root/PepePow_Miner/build-v070-zero-nibble/lazy-zero-elide; do
    [[ -x "${candidate}/pepepowminer" ]] || continue
    readlink -f "${candidate}"
    return 0
  done
  return 1
}

STABLE_DIR="$(find_stable_dir || true)"
CANDIDATE_DIR="$(find_candidate_dir || true)"
[[ -n "${STABLE_DIR}" ]] || {
  echo "ERROR: installed v0.6.0-PR package with config.txt was not found." >&2
  exit 1
}
[[ -n "${CANDIDATE_DIR}" ]] || {
  echo "ERROR: lazy-zero-elide candidate build was not found." >&2
  echo "Expected: /root/pepepow-v060-8h-src/build-v070-zero-nibble/lazy-zero-elide" >&2
  exit 1
}

STABLE_BIN="${STABLE_DIR}/pepepowminer"
CANDIDATE_BIN="${CANDIDATE_DIR}/pepepowminer"
PROXY_SCRIPT="${STABLE_DIR}/stratum-replay-proxy.py"
CONFIG_FILE="${STABLE_DIR}/config.txt"

# shellcheck disable=SC1090
source "${CONFIG_FILE}"
if ! declare -p PEPEPOW_ARGS >/dev/null 2>&1 || [[ ${#PEPEPOW_ARGS[@]} -eq 0 ]]; then
  echo "ERROR: PEPEPOW_ARGS is missing or invalid in ${CONFIG_FILE}" >&2
  exit 1
fi
: "${PEPEPOW_UPSTREAM:?missing PEPEPOW_UPSTREAM}"
: "${PEPEPOW_PROXY_PORT:?missing PEPEPOW_PROXY_PORT}"

GPU_APPS="$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null || true)"
if [[ -n "${GPU_APPS//[[:space:]]/}" ]]; then
  echo "ERROR: GPU is busy. Use an empty flight sheet and stop all CUDA workloads." >&2
  echo "Active CUDA processes:" >&2
  echo "${GPU_APPS}" >&2
  exit 2
fi

if [[ -x "${CANDIDATE_DIR}/pepepow_cuda_header80_validation" ]]; then
  echo "PRECHECK=CANDIDATE_CONSENSUS"
  "${CANDIDATE_DIR}/pepepow_cuda_header80_validation" > /tmp/v070-live-candidate-validation.log 2>&1
  echo "PRECHECK_RESULT=PASS"
else
  echo "ERROR: candidate validation executable is missing." >&2
  exit 1
fi

mkdir -p "${STAGE_ROOT}"/{stages,nvidia,metadata}
cp -f /tmp/v070-live-candidate-validation.log "${STAGE_ROOT}/metadata/candidate-validation.log"
sha256sum "${STABLE_BIN}" > "${STAGE_ROOT}/metadata/stable-binary.sha256"
sha256sum "${CANDIDATE_BIN}" > "${STAGE_ROOT}/metadata/candidate-binary.sha256"
"${STABLE_BIN}" --version > "${STAGE_ROOT}/metadata/stable-version.txt" 2>&1 || true
"${CANDIDATE_BIN}" --version > "${STAGE_ROOT}/metadata/candidate-version.txt" 2>&1 || true
nvidia-smi -q > "${STAGE_ROOT}/nvidia/nvidia-smi-before.txt" 2>&1 || true

{
  echo "name=${NAME}"
  echo "stable_dir=${STABLE_DIR}"
  echo "candidate_dir=${CANDIDATE_DIR}"
  echo "stage_seconds=${STAGE_SECONDS}"
  echo "warmup_seconds=${WARMUP_SECONDS}"
  echo "sample_seconds=${SAMPLE_SECONDS}"
  echo "stages=baseline-a1 candidate-b baseline-a2"
  echo "started_at=$(date --iso-8601=seconds)"
} > "${STAGE_ROOT}/MANIFEST.txt"

printf 'stage,variant,valid,samples,mean_mhs,median_mhs,min_mhs,max_mhs,stdev_mhs,accepted,rejected,jobs,power_mean_w,temp_mean_c,clock_mean_mhz,util_mean_pct,reason\n' > "${RESULTS}"

current_miner_pid=""
current_proxy_pid=""
current_telemetry_pid=""

cleanup_stage_processes() {
  local pid
  for pid in "${current_telemetry_pid:-}" "${current_miner_pid:-}" "${current_proxy_pid:-}"; do
    [[ -n "$pid" ]] || continue
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  current_miner_pid=""
  current_proxy_pid=""
  current_telemetry_pid=""
}
cleanup_all() {
  cleanup_stage_processes
}
trap cleanup_all EXIT INT TERM

write_status() {
  local tmp="${STATUS_FILE}.tmp"
  {
    printf 'STATE=%q\n' "${1:-}"
    printf 'STAGE_INDEX=%q\n' "${2:-0}"
    printf 'STAGE_TOTAL=%q\n' "3"
    printf 'STAGE_ID=%q\n' "${3:-}"
    printf 'VARIANT=%q\n' "${4:-}"
    printf 'STAGE_START_EPOCH=%q\n' "${5:-0}"
    printf 'STAGE_SECONDS=%q\n' "${STAGE_SECONDS}"
    printf 'WARMUP_SECONDS=%q\n' "${WARMUP_SECONDS}"
  } > "$tmp"
  mv -f "$tmp" "${STATUS_FILE}"
}

make_args() {
  local port="$1" i
  STAGE_ARGS=("${PEPEPOW_ARGS[@]}")
  for ((i=0; i<${#STAGE_ARGS[@]}; i++)); do
    if [[ "${STAGE_ARGS[$i]}" == "-o" || "${STAGE_ARGS[$i]}" == "--pool" ]]; then
      if (( i + 1 < ${#STAGE_ARGS[@]} )); then
        STAGE_ARGS[$((i+1))]="stratum+tcp://127.0.0.1:${port}"
        return 0
      fi
    fi
  done
  echo "ERROR: pool argument (-o/--pool) was not found in PEPEPOW_ARGS." >&2
  return 1
}

telemetry_loop() {
  local csv="$1" start_epoch="$2" now elapsed row
  echo 'elapsed_s,timestamp,temperature_gpu_c,utilization_gpu_pct,clock_sm_mhz,clock_memory_mhz,power_w,power_limit_w,fan_pct,memory_used_mib' > "$csv"
  while true; do
    now="$(date +%s)"
    elapsed=$((now - start_epoch))
    row="$(nvidia-smi --query-gpu=timestamp,temperature.gpu,utilization.gpu,clocks.current.sm,clocks.current.memory,power.draw,power.limit,fan.speed,memory.used --format=csv,noheader,nounits 2>/dev/null | head -n1 || true)"
    [[ -n "$row" ]] && printf '%s,%s\n' "$elapsed" "$row" >> "$csv"
    sleep "${SAMPLE_SECONDS}"
  done
}

redact_log() {
  local src="$1" dst="$2" token=""
  local i
  for ((i=0; i<${#PEPEPOW_ARGS[@]}; i++)); do
    if [[ "${PEPEPOW_ARGS[$i]}" == "-u" && $((i+1)) -lt ${#PEPEPOW_ARGS[@]} ]]; then
      token="${PEPEPOW_ARGS[$((i+1))]}"
      break
    fi
  done
  if [[ -n "$token" ]]; then
    python3 - "$src" "$dst" "$token" <<'PY'
from pathlib import Path
import sys
src, dst, token = sys.argv[1:4]
text = Path(src).read_text(errors="replace")
Path(dst).write_text(text.replace(token, "<REDACTED_WALLET_WORKER>"), encoding="utf-8")
PY
  else
    cp -f "$src" "$dst"
  fi
}

summarize_stage() {
  local stage="$1" variant="$2" console="$3" telemetry="$4" out="$5"
  python3 - "$stage" "$variant" "$console" "$telemetry" "$out" "${WARMUP_SECONDS}" <<'PY'
from __future__ import annotations
import csv, json, re, statistics, sys
from pathlib import Path
stage, variant, console_path, telemetry_path, out_path, warmup = sys.argv[1:]
warmup = int(warmup)
ansi = re.compile(r"\x1b\[[0-9;]*m")
text = ansi.sub("", Path(console_path).read_text(errors="replace"))

def uptime_seconds(value: str) -> int:
    parts = [int(x) for x in value.split(":")]
    total = 0
    for x in parts:
        total = total * 60 + x
    return total

samples = []
for m in re.finditer(r"\[MINING\]\s*\|\s*([0-9.]+)\s+MH/s\s*\|\s*A\s+(\d+)\s*\|\s*R\s+(\d+)\s*\|\s*Uptime\s+([0-9:]+)", text):
    samples.append((float(m.group(1)), int(m.group(2)), int(m.group(3)), uptime_seconds(m.group(4))))
warm = [x for x in samples if x[3] >= warmup]
rates = [x[0] for x in warm]
accepted = warm[-1][1] if warm else (samples[-1][1] if samples else 0)
rejected = warm[-1][2] if warm else (samples[-1][2] if samples else 0)
jobs = len(re.findall(r"\[JOB\]", text))
reject_reasons = [x.strip() for x in re.findall(r"\[REJECTED\].*?reason=([^\r\n]+)", text)]

gpu_rows = []
if Path(telemetry_path).exists():
    with open(telemetry_path, newline="", errors="replace") as fh:
        for row in csv.DictReader(fh, skipinitialspace=True):
            try:
                if int(float(row.get("elapsed_s", "0"))) >= warmup:
                    gpu_rows.append(row)
            except ValueError:
                pass

def nums(key):
    out = []
    for row in gpu_rows:
        try:
            out.append(float(row[key].strip()))
        except (KeyError, ValueError, AttributeError):
            pass
    return out

def mean_or_zero(values):
    return statistics.mean(values) if values else 0.0

valid = bool(rates)
result = {
    "stage": stage,
    "variant": variant,
    "valid": int(valid),
    "samples": len(rates),
    "mean_mhs": statistics.mean(rates) if rates else 0.0,
    "median_mhs": statistics.median(rates) if rates else 0.0,
    "min_mhs": min(rates) if rates else 0.0,
    "max_mhs": max(rates) if rates else 0.0,
    "stdev_mhs": statistics.pstdev(rates) if rates else 0.0,
    "accepted": accepted,
    "rejected": rejected,
    "jobs": jobs,
    "reject_reasons": reject_reasons,
    "power_mean_w": mean_or_zero(nums("power_w")),
    "temp_mean_c": mean_or_zero(nums("temperature_gpu_c")),
    "clock_mean_mhz": mean_or_zero(nums("clock_sm_mhz")),
    "util_mean_pct": mean_or_zero(nums("utilization_gpu_pct")),
    "reason": "ok" if valid else "no_warm_hashrate_samples",
}
Path(out_path).write_text(json.dumps(result, indent=2, sort_keys=True), encoding="utf-8")
print(",".join([
    result["stage"], result["variant"], str(result["valid"]), str(result["samples"]),
    f'{result["mean_mhs"]:.6f}', f'{result["median_mhs"]:.6f}',
    f'{result["min_mhs"]:.6f}', f'{result["max_mhs"]:.6f}',
    f'{result["stdev_mhs"]:.6f}', str(result["accepted"]), str(result["rejected"]),
    str(result["jobs"]), f'{result["power_mean_w"]:.3f}', f'{result["temp_mean_c"]:.3f}',
    f'{result["clock_mean_mhz"]:.3f}', f'{result["util_mean_pct"]:.3f}', result["reason"]
]))
PY
}

run_stage() {
  local index="$1" stage="$2" variant="$3" binary="$4" port="$5"
  local dir="${STAGE_ROOT}/stages/${stage}"
  local raw_console="${dir}/miner-console.raw.log"
  local console="${dir}/miner-console.log"
  local proxy_raw="${dir}/stratum-proxy.raw.log"
  local proxy_log="${dir}/stratum-proxy.log"
  local proxy_console="${dir}/proxy-console.log"
  local telemetry="${dir}/gpu-timeseries.csv"
  local summary="${dir}/summary.json"
  local start_epoch miner_rc=0

  mkdir -p "$dir"
  make_args "$port"

  echo
  echo "======================================================================"
  echo "LIVE_STAGE index=${index} total=3 id=${stage} variant=${variant}"
  echo "STATUS=STARTING"
  echo "DURATION_SECONDS=${STAGE_SECONDS} WARMUP_SECONDS=${WARMUP_SECONDS}"
  echo "======================================================================"

  start_epoch="$(date +%s)"
  write_status "STARTING" "$index" "$stage" "$variant" "$start_epoch"

  "${PROXY_SCRIPT}" \
    --upstream "${PEPEPOW_UPSTREAM}" \
    --listen-host 127.0.0.1 \
    --listen-port "$port" \
    --log "$proxy_raw" \
    >"$proxy_console" 2>&1 &
  current_proxy_pid=$!
  sleep 2
  if ! kill -0 "$current_proxy_pid" 2>/dev/null; then
    echo "LIVE_STAGE_RESULT stage=${stage} variant=${variant} valid=0 reason=proxy_start_failed"
    return 1
  fi

  "$binary" "${STAGE_ARGS[@]}" >"$raw_console" 2>&1 &
  current_miner_pid=$!
  telemetry_loop "$telemetry" "$start_epoch" &
  current_telemetry_pid=$!

  write_status "WARMUP" "$index" "$stage" "$variant" "$start_epoch"
  echo "STATUS=WARMUP"
  sleep "${WARMUP_SECONDS}"

  if ! kill -0 "$current_miner_pid" 2>/dev/null; then
    wait "$current_miner_pid" || miner_rc=$?
    echo "LIVE_STAGE_RESULT stage=${stage} variant=${variant} valid=0 reason=miner_exited_during_warmup rc=${miner_rc}"
    cleanup_stage_processes
    redact_log "$raw_console" "$console"
    [[ -f "$proxy_raw" ]] && { redact_log "$proxy_raw" "$proxy_log"; rm -f "$proxy_raw"; }
    return 1
  fi

  write_status "MEASURING" "$index" "$stage" "$variant" "$start_epoch"
  echo "STATUS=MEASURING"
  sleep "$((STAGE_SECONDS - WARMUP_SECONDS))"

  if kill -0 "$current_miner_pid" 2>/dev/null; then
    kill -TERM "$current_miner_pid" 2>/dev/null || true
    wait "$current_miner_pid" 2>/dev/null || true
  else
    wait "$current_miner_pid" || miner_rc=$?
  fi
  current_miner_pid=""

  if kill -0 "$current_telemetry_pid" 2>/dev/null; then
    kill -TERM "$current_telemetry_pid" 2>/dev/null || true
    wait "$current_telemetry_pid" 2>/dev/null || true
  fi
  current_telemetry_pid=""
  if kill -0 "$current_proxy_pid" 2>/dev/null; then
    kill -TERM "$current_proxy_pid" 2>/dev/null || true
    wait "$current_proxy_pid" 2>/dev/null || true
  fi
  current_proxy_pid=""

  redact_log "$raw_console" "$console"
  rm -f "$raw_console"
  [[ -f "$proxy_raw" ]] && { redact_log "$proxy_raw" "$proxy_log"; rm -f "$proxy_raw"; }
  result_line="$(summarize_stage "$stage" "$variant" "$console" "$telemetry" "$summary")"
  echo "$result_line" >> "${RESULTS}"
  valid_field="$(cut -d, -f3 <<<"$result_line")"
  median_field="$(cut -d, -f6 <<<"$result_line")"
  accepted_field="$(cut -d, -f10 <<<"$result_line")"
  rejected_field="$(cut -d, -f11 <<<"$result_line")"
  echo "LIVE_STAGE_RESULT stage=${stage} variant=${variant} valid=${valid_field} median_mhs=${median_field} accepted=${accepted_field} rejected=${rejected_field}"
  sleep 5
}

run_stage 1 baseline-a1 baseline "${STABLE_BIN}" 49401
run_stage 2 candidate-b lazy-zero-elide "${CANDIDATE_BIN}" 49402
run_stage 3 baseline-a2 baseline "${STABLE_BIN}" 49403

write_status "ANALYZING" 3 baseline-a2 baseline "$(date +%s)"
python3 - "${RESULTS}" "${STAGE_ROOT}/summary.txt" "${STAGE_ROOT}/summary.json" <<'PY'
from __future__ import annotations
import csv, json, statistics, sys
src, txt_path, json_path = sys.argv[1:]
rows = list(csv.DictReader(open(src, encoding="utf-8")))
valid = [r for r in rows if r["valid"] == "1"]
base = [r for r in valid if r["variant"] == "baseline"]
cand = [r for r in valid if r["variant"] == "lazy-zero-elide"]

def weighted_mean(items, key):
    weights = [max(int(r["samples"]), 1) for r in items]
    vals = [float(r[key]) for r in items]
    return sum(v*w for v,w in zip(vals,weights))/sum(weights) if items else 0.0

base_mean = weighted_mean(base, "mean_mhs")
base_median = statistics.mean([float(r["median_mhs"]) for r in base]) if base else 0.0
cand_mean = weighted_mean(cand, "mean_mhs")
cand_median = statistics.mean([float(r["median_mhs"]) for r in cand]) if cand else 0.0
uplift_mean = (cand_mean/base_mean - 1.0)*100.0 if base_mean and cand_mean else 0.0
uplift_median = (cand_median/base_median - 1.0)*100.0 if base_median and cand_median else 0.0
candidate_rejected = sum(int(r["rejected"]) for r in cand)
candidate_accepted = sum(int(r["accepted"]) for r in cand)
baseline_rejected = sum(int(r["rejected"]) for r in base)
baseline_accepted = sum(int(r["accepted"]) for r in base)
pass_gate = bool(base and cand and candidate_accepted > 0 and candidate_rejected == 0 and uplift_mean > 0.25)
result = {
    "stages_total": len(rows),
    "stages_valid": len(valid),
    "baseline_mean_mhs": base_mean,
    "baseline_median_mhs": base_median,
    "candidate_mean_mhs": cand_mean,
    "candidate_median_mhs": cand_median,
    "uplift_mean_pct": uplift_mean,
    "uplift_median_pct": uplift_median,
    "baseline_accepted": baseline_accepted,
    "baseline_rejected": baseline_rejected,
    "candidate_accepted": candidate_accepted,
    "candidate_rejected": candidate_rejected,
    "live_gate": "PASS" if pass_gate else "PENDING",
    "target_2mh": "PASS" if cand_mean >= 2.0 else "PENDING",
}
with open(txt_path, "w", encoding="utf-8") as f:
    for k,v in result.items():
        if isinstance(v, float):
            f.write(f"{k}={v:.6f}\n")
        else:
            f.write(f"{k}={v}\n")
with open(json_path, "w", encoding="utf-8") as f:
    json.dump({"summary":result, "stages":rows}, f, indent=2, sort_keys=True)
PY

nvidia-smi -q > "${STAGE_ROOT}/nvidia/nvidia-smi-after.txt" 2>&1 || true
dmesg -T 2>/dev/null | grep -Ei 'NVRM|Xid|CUDA|nvidia' | tail -n200 > "${STAGE_ROOT}/nvidia/kernel-events.txt" || true
echo "finished_at=$(date --iso-8601=seconds)" >> "${STAGE_ROOT}/MANIFEST.txt"
write_status "PACKAGING" 3 baseline-a2 baseline "$(date +%s)"

tar -C "${OUT_ROOT}" -czf "${ARCHIVE}" "${NAME}"
sha256sum "${ARCHIVE}" > "${ARCHIVE}.sha256"

echo
echo "========== V0.7.0 LIVE A/B/A COMPLETE =========="
cat "${STAGE_ROOT}/summary.txt"
echo "RESULTS=${RESULTS}"
echo "ARCHIVE=${ARCHIVE}"
echo "SHA256_FILE=${ARCHIVE}.sha256"

write_status "PUBLISHING" 3 baseline-a2 baseline "$(date +%s)"
if curl -fsSL "${PUBLISHER_URL}" -o "${PUBLISHER}"; then
  chmod +x "${PUBLISHER}"
  PUBLIC_UPLOAD=1 "${PUBLISHER}" "${ARCHIVE}" || true
fi
write_status "COMPLETE" 3 baseline-a2 baseline "$(date +%s)"

echo "DOWNLOAD_LINKS_FILE=${ARCHIVE}.links.txt"
ls -lh "${ARCHIVE}" "${ARCHIVE}.sha256" "${ARCHIVE}.links.txt" 2>/dev/null || true
