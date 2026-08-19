#!/usr/bin/env bash
set -Eeuo pipefail

# PepeW Tesla V100 KV4-A one-command A/B test for HiveOS.
# It waits visibly for the rolling asset, installs it, verifies identity/KAT,
# measures live hashrate with a heartbeat, and rolls back automatically on a
# correctness failure or performance regression.

URL="${PEPEW_KV4A_URL:-https://github.com/iPepew/PepePow_Miner/releases/download/hiveos-v100-kv4a-test/PepeW-Miner-HiveOS.tar.gz}"
MINERDIR="${PEPEW_MINER_DIR:-/hive/miners/custom/PepeW-Miner}"
LOG="${PEPEW_LOG:-/var/log/miner/custom/PepeW-Miner/pepew.log}"
BASELINE="${PEPEW_BASELINE_MHS:-10.086}"
MIN_GAIN_PCT="${PEPEW_MIN_GAIN_PCT:-1.0}"
WAIT_ASSET="${PEPEW_WAIT_ASSET_SECONDS:-600}"
ASSET_STEP="${PEPEW_ASSET_PROGRESS_SECONDS:-10}"
WAIT_ONLINE="${PEPEW_WAIT_ONLINE_SECONDS:-90}"
WARMUP="${PEPEW_WARMUP_SECONDS:-30}"
TEST="${PEPEW_TEST_SECONDS:-300}"
STEP="${PEPEW_PROGRESS_SECONDS:-5}"
TMP="$(mktemp -d /tmp/pepew-kv4a-ab.XXXXXX)"
SAMPLES="$TMP/samples.txt"
BACKUP="${MINERDIR}.backup.kv4a.$(date +%Y%m%d-%H%M%S)"
NEW_BUILD=""

fmt_time() {
  local s="$1"
  printf '%02d:%02d' "$((s/60))" "$((s%60))"
}

latest_line() {
  grep -a '^\[MINING\]' "$LOG" 2>/dev/null | tail -1 || true
}

latest_hash() {
  latest_line | awk '{for(i=1;i<=NF;i++) if($i=="MH/s"){print $(i-1); exit}}'
}

gpu_line() {
  nvidia-smi \
    --query-gpu=temperature.gpu,power.draw,power.limit,utilization.gpu,clocks.current.graphics,clocks.current.memory,memory.used \
    --format=csv,noheader,nounits 2>/dev/null | head -1 || true
}

ar_line() {
  local line a r rec state
  line="$(latest_line)"
  a="$(sed -n 's/.*| A \([0-9][0-9]*\) |.*/\1/p' <<<"$line")"
  r="$(sed -n 's/.*| R \([0-9][0-9]*\) |.*/\1/p' <<<"$line")"
  rec="$(sed -n 's/.*| REC \([0-9][0-9]*\) |.*/\1/p' <<<"$line")"
  state="$(sed -n 's/.*| STATE \([^ |][^ |]*\).*/\1/p' <<<"$line")"
  printf '%s %s %s %s' "${a:-0}" "${r:-0}" "${rec:-0}" "${state:-unknown}"
}

stats_from_samples() {
  awk '
    NF {sum+=$1; if(n==0||$1<min)min=$1; if(n==0||$1>max)max=$1; n++}
    END {if(n) printf "%.3f %.3f %.3f %d",sum/n,min,max,n; else printf "0 0 0 0"}
  ' "$SAMPLES"
}

countdown() {
  local label="$1" total="$2"
  local e remain
  for ((e=0; e<total; e+=STEP)); do
    remain=$((total-e)); ((remain<0)) && remain=0
    printf '[%s] elapsed %s / %s | remaining %s\n' \
      "$label" "$(fmt_time "$e")" "$(fmt_time "$total")" "$(fmt_time "$remain")"
    sleep "$STEP"
  done
}

rollback() {
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
    echo "ERROR: backup is missing: $BACKUP"
  fi
}

cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

echo '============================================================'
echo 'PEPEW TESLA V100 KV4-A CONSTANT-MATRIX A/B TEST'
echo '============================================================'
echo "Asset:       $URL"
echo "Miner dir:   $MINERDIR"
echo "Baseline:    $BASELINE MH/s"
echo "Min gain:    $MIN_GAIN_PCT %"
echo "Asset wait:  $(fmt_time "$WAIT_ASSET")"
echo "Wait online: $(fmt_time "$WAIT_ONLINE")"
echo "Warmup:      $(fmt_time "$WARMUP")"
echo "Measure:     $(fmt_time "$TEST")"
echo "Heartbeat:   ${STEP}s"
echo "GPU before:  $(gpu_line)"
echo

if [[ ! -d "$MINERDIR" ]]; then
  echo "FAIL: current miner directory does not exist: $MINERDIR"
  exit 2
