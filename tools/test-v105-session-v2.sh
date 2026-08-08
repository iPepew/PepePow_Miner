#!/usr/bin/env bash
set -u

NAME="${PEPEW_NAME:-PepeW-Miner-v1.0.5-HiveOS}"
DIR="/hive/miners/custom/${NAME}"
LOG_ROOT="/var/log/miner/custom/${NAME}"
EXPECTED_GPU_COUNT="${PEPEW_EXPECTED_GPU_COUNT:-$(nvidia-smi -L 2>/dev/null | grep -c '^GPU ' || true)}"
CAPTURE_SECONDS="${PEPEW_CAPTURE_SECONDS:-600}"
SAMPLE_INTERVAL="${PEPEW_SAMPLE_INTERVAL:-2}"
STARTUP_TIMEOUT="${PEPEW_STARTUP_TIMEOUT:-180}"
PROCESS_LOSS_GRACE="${PEPEW_PROCESS_LOSS_GRACE:-20}"
STOP_AT_END="${PEPEW_STOP_AT_END:-1}"
SESSION_BASE="${PEPEW_SESSION_BASE:-/root/pepew-tests}"

[[ "$EXPECTED_GPU_COUNT" =~ ^[1-9][0-9]*$ ]] || EXPECTED_GPU_COUNT=1
[[ "$CAPTURE_SECONDS" =~ ^[1-9][0-9]*$ ]] || CAPTURE_SECONDS=600
[[ "$SAMPLE_INTERVAL" =~ ^[1-9][0-9]*$ ]] || SAMPLE_INTERVAL=2
[[ "$STARTUP_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || STARTUP_TIMEOUT=180
[[ "$PROCESS_LOSS_GRACE" =~ ^[1-9][0-9]*$ ]] || PROCESS_LOSS_GRACE=20
[[ "$STOP_AT_END" =~ ^[01]$ ]] || STOP_AT_END=1

if (( EUID != 0 )); then
  echo 'ERROR: run as root.' >&2
  exit 2
fi

now_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
status_value() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n1; }
capture_cmd() {
  local out="$1"; shift
  {
    echo "timestamp_utc=$(now_iso)"
    printf 'command='; printf '%q ' "$@"; echo
    "$@" 2>&1 || true
  } > "$out"
}

stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
session_dir="${SESSION_BASE%/}/PepeW-v105-session-v2-${stamp}"
archive="${session_dir}.tar.gz"
summary="$session_dir/SUMMARY.txt"
mkdir -p "$session_dir" "$session_dir/system" "$session_dir/logs" "$session_dir/samples" "$session_dir/status"

start_epoch="$(date +%s)"
ready_epoch=0
process_loss_since=0
session_result='STARTING'
finalized=0

# Record offsets so final logs contain this session only.
declare -a pepew_offsets proxy_offsets proxy_console_offsets
for ((i=0; i<EXPECTED_GPU_COUNT; ++i)); do
  for kind in pepew proxy proxy_console; do
    case "$kind" in
      pepew) f="$LOG_ROOT/gpu${i}/pepew.log" ;;
      proxy) f="$LOG_ROOT/gpu${i}/stratum-proxy.log" ;;
      proxy_console) f="$LOG_ROOT/gpu${i}/proxy-console.log" ;;
    esac
    n=0
    [[ -f "$f" ]] && n="$(wc -c < "$f" 2>/dev/null || echo 0)"
    case "$kind" in
      pepew) pepew_offsets[$i]="$n" ;;
      proxy) proxy_offsets[$i]="$n" ;;
      proxy_console) proxy_console_offsets[$i]="$n" ;;
    esac
  done
done

{
  echo "SESSION_START_UTC=$(now_iso)"
  echo "COLLECTOR_VERSION=v2"
  echo "CONTROL_METHOD=miner_restart"
  echo "EXPECTED_GPU_COUNT=$EXPECTED_GPU_COUNT"
  echo "CAPTURE_SECONDS=$CAPTURE_SECONDS"
  echo "SAMPLE_INTERVAL=$SAMPLE_INTERVAL"
  echo "STARTUP_TIMEOUT=$STARTUP_TIMEOUT"
  echo "PROCESS_LOSS_GRACE=$PROCESS_LOSS_GRACE"
  echo "HOSTNAME=$(hostname 2>/dev/null || true)"
  echo "KERNEL=$(uname -a 2>/dev/null || true)"
  echo "HIVE_VERSION=$(cat /etc/hiveos-version 2>/dev/null || true)"
} > "$session_dir/session.env"

