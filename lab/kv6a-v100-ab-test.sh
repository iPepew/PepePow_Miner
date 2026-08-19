#!/usr/bin/env bash
set -Eeuo pipefail

URL="${PEPEW_KV6A_URL:-https://github.com/iPepew/PepePow_Miner/releases/download/hiveos-v100-kv6a-test/PepeW-Miner-HiveOS.tar.gz}"
MINERDIR="${PEPEW_MINER_DIR:-/hive/miners/custom/PepeW-Miner}"
LOG="${PEPEW_LOG:-/var/log/miner/custom/PepeW-Miner/pepew.log}"
BASELINE="${PEPEW_BASELINE_MHS:-10.212}"
MIN_GAIN_PCT="${PEPEW_MIN_GAIN_PCT:-1.0}"
WAIT_ASSET="${PEPEW_WAIT_ASSET_SECONDS:-900}"
ASSET_STEP="${PEPEW_ASSET_PROGRESS_SECONDS:-10}"
WAIT_ONLINE="${PEPEW_WAIT_ONLINE_SECONDS:-120}"
WARMUP="${PEPEW_WARMUP_SECONDS:-30}"
TEST="${PEPEW_TEST_SECONDS:-300}"
STEP="${PEPEW_PROGRESS_SECONDS:-5}"
TMP="$(mktemp -d /tmp/pepew-kv6a-ab.XXXXXX)"
SAMPLES="$TMP/samples.txt"
BACKUP="${MINERDIR}.backup.kv6a.$(date +%Y%m%d-%H%M%S)"
BUILD=""

fmt_time(){ printf '%02d:%02d' "$(( $1/60 ))" "$(( $1%60 ))"; }
latest_line(){ grep -a '^\[MINING\]' "$LOG" 2>/dev/null | tail -1 || true; }
latest_hash(){ latest_line | awk '{for(i=1;i<=NF;i++)if($i=="MH/s"){print $(i-1);exit}}'; }
gpu_line(){ nvidia-smi --query-gpu=temperature.gpu,power.draw,power.limit,utilization.gpu,clocks.current.graphics,clocks.current.memory,memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 || true; }
stats(){ awk 'NF{sum+=$1;if(!n||$1<min)min=$1;if(!n||$1>max)max=$1;n++}END{if(n)printf "%.3f %.3f %.3f %d",sum/n,min,max,n;else printf "0 0 0 0"}' "$SAMPLES"; }

ar_line(){
  local line a r rec state
  line="$(latest_line)"
  a="$(sed -n 's/.*| A \([0-9][0-9]*\) |.*/\1/p' <<<"$line")"
  r="$(sed -n 's/.*| R \([0-9][0-9]*\) |.*/\1/p' <<<"$line")"
  rec="$(sed -n 's/.*| REC \([0-9][0-9]*\) |.*/\1/p' <<<"$line")"
  state="$(sed -n 's/.*| STATE \([^ |][^ |]*\).*/\1/p' <<<"$line")"
  printf '%s %s %s %s' "${a:-0}" "${r:-0}" "${rec:-0}" "${state:-unknown}"
}

countdown(){
  local label="$1" total="$2" e r
  for ((e=0;e<total;e+=STEP)); do
    r=$((total-e)); ((r<0)) && r=0
    printf '[%s] elapsed %s / %s | remaining %s\n' "$label" "$(fmt_time "$e")" "$(fmt_time "$total")" "$(fmt_time "$r")"
    sleep "$STEP"
  done
}

rollback(){
  echo
  echo '=== ROLLBACK ==='
  miner stop || true
  countdown STOP 15
  rm -rf "$MINERDIR"
  if [[ -d "$BACKUP" ]]; then
    mv "$BACKUP" "$MINERDIR"
    chmod +x "$MINERDIR/pepepowminer" "$MINERDIR/h-run.sh" "$MINERDIR/h-config.sh" "$MINERDIR/h-stats.sh" 2>/dev/null || true
    miner start || true
    echo "Rollback complete: restored $MINERDIR"
  else
    echo "ERROR: missing backup $BACKUP"
  fi
}
trap 'rm -rf "$TMP"' EXIT

