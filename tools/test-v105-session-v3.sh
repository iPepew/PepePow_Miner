#!/usr/bin/env bash
set -u

NAME="${PEPEW_NAME:-PepeW-Miner-v1.0.5-HiveOS}"
DIR="/hive/miners/custom/${NAME}"
LOG_ROOT="/var/log/miner/custom/${NAME}"
EXPECTED_GPU_COUNT="${PEPEW_EXPECTED_GPU_COUNT:-1}"
CAPTURE_SECONDS="${PEPEW_CAPTURE_SECONDS:-600}"
SAMPLE_INTERVAL="${PEPEW_SAMPLE_INTERVAL:-2}"
STARTUP_TIMEOUT="${PEPEW_STARTUP_TIMEOUT:-180}"
FALLBACK_AFTER="${PEPEW_FALLBACK_AFTER:-20}"
PROCESS_LOSS_GRACE="${PEPEW_PROCESS_LOSS_GRACE:-20}"
STOP_AT_END="${PEPEW_STOP_AT_END:-1}"
SESSION_BASE="${PEPEW_SESSION_BASE:-/root/pepew-tests}"

[[ "$EXPECTED_GPU_COUNT" =~ ^[1-9][0-9]*$ ]] || EXPECTED_GPU_COUNT=1
[[ "$CAPTURE_SECONDS" =~ ^[1-9][0-9]*$ ]] || CAPTURE_SECONDS=600
[[ "$SAMPLE_INTERVAL" =~ ^[1-9][0-9]*$ ]] || SAMPLE_INTERVAL=2
[[ "$STARTUP_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || STARTUP_TIMEOUT=180
[[ "$FALLBACK_AFTER" =~ ^[1-9][0-9]*$ ]] || FALLBACK_AFTER=20
[[ "$PROCESS_LOSS_GRACE" =~ ^[1-9][0-9]*$ ]] || PROCESS_LOSS_GRACE=20
[[ "$STOP_AT_END" =~ ^[01]$ ]] || STOP_AT_END=1

if (( EUID != 0 )); then
  echo 'ERROR: run as root.' >&2
  exit 2
fi

now_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
status_value() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n1; }
proc_count() { pgrep "$@" 2>/dev/null | wc -l | tr -d ' '; }

stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
session_dir="${SESSION_BASE%/}/PepeW-v105-session-v3-${stamp}"
archive="${session_dir}.tar.gz"
summary="$session_dir/SUMMARY.txt"
mkdir -p "$session_dir" "$session_dir/system" "$session_dir/logs" "$session_dir/status"

start_epoch="$(date +%s)"
ready_epoch=0
process_loss_since=0
fallback_sent=0
session_result='STARTING'
finalized=0

echo 'timestamp_utc,index,name,uuid,pci_bus,temperature_c,fan_pct,power_w,power_limit_w,graphics_clock_mhz,memory_clock_mhz,util_gpu_pct,util_mem_pct,memory_used_mib,memory_total_mib,pstate' > "$session_dir/gpu-samples.csv"
echo 'timestamp_utc,gpu,hps,mhs,accepted,rejected,updated_epoch,status_age_sec,miner_pid,proxy_pid' > "$session_dir/miner-status.csv"
echo 'timestamp_utc,load1,load5,load15,mem_available_kb,miner_processes,proxy_processes' > "$session_dir/system-samples.csv"

{
  echo "SESSION_START_UTC=$(now_iso)"
  echo "EXPECTED_GPU_COUNT=$EXPECTED_GPU_COUNT"
  echo "CAPTURE_SECONDS=$CAPTURE_SECONDS"
  echo "SAMPLE_INTERVAL=$SAMPLE_INTERVAL"
  echo "STARTUP_TIMEOUT=$STARTUP_TIMEOUT"
  echo "FALLBACK_AFTER=$FALLBACK_AFTER"
  echo "PROCESS_LOSS_GRACE=$PROCESS_LOSS_GRACE"
  echo "HOSTNAME=$(hostname 2>/dev/null || true)"
  echo "KERNEL=$(uname -a 2>/dev/null || true)"
  echo "HIVE_VERSION=$(cat /etc/hiveos-version 2>/dev/null || true)"
} > "$session_dir/session.env"

nvidia-smi -L > "$session_dir/system/nvidia-smi-L.txt" 2>&1 || true
nvidia-smi > "$session_dir/system/nvidia-smi-start.txt" 2>&1 || true
nvidia-smi -q > "$session_dir/system/nvidia-smi-q-start.txt" 2>&1 || true
nvidia-smi -q -d ECC > "$session_dir/system/nvidia-smi-ecc-start.txt" 2>&1 || true
dmesg > "$session_dir/system/dmesg-start.txt" 2>&1 || true
grep -E 'NVRM: Xid|Xid \(' "$session_dir/system/dmesg-start.txt" > "$session_dir/system/xid-start.txt" 2>/dev/null || true
screen -ls > "$session_dir/system/screen-before.txt" 2>&1 || true
ps auxww > "$session_dir/system/ps-before.txt" 2>&1 || true

if [[ -d "$DIR" ]]; then
  for f in VERSION BUILD_PROFILE h-manifest.conf h-config.sh h-run.sh h-stats.sh console-monitor.sh pepepowminer.sha256 config.txt active-workers.env; do
    [[ -f "$DIR/$f" ]] && cp -a "$DIR/$f" "$session_dir/" 2>/dev/null || true
  done
  [[ -x "$DIR/pepepowminer" ]] && "$DIR/pepepowminer" --version > "$session_dir/binary-version.txt" 2>&1 || true
  [[ -x "$DIR/pepepowminer" ]] && "$DIR/pepepowminer" --list-gpu > "$session_dir/list-gpu.txt" 2>&1 || true
  [[ -f "$DIR/pepepowminer.sha256" ]] && (cd "$DIR" && sha256sum -c pepepowminer.sha256) > "$session_dir/binary-sha-check.txt" 2>&1 || true
fi

# Record log offsets so the archive contains only this session's new lines.
declare -a miner_log_start proxy_log_start proxy_console_start debug_log_start
for ((i=0; i<EXPECTED_GPU_COUNT; ++i)); do
  miner_log_start[$i]="$(wc -l < "$LOG_ROOT/gpu${i}/pepew.log" 2>/dev/null || echo 0)"
  proxy_log_start[$i]="$(wc -l < "$LOG_ROOT/gpu${i}/stratum-proxy.log" 2>/dev/null || echo 0)"
  proxy_console_start[$i]="$(wc -l < "$LOG_ROOT/gpu${i}/proxy-console.log" 2>/dev/null || echo 0)"
  debug_log_start[$i]="$(wc -l < "$DIR/gpu${i}/pepepow-debug.log" 2>/dev/null || echo 0)"
done

finalize() {
  (( finalized == 0 )) || return 0
  finalized=1
  trap - INT TERM EXIT
  local end_epoch elapsed xid_start_count=0 i s
  end_epoch="$(date +%s)"
  elapsed=$((end_epoch-start_epoch))

  # Capture the live state before stopping the miner.
  nvidia-smi > "$session_dir/system/nvidia-smi-live-end.txt" 2>&1 || true
  nvidia-smi -q > "$session_dir/system/nvidia-smi-q-live-end.txt" 2>&1 || true
  ps auxww > "$session_dir/system/ps-live-end.txt" 2>&1 || true
  screen -ls > "$session_dir/system/screen-live-end.txt" 2>&1 || true

  for ((i=0; i<EXPECTED_GPU_COUNT; ++i)); do
    [[ -f "$DIR/gpu${i}/miner-status.env" ]] && cp -a "$DIR/gpu${i}/miner-status.env" "$session_dir/status/gpu${i}-final.env" 2>/dev/null || true
    s=$(( ${miner_log_start[$i]:-0} + 1 )); [[ -f "$LOG_ROOT/gpu${i}/pepew.log" ]] && tail -n "+$s" "$LOG_ROOT/gpu${i}/pepew.log" > "$session_dir/logs/gpu${i}-pepew-session.log" 2>/dev/null || true
    s=$(( ${proxy_log_start[$i]:-0} + 1 )); [[ -f "$LOG_ROOT/gpu${i}/stratum-proxy.log" ]] && tail -n "+$s" "$LOG_ROOT/gpu${i}/stratum-proxy.log" > "$session_dir/logs/gpu${i}-proxy-session.log" 2>/dev/null || true
    s=$(( ${proxy_console_start[$i]:-0} + 1 )); [[ -f "$LOG_ROOT/gpu${i}/proxy-console.log" ]] && tail -n "+$s" "$LOG_ROOT/gpu${i}/proxy-console.log" > "$session_dir/logs/gpu${i}-proxy-console-session.log" 2>/dev/null || true
    s=$(( ${debug_log_start[$i]:-0} + 1 )); [[ -f "$DIR/gpu${i}/pepepow-debug.log" ]] && tail -n "+$s" "$DIR/gpu${i}/pepepow-debug.log" > "$session_dir/logs/gpu${i}-debug-session.log" 2>/dev/null || true
  done
  [[ -f "$LOG_ROOT/runtime-diagnostics.txt" ]] && cp -a "$LOG_ROOT/runtime-diagnostics.txt" "$session_dir/logs/" 2>/dev/null || true
  [[ -f "$LOG_ROOT/miner-exit-status.txt" ]] && cp -a "$LOG_ROOT/miner-exit-status.txt" "$session_dir/logs/" 2>/dev/null || true

  dmesg > "$session_dir/system/dmesg-end.txt" 2>&1 || true
  grep -E 'NVRM: Xid|Xid \(' "$session_dir/system/dmesg-end.txt" > "$session_dir/system/xid-end.txt" 2>/dev/null || true
  [[ -f "$session_dir/system/xid-start.txt" ]] && xid_start_count="$(wc -l < "$session_dir/system/xid-start.txt" | tr -d ' ')"
  [[ "$xid_start_count" =~ ^[0-9]+$ ]] || xid_start_count=0
  tail -n "+$((xid_start_count+1))" "$session_dir/system/xid-end.txt" > "$session_dir/system/xid-session.txt" 2>/dev/null || true

  if (( STOP_AT_END == 1 )); then
    echo '[CAPTURE] stopping miner after capture...'
    miner stop > "$session_dir/miner-stop-after.txt" 2>&1 || true
  fi

  {
    echo '===== PepeW Miner v1.0.5 session-v3 summary ====='
    echo "START_UTC=$(date -u -d "@$start_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "$start_epoch")"
    echo "END_UTC=$(now_iso)"
    echo "SESSION_RESULT=$session_result"
    echo "TOTAL_DURATION_SEC=$elapsed"
    if (( ready_epoch > 0 )); then
      echo "STARTUP_SEC=$((ready_epoch-start_epoch))"
      echo "MINING_DURATION_SEC=$((end_epoch-ready_epoch))"
    else
      echo "STARTUP_SEC=$elapsed"
      echo 'MINING_DURATION_SEC=0'
    fi
    echo "FALLBACK_START_SENT=$fallback_sent"
    echo
    echo '--- GPU telemetry summary ---'
    awk -F',' 'NR>1 {g=$2;t=$6+0;p=$8+0;u=$12+0;n[g]++;ts[g]+=t;ps[g]+=p;us[g]+=u;if(!(g in tmin)||t<tmin[g])tmin[g]=t;if(t>tmax[g])tmax[g]=t;if(!(g in pmin)||p<pmin[g])pmin[g]=p;if(p>pmax[g])pmax[g]=p} END{for(g in n)printf "GPU%s samples=%d temp_avg=%.1fC temp_min=%.1fC temp_max=%.1fC power_avg=%.1fW power_min=%.1fW power_max=%.1fW util_avg=%.1f%%\n",g,n[g],ts[g]/n[g],tmin[g],tmax[g],ps[g]/n[g],pmin[g],pmax[g],us[g]/n[g]}' "$session_dir/gpu-samples.csv" 2>/dev/null || true
    echo
    echo '--- Miner summary ---'
    awk -F',' 'NR>1 {g=$2;h=$4+0;a=$5+0;r=$6+0;n[g]++;if(h>0){hs[g]+=h;hn[g]++;if(!(g in hmin)||h<hmin[g])hmin[g]=h;if(h>hmax[g])hmax[g]=h}if(a>amax[g])amax[g]=a;if(r>rmax[g])rmax[g]=r} END{for(g in n)printf "GPU%s hashrate_avg=%.3fMH/s hashrate_min=%.3fMH/s hashrate_max=%.3fMH/s accepted=%d rejected=%d\n",g,(hn[g]?hs[g]/hn[g]:0),hmin[g]+0,hmax[g]+0,amax[g]+0,rmax[g]+0}' "$session_dir/miner-status.csv" 2>/dev/null || true
    echo
    echo '--- New NVIDIA Xid ---'
    if [[ -s "$session_dir/system/xid-session.txt" ]]; then cat "$session_dir/system/xid-session.txt"; else echo none; fi
    echo
    echo '--- Session log counts ---'
    for ((i=0; i<EXPECTED_GPU_COUNT; ++i)); do
      l="$session_dir/logs/gpu${i}-pepew-session.log"
      [[ -f "$l" ]] || continue
      printf 'GPU%s ACCEPTED=%s REJECTED=%s ERROR=%s JOB=%s MINING=%s STOP=%s\n' "$i" "$(grep -ac '^\[ACCEPTED\]' "$l" 2>/dev/null || true)" "$(grep -ac '^\[REJECTED\]' "$l" 2>/dev/null || true)" "$(grep -ac '^\[ERROR\]' "$l" 2>/dev/null || true)" "$(grep -ac '^\[JOB\]' "$l" 2>/dev/null || true)" "$(grep -ac '^\[MINING\]' "$l" 2>/dev/null || true)" "$(grep -ac 'STOP' "$l" 2>/dev/null || true)"
    done
  } > "$summary"

  tar -C "$(dirname "$session_dir")" -czf "$archive" "$(basename "$session_dir")" 2>/dev/null || true
  sha256sum "$archive" > "${archive}.sha256" 2>/dev/null || true
  echo
  echo '===== SESSION COMPLETE ====='
  cat "$summary"
  echo "SESSION_ARCHIVE=$archive"
  [[ -f "${archive}.sha256" ]] && echo "SESSION_ARCHIVE_SHA256=$(awk '{print $1}' "${archive}.sha256")"
}