capture_cmd "$session_dir/system/date-start.txt" date
capture_cmd "$session_dir/system/uptime-start.txt" uptime
capture_cmd "$session_dir/system/uname.txt" uname -a
capture_cmd "$session_dir/system/free-start.txt" free -h
capture_cmd "$session_dir/system/lscpu.txt" lscpu
capture_cmd "$session_dir/system/lspci-nvidia.txt" bash -lc "lspci -nn 2>/dev/null | grep -Ei 'NVIDIA|VGA|3D'"
capture_cmd "$session_dir/system/timedatectl.txt" timedatectl status
capture_cmd "$session_dir/system/nvidia-smi-L.txt" nvidia-smi -L
capture_cmd "$session_dir/system/nvidia-smi-start.txt" nvidia-smi
capture_cmd "$session_dir/system/nvidia-smi-q-start.txt" nvidia-smi -q
capture_cmd "$session_dir/system/nvidia-smi-ecc-start.txt" nvidia-smi -q -d ECC
capture_cmd "$session_dir/system/nvidia-smi-perf-start.txt" nvidia-smi -q -d PERFORMANCE,POWER,CLOCK,UTILIZATION,TEMPERATURE
capture_cmd "$session_dir/system/screen-start.txt" screen -ls
dmesg > "$session_dir/system/dmesg-start.txt" 2>&1 || true
grep -E 'NVRM: Xid|Xid \(' "$session_dir/system/dmesg-start.txt" > "$session_dir/system/xid-start.txt" 2>/dev/null || true

if [[ -d "$DIR" ]]; then
  for f in VERSION BUILD_PROFILE h-manifest.conf h-config.sh h-run.sh h-stats.sh console-monitor.sh pepepowminer.sha256 config.txt; do
    [[ -f "$DIR/$f" ]] && cp -a "$DIR/$f" "$session_dir/" 2>/dev/null || true
  done
  [[ -x "$DIR/pepepowminer" ]] && "$DIR/pepepowminer" --version > "$session_dir/binary-version.txt" 2>&1 || true
  [[ -x "$DIR/pepepowminer" ]] && "$DIR/pepepowminer" --list-gpu > "$session_dir/list-gpu.txt" 2>&1 || true
  [[ -f "$DIR/pepepowminer.sha256" ]] && (cd "$DIR" && sha256sum -c pepepowminer.sha256) > "$session_dir/binary-sha-check.txt" 2>&1 || true
fi

echo 'timestamp_utc,index,name,uuid,pci_bus,temperature_c,fan_pct,power_w,power_limit_w,graphics_clock_mhz,memory_clock_mhz,util_gpu_pct,util_mem_pct,memory_used_mib,memory_total_mib,pstate' > "$session_dir/gpu-samples.csv"
echo 'timestamp_utc,gpu,hps,mhs,accepted,rejected,updated_epoch,status_age_sec,miner_pid,proxy_pid' > "$session_dir/miner-status.csv"
echo 'timestamp_utc,load1,load5,load15,mem_available_kb,swap_free_kb,miner_processes,proxy_processes' > "$session_dir/system-samples.csv"

copy_new_bytes() {
  local src="$1" offset="$2" dst="$3"
  [[ -f "$src" ]] || return 0
  local size
  size="$(wc -c < "$src" 2>/dev/null || echo 0)"
  [[ "$size" =~ ^[0-9]+$ ]] || size=0
  [[ "$offset" =~ ^[0-9]+$ ]] || offset=0
  if (( size >= offset )); then
    tail -c "+$((offset + 1))" "$src" > "$dst" 2>/dev/null || true
  else
    cp -a "$src" "$dst" 2>/dev/null || true
  fi
}