fi

if [[ -e "$BACKUP" ]]; then
  echo "FAIL: backup path already exists: $BACKUP"
  exit 2
fi

echo '=== [1/8] WAIT FOR + DOWNLOAD KV4-A ==='
ASSET_READY=0
for ((e=0; e<=WAIT_ASSET; e+=ASSET_STEP)); do
  remain=$((WAIT_ASSET-e)); ((remain<0)) && remain=0
  if wget -q --spider "$URL"; then
    ASSET_READY=1
    printf '[ASSET] elapsed %s / %s | remaining %s | READY\n' \
      "$(fmt_time "$e")" "$(fmt_time "$WAIT_ASSET")" "$(fmt_time "$remain")"
    break
  fi
  printf '[ASSET] elapsed %s / %s | remaining %s | waiting for GitHub Actions release asset\n' \
    "$(fmt_time "$e")" "$(fmt_time "$WAIT_ASSET")" "$(fmt_time "$remain")"
  (( e >= WAIT_ASSET )) && break
  sleep "$ASSET_STEP"
done

if (( ! ASSET_READY )); then
  echo "FAIL: KV4-A asset was not published within $(fmt_time "$WAIT_ASSET")."
  echo 'No miner files were changed.'
  exit 2
fi

wget -O "$TMP/PepeW-Miner-HiveOS.tar.gz" "$URL"
tar -xzf "$TMP/PepeW-Miner-HiveOS.tar.gz" -C "$TMP"
if [[ ! -x "$TMP/PepeW-Miner/pepepowminer" ]]; then
  echo 'FAIL: package does not contain executable PepeW-Miner/pepepowminer'
  exit 2
fi

NEW_BUILD="$(sed -n 's/^version=//p' "$TMP/PepeW-Miner/BUILD_INFO.txt" | head -1)"
echo "Downloaded build: ${NEW_BUILD:-unknown}"
if [[ "$NEW_BUILD" != v100-kv4a-cmem-t* ]]; then
  echo "FAIL: expected v100-kv4a-cmem build, got: ${NEW_BUILD:-missing}"
  exit 2
fi
grep -Fx 'matrix_storage=constant-32k' "$TMP/PepeW-Miner/BUILD_INFO.txt"
grep -Fx 'matrix_generation=host-strict-reference' "$TMP/PepeW-Miner/BUILD_INFO.txt"
grep -Fx 'scalar_path=kv3b-strict' "$TMP/PepeW-Miner/BUILD_INFO.txt"
grep -Fx 'consensus=strict-fp64' "$TMP/PepeW-Miner/BUILD_INFO.txt"
echo '[PACKAGE] identity PASS'

echo
echo '=== [2/8] STOP CURRENT MINER ==='
miner stop || true
countdown STOP 15

echo
echo '=== [3/8] BACKUP + INSTALL ==='
mv "$MINERDIR" "$BACKUP"
mv "$TMP/PepeW-Miner" "$MINERDIR"
chmod +x "$MINERDIR/pepepowminer" "$MINERDIR/h-run.sh" "$MINERDIR/h-config.sh" "$MINERDIR/h-stats.sh"
if [[ -f "$BACKUP/config.txt" ]]; then
  cp -f "$BACKUP/config.txt" "$MINERDIR/config.txt"
fi
echo "Backup: $BACKUP"
cat "$MINERDIR/BUILD_INFO.txt"

echo
echo '=== [4/8] START KV4-A ==='
rm -f "$LOG" 2>/dev/null || true
miner start

echo
echo '=== [5/8] WAIT FOR KAT + ONLINE TELEMETRY ==='
KAT_OK=0
ONLINE=0
for ((e=0; e<=WAIT_ONLINE; e+=STEP)); do
  kat="$(grep -a -E 'Consensus KAT: PASS|HooHashV110 CUDA consensus self-test: PASS' "$LOG" 2>/dev/null | tail -1 || true)"
  line="$(latest_line)"
  h="$(latest_hash)"
  remain=$((WAIT_ONLINE-e)); ((remain<0)) && remain=0

  [[ -n "$kat" ]] && KAT_OK=1
  if [[ "$line" == *'STATE online'* ]] && [[ -n "$h" ]] && awk -v x="$h" 'BEGIN{exit !(x>0)}'; then
    ONLINE=1
  fi

  printf '[START] elapsed %s / %s | remaining %s | KAT %s | online %s | last %s MH/s | GPU %s\n' \
    "$(fmt_time "$e")" "$(fmt_time "$WAIT_ONLINE")" "$(fmt_time "$remain")" \
    "$([[ $KAT_OK -eq 1 ]] && echo PASS || echo waiting)" \
    "$([[ $ONLINE -eq 1 ]] && echo yes || echo no)" \
    "${h:-0}" "$(gpu_line)"

  if (( KAT_OK && ONLINE )); then
    break
  fi
  (( e >= WAIT_ONLINE )) && break
  sleep "$STEP"
