#!/usr/bin/env bash
set -Eeuo pipefail

LOG="${PEPEW_LOG:-/var/log/miner/custom/PepeW-Miner/pepew.log}"
WARMUP="${PEPEW_WARMUP_SECONDS:-30}"
TEST="${PEPEW_TEST_SECONDS:-300}"
STEP="${PEPEW_PROGRESS_SECONDS:-5}"
WAIT_ONLINE="${PEPEW_WAIT_ONLINE_SECONDS:-60}"
SAMPLES="$(mktemp /tmp/pepew-kv2-samples.XXXXXX)"
trap 'rm -f "$SAMPLES"' EXIT

fmt_time() {
  local s="$1"
  printf '%02d:%02d' "$((s/60))" "$((s%60))"
}

latest_line() {
  grep '\[MINING\]' "$LOG" 2>/dev/null | tail -1 || true
}

latest_hash() {
  latest_line | awk '{for(i=1;i<=NF;i++) if($i=="MH/s"){print $(i-1); exit}}'
}

gpu_line() {
  nvidia-smi --query-gpu=temperature.gpu,power.draw,power.limit,utilization.gpu,clocks.current.graphics,clocks.current.memory --format=csv,noheader,nounits 2>/dev/null | head -1 || true
}

ar_line() {
  local line a r rec state
  line="$(latest_line)"
  a="$(sed -n 's/.*| A \([0-9][0-9]*\) |.*/\1/p' <<<"$line")"
  r="$(sed -n 's/.*| R \([0-9][0-9]*\) |.*/\1/p' <<<"$line")"
  rec="$(sed -n 's/.*| REC \([0-9][0-9]*\) |.*/\1/p' <<<"$line")"
  state="$(sed -n 's/.*| STATE \([^ |][^ |]*\).*/\1/p' <<<"$line")"
  printf 'A/R %s/%s | REC %s | %s' "${a:-?}" "${r:-?}" "${rec:-?}" "${state:-unknown}"
}

stats_from_samples() {
  awk '
    NF {sum+=$1; if(n==0||$1<min)min=$1; if(n==0||$1>max)max=$1; n++}
    END {if(n) printf "%.3f %.3f %.3f %d",sum/n,min,max,n; else printf "0 0 0 0"}
  ' "$SAMPLES"
}

echo '=== PEPEW V100 KV2-A 5 MINUTE MONITOR ==='
echo "Log: $LOG"
echo "Wait online: $(fmt_time "$WAIT_ONLINE")"
echo "Warmup:      $(fmt_time "$WARMUP")"
echo "Measure:     $(fmt_time "$TEST")"
echo "Heartbeat:   ${STEP}s"
echo

# Wait for live miner telemetry.
online=0
for ((e=0; e<=WAIT_ONLINE; e+=STEP)); do
  line="$(latest_line)"
  h="$(latest_hash)"
  remain=$((WAIT_ONLINE-e)); ((remain<0)) && remain=0
  if [[ "$line" == *'STATE online'* ]] && [[ -n "$h" ]] && awk -v x="$h" 'BEGIN{exit !(x>0)}'; then
    echo "[STRATUM] elapsed $(fmt_time "$e") / $(fmt_time "$WAIT_ONLINE") | remaining $(fmt_time "$remain") | ${h} MH/s | online"
    online=1
    break
  fi
  echo "[STRATUM] elapsed $(fmt_time "$e") / $(fmt_time "$WAIT_ONLINE") | remaining $(fmt_time "$remain") | waiting for online telemetry"
  (( e >= WAIT_ONLINE )) && break
  sleep "$STEP"
done

if (( ! online )); then
  echo 'FAIL: miner did not reach online telemetry state.'
  tail -80 "$LOG" 2>/dev/null || true
  exit 2
fi

# Warmup with live heartbeat.
echo
echo '=== WARMUP ==='
for ((e=0; e<=WARMUP; e+=STEP)); do
  h="$(latest_hash)"; gpu="$(gpu_line)"; ar="$(ar_line)"
  remain=$((WARMUP-e)); ((remain<0)) && remain=0
  echo "[WARMUP] elapsed $(fmt_time "$e") / $(fmt_time "$WARMUP") | remaining $(fmt_time "$remain") | miner ${h:-0} MH/s | GPU ${gpu:-n/a} | $ar"
  (( e >= WARMUP )) && break
  sleep "$STEP"
done

# Measurement.
: > "$SAMPLES"
echo
echo '=== MEASURE ==='
for ((e=0; e<=TEST; e+=STEP)); do
  h="$(latest_hash)"
  if [[ -n "$h" ]] && awk -v x="$h" 'BEGIN{exit !(x>0)}'; then printf '%s\n' "$h" >> "$SAMPLES"; fi
  read -r avg min max n <<<"$(stats_from_samples)"
  gpu="$(gpu_line)"; ar="$(ar_line)"
  remain=$((TEST-e)); ((remain<0)) && remain=0
  pct=$(( TEST>0 ? e*100/TEST : 100 )); ((pct>100)) && pct=100
  printf '[MEASURE] %s / %s | %3d%% | remaining %s | last %s MH/s | avg %s MH/s (%s samples) | GPU %s | %s\n' \
    "$(fmt_time "$e")" "$(fmt_time "$TEST")" "$pct" "$(fmt_time "$remain")" "${h:-0}" "$avg" "$n" "${gpu:-n/a}" "$ar"
  (( e >= TEST )) && break
  sleep "$STEP"
done

read -r avg min max n <<<"$(stats_from_samples)"
echo
echo '=== KV2-A TEST RESULT ==='
echo "Samples:       $n"
echo "Hashrate avg:  $avg MH/s"
echo "Hashrate min:  $min MH/s"
echo "Hashrate max:  $max MH/s"
echo "Final GPU:     $(gpu_line)"
echo "Final shares:  $(ar_line)"
echo "Build info:"
cat /hive/miners/custom/PepeW-Miner/BUILD_INFO.txt 2>/dev/null || echo 'BUILD_INFO.txt not found'
