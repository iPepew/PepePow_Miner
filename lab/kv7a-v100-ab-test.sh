#!/usr/bin/env bash
set -Eeuo pipefail

URL="${PEPEW_KV7A_URL:-https://github.com/iPepew/PepePow_Miner/releases/download/hiveos-v100-kv7a-test/PepeW-Miner-HiveOS.tar.gz}"
MINERDIR="${PEPEW_MINER_DIR:-/hive/miners/custom/PepeW-Miner}"
LOG="${PEPEW_LOG:-/var/log/miner/custom/PepeW-Miner/pepew.log}"
BASELINE="${PEPEW_BASELINE_MHS:-9.83}"
KEEP_THRESHOLD="${PEPEW_KEEP_MHS:-11.80}"
WAIT_ASSET="${PEPEW_WAIT_ASSET_SECONDS:-900}"
WAIT_ONLINE="${PEPEW_WAIT_ONLINE_SECONDS:-150}"
WARMUP="${PEPEW_WARMUP_SECONDS:-30}"
TEST="${PEPEW_TEST_SECONDS:-300}"
STEP="${PEPEW_PROGRESS_SECONDS:-5}"
TMP="$(mktemp -d /tmp/pepew-kv7a.XXXXXX)"
SAMPLES="$TMP/samples.txt"
BACKUP="${MINERDIR}.backup.kv7a.$(date +%Y%m%d-%H%M%S)"
KEEP=0
INSTALLED=0

fmt(){ printf '%02d:%02d' "$(( $1/60 ))" "$(( $1%60 ))"; }
latest(){ grep -a '^\[MINING\]' "$LOG" 2>/dev/null | tail -1 || true; }
hash(){ latest | awk '{for(i=1;i<=NF;i++)if($i=="MH/s"){print $(i-1);exit}}'; }
gpu(){ nvidia-smi --query-gpu=temperature.gpu,power.draw,power.limit,utilization.gpu,clocks.current.graphics,clocks.current.memory,memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 || true; }
stats(){ awk 'NF{sum+=$1;if(!n||$1<min)min=$1;if(!n||$1>max)max=$1;n++}END{if(n)printf "%.3f %.3f %.3f %d",sum/n,min,max,n;else printf "0 0 0 0"}' "$SAMPLES"; }

ar(){
  local line a r rec state
  line="$(latest)"
  a="$(sed -n 's/.*| A \([0-9][0-9]*\) |.*/\1/p' <<<"$line")"
  r="$(sed -n 's/.*| R \([0-9][0-9]*\) |.*/\1/p' <<<"$line")"
  rec="$(sed -n 's/.*| REC \([0-9][0-9]*\) |.*/\1/p' <<<"$line")"
  state="$(sed -n 's/.*| STATE \([^ |][^ |]*\).*/\1/p' <<<"$line")"
  printf '%s %s %s %s' "${a:-0}" "${r:-0}" "${rec:-0}" "${state:-unknown}"
}

rollback(){
  (( KEEP )) && return 0
  (( INSTALLED )) || return 0
  echo
  echo '=== ROLLBACK TO PREVIOUS PEPEW ==='
  miner stop || true
  sleep 8
  rm -rf "$MINERDIR"
  if [[ -d "$BACKUP" ]]; then
    mv "$BACKUP" "$MINERDIR"
    chmod +x "$MINERDIR/pepepowminer" "$MINERDIR/h-run.sh" "$MINERDIR/h-config.sh" "$MINERDIR/h-stats.sh" 2>/dev/null || true
    miner start || true
    echo "Restored: $MINERDIR"
  else
    echo "WARNING: backup not found: $BACKUP"
  fi
}