finalize() {
  (( finalized == 0 )) || return 0
  finalized=1
  trap - INT TERM EXIT
  local end_epoch elapsed xid_start_count=0 i
  end_epoch="$(date +%s)"
  elapsed=$((end_epoch - start_epoch))

  # Capture live state BEFORE stopping the miner.
  capture_cmd "$session_dir/system/ps-before-stop.txt" ps auxww
  capture_cmd "$session_dir/system/screen-before-stop.txt" screen -ls
  capture_cmd "$session_dir/system/nvidia-smi-before-stop.txt" nvidia-smi
  capture_cmd "$session_dir/system/nvidia-smi-q-before-stop.txt" nvidia-smi -q
  capture_cmd "$session_dir/system/nvidia-smi-ecc-before-stop.txt" nvidia-smi -q -d ECC
  capture_cmd "$session_dir/system/nvidia-smi-perf-before-stop.txt" nvidia-smi -q -d PERFORMANCE,POWER,CLOCK,UTILIZATION,TEMPERATURE

  [[ -f "$LOG_ROOT/runtime-diagnostics.txt" ]] && cp -a "$LOG_ROOT/runtime-diagnostics.txt" "$session_dir/logs/" 2>/dev/null || true
  [[ -f "$LOG_ROOT/miner-exit-status.txt" ]] && cp -a "$LOG_ROOT/miner-exit-status.txt" "$session_dir/logs/miner-exit-status-before-stop.txt" 2>/dev/null || true
  [[ -f "$DIR/active-workers.env" ]] && cp -a "$DIR/active-workers.env" "$session_dir/" 2>/dev/null || true

  for ((i=0; i<EXPECTED_GPU_COUNT; ++i)); do
    copy_new_bytes "$LOG_ROOT/gpu${i}/pepew.log" "${pepew_offsets[$i]:-0}" "$session_dir/logs/gpu${i}-pepew-session.log"
    copy_new_bytes "$LOG_ROOT/gpu${i}/stratum-proxy.log" "${proxy_offsets[$i]:-0}" "$session_dir/logs/gpu${i}-proxy-session.log"
    copy_new_bytes "$LOG_ROOT/gpu${i}/proxy-console.log" "${proxy_console_offsets[$i]:-0}" "$session_dir/logs/gpu${i}-proxy-console-session.log"
    [[ -f "$DIR/gpu${i}/pepepow-debug.log" ]] && cp -a "$DIR/gpu${i}/pepepow-debug.log" "$session_dir/logs/gpu${i}-debug.log" 2>/dev/null || true
    [[ -f "$DIR/gpu${i}/miner-status.env" ]] && cp -a "$DIR/gpu${i}/miner-status.env" "$session_dir/status/gpu${i}-final-live.env" 2>/dev/null || true
  done

  dmesg > "$session_dir/system/dmesg-before-stop.txt" 2>&1 || true
  grep -E 'NVRM: Xid|Xid \(' "$session_dir/system/dmesg-before-stop.txt" > "$session_dir/system/xid-end.txt" 2>/dev/null || true
  [[ -f "$session_dir/system/xid-start.txt" ]] && xid_start_count="$(wc -l < "$session_dir/system/xid-start.txt" | tr -d ' ')"
  [[ "$xid_start_count" =~ ^[0-9]+$ ]] || xid_start_count=0
  tail -n "+$((xid_start_count + 1))" "$session_dir/system/xid-end.txt" > "$session_dir/system/xid-session.txt" 2>/dev/null || true

  if (( STOP_AT_END == 1 )); then
    echo '[CAPTURE] stopping miner after capture...'
    miner stop > "$session_dir/miner-stop-after.txt" 2>&1 || true
    sleep 3
    [[ -f "$LOG_ROOT/miner-exit-status.txt" ]] && cp -a "$LOG_ROOT/miner-exit-status.txt" "$session_dir/logs/miner-exit-status-after-stop.txt" 2>/dev/null || true
  fi

  {
    echo '===== PepeW Miner v1.0.5 session-v2 summary ====='
    echo "START_UTC=$(date -u -d "@$start_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "$start_epoch")"
    echo "END_UTC=$(now_iso)"
    echo "SESSION_RESULT=$session_result"
    echo "TOTAL_DURATION_SEC=$elapsed"
    if (( ready_epoch > 0 )); then
      echo "READY_UTC=$(date -u -d "@$ready_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "$ready_epoch")"
      echo "STARTUP_SEC=$((ready_epoch-start_epoch))"
      echo "MINING_DURATION_SEC=$((end_epoch-ready_epoch))"
    else
      echo 'READY_UTC=never'
      echo "STARTUP_SEC=$elapsed"
      echo 'MINING_DURATION_SEC=0'
    fi
    echo "EXPECTED_GPU_COUNT=$EXPECTED_GPU_COUNT"
    echo
    echo '--- GPU telemetry summary ---'
    awk -F',' 'NR>1 {g=$2; temp=$6+0; p=$8+0; u=$12+0; n[g]++; if(temp>0){ts[g]+=temp;if(!(g in tmin)||temp<tmin[g])tmin[g]=temp;if(temp>tmax[g])tmax[g]=temp} if(p>0){ps[g]+=p;if(!(g in pmin)||p<pmin[g])pmin[g]=p;if(p>pmax[g])pmax[g]=p} us[g]+=u} END{for(g in n)printf "GPU%s samples=%d temp_avg=%.1fC temp_min=%.1fC temp_max=%.1fC power_avg=%.1fW power_min=%.1fW power_max=%.1fW util_avg=%.1f%%\n",g,n[g],ts[g]/n[g],tmin[g],tmax[g],ps[g]/n[g],pmin[g],pmax[g],us[g]/n[g]}' "$session_dir/gpu-samples.csv" 2>/dev/null || true
    echo
    echo '--- Miner summary ---'
    awk -F',' 'NR>1 {g=$2;h=$4+0;a=$5+0;r=$6+0;n[g]++;if(h>0){hs[g]+=h;hn[g]++;if(!(g in hmin)||h<hmin[g])hmin[g]=h;if(h>hmax[g])hmax[g]=h}if(a>amax[g])amax[g]=a;if(r>rmax[g])rmax[g]=r} END{for(g in n)printf "GPU%s hashrate_avg=%.3fMH/s hashrate_min=%.3fMH/s hashrate_max=%.3fMH/s accepted=%d rejected=%d\n",g,(hn[g]?hs[g]/hn[g]:0),hmin[g]+0,hmax[g]+0,amax[g]+0,rmax[g]+0}' "$session_dir/miner-status.csv" 2>/dev/null || true
    echo
    echo '--- New NVIDIA Xid ---'
    if [[ -s "$session_dir/system/xid-session.txt" ]]; then cat "$session_dir/system/xid-session.txt"; else echo 'none'; fi
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
  echo
  echo "SESSION_ARCHIVE=$archive"
  [[ -f "${archive}.sha256" ]] && echo "SESSION_ARCHIVE_SHA256=$(awk '{print $1}' "${archive}.sha256")"
}

