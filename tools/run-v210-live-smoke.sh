#!/usr/bin/env bash
set -euo pipefail
umask 077

OUT_ROOT="${OUT_ROOT:-/root/pepepow-tests}"
DURATION="${DURATION:-600}"
WARMUP="${WARMUP:-120}"
SAMPLE_SECONDS="${SAMPLE_SECONDS:-2}"
PORT="${PORT:-35582}"
STAMP="$(date +%Y%m%d_%H%M%S)"
NAME="v210-live-smoke-${STAMP}"
STAGE="${OUT_ROOT}/${NAME}"
ARCHIVE="${OUT_ROOT}/${NAME}.tar.gz"
STATUS_FILE="${STAGE}/status.env"
SUMMARY="${STAGE}/summary.txt"
PUBLISHER_URL="https://raw.githubusercontent.com/iPepew/PepePow_Miner/experiment/v2.0.0-warp-service/tools/publish-test-results.sh"
PUBLISHER="/root/publish-pepepow-test-results.sh"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1" >&2; exit 1; }; }
for c in bash grep sed awk python3 nvidia-smi tar sha256sum curl stdbuf; do need "$c"; done
(( DURATION >= 300 && WARMUP >= 60 && WARMUP < DURATION )) || {
  echo "ERROR: require DURATION>=300, WARMUP>=60 and WARMUP<DURATION" >&2
  exit 1
}

find_stable(){
  local d
  for d in /hive/miners/custom/pepepowminer-v0.6.0-PR /hive/miners/custom/pepepowminer /hive/miners/custom/pepepow; do
    [[ -x "$d/pepepowminer" && -f "$d/config.txt" && -x "$d/stratum-replay-proxy.py" ]] && { readlink -f "$d"; return 0; }
  done
  return 1
}
find_candidate(){
  local d
  for d in /root/pepepow-v060-8h-src/build-v210-geometry/service768 /root/pepepow-v060-src/build-v210-geometry/service768 /root/PepePow_Miner/build-v210-geometry/service768; do
    [[ -x "$d/pepepowminer" && -x "$d/pepepow_cuda_header80_validation" ]] && { readlink -f "$d"; return 0; }
  done
  return 1
}

STABLE="$(find_stable || true)"
CANDIDATE="$(find_candidate || true)"
[[ -n "$STABLE" ]] || { echo "ERROR: stable config/proxy not found" >&2; exit 1; }
[[ -n "$CANDIDATE" ]] || { echo "ERROR: service768 build not found" >&2; exit 1; }

# shellcheck disable=SC1090
source "$STABLE/config.txt"
declare -p PEPEPOW_ARGS >/dev/null 2>&1 || { echo "ERROR: PEPEPOW_ARGS missing" >&2; exit 1; }
: "${PEPEPOW_UPSTREAM:?missing PEPEPOW_UPSTREAM}"

GPU_APPS="$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null || true)"
if [[ -n "${GPU_APPS//[[:space:]]/}" ]]; then
  echo "ERROR: GPU busy. Use an empty flight sheet." >&2
  echo "$GPU_APPS" >&2
  exit 2
fi

mkdir -p "$STAGE"/{logs,metadata,nvidia}
RAW_LOG="$STAGE/logs/miner.raw.log"
MINER_LOG="$STAGE/logs/miner.log"
PROXY_RAW="$STAGE/logs/proxy.raw.log"
PROXY_LOG="$STAGE/logs/proxy.log"
PROXY_CONSOLE="$STAGE/logs/proxy-console.log"
GPU_CSV="$STAGE/logs/gpu.csv"
ERRPAT='WORKER_ERROR|illegal memory access|unspecified launch failure|device-side assert|CUDA_ERROR|cudaError|CUDA error|out of memory|failed to launch|cudaMemcpy[^[:cntrl:]]*(failed|error)'

xid_count(){ dmesg 2>/dev/null | grep -Ec 'NVRM: Xid|Xid \(' || true; }
set_status(){
  local state="$1" reason="${2:-}" elapsed="${3:-0}"
  printf 'STATE=%q\nREASON=%q\nELAPSED=%q\nDURATION=%q\nWARMUP=%q\n' \
    "$state" "$reason" "$elapsed" "$DURATION" "$WARMUP" >"$STATUS_FILE"
}

