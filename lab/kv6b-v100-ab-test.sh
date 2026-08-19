#!/usr/bin/env bash
set -Eeuo pipefail

URL="${PEPEW_KV6B_URL:-https://github.com/iPepew/PepePow_Miner/releases/download/hiveos-v100-kv6b-test/PepeW-Miner-HiveOS.tar.gz}"
MINERDIR="${PEPEW_MINER_DIR:-/hive/miners/custom/PepeW-Miner}"
LOG="${PEPEW_LOG:-/var/log/miner/custom/PepeW-Miner/pepew.log}"
BASELINE="${PEPEW_BASELINE_MHS:-10.212}"
MIN_GAIN_PCT="${PEPEW_MIN_GAIN_PCT:-1.0}"
WAIT_ASSET="${PEPEW_WAIT_ASSET_SECONDS:-900}"
WAIT_ONLINE="${PEPEW_WAIT_ONLINE_SECONDS:-120}"
WARMUP="${PEPEW_WARMUP_SECONDS:-30}"
TEST="${PEPEW_TEST_SECONDS:-300}"
STEP="${PEPEW_PROGRESS_SECONDS:-5}"
TMP="$(mktemp -d /tmp/pepew-kv6b-ab.XXXXXX)"
SAMPLES="$TMP/samples.txt"
BACKUP="${MINERDIR}.backup.kv6b.$(date +%Y%m%d-%H%M%S)"
KEEP=0

fmt(){ printf '%02d:%02d' "$(( $1/60 ))" "$(( $1%60 ))"; }
latest(){ grep -a '^\[MINING\]' "$LOG" 2>/dev/null | tail -1 || true; }
hash(){ latest | awk '{for(i=1;i<=NF;i++)if($i=="MH/s"){print $(i-1);exit}}'; }
gpu(){ nvidia-smi --query-gpu=temperature.gpu,power.draw,power.limit,utilization.gpu,clocks.current.graphics,clocks.current.memory,memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 || true; }

rollback(){
  if (( KEEP )); then return; fi
  echo
  echo '=== ROLLBACK ==='
  miner stop || true
  for i in 1 2 3; do printf '[STOP] elapsed %s / 00:15 | remaining %s\n' "$(fmt $((i*5)))" "$(fmt $((15-i*5)))"; sleep 5; done
  rm -rf "$MINERDIR"
  if [ -d "$BACKUP" ]; then mv "$BACKUP" "$MINERDIR"; fi
  chmod +x "$MINERDIR/pepepowminer" "$MINERDIR/h-run.sh" "$MINERDIR/h-config.sh" "$MINERDIR/h-stats.sh" 2>/dev/null || true
  miner start || true
  echo "Rollback complete: restored $MINERDIR"
}
trap rollback EXIT

printf '%s\n' '============================================================'
printf '%s\n' 'PEPEW TESLA V100 KV6-B FP64 PREDICATE A/B TEST'
printf '%s\n' '============================================================'
echo "Asset:       $URL"
echo "Miner dir:   $MINERDIR"
echo "Baseline:    $BASELINE MH/s (KV4-A)"
echo "Min gain:    $MIN_GAIN_PCT %"
echo "Asset wait:  $(fmt "$WAIT_ASSET")"
echo "Wait online: $(fmt "$WAIT_ONLINE")"
echo "Warmup:      $(fmt "$WARMUP")"
echo "Measure:     $(fmt "$TEST")"
echo "Heartbeat:   ${STEP}s"
echo "GPU before:  $(gpu)"

