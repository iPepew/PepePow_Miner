#!/usr/bin/env bash
set -Eeuo pipefail

# Live comparison harness for Foztor hoo_gpu on the same HiveOS worker used by PepeW.
# - downloads the official hoo_gpu archive from htn.foztor.net
# - reuses the active HiveOS custom-miner pool/user/password
# - forces PEPEW mode and keeps CPU validation enabled
# - records Foztor autotune/LUT diagnostics and V100 telemetry
# - restores the HiveOS miner on exit

FOZTOR_URL="${FOZTOR_URL:-https://htn.foztor.net/hoo_gpu.tar.gz}"
WORK_ROOT="${FOZTOR_WORK_ROOT:-/tmp/pepew-foztor-v100}"
AUTOTUNE_TIMEOUT="${FOZTOR_AUTOTUNE_TIMEOUT:-420}"
WARMUP_SECONDS="${FOZTOR_WARMUP_SECONDS:-30}"
TEST_SECONDS="${FOZTOR_TEST_SECONDS:-300}"
SAMPLE_SECONDS="${FOZTOR_SAMPLE_SECONDS:-5}"
EXP_THRESHOLD="${FOZTOR_EXP_THRESHOLD:-1.5}"
GPU_ID="${FOZTOR_GPU_ID:-0}"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "ERROR: run as root on the HiveOS worker" >&2
  exit 2
fi

for cmd in curl tar awk grep sed date nvidia-smi; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: missing $cmd" >&2; exit 2; }
done

if [[ ! -f /hive-config/wallet.conf ]]; then
  echo "ERROR: /hive-config/wallet.conf not found" >&2
  exit 2
fi

# shellcheck disable=SC1091
source /hive-config/wallet.conf
POOL="${CUSTOM_URL:-}"
USER="${CUSTOM_TEMPLATE:-}"
PASS="${CUSTOM_PASS:-x}"

if [[ -z "$POOL" || -z "$USER" ]]; then
  echo "ERROR: active HiveOS wallet.conf does not contain CUSTOM_URL/CUSTOM_TEMPLATE" >&2
  exit 2
fi

mkdir -p "$WORK_ROOT"
rm -rf "$WORK_ROOT/pkg"
mkdir -p "$WORK_ROOT/pkg"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="$WORK_ROOT/report-$RUN_ID"
mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/foztor.log"
GPU_CSV="$OUT_DIR/gpu.csv"
API_CSV="$OUT_DIR/api.csv"
INFO="$OUT_DIR/info.txt"
ARCHIVE="$OUT_DIR/hoo_gpu.tar.gz"

restore_miner() {
  set +e
  if [[ -n "${FOZTOR_PID:-}" ]]; then kill "$FOZTOR_PID" 2>/dev/null || true; wait "$FOZTOR_PID" 2>/dev/null || true; fi
  if command -v miner >/dev/null 2>&1; then miner start >/dev/null 2>&1 || true; fi
}
trap restore_miner EXIT INT TERM

echo "=== FOZTOR V100 / PEPEW LIVE BENCHMARK ==="
echo "Official archive: $FOZTOR_URL"
echo "GPU: $GPU_ID"
echo "exp-threshold: $EXP_THRESHOLD"
echo "Autotune wait: ${AUTOTUNE_TIMEOUT}s"
echo "Measure: ${TEST_SECONDS}s after ${WARMUP_SECONDS}s warmup"
echo

echo "=== STOP CURRENT HIVEOS MINER ==="
if command -v miner >/dev/null 2>&1; then miner stop || true; sleep 3; fi

echo "=== DOWNLOAD OFFICIAL FOZTOR ==="
curl -fL --retry 3 --connect-timeout 20 "$FOZTOR_URL" -o "$ARCHIVE"
tar -xzf "$ARCHIVE" -C "$WORK_ROOT/pkg"

FOZTOR_BIN="$(find "$WORK_ROOT/pkg" -type f -name hoo_gpu -perm -u+x | head -n1 || true)"
if [[ -z "$FOZTOR_BIN" ]]; then
  FOZTOR_BIN="$(find "$WORK_ROOT/pkg" -type f -name hoo_gpu | head -n1 || true)"
fi
[[ -n "$FOZTOR_BIN" ]] || { echo "ERROR: hoo_gpu binary not found in archive" >&2; exit 2; }
chmod +x "$FOZTOR_BIN"
FOZTOR_DIR="$(dirname "$FOZTOR_BIN")"