ARGS=("${PEPEPOW_ARGS[@]}")
FOUND_POOL=0
for ((i=0;i<${#ARGS[@]};i++)); do
  if [[ "${ARGS[$i]}" == "-o" || "${ARGS[$i]}" == "--pool" ]]; then
    ARGS[$((i+1))]="stratum+tcp://127.0.0.1:${PORT}"
    FOUND_POOL=1
    break
  fi
done
(( FOUND_POOL == 1 )) || { echo "ERROR: pool argument not found" >&2; exit 1; }

WALLET=""
for ((i=0;i<${#PEPEPOW_ARGS[@]};i++)); do
  if [[ "${PEPEPOW_ARGS[$i]}" == "-u" && $((i+1)) -lt ${#PEPEPOW_ARGS[@]} ]]; then
    WALLET="${PEPEPOW_ARGS[$((i+1))]}"
    break
  fi
done

MINER_PID=""
PROXY_PID=""
TELEMETRY_PID=""
cleanup(){
  local p
  for p in "${TELEMETRY_PID:-}" "${MINER_PID:-}" "${PROXY_PID:-}"; do
    [[ -n "$p" ]] || continue
    kill -TERM "$p" 2>/dev/null || true
  done
  sleep 1
  for p in "${TELEMETRY_PID:-}" "${MINER_PID:-}" "${PROXY_PID:-}"; do
    [[ -n "$p" ]] || continue
    kill -KILL "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

set_status PRECHECK
"$CANDIDATE/pepepow_cuda_header80_validation" >"$STAGE/metadata/validation.log" 2>&1
sha256sum "$CANDIDATE/pepepowminer" >"$STAGE/metadata/candidate-binary.sha256"
"$CANDIDATE/pepepowminer" --version >"$STAGE/metadata/candidate-version.txt" 2>&1 || true
nvidia-smi -q >"$STAGE/nvidia/nvidia-smi-before.txt" 2>&1 || true
dmesg 2>/dev/null | grep -E 'NVRM|Xid' >"$STAGE/nvidia/xid-before.txt" || true
XID_BEFORE="$(xid_count)"

cat >"$STAGE/MANIFEST.txt" <<META
name=$NAME
candidate=service768
candidate_dir=$CANDIDATE
duration_seconds=$DURATION
warmup_seconds=$WARMUP
target_hps=2000000
started_at=$(date --iso-8601=seconds)
META

: >"$RAW_LOG"
: >"$PROXY_RAW"
echo 'elapsed_s,timestamp,temperature_c,util_pct,core_mhz,power_w' >"$GPU_CSV"

"$STABLE/stratum-replay-proxy.py" \
  --upstream "$PEPEPOW_UPSTREAM" \
  --listen-host 127.0.0.1 \
  --listen-port "$PORT" \
  --log "$PROXY_RAW" \
  >"$PROXY_CONSOLE" 2>&1 &
PROXY_PID=$!
sleep 2
kill -0 "$PROXY_PID" 2>/dev/null || { cat "$PROXY_CONSOLE" >&2; exit 1; }

START_EPOCH="$(date +%s)"
(
  cd "$STABLE"
  exec stdbuf -oL -eL "$CANDIDATE/pepepowminer" "${ARGS[@]}"
) >"$RAW_LOG" 2>&1 &
MINER_PID=$!

(
  while true; do
    now="$(date +%s)"
    elapsed=$((now-START_EPOCH))
    row="$(nvidia-smi --query-gpu=timestamp,temperature.gpu,utilization.gpu,clocks.current.sm,power.draw --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d ' ' || true)"
    [[ -n "$row" ]] && printf '%s,%s\n' "$elapsed" "$row" >>"$GPU_CSV"
    sleep "$SAMPLE_SECONDS"
  done
) &
TELEMETRY_PID=$!

FAIL_REASON=""
set_status RUNNING '' 0
echo "LIVE_SMOKE_START candidate=service768 pid=$MINER_PID duration=$DURATION warmup=$WARMUP"
while true; do
  NOW="$(date +%s)"
  ELAPSED=$((NOW-START_EPOCH))
  set_status RUNNING '' "$ELAPSED"
  kill -0 "$MINER_PID" 2>/dev/null || { FAIL_REASON=miner_exited_early; break; }
  kill -0 "$PROXY_PID" 2>/dev/null || { FAIL_REASON=proxy_exited_early; break; }
  grep -Eaiq "$ERRPAT" "$RAW_LOG" 2>/dev/null && { FAIL_REASON=cuda_or_worker_error; break; }
  XID_NOW="$(xid_count)"
  (( XID_NOW > XID_BEFORE )) && { FAIL_REASON=new_nvidia_xid; break; }
  (( ELAPSED >= DURATION )) && break
  sleep 2
done

set_status STOPPING "$FAIL_REASON" "$ELAPSED"
cleanup
trap - EXIT INT TERM

python3 - "$RAW_LOG" "$MINER_LOG" "$PROXY_RAW" "$PROXY_LOG" "$PROXY_CONSOLE" "$WALLET" <<'PY'
from pathlib import Path
import sys
raw, miner, praw, proxy, pconsole, wallet = sys.argv[1:]
for src, dst in ((raw, miner), (praw, proxy), (pconsole, pconsole)):
    text = Path(src).read_text(errors='replace') if Path(src).exists() else ''
    if wallet:
        text = text.replace(wallet, '<REDACTED_WALLET_WORKER>')
    Path(dst).write_text(text, encoding='utf-8')
PY
rm -f "$RAW_LOG" "$PROXY_RAW"

nvidia-smi -q >"$STAGE/nvidia/nvidia-smi-after.txt" 2>&1 || true
dmesg 2>/dev/null | grep -E 'NVRM|Xid' >"$STAGE/nvidia/xid-after.txt" || true
XID_AFTER="$(xid_count)"

python3 - "$MINER_LOG" "$GPU_CSV" "$SUMMARY" "$WARMUP" "$FAIL_REASON" "$XID_BEFORE" "$XID_AFTER" <<'PY'
import csv, re, statistics, sys
from pathlib import Path
log, gpu, out, warmup, fail, xb, xa = sys.argv[1:]
warmup = int(warmup); xb = int(xb); xa = int(xa)
text = re.sub(r'\x1b\[[0-9;]*m', '', Path(log).read_text(errors='replace'))

def seconds(value):
    total = 0
    for part in value.split(':'):
        total = total * 60 + int(part)
    return total

samples = []
for m in re.finditer(r'\[MINING\]\s*\|\s*([0-9.]+)\s+MH/s\s*\|\s*A\s+(\d+)\s*\|\s*R\s+(\d+)\s*\|\s*Uptime\s+([0-9:]+)', text):
    samples.append((float(m.group(1)), int(m.group(2)), int(m.group(3)), seconds(m.group(4))))
warm = [x for x in samples if x[3] >= warmup]
rates = [x[0] for x in warm]
accepted = samples[-1][1] if samples else 0
rejected = samples[-1][2] if samples else 0
jobs = len(re.findall(r'\[JOB\]', text))

telemetry = []
try:
    with open(gpu, newline='', errors='replace') as fh:
        for row in csv.DictReader(fh):
            try:
                if int(float(row['elapsed_s'])) >= warmup and float(row['util_pct']) >= 50:
                    telemetry.append(row)
            except Exception:
                pass
except Exception:
    pass

def avg(key):
    vals = []
    for row in telemetry:
        try: vals.append(float(row[key]))
        except Exception: pass
    return statistics.mean(vals) if vals else 0.0

mean = statistics.mean(rates) if rates else 0.0
median = statistics.median(rates) if rates else 0.0
minimum = min(rates) if rates else 0.0
maximum = max(rates) if rates else 0.0
stdev = statistics.pstdev(rates) if rates else 0.0
new_xid = max(0, xa-xb)

if fail:
    smoke_gate, reason = 'FAIL', fail
elif new_xid:
    smoke_gate, reason = 'FAIL', 'new_nvidia_xid'
elif not rates:
    smoke_gate, reason = 'FAIL', 'no_warm_hashrate_samples'
elif rejected:
    smoke_gate, reason = 'FAIL', 'rejected_shares'
elif not accepted:
    smoke_gate, reason = 'INCONCLUSIVE', 'no_accepted_shares'
else:
    smoke_gate, reason = 'PASS', 'ok'

target_gate = 'PASS' if smoke_gate == 'PASS' and mean >= 2.0 and median >= 2.0 else 'PENDING'
with open(out, 'w') as fh:
    data = {
        'candidate':'service768', 'smoke_gate':smoke_gate, 'reason':reason,
        'samples':len(rates), 'mean_mhs':mean, 'median_mhs':median,
        'min_mhs':minimum, 'max_mhs':maximum, 'stdev_mhs':stdev,
        'accepted':accepted, 'rejected':rejected, 'jobs':jobs,
        'clock_mean_mhz':avg('core_mhz'), 'power_mean_w':avg('power_w'),
        'temp_mean_c':avg('temperature_c'), 'xid_before':xb,
        'xid_after':xa, 'new_xid_count':new_xid,
        'LIVE_GATE':'SMOKE_PASS' if smoke_gate == 'PASS' else 'PENDING',
        'TARGET_2MH':'LIVE_SMOKE_PASS' if target_gate == 'PASS' else 'PENDING',
    }
    for key, value in data.items():
        fh.write(f'{key}={value}\n')
PY

printf 'finished_at=%s\n' "$(date --iso-8601=seconds)" >>"$STAGE/MANIFEST.txt"
FINAL_REASON="$(grep '^reason=' "$SUMMARY" | cut -d= -f2- || true)"
set_status COMPLETE "$FINAL_REASON" "$ELAPSED"
tar -C "$OUT_ROOT" -czf "$ARCHIVE" "$NAME"
sha256sum "$ARCHIVE" >"$ARCHIVE.sha256"

echo
echo '========== V2.1 SERVICE768 LIVE SMOKE COMPLETE =========='
cat "$SUMMARY"
echo "ARCHIVE=$ARCHIVE"
echo "SHA256_FILE=$ARCHIVE.sha256"
echo "NOTE=Stable miner was not restarted automatically."

if curl -fsSL "$PUBLISHER_URL" -o "$PUBLISHER"; then
  chmod +x "$PUBLISHER"
  PUBLIC_UPLOAD="${PUBLIC_UPLOAD:-1}" "$PUBLISHER" "$ARCHIVE" || true
fi