echo
echo '=== [1/8] WAIT FOR + DOWNLOAD KV6-B ==='
asset="$TMP/PepeW-Miner-HiveOS.tar.gz"
ready=0
for ((e=0;e<=WAIT_ASSET;e+=10)); do
  left=$((WAIT_ASSET-e)); ((left<0)) && left=0
  if wget -q --no-cache -O "$asset" "$URL" 2>/dev/null && [ -s "$asset" ]; then
    echo "[ASSET] elapsed $(fmt "$e") / $(fmt "$WAIT_ASSET") | remaining $(fmt "$left") | READY"
    ready=1
    break
  fi
  printf '[ASSET] elapsed %s / %s | remaining %s | waiting for GitHub Actions release asset\n' "$(fmt "$e")" "$(fmt "$WAIT_ASSET")" "$(fmt "$left")"
  sleep 10
done
if (( ! ready )); then echo 'FAIL: KV6-B asset was not published within wait window'; exit 1; fi

mkdir -p "$TMP/unpack"
tar -xzf "$asset" -C "$TMP/unpack"
info="$TMP/unpack/PepeW-Miner/BUILD_INFO.txt"
manifest="$TMP/unpack/PepeW-Miner/h-manifest.conf"
test -s "$info" && test -s "$manifest"
cat "$info"
grep -F 'kernel=kv6b-exact-sw-predicate-t256' "$info"
grep -F 'sw_state=boolean-exact-positive-fp64' "$info"
grep -F 'zero_nibble=skip-exact' "$info"
grep -F 'consensus=strict-fp64' "$info"
echo '[PACKAGE] identity PASS'

echo
echo '=== [2/8] STOP CURRENT MINER ==='
miner stop || true
for ((e=0;e<15;e+=5)); do printf '[STOP] elapsed %s / 00:15 | remaining %s\n' "$(fmt "$e")" "$(fmt $((15-e)))"; sleep 5; done

echo
echo '=== [3/8] BACKUP + INSTALL ==='
if [ -d "$MINERDIR" ]; then mv "$MINERDIR" "$BACKUP"; fi
mv "$TMP/unpack/PepeW-Miner" "$MINERDIR"
chmod +x "$MINERDIR/pepepowminer" "$MINERDIR/h-run.sh" "$MINERDIR/h-config.sh" "$MINERDIR/h-stats.sh"
echo "Backup: $BACKUP"
echo 'Installed:'
cat "$MINERDIR/BUILD_INFO.txt"

echo
echo '=== [4/8] START KV6-B ==='
: > "$LOG" 2>/dev/null || true
miner start

echo
echo '=== [5/8] WAIT FOR KAT + ONLINE ==='
online=0
kat=0
for ((e=0;e<=WAIT_ONLINE;e+=5)); do
  line="$(latest)"
  hv="$(hash)"; hv="${hv:-0}"
  if grep -a -E 'KAT.*PASS|consensus.*PASS|HooHashV110 CUDA consensus self-test: PASS' "$LOG" >/dev/null 2>&1; then kat=1; fi
  [[ "$line" == *'STATE online'* ]] && online=1
  printf '[START] elapsed %s / %s | remaining %s | KAT %s | online %s | last %s MH/s | GPU %s\n' \
    "$(fmt "$e")" "$(fmt "$WAIT_ONLINE")" "$(fmt $((WAIT_ONLINE-e)))" \
    "$([ $kat -eq 1 ] && echo PASS || echo waiting)" "$([ $online -eq 1 ] && echo yes || echo no)" "$hv" "$(gpu)"
  if (( kat && online )); then break; fi
  sleep 5
done
if (( !kat || !online )); then echo 'FAIL: KV6-B did not reach KAT PASS + online'; tail -100 "$LOG" || true; exit 1; fi

echo
echo '=== [6/8] WARMUP ==='
for ((e=0;e<=WARMUP;e+=STEP)); do
  line="$(latest)"; hv="$(hash)"; hv="${hv:-0}"
  printf '[WARMUP] elapsed %s / %s | remaining %s | %s MH/s | %s | GPU %s\n' \
    "$(fmt "$e")" "$(fmt "$WARMUP")" "$(fmt $((WARMUP-e)))" "$hv" "${line#*MH/s | }" "$(gpu)"
  (( e==WARMUP )) || sleep "$STEP"