cleanup(){
  rollback || true
  rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

cat <<EOF
============================================================
PEPEW TESLA V100 KV7-A OCCUPANCY6 A/B TEST
============================================================
Asset:        $URL
Baseline:     $BASELINE MH/s
Keep >=:      $KEEP_THRESHOLD MH/s
Geometry:     640 threads/block, R48 target, 6 nonces/thread
Full batch:   1,228,800 = 640 x 320 x 6
Cache target: PreferL1, shared carveout 0%
Warmup:       ${WARMUP}s
Measure:      ${TEST}s
GPU before:   $(gpu)
EOF

[[ -d "$MINERDIR" ]] || { echo "FAIL: miner directory missing: $MINERDIR"; exit 2; }

echo
echo '=== [1/8] WAIT FOR GITHUB ACTIONS ASSET ==='
asset="$TMP/PepeW-Miner-HiveOS.tar.gz"
ready=0
for ((e=0;e<=WAIT_ASSET;e+=10)); do
  left=$((WAIT_ASSET-e)); ((left<0)) && left=0
  if wget -q --no-cache -O "$asset" "$URL" 2>/dev/null && [[ -s "$asset" ]]; then
    echo "[ASSET] elapsed $(fmt "$e") / $(fmt "$WAIT_ASSET") | READY"
    ready=1
    break
  fi
  echo "[ASSET] elapsed $(fmt "$e") / $(fmt "$WAIT_ASSET") | remaining $(fmt "$left") | waiting"
  ((e>=WAIT_ASSET)) || sleep 10
done
(( ready )) || { echo 'FAIL: KV7-A asset not published. Existing miner was not touched.'; exit 2; }

mkdir -p "$TMP/unpack"
tar -xzf "$asset" -C "$TMP/unpack"
NEW="$TMP/unpack/PepeW-Miner"
INFO="$NEW/BUILD_INFO.txt"
[[ -x "$NEW/pepepowminer" && -s "$INFO" ]] || { echo 'FAIL: invalid package'; exit 2; }
cat "$INFO"
grep -E '^version=v100-kv7a-t640-r48-n6-' "$INFO"
grep -Fx 'cuda_threads=640' "$INFO"
grep -Fx 'cuda_max_registers=48' "$INFO"
grep -Fx 'nonces_per_thread=6' "$INFO"
grep -Fx 'batch_nonces=1228800' "$INFO"
grep -Fx 'cache=PreferL1' "$INFO"
grep -Fx 'consensus=strict-fp64' "$INFO"
echo '[PACKAGE] identity PASS'

echo
echo '=== [2/8] STOP CURRENT MINER ==='
miner stop || true
sleep 8

echo
echo '=== [3/8] BACKUP + INSTALL KV7-A ==='
mv "$MINERDIR" "$BACKUP"
mv "$NEW" "$MINERDIR"
INSTALLED=1
chmod +x "$MINERDIR/pepepowminer" "$MINERDIR/h-run.sh" "$MINERDIR/h-config.sh" "$MINERDIR/h-stats.sh"
[[ -f "$BACKUP/config.txt" ]] && cp -f "$BACKUP/config.txt" "$MINERDIR/config.txt"
echo "Backup: $BACKUP"

echo
echo '=== [4/8] START KV7-A ==='
rm -f "$LOG" 2>/dev/null || true
miner start

echo
echo '=== [5/8] KAT + ONLINE GATE ==='
kat=0; online=0
for ((e=0;e<=WAIT_ONLINE;e+=STEP)); do
  grep -a -E 'Consensus KAT: PASS|HooHashV110 CUDA consensus self-test: PASS|KAT GPU consensus=PASS' "$LOG" >/dev/null 2>&1 && kat=1 || true
  line="$(latest)"; hv="$(hash)"; hv="${hv:-0}"
  [[ "$line" == *'STATE online'* ]] && online=1
  left=$((WAIT_ONLINE-e)); ((left<0)) && left=0
  printf '[START] %s/%s | remaining %s | KAT %s | online %s | %s MH/s | GPU %s\n' \
    "$(fmt "$e")" "$(fmt "$WAIT_ONLINE")" "$(fmt "$left")" \
    "$([[ $kat -eq 1 ]] && echo PASS || echo waiting)" "$([[ $online -eq 1 ]] && echo yes || echo no)" "$hv" "$(gpu)"
  (( kat && online )) && break
  if grep -a -E 'too many resources requested|CUDA error|Fatal:|consensus self-test FAILED|KAT GPU consensus=FAIL' "$LOG" >/dev/null 2>&1; then
    echo 'FAIL: CUDA/KAT fatal detected'
    tail -120 "$LOG" || true
    exit 3
  fi
  ((e>=WAIT_ONLINE)) || sleep "$STEP"
done
if (( !kat || !online )); then
  echo 'FAIL: candidate did not reach KAT PASS + online'
  tail -140 "$LOG" || true
  exit 3
fi

echo
echo '=== [6/8] WARMUP ==='
for ((e=0;e<=WARMUP;e+=STEP)); do
  hv="$(hash)"; hv="${hv:-0}"
  read -r a r rec state <<<"$(ar)"
  printf '[WARMUP] %s/%s | %s MH/s | A/R %s/%s | REC %s | %s | GPU %s\n' \
    "$(fmt "$e")" "$(fmt "$WARMUP")" "$hv" "$a" "$r" "$rec" "$state" "$(gpu)"
  ((e>=WARMUP)) || sleep "$STEP"
done

echo
echo '=== [7/8] MEASURE ==='
: > "$SAMPLES"
for ((e=0;e<=TEST;e+=STEP)); do
  hv="$(hash)"; hv="${hv:-0}"
  if awk -v x="$hv" 'BEGIN{exit !(x>0)}'; then echo "$hv" >> "$SAMPLES"; fi
  read -r avg min max n <<<"$(stats)"
  read -r a r rec state <<<"$(ar)"
  pct=$((TEST>0?e*100/TEST:100)); ((pct>100)) && pct=100
  printf '[MEASURE] %s/%s | %3d%% | last %s | avg %s | min %s | max %s | n %s | A/R %s/%s | REC %s | GPU %s\n' \
    "$(fmt "$e")" "$(fmt "$TEST")" "$pct" "$hv" "$avg" "$min" "$max" "$n" "$a" "$r" "$rec" "$(gpu)"
  if grep -a -E 'too many resources requested|CUDA error|Fatal:|Xid' "$LOG" >/dev/null 2>&1; then
    echo 'FAIL: CUDA/runtime fatal detected during measurement'
    exit 4
  fi
  ((e>=TEST)) || sleep "$STEP"
done

read -r AVG MIN MAX N <<<"$(stats)"
read -r A R REC STATE <<<"$(ar)"
GAIN="$(awk -v a="$AVG" -v b="$BASELINE" 'BEGIN{if(b>0)printf "%.2f",(a/b-1)*100;else print "0.00"}')"

echo
echo '=== [8/8] RESULT ==='
echo "Build:       $(sed -n 's/^version=//p' "$MINERDIR/BUILD_INFO.txt" | head -1)"
echo "Baseline:    $BASELINE MH/s"
echo "Keep gate:   $KEEP_THRESHOLD MH/s"
echo "Average:     $AVG MH/s"
echo "Minimum:     $MIN MH/s"
echo "Maximum:     $MAX MH/s"
echo "Samples:     $N"
echo "Gain:        $GAIN %"
echo "Shares A/R:  $A/$R"
echo "Reconnects:  $REC"
echo "State:       $STATE"
echo "GPU final:   $(gpu)"
echo "Backup:      $BACKUP"

perf=0
awk -v a="$AVG" -v k="$KEEP_THRESHOLD" 'BEGIN{exit !(a>=k)}' && perf=1
if (( !perf )) || (( R > 0 )) || (( REC > 1 )) || [[ "$STATE" != online ]]; then
  echo 'KV7-A VERDICT: REJECT -> automatic rollback'
  (( !perf )) && echo "Reason: $AVG MH/s < $KEEP_THRESHOLD MH/s"
  (( R > 0 )) && echo "Reason: rejected shares = $R"
  (( REC > 1 )) && echo "Reason: reconnects = $REC"
  [[ "$STATE" != online ]] && echo "Reason: final state = $STATE"
  exit 5
fi

KEEP=1
trap - EXIT INT TERM
rm -rf "$TMP"
echo 'KV7-A VERDICT: PASS -> candidate kept installed'
echo 'Send the RESULT block plus the GPU lines to ChatGPT.'