# Force a fresh Foztor autotune so we can see the real sm_70 choices on this V100.
find "$FOZTOR_DIR" -maxdepth 1 -type f -name '.hoo_autotune_*' -delete 2>/dev/null || true

{
  echo "run_id=$RUN_ID"
  echo "foztor_url=$FOZTOR_URL"
  echo "foztor_bin=$FOZTOR_BIN"
  echo "exp_threshold=$EXP_THRESHOLD"
  echo "gpu_id=$GPU_ID"
  echo "pool_host=$(sed -E 's#(stratum\+(tcp|tcps)://)?([^/:]+).*#\3#' <<<"$POOL")"
  echo "user_redacted=${USER:0:8}..."
  echo
  nvidia-smi -i "$GPU_ID" --query-gpu=name,pci.bus_id,compute_cap,driver_version,pstate,clocks.current.graphics,clocks.current.memory,power.limit --format=csv,noheader 2>&1 || true
  echo
  sha256sum "$FOZTOR_BIN" 2>/dev/null || true
  find "$FOZTOR_DIR" -maxdepth 2 -type f -name '*sm70*' -o -name '*.cubin' 2>/dev/null | sort || true
} > "$INFO"

cd "$FOZTOR_DIR"
ARGS=(
  -o "$POOL"
  -u "$USER"
  -p "$PASS"
  --pepepow
  --gpu-id "$GPU_ID"
  --exp-threshold "$EXP_THRESHOLD"
  --no-share-hashrate
  --same-stratum
  --reset-autotune
)

echo "=== START FOZTOR ==="
echo "Command: ./hoo_gpu -o <pool> -u <wallet.worker> -p <redacted> --pepepow --gpu-id $GPU_ID --exp-threshold $EXP_THRESHOLD --no-share-hashrate --same-stratum --reset-autotune"
stdbuf -oL -eL "$FOZTOR_BIN" "${ARGS[@]}" > >(tee -a "$LOG") 2>&1 &
FOZTOR_PID=$!

# Wait for successful PEPEW kernel load/autotune, but don't hang forever.
echo "=== WAIT FOR FOZTOR AUTOTUNE ==="
start_wait=$(date +%s)
while kill -0 "$FOZTOR_PID" 2>/dev/null; do
  if grep -Eq 'Autotuned:|Autotune Results:|Loaded cached autotune:' "$LOG" 2>/dev/null; then
    echo "Autotune result detected."
    break
  fi
  now=$(date +%s)
  if (( now - start_wait >= AUTOTUNE_TIMEOUT )); then
    echo "WARNING: autotune marker not seen after ${AUTOTUNE_TIMEOUT}s; continuing with live miner."
    break
  fi
  sleep 5
done
kill -0 "$FOZTOR_PID" 2>/dev/null || { echo "ERROR: Foztor exited during startup" >&2; tail -n 120 "$LOG"; exit 3; }

echo
 echo "=== FOZTOR KEY STARTUP / AUTOTUNE LINES ==="
grep -Eai 'sm_70|sm70|fatbin|pepew_mining_kernel|autotun|AT cand|tpb=|blocks=|batch=|warp=|LUT|magic|shared|carveout|cache|exp-threshold|torture|CPU validation|miscalc' "$LOG" | tail -n 180 || true

echo "=== WARMUP ${WARMUP_SECONDS}s ==="
sleep "$WARMUP_SECONDS"

echo 'timestamp,temp_c,power_w,power_limit_w,graphics_mhz,memory_mhz,gpu_util_pct,mem_util_pct,pstate' > "$GPU_CSV"
echo 'timestamp,gkhs,gacc,grej,raw' > "$API_CSV"

sum_mhs=0
samples=0
min_mhs=""
max_mhs=""
start=$(date +%s)
end=$((start + TEST_SECONDS))

api_summary() {
  if command -v nc >/dev/null 2>&1; then
    (echo summary | timeout 2 nc -w 2 127.0.0.1 4049 2>/dev/null || true) | tr -d '\0\r\n'
  fi
}

parse_api() {
  local raw="$1" key="$2"
  sed -nE "s/.*(^|;)${key}=([^;|]*).*/\2/p" <<<";$raw" | tail -n1
}