trap 'session_result=INTERRUPTED; finalize; exit 130' INT TERM
trap 'finalize' EXIT

echo '===== PepeW Miner v1.0.5 session collector v2 ====='
echo "session_dir=$session_dir"
echo "startup_timeout=${STARTUP_TIMEOUT}s"
echo "mining_capture=${CAPTURE_SECONDS}s"
echo "sample_interval=${SAMPLE_INTERVAL}s"
echo '[CAPTURE] requesting ONE HiveOS miner restart...'
miner restart > "$session_dir/miner-restart.txt" 2>&1 || true
restart_return_epoch="$(date +%s)"
echo "RESTART_COMMAND_RETURN_UTC=$(now_iso)" >> "$session_dir/session.env"
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
  for ((i=0;i<EXPECTED_GPU_COUNT;++i)); do
    status="$DIR/gpu${i}/miner-status.env"
    hps=0; accepted=0; rejected=0; updated=0; age=-1
    if [[ -s "$status" ]]; then
      hps="$(status_value "$status" HPS)"; [[ "$hps" =~ ^[0-9]+$ ]] || hps=0
      accepted="$(status_value "$status" ACCEPTED)"; [[ "$accepted" =~ ^[0-9]+$ ]] || accepted=0
      rejected="$(status_value "$status" REJECTED)"; [[ "$rejected" =~ ^[0-9]+$ ]] || rejected=0
      updated="$(status_value "$status" UPDATED_EPOCH)"; [[ "$updated" =~ ^[0-9]+$ ]] || updated=0
      (( hps > 0 )) && ready_gpu_count=$((ready_gpu_count+1))
      (( updated > 0 )) && age=$((now_epoch-updated))
      cp -a "$status" "$session_dir/status/gpu${i}-sample$(printf '%05d' "$sample").env" 2>/dev/null || true
    fi
    mhs="$(awk -v h="$hps" 'BEGIN{printf "%.6f",h/1000000.0}')"
    mpid="$(pgrep -x pepepowminer 2>/dev/null | sed -n "$((i+1))p" || true)"
    ppid="$(pgrep -f '[s]tratum-replay-proxy.py' 2>/dev/null | sed -n "$((i+1))p" || true)"
    echo "$ts,$i,$hps,$mhs,$accepted,$rejected,$updated,$age,$mpid,$ppid" >> "$session_dir/miner-status.csv"
  done

  read -r load1 load5 load15 _ < /proc/loadavg || true
  mem_avail="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  swap_free="$(awk '/SwapFree:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  miner_count="$(pgrep -x pepepowminer 2>/dev/null | wc -l | tr -d ' ')"
  proxy_count="$(pgrep -f '[s]tratum-replay-proxy.py' 2>/dev/null | wc -l | tr -d ' ')"
  echo "$ts,${load1:-0},${load5:-0},${load15:-0},${mem_avail:-0},${swap_free:-0},$miner_count,$proxy_count" >> "$session_dir/system-samples.csv"

  if (( sample == 1 || sample % 5 == 0 )); then
    ps -eo pid,ppid,etimes,pcpu,pmem,rss,vsz,stat,comm,args --sort=-pcpu > "$session_dir/samples/ps-$(printf '%05d' "$sample").txt" 2>&1 || true
    screen -ls > "$session_dir/samples/screen-$(printf '%05d' "$sample").txt" 2>&1 || true
    nvidia-smi -q -d PERFORMANCE,POWER,CLOCK,UTILIZATION,TEMPERATURE > "$session_dir/samples/nvidia-q-$(printf '%05d' "$sample").txt" 2>&1 || true
    nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader > "$session_dir/samples/compute-apps-$(printf '%05d' "$sample").txt" 2>&1 || true
    ss -ntp > "$session_dir/samples/ss-$(printf '%05d' "$sample").txt" 2>&1 || true
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
        echo "[CAPTURE] worker/proxy missing for ${PROCESS_LOSS_GRACE}s; stopping capture." | tee -a "$session_dir/session-events.txt"
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
