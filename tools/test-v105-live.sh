#!/usr/bin/env bash
set -u

NAME="${PEPEW_NAME:-PepeW-Miner-v1.0.5-HiveOS}"
DIR="/hive/miners/custom/${NAME}"
LOG_ROOT="/var/log/miner/custom/${NAME}"
EXPECTED_GPU_COUNT="${PEPEW_EXPECTED_GPU_COUNT:-$(nvidia-smi -L 2>/dev/null | grep -c '^GPU ' || true)}"
[[ "${EXPECTED_GPU_COUNT}" =~ ^[0-9]+$ ]] || EXPECTED_GPU_COUNT=0

failures=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; failures=$((failures+1)); }

printf '%s\n' '===== PepeW Miner v1.0.5 live validation ====='
printf 'package=%s\nexpected_gpus=%s\n' "$DIR" "$EXPECTED_GPU_COUNT"

[[ -d "$DIR" ]] && pass "package directory" || fail "package directory missing"
for file in h-manifest.conf h-config.sh h-run.sh h-stats.sh console-monitor.sh pepepowminer stratum-replay-proxy.py; do
  [[ -s "$DIR/$file" ]] && pass "$file" || fail "missing $file"
done

if [[ -s "$DIR/pepepowminer.sha256" ]]; then
  (cd "$DIR" && sha256sum -c pepepowminer.sha256) && pass "binary SHA256" || fail "binary SHA256"
else
  fail "pepepowminer.sha256 missing"
fi

version="$($DIR/pepepowminer --version 2>&1 | head -n1 || true)"
printf 'binary=%s\n' "$version"
grep -Fq '1.0.5' <<<"$version" && pass "binary version" || fail "binary version"

printf '%s\n' '----- detected CUDA devices -----'
"$DIR/pepepowminer" --list-gpu 2>&1 || fail "GPU listing"

miner_count="$(pgrep -x pepepowminer 2>/dev/null | wc -l | tr -d ' ')"
proxy_count="$(pgrep -f '[s]tratum-replay-proxy.py' 2>/dev/null | wc -l | tr -d ' ')"
printf 'miner_processes=%s\nproxy_processes=%s\n' "$miner_count" "$proxy_count"

if (( EXPECTED_GPU_COUNT > 0 )); then
  [[ "$miner_count" == "$EXPECTED_GPU_COUNT" ]] && pass "one miner per GPU" || fail "expected ${EXPECTED_GPU_COUNT} miner processes, found ${miner_count}"
  [[ "$proxy_count" == "$EXPECTED_GPU_COUNT" ]] && pass "one proxy per GPU" || fail "expected ${EXPECTED_GPU_COUNT} proxies, found ${proxy_count}"
fi

for ((i=0; i<EXPECTED_GPU_COUNT; ++i)); do
  status="$DIR/gpu${i}/miner-status.env"
  if [[ -s "$status" ]]; then
    hps="$(sed -n 's/^HPS=//p' "$status" | tail -n1)"
    accepted="$(sed -n 's/^ACCEPTED=//p' "$status" | tail -n1)"
    rejected="$(sed -n 's/^REJECTED=//p' "$status" | tail -n1)"
    updated="$(sed -n 's/^UPDATED_EPOCH=//p' "$status" | tail -n1)"
    printf 'GPU%s HPS=%s A=%s R=%s UPDATED=%s\n' "$i" "${hps:-0}" "${accepted:-0}" "${rejected:-0}" "${updated:-0}"
    [[ "${hps:-0}" =~ ^[1-9][0-9]*$ ]] && pass "GPU${i} hashrate" || fail "GPU${i} hashrate missing"
  else
    fail "GPU${i} status missing"
  fi
done

telemetry="$(bash -c 'source "$1"; printf "TOTAL_KHS=%s\nSTATS=%s\n" "$khs" "$stats"' _ "$DIR/h-stats.sh" 2>&1 || true)"
printf '%s\n' "$telemetry"
total_khs="$(sed -n 's/^TOTAL_KHS=//p' <<<"$telemetry" | tail -n1)"
[[ "${total_khs:-0}" =~ ^[1-9][0-9]*$ ]] && pass "aggregate hashrate" || fail "aggregate hashrate missing"
grep -Fq '"ver":"1.0.5"' <<<"$telemetry" && pass "telemetry version" || fail "telemetry version"

printf '%s\n' '----- last events -----'
for ((i=0; i<EXPECTED_GPU_COUNT; ++i)); do
  printf '[GPU %s]\n' "$i"
  grep -aE '^\[(MINING|ACCEPTED|REJECTED|ERROR)\]' "$LOG_ROOT/gpu${i}/pepew.log" 2>/dev/null | tail -n 12 || true
done

printf '%s\n' '----- GPU state -----'
nvidia-smi --query-gpu=index,pci.bus_id,name,temperature.gpu,fan.speed,power.draw,clocks.current.graphics,clocks.current.memory --format=csv,noheader 2>/dev/null || true

printf '%s\n' '----- NVIDIA Xid -----'
xid="$(dmesg 2>/dev/null | grep -E 'NVRM: Xid|Xid \(' | tail -n 20 || true)"
if [[ -z "$xid" ]]; then
  pass "no NVIDIA Xid in current dmesg"
else
  printf '%s\n' "$xid"
  fail "NVIDIA Xid detected"
fi

if (( failures == 0 )); then
  echo 'PEPEW_V105_LIVE_GATE=PASS'
  exit 0
fi

echo "PEPEW_V105_LIVE_GATE=FAIL failures=${failures}"
exit 1