while (( $(date +%s) < end )); do
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  gpu=$(nvidia-smi -i "$GPU_ID" --query-gpu=temperature.gpu,power.draw,power.limit,clocks.current.graphics,clocks.current.memory,utilization.gpu,utilization.memory,pstate --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' || true)
  echo "$ts,$gpu" >> "$GPU_CSV"

  raw="$(api_summary)"
  gkhs="$(grep -oE '(^|;)GKHS=[0-9.]+' <<<"$raw" | tail -n1 | cut -d= -f2 || true)"
  gacc="$(grep -oE '(^|;)GACC=[0-9]+' <<<"$raw" | tail -n1 | cut -d= -f2 || true)"
  grej="$(grep -oE '(^|;)GREJ=[0-9]+' <<<"$raw" | tail -n1 | cut -d= -f2 || true)"
  echo "$ts,${gkhs:-0},${gacc:-0},${grej:-0},\"${raw//\"/}\"" >> "$API_CSV"

  mhs=0
  if [[ -n "$gkhs" ]]; then mhs=$(awk -v x="$gkhs" 'BEGIN{printf "%.6f",x/1000.0}'); fi
  if awk -v x="$mhs" 'BEGIN{exit !(x>0)}'; then
    samples=$((samples+1))
    sum_mhs=$(awk -v a="$sum_mhs" -v b="$mhs" 'BEGIN{printf "%.6f",a+b}')
    if [[ -z "$min_mhs" ]] || awk -v a="$mhs" -v b="$min_mhs" 'BEGIN{exit !(a<b)}'; then min_mhs="$mhs"; fi
    if [[ -z "$max_mhs" ]] || awk -v a="$mhs" -v b="$max_mhs" 'BEGIN{exit !(a>b)}'; then max_mhs="$mhs"; fi
  fi
  avg=$(awk -v s="$sum_mhs" -v n="$samples" 'BEGIN{if(n>0)printf "%.3f",s/n;else print "0.000"}')
  IFS=',' read -r temp power pl core mem util mutil pstate <<<"$gpu"
  elapsed=$(( $(date +%s) - start ))
  printf '[FOZTOR] %03ds/%03ds | last %.3f MH/s | avg %s | GPU %sC %sW core %s mem %s util %s%% | A/R %s/%s\n' \
    "$elapsed" "$TEST_SECONDS" "$mhs" "$avg" "${temp:-?}" "${power:-?}" "${core:-?}" "${mem:-?}" "${util:-?}" "${gacc:-?}" "${grej:-?}"
  sleep "$SAMPLE_SECONDS"
done

avg=$(awk -v s="$sum_mhs" -v n="$samples" 'BEGIN{if(n>0)printf "%.3f",s/n;else print "0.000"}')

{
  echo
  echo "=== FOZTOR FINAL RESULT ==="
  echo "Samples: $samples"
  echo "Hashrate avg: $avg MH/s"
  echo "Hashrate min: ${min_mhs:-0} MH/s"
  echo "Hashrate max: ${max_mhs:-0} MH/s"
  echo "exp-threshold: $EXP_THRESHOLD"
  echo
  echo "=== FINAL AUTOTUNE ==="
  grep -Eai 'Autotuned:|Autotune Results:|Loaded cached autotune:|tpb=|blocks=|batch=|warp=' "$LOG" | tail -n 40 || true
  echo
  echo "=== HASH QUALITY / VALIDATION ==="
  grep -Eai 'CPU validation|fails CPU validation|miscalc|invalid GPU|solution' "$LOG" | tail -n 120 || true
} | tee "$OUT_DIR/summary.txt"

# Redact user/pool credentials from the copied log before packaging.
cp "$LOG" "$OUT_DIR/foztor.redacted.log"
sed -i -e "s#${USER//\/\\}#<USER_REDACTED>#g" -e "s#${POOL//\/\\}#<POOL_REDACTED>#g" -e "s#${PASS//\/\\}#<PASS_REDACTED>#g" "$OUT_DIR/foztor.redacted.log" 2>/dev/null || true
rm -f "$LOG" "$ARCHIVE"

REPORT_TGZ="$WORK_ROOT/foztor-v100-report-$RUN_ID.tar.gz"
tar -C "$OUT_DIR" -czf "$REPORT_TGZ" .

echo
echo "Report: $REPORT_TGZ"
echo "Send summary.txt plus the report archive to ChatGPT."