done

if (( ! KAT_OK )); then
  echo 'FAIL: KV4-A consensus KAT did not pass.'
  tail -120 "$LOG" 2>/dev/null || true
  rollback
  exit 3
fi
if (( ! ONLINE )); then
  echo 'FAIL: KV4-A did not reach online mining state.'
  tail -120 "$LOG" 2>/dev/null || true
  rollback
  exit 4
fi
echo '[START] KAT PASS + online PASS'

echo
echo '=== [6/8] WARMUP ==='
for ((e=0; e<=WARMUP; e+=STEP)); do
  h="$(latest_hash)"
  read -r a r rec state <<<"$(ar_line)"
  remain=$((WARMUP-e)); ((remain<0)) && remain=0
  printf '[WARMUP] elapsed %s / %s | remaining %s | %s MH/s | A/R %s/%s | REC %s | %s | GPU %s\n' \
    "$(fmt_time "$e")" "$(fmt_time "$WARMUP")" "$(fmt_time "$remain")" \
    "${h:-0}" "$a" "$r" "$rec" "$state" "$(gpu_line)"
  (( e >= WARMUP )) && break
  sleep "$STEP"
done

echo
echo '=== [7/8] MEASURE ==='
: > "$SAMPLES"
for ((e=0; e<=TEST; e+=STEP)); do
  h="$(latest_hash)"
  if [[ -n "$h" ]] && awk -v x="$h" 'BEGIN{exit !(x>0)}'; then
    printf '%s\n' "$h" >> "$SAMPLES"
  fi
  read -r avg min max n <<<"$(stats_from_samples)"
  read -r a r rec state <<<"$(ar_line)"
  remain=$((TEST-e)); ((remain<0)) && remain=0
  pct=$(( TEST>0 ? e*100/TEST : 100 )); ((pct>100)) && pct=100
  printf '[MEASURE] %s / %s | %3d%% | remaining %s | last %s MH/s | avg %s | min %s | max %s | n %s | A/R %s/%s | REC %s | %s | GPU %s\n' \
    "$(fmt_time "$e")" "$(fmt_time "$TEST")" "$pct" "$(fmt_time "$remain")" \
    "${h:-0}" "$avg" "$min" "$max" "$n" "$a" "$r" "$rec" "$state" "$(gpu_line)"
  (( e >= TEST )) && break
  sleep "$STEP"
done

read -r avg min max n <<<"$(stats_from_samples)"
read -r a r rec state <<<"$(ar_line)"
required="$(awk -v b="$BASELINE" -v g="$MIN_GAIN_PCT" 'BEGIN{printf "%.3f",b*(1.0+g/100.0)}')"
gain="$(awk -v a="$avg" -v b="$BASELINE" 'BEGIN{if(b>0)printf "%.2f",(a/b-1.0)*100.0;else print "0.00"}')"

echo
echo '=== [8/8] RESULT ==='
echo "Build:          $NEW_BUILD"
echo "Baseline:       $BASELINE MH/s"
echo "Required:       $required MH/s  (${MIN_GAIN_PCT}% minimum gain)"
echo "Average:        $avg MH/s"
echo "Minimum:        $min MH/s"
echo "Maximum:        $max MH/s"
echo "Samples:        $n"
echo "Gain:           $gain %"
echo "Shares A/R:     $a/$r"
echo "Reconnects:     $rec"
echo "State:          $state"
echo "GPU final:      $(gpu_line)"
echo "Backup:         $BACKUP"

PERF_OK=0
awk -v a="$avg" -v req="$required" 'BEGIN{exit !(a>=req)}' && PERF_OK=1

if [[ "$state" != online ]] || (( r > 0 )) || (( rec > 1 )) || (( ! PERF_OK )); then
  echo
  echo 'KV4-A VERDICT: REJECT -> automatic rollback'
  if (( ! PERF_OK )); then
    echo "Reason: average $avg MH/s is below required $required MH/s"
  fi
  (( r > 0 )) && echo "Reason: rejected shares = $r"
  (( rec > 1 )) && echo "Reason: reconnects = $rec"
  [[ "$state" != online ]] && echo "Reason: final state = $state"
  rollback
  exit 5
fi

echo
echo 'KV4-A VERDICT: PASS -> keeping candidate installed'
echo 'The previous miner remains available in the backup directory printed above.'
echo 'Next step: run a 20-minute soak before promoting KV4-A to the new baseline.'