echo '============================================================'
echo 'PEPEW TESLA V100 KV6-A WORD-PIPELINE A/B TEST'
echo '============================================================'
echo "Asset:       $URL"
echo "Miner dir:   $MINERDIR"
echo "Baseline:    $BASELINE MH/s (KV4-A)"
echo "Min gain:    $MIN_GAIN_PCT %"
echo "Asset wait:  $(fmt_time "$WAIT_ASSET")"
echo "Wait online: $(fmt_time "$WAIT_ONLINE")"
echo "Warmup:      $(fmt_time "$WARMUP")"
echo "Measure:     $(fmt_time "$TEST")"
echo "Heartbeat:   ${STEP}s"
echo "GPU before:  $(gpu_line)"
echo

[[ -d "$MINERDIR" ]] || { echo "FAIL: miner dir missing: $MINERDIR"; exit 2; }

echo '=== [1/8] WAIT FOR + DOWNLOAD KV6-A ==='
READY=0
for ((e=0;e<=WAIT_ASSET;e+=ASSET_STEP)); do
  r=$((WAIT_ASSET-e)); ((r<0)) && r=0
  if wget -q --spider "$URL"; then
    READY=1
    printf '[ASSET] elapsed %s / %s | remaining %s | READY\n' "$(fmt_time "$e")" "$(fmt_time "$WAIT_ASSET")" "$(fmt_time "$r")"
    break
  fi
  printf '[ASSET] elapsed %s / %s | remaining %s | waiting for GitHub Actions release asset\n' "$(fmt_time "$e")" "$(fmt_time "$WAIT_ASSET")" "$(fmt_time "$r")"
  ((e>=WAIT_ASSET)) && break
  sleep "$ASSET_STEP"
done
((READY)) || { echo 'FAIL: KV6-A asset not published in time. No miner files changed.'; exit 2; }

wget -O "$TMP/PepeW-Miner-HiveOS.tar.gz" "$URL"
tar -xzf "$TMP/PepeW-Miner-HiveOS.tar.gz" -C "$TMP"
INFO="$TMP/PepeW-Miner/BUILD_INFO.txt"
[[ -x "$TMP/PepeW-Miner/pepepowminer" ]] || { echo 'FAIL: package executable missing'; exit 2; }
BUILD="$(sed -n 's/^version=//p' "$INFO" | head -1)"
echo "Downloaded build: ${BUILD:-unknown}"
[[ "$BUILD" == v100-kv6a-word-t* ]] || { echo "FAIL: wrong build: $BUILD"; exit 2; }
grep -Fx 'matrix_storage=constant-32k' "$INFO"
grep -Fx 'word_pipeline=uint32x8' "$INFO"
grep -Fx 'target_compare=be-wordwise' "$INFO"
grep -Fx 'byte_materialization=diagnostics-or-share-hit-only' "$INFO"
grep -Fx 'consensus=strict-fp64' "$INFO"
echo '[PACKAGE] identity PASS'

echo '=== [2/8] STOP CURRENT MINER ==='
miner stop || true
countdown STOP 15

echo '=== [3/8] BACKUP + INSTALL ==='
mv "$MINERDIR" "$BACKUP"
mv "$TMP/PepeW-Miner" "$MINERDIR"
chmod +x "$MINERDIR/pepepowminer" "$MINERDIR/h-run.sh" "$MINERDIR/h-config.sh" "$MINERDIR/h-stats.sh"
[[ -f "$BACKUP/config.txt" ]] && cp -f "$BACKUP/config.txt" "$MINERDIR/config.txt"
echo "Backup: $BACKUP"
cat "$MINERDIR/BUILD_INFO.txt"

echo '=== [4/8] START KV6-A ==='
rm -f "$LOG" 2>/dev/null || true
miner start

echo '=== [5/8] WAIT FOR KAT + ONLINE ==='
KAT=0; ONLINE=0
for ((e=0;e<=WAIT_ONLINE;e+=STEP)); do
  k="$(grep -a -E 'Consensus KAT: PASS|HooHashV110 CUDA consensus self-test: PASS' "$LOG" 2>/dev/null | tail -1 || true)"
  l="$(latest_line)"; h="$(latest_hash)"; r=$((WAIT_ONLINE-e)); ((r<0)) && r=0
  [[ -n "$k" ]] && KAT=1
  if [[ "$l" == *'STATE online'* ]] && [[ -n "$h" ]] && awk -v x="$h" 'BEGIN{exit !(x>0)}'; then ONLINE=1; fi
  printf '[START] elapsed %s / %s | remaining %s | KAT %s | online %s | last %s MH/s | GPU %s\n' \
    "$(fmt_time "$e")" "$(fmt_time "$WAIT_ONLINE")" "$(fmt_time "$r")" \
    "$([[ $KAT -eq 1 ]] && echo PASS || echo waiting)" "$([[ $ONLINE -eq 1 ]] && echo yes || echo no)" "${h:-0}" "$(gpu_line)"
  ((KAT&&ONLINE)) && break
  ((e>=WAIT_ONLINE)) && break
  sleep "$STEP"