trap 'session_result=INTERRUPTED; finalize; exit 130' INT TERM
trap 'finalize' EXIT

echo '===== PepeW Miner v1.0.5 session collector v3 ====='
echo "session_dir=$session_dir"
echo "startup_timeout=${STARTUP_TIMEOUT}s"
echo "mining_capture=${CAPTURE_SECONDS}s"
echo "sample_interval=${SAMPLE_INTERVAL}s"

miner_count_before="$(proc_count -x pepepowminer)"
proxy_count_before="$(proc_count -f '[s]tratum-replay-proxy.py')"
if (( miner_count_before >= EXPECTED_GPU_COUNT || proxy_count_before >= EXPECTED_GPU_COUNT )); then
  echo '[CAPTURE] miner is already active; requesting HiveOS miner restart...'
  miner restart > "$session_dir/miner-control-primary.txt" 2>&1 || true
  echo 'restart' > "$session_dir/miner-control-mode.txt"
else
  echo '[CAPTURE] miner is stopped; requesting HiveOS miner start...'
  miner start > "$session_dir/miner-control-primary.txt" 2>&1 || true
  echo 'start' > "$session_dir/miner-control-mode.txt"
fi

echo '[CAPTURE] waiting for worker + proxy + positive hashrate...'
sample=0
while :; do
  now_epoch="$(date +%s)"
  elapsed=$((now_epoch-start_epoch))
  if (( ready_epoch > 0 )); then
    mining_elapsed=$((now_epoch-ready_epoch))
    if (( mining_elapsed >= CAPTURE_SECONDS )); then session_result='COMPLETED'; break; fi
  elif (( elapsed >= STARTUP_TIMEOUT )); then
    session_result='START_TIMEOUT'
    echo "[CAPTURE] START_TIMEOUT after ${elapsed}s" | tee -a "$session_dir/session-events.txt"
    break
  fi

  sample=$((sample+1))
  ts="$(now_iso)"
  nvidia-smi --query-gpu=index,name,uuid,pci.bus_id,temperature.gpu,fan.speed,power.draw,power.limit,clocks.current.graphics,clocks.current.memory,utilization.gpu,utilization.memory,memory.used,memory.total,pstate --format=csv,noheader,nounits 2>/dev/null | while IFS= read -r line; do echo "$ts,$line" >> "$session_dir/gpu-samples.csv"; done

  ready_gpu_count=0
  for ((i=0; i<EXPECTED_GPU_COUNT; ++i)); do
    status="$DIR/gpu${i}/miner-status.env"
    hps=0; accepted=0; rejected=0; updated=0; age=-1
    if [[ -s "$status" ]]; then
      hps="$(status_value "$status" HPS)"; [[ "$hps" =~ ^[0-9]+$ ]] || hps=0
      accepted="$(status_value "$status" ACCEPTED)"; [[ "$accepted" =~ ^[0-9]+$ ]] || accepted=0
      rejected="$(status_value "$status" REJECTED)"; [[ "$rejected" =~ ^[0-9]+$ ]] || rejected=0
      updated="$(status_value "$status" UPDATED_EPOCH)"; [[ "$updated" =~ ^[0-9]+$ ]] || updated=0
      (( hps > 0 )) && ready_gpu_count=$((ready_gpu_count+1))
      (( updated > 0 )) && age=$((now_epoch-updated))
    fi
    mhs="$(awk -v h="$hps" 'BEGIN{printf "%.6f",h/1000000.0}')"
    mpid="$(pgrep -x pepepowminer 2>/dev/null | sed -n "$((i+1))p" || true)"
    ppid="$(pgrep -f '[s]tratum-replay-proxy.py' 2>/dev/null | sed -n "$((i+1))p" || true)"
    echo "$ts,$i,$hps,$mhs,$accepted,$rejected,$updated,$age,$mpid,$ppid" >> "$session_dir/miner-status.csv"
  done

  miner_count="$(proc_count -x pepepowminer)"
  proxy_count="$(proc_count -f '[s]tratum-replay-proxy.py')"
  read -r load1 load5 load15 _ < /proc/loadavg || true
  mem_avail="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  echo "$ts,${load1:-0},${load5:-0},${load15:-0},${mem_avail:-0},$miner_count,$proxy_count" >> "$session_dir/system-samples.csv"

  # One automatic fallback for the exact HiveOS state seen on the V100 rig:
  # restart on a stopped miner may be a no-op, or a delayed stop may kill the first start.
  if (( ready_epoch == 0 && fallback_sent == 0 && elapsed >= FALLBACK_AFTER && miner_count == 0 && proxy_count == 0 )); then
    fallback_sent=1
    echo "[CAPTURE] no worker/proxy after ${elapsed}s; sending one fallback 'miner start'..." | tee -a "$session_dir/session-events.txt"
    miner start > "$session_dir/miner-control-fallback.txt" 2>&1 || true
  fi

  if (( ready_epoch == 0 && miner_count >= EXPECTED_GPU_COUNT && proxy_count >= EXPECTED_GPU_COUNT && ready_gpu_count >= EXPECTED_GPU_COUNT )); then
    ready_epoch="$now_epoch"
    session_result='MINING'
    process_loss_since=0
    echo "[CAPTURE] READY after ${elapsed}s; mining timer starts now." | tee -a "$session_dir/session-events.txt"
  fi

  if (( ready_epoch > 0 )); then
    if (( miner_count < EXPECTED_GPU_COUNT || proxy_count < EXPECTED_GPU_COUNT )); then
      if (( process_loss_since == 0 )); then
        process_loss_since="$now_epoch"
        echo '[CAPTURE] worker/proxy count dropped; grace timer started.' | tee -a "$session_dir/session-events.txt"
      elif (( now_epoch-process_loss_since >= PROCESS_LOSS_GRACE )); then
        session_result='PROCESS_LOST'
        echo "[CAPTURE] worker/proxy missing for ${PROCESS_LOSS_GRACE}s." | tee -a "$session_dir/session-events.txt"
        break
      fi
    else
      process_loss_since=0
    fi
  fi

  sleep "$SAMPLE_INTERVAL"
done

finalize
trap - INT TERM EXIT
exit 0
