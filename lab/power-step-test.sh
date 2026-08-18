#!/usr/bin/env bash
set -euo pipefail

TARGET_PL="${PEPEW_POWER_LIMIT:-225}"
TEST_SECONDS="${PEPEW_POWER_TEST_SECONDS:-120}"
INTERVAL="${PEPEW_PROGRESS_SECONDS:-5}"
LOG_FILE="${PEPEW_MINER_LOG:-/var/log/miner/custom/PepeW-Miner/pepew.log}"
GPU_INDEX="${PEPEW_GPU_INDEX:-0}"

fmt_time() {
  local s="$1"
  printf '%02d:%02d' $((s / 60)) $((s % 60))
}

latest_mhs() {
  grep -a '^\[MINING\]' "$LOG_FILE" 2>/dev/null | tail -n1 | awk '{print $2+0}'
}

sample_gpu() {
  nvidia-smi -i "$GPU_INDEX" \
    --query-gpu=temperature.gpu,power.draw,power.limit,clocks.current.graphics,utilization.gpu \
    --format=csv,noheader,nounits 2>/dev/null | tr -d ' '
}

if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "ERROR: nvidia-smi not found" >&2
  exit 1
fi

if [[ ! "$TARGET_PL" =~ ^[0-9]+$ ]] || [[ ! "$TEST_SECONDS" =~ ^[0-9]+$ ]] || [[ ! "$INTERVAL" =~ ^[0-9]+$ ]]; then
  echo "ERROR: PEPEW_POWER_LIMIT, PEPEW_POWER_TEST_SECONDS and PEPEW_PROGRESS_SECONDS must be integers" >&2
  exit 1
fi

MIN_PL=$(nvidia-smi -i "$GPU_INDEX" --query-gpu=power.min_limit --format=csv,noheader,nounits | awk '{printf "%.0f",$1}')
MAX_PL=$(nvidia-smi -i "$GPU_INDEX" --query-gpu=power.max_limit --format=csv,noheader,nounits | awk '{printf "%.0f",$1}')

if (( TARGET_PL < MIN_PL || TARGET_PL > MAX_PL )); then
  echo "ERROR: requested PL ${TARGET_PL}W outside supported ${MIN_PL}-${MAX_PL}W" >&2
  exit 1
fi

CURRENT_PL=$(nvidia-smi -i "$GPU_INDEX" --query-gpu=power.limit --format=csv,noheader,nounits | awk '{printf "%.0f",$1}')
echo "=== PEPEW V100 POWER STEP ==="
echo "GPU: $GPU_INDEX"
echo "Current PL: ${CURRENT_PL} W"
echo "Target PL:  ${TARGET_PL} W"
echo "Duration:   $(fmt_time "$TEST_SECONDS")"
echo "Heartbeat:  ${INTERVAL}s"
echo

nvidia-smi -i "$GPU_INDEX" -pl "$TARGET_PL"

start=$(date +%s)
end=$((start + TEST_SECONDS))
samples=0
sum_mhs=0
min_mhs=""
max_mhs=""

while true; do
  now=$(date +%s)
  elapsed=$((now - start))
  (( elapsed > TEST_SECONDS )) && elapsed=$TEST_SECONDS
  remaining=$((TEST_SECONDS - elapsed))
  percent=$(( TEST_SECONDS > 0 ? elapsed * 100 / TEST_SECONDS : 100 ))

  mhs=$(latest_mhs)
  [[ -n "$mhs" ]] || mhs=0
  IFS=',' read -r temp power pl clock util <<< "$(sample_gpu)"

  if awk -v x="$mhs" 'BEGIN{exit !(x>0)}'; then
    samples=$((samples + 1))
    sum_mhs=$(awk -v a="$sum_mhs" -v b="$mhs" 'BEGIN{printf "%.6f",a+b}')
    avg=$(awk -v s="$sum_mhs" -v n="$samples" 'BEGIN{printf "%.3f",s/n}')
    if [[ -z "$min_mhs" ]] || awk -v a="$mhs" -v b="$min_mhs" 'BEGIN{exit !(a<b)}'; then min_mhs="$mhs"; fi
    if [[ -z "$max_mhs" ]] || awk -v a="$mhs" -v b="$max_mhs" 'BEGIN{exit !(a>b)}'; then max_mhs="$mhs"; fi
  else
    avg="0.000"
  fi

  printf '[POWER] %s / %s | %3d%% | remaining %s | last %.3f MH/s | avg %s MH/s | GPU %sC %s/%sW %sMHz %s%%\n' \
    "$(fmt_time "$elapsed")" "$(fmt_time "$TEST_SECONDS")" "$percent" "$(fmt_time "$remaining")" \
    "$mhs" "$avg" "$temp" "$power" "$pl" "$clock" "$util"

  (( now >= end )) && break
  sleep_for=$INTERVAL
  (( now + sleep_for > end )) && sleep_for=$((end - now))
  (( sleep_for > 0 )) && sleep "$sleep_for"
done

echo
echo "=== POWER STEP RESULT ==="
printf 'PL: %s W\n' "$TARGET_PL"
printf 'Samples: %d\n' "$samples"
printf 'Hashrate avg: %s MH/s\n' "$(awk -v s="$sum_mhs" -v n="$samples" 'BEGIN{if(n>0)printf "%.3f",s/n; else print "0.000"}')"
printf 'Hashrate min: %s MH/s\n' "${min_mhs:-0}"
printf 'Hashrate max: %s MH/s\n' "${max_mhs:-0}"
printf 'Final GPU: '
sample_gpu