done
if ((!KAT||!ONLINE)); then
  echo 'FAIL: KAT/online gate failed'
  tail -120 "$LOG" 2>/dev/null || true
  rollback
  exit 3
fi

echo '=== [6/8] WARMUP ==='
for ((e=0;e<=WARMUP;e+=STEP)); do
  h="$(latest_hash)"; read -r a rj rec state <<<"$(ar_line)"; r=$((WARMUP-e)); ((r<0)) && r=0
  printf '[WARMUP] elapsed %s / %s | remaining %s | %s MH/s | A/R %s/%s | REC %s | %s | GPU %s\n' \
    "$(fmt_time "$e")" "$(fmt_time "$WARMUP")" "$(fmt_time "$r")" "${h:-0}" "$a" "$rj" "$rec" "$state" "$(gpu_line)"
  ((e>=WARMUP)) && break
  sleep "$STEP"
done

echo '=== [7/8] MEASURE ==='
: > "$SAMPLES"
for ((e=0;e<=TEST;e+=STEP)); do
  h="$(latest_hash)"
  if [[ -n "$h" ]] && awk -v x="$h" 'BEGIN{exit !(x>0)}'; then echo "$h" >> "$SAMPLES"; fi
  read -r avg min max n <<<"$(stats)"
  read -r a rj rec state <<<"$(ar_line)"
  r=$((TEST-e)); ((r<0)) && r=0; pct=$((TEST>0?e*100/TEST:100)); ((pct>100))&&pct=100
  printf '[MEASURE] %s / %s | %3d%% | remaining %s | last %s MH/s | avg %s | min %s | max %s | n %s | A/R %s/%s | REC %s | %s | GPU %s\n' \
    "$(fmt_time "$e")" "$(fmt_time "$TEST")" "$pct" "$(fmt_time "$r")" "${h:-0}" "$avg" "$min" "$max" "$n" "$a" "$rj" "$rec" "$state" "$(gpu_line)"
  ((e>=TEST)) && break
  sleep "$STEP"
done

read -r avg min max n <<<"$(stats)"
read -r a rj rec state <<<"$(ar_line)"
required="$(awk -v b="$BASELINE" -v g="$MIN_GAIN_PCT" 'BEGIN{printf "%.3f",b*(1+g/100)}')"
gain="$(awk -v a="$avg" -v b="$BASELINE" 'BEGIN{if(b>0)printf "%.2f",(a/b-1)*100;else print "0.00"}')"

echo '=== [8/8] RESULT ==='
echo "Build:      $BUILD"
echo "Baseline:   $BASELINE MH/s"
echo "Required:   $required MH/s (${MIN_GAIN_PCT}% minimum gain)"
echo "Average:    $avg MH/s"
echo "Minimum:    $min MH/s"
echo "Maximum:    $max MH/s"
echo "Samples:    $n"
echo "Gain:       $gain %"
echo "Shares A/R: $a/$rj"
echo "Reconnects: $rec"
echo "State:      $state"
echo "GPU final:  $(gpu_line)"
echo "Backup:     $BACKUP"

PERF_OK=0
awk -v a="$avg" -v req="$required" 'BEGIN{exit !(a>=req)}' && PERF_OK=1
if [[ "$state" != online ]] || ((rj>0)) || ((rec>1)) || ((!PERF_OK)); then
  echo 'KV6-A VERDICT: REJECT -> restoring KV4-A baseline'
  ((!PERF_OK)) && echo "Reason: average $avg MH/s is below required $required MH/s"
  ((rj>0)) && echo "Reason: rejected shares = $rj"
  ((rec>1)) && echo "Reason: reconnects = $rec"
  [[ "$state" != online ]] && echo "Reason: final state = $state"
  rollback
  exit 5
fi

echo 'KV6-A VERDICT: PASS -> keeping candidate installed'
echo 'Next gate: 20-minute soak + real accepted-share validation.'