done

echo
echo '=== [7/8] MEASURE ==='
: > "$SAMPLES"
for ((e=0;e<=TEST;e+=STEP)); do
  line="$(latest)"; hv="$(hash)"; hv="${hv:-0}"
  if awk -v x="$hv" 'BEGIN{exit !(x>0)}'; then echo "$hv" >> "$SAMPLES"; fi
  read -r avg min max n < <(awk 'NF{sum+=$1;if(!n||$1<min)min=$1;if(!n||$1>max)max=$1;n++}END{if(n)printf "%.3f %.3f %.3f %d",sum/n,min,max,n;else print "0 0 0 0"}' "$SAMPLES")
  a="$(sed -n 's/.*| A \([0-9][0-9]*\) |.*/\1/p' <<<"$line")"; a="${a:-0}"
  r="$(sed -n 's/.*| R \([0-9][0-9]*\) |.*/\1/p' <<<"$line")"; r="${r:-0}"
  rec="$(sed -n 's/.*| REC \([0-9][0-9]*\) |.*/\1/p' <<<"$line")"; rec="${rec:-0}"
  pct=$(( e*100/TEST )); ((e>TEST)) && pct=100
  printf '[MEASURE] %s / %s | %3d%% | remaining %s | last %s MH/s | avg %s | min %s | max %s | n %s | A/R %s/%s | REC %s | GPU %s\n' \
    "$(fmt "$e")" "$(fmt "$TEST")" "$pct" "$(fmt $((TEST-e)))" "$hv" "$avg" "$min" "$max" "$n" "$a" "$r" "$rec" "$(gpu)"
  (( e==TEST )) || sleep "$STEP"
done

read -r AVG MIN MAX N < <(awk 'NF{sum+=$1;if(!n||$1<min)min=$1;if(!n||$1>max)max=$1;n++}END{if(n)printf "%.3f %.3f %.3f %d",sum/n,min,max,n;else print "0 0 0 0"}' "$SAMPLES")
REQ="$(awk -v b="$BASELINE" -v g="$MIN_GAIN_PCT" 'BEGIN{printf "%.3f",b*(1+g/100)}')"
GAIN="$(awk -v a="$AVG" -v b="$BASELINE" 'BEGIN{printf "%.2f",(a/b-1)*100}')"
line="$(latest)"
a="$(sed -n 's/.*| A \([0-9][0-9]*\) |.*/\1/p' <<<"$line")"; a="${a:-0}"
r="$(sed -n 's/.*| R \([0-9][0-9]*\) |.*/\1/p' <<<"$line")"; r="${r:-0}"
rec="$(sed -n 's/.*| REC \([0-9][0-9]*\) |.*/\1/p' <<<"$line")"; rec="${rec:-0}"

echo
echo '=== [8/8] RESULT ==='
echo "Build:       $(sed -n 's/^version=//p' "$MINERDIR/BUILD_INFO.txt")"
echo "Baseline:    $BASELINE MH/s"
echo "Required:    $REQ MH/s (${MIN_GAIN_PCT}% minimum gain)"
echo "Average:     $AVG MH/s"
echo "Minimum:     $MIN MH/s"
echo "Maximum:     $MAX MH/s"
echo "Samples:     $N"
echo "Gain:        $GAIN %"
echo "Shares A/R:  $a/$r"
echo "Reconnects:  $rec"
echo "GPU final:   $(gpu)"
echo "Backup:      $BACKUP"

if awk -v a="$AVG" -v r="$REQ" 'BEGIN{exit !(a>=r)}'; then
  echo 'KV6-B VERDICT: PASS -> keeping candidate installed'
  KEEP=1
  trap - EXIT
  exit 0
else
  echo "KV6-B VERDICT: REJECT -> restoring KV4-A baseline"
  echo "Reason: average $AVG MH/s is below required $REQ MH/s"
  exit 2
fi
