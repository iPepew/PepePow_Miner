#!/usr/bin/env bash
set -u

NAME="${PEPEW_NAME:-PepeW-Miner-v1.0.5-HiveOS}"
DIR="/hive/miners/custom/${NAME}"
LOG_ROOT="/var/log/miner/custom/${NAME}"
EXPECTED_GPU_COUNT="${PEPEW_EXPECTED_GPU_COUNT:-1}"
CAPTURE_SECONDS="${PEPEW_CAPTURE_SECONDS:-600}"
SAMPLE_INTERVAL="${PEPEW_SAMPLE_INTERVAL:-2}"
READY_TIMEOUT="${PEPEW_READY_TIMEOUT:-60}"
PROCESS_LOSS_GRACE="${PEPEW_PROCESS_LOSS_GRACE:-20}"
SESSION_BASE="${PEPEW_SESSION_BASE:-/root/pepew-tests}"

[[ "$EXPECTED_GPU_COUNT" =~ ^[1-9][0-9]*$ ]] || EXPECTED_GPU_COUNT=1
[[ "$CAPTURE_SECONDS" =~ ^[1-9][0-9]*$ ]] || CAPTURE_SECONDS=600
[[ "$SAMPLE_INTERVAL" =~ ^[1-9][0-9]*$ ]] || SAMPLE_INTERVAL=2
[[ "$READY_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || READY_TIMEOUT=60
[[ "$PROCESS_LOSS_GRACE" =~ ^[1-9][0-9]*$ ]] || PROCESS_LOSS_GRACE=20

if (( EUID != 0 )); then
  echo 'ERROR: run as root.' >&2
  exit 2
fi

now_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
status_value() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n1; }
proc_count() { pgrep "$@" 2>/dev/null | wc -l | tr -d ' '; }
capture_cmd() {
  local out="$1"; shift
  {
    echo "timestamp_utc=$(now_iso)"
    printf 'command='; printf '%q ' "$@"; echo
    "$@" 2>&1 || true
  } > "$out"
}

stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
session_dir="${SESSION_BASE%/}/PepeW-v105-passive-${stamp}"
archive="${session_dir}.tar.gz"
summary="$session_dir/SUMMARY.txt"
mkdir -p "$session_dir" "$session_dir/system" "$session_dir/logs" "$session_dir/status"

start_epoch="$(date +%s)"
ready_epoch=0
process_loss_since=0
session_result='WAITING_FOR_RUNNING_MINER'
finalized=0

worker_count="$(proc_count -x pepepowminer)"
proxy_count="$(proc_count -f '[s]tratum-replay-proxy.py')"
if (( worker_count < EXPECTED_GPU_COUNT || proxy_count < EXPECTED_GPU_COUNT )); then
  echo "ERROR: miner is not running. workers=${worker_count}/${EXPECTED_GPU_COUNT} proxies=${proxy_count}/${EXPECTED_GPU_COUNT}" >&2
  echo "Start the flight sheet manually first, verify that PepeW is mining, then run this collector." >&2
  rm -rf "$session_dir"
  exit 3
fi

{
  echo "SESSION_START_UTC=$(now_iso)"
  echo "MODE=passive_capture"
  echo "EXPECTED_GPU_COUNT=$EXPECTED_GPU_COUNT"
  echo "CAPTURE_SECONDS=$CAPTURE_SECONDS"
  echo "SAMPLE_INTERVAL=$SAMPLE_INTERVAL"
  echo "READY_TIMEOUT=$READY_TIMEOUT"
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
capture_cmd "$session_dir/system/nvidia-smi-topo.txt" nvidia-smi topo -m
capture_cmd "$session_dir/system/ps-start.txt" ps auxww
capture_cmd "$session_dir/system/ss-start.txt" ss -tpn
dmesg > "$session_dir/system/dmesg-start.txt" 2>&1 || true
grep -E 'NVRM: Xid|Xid \(' "$session_dir/system/dmesg-start.txt" > "$session_dir/system/xid-start.txt" 2>/dev/null || true

if [[ -d "$DIR" ]]; then
  for f in VERSION BUILD_PROFILE h-manifest.conf h-config.sh h-run.sh h-stats.sh console-monitor.sh pepepowminer.sha256 config.txt active-workers.env; do
    [[ -f "$DIR/$f" ]] && cp -a "$DIR/$f" "$session_dir/" 2>/dev/null || true
  done
  [[ -x "$DIR/pepepowminer" ]] && "$DIR/pepepowminer" --version > "$session_dir/binary-version.txt" 2>&1 || true
  [[ -x "$DIR/pepepowminer" ]] && "$DIR/pepepowminer" --list-gpu > "$session_dir/list-gpu.txt" 2>&1 || true
  [[ -f "$DIR/pepepowminer.sha256" ]] && (cd "$DIR" && sha256sum -c pepepowminer.sha256) > "$session_dir/binary-sha-check.txt" 2>&1 || true
fi

# Record line offsets so the archive contains only events generated during this capture.
for ((i=0;i<EXPECTED_GPU_COUNT;++i)); do
  for f in pepew.log stratum-proxy.log proxy-console.log; do
    p="$LOG_ROOT/gpu${i}/$f"
    n=0
    [[ -f "$p" ]] && n="$(wc -l < "$p" 2>/dev/null | tr -d ' ')"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    echo "$n" > "$session_dir/status/gpu${i}-${f}.startline"
  done
done

# Baseline NVIDIA Xid count.
xid_start_count="$(wc -l < "$session_dir/system/xid-start.txt" 2>/dev/null | tr -d ' ')"
[[ "$xid_start_count" =~ ^[0-9]+$ ]] || xid_start_count=0

echo 'timestamp_utc,index,name,uuid,pci_bus,temperature_c,fan_pct,power_w,power_limit_w,graphics_clock_mhz,memory_clock_mhz,util_gpu_pct,util_mem_pct,memory_used_mib,memory_total_mib,pstate' > "$session_dir/gpu-samples.csv"
echo 'timestamp_utc,gpu,hps,mhs,accepted,rejected,updated_epoch,status_age_sec,miner_pid,proxy_pid' > "$session_dir/miner-status.csv"
echo 'timestamp_utc,load1,load5,load15,mem_available_kb,swap_free_kb,miner_processes,proxy_processes,miner_cpu_pct,miner_mem_pct' > "$session_dir/system-samples.csv"

finalize() {
  (( finalized == 0 )) || return 0
  finalized=1
  trap - INT TERM EXIT
  local end_epoch elapsed i f p startline l
  end_epoch="$(date +%s)"
  elapsed=$((end_epoch-start_epoch))

  capture_cmd "$session_dir/system/date-end.txt" date
  capture_cmd "$session_dir/system/uptime-end.txt" uptime
  capture_cmd "$session_dir/system/free-end.txt" free -h
  capture_cmd "$session_dir/system/nvidia-smi-end.txt" nvidia-smi
  capture_cmd "$session_dir/system/nvidia-smi-q-end.txt" nvidia-smi -q
  capture_cmd "$session_dir/system/nvidia-smi-ecc-end.txt" nvidia-smi -q -d ECC
  capture_cmd "$session_dir/system/nvidia-smi-perf-end.txt" nvidia-smi -q -d PERFORMANCE,POWER,CLOCK,UTILIZATION,TEMPERATURE
  capture_cmd "$session_dir/system/ps-end.txt" ps auxww
  capture_cmd "$session_dir/system/ss-end.txt" ss -tpn
  dmesg > "$session_dir/system/dmesg-end.txt" 2>&1 || true
  grep -E 'NVRM: Xid|Xid \(' "$session_dir/system/dmesg-end.txt" > "$session_dir/system/xid-end.txt" 2>/dev/null || true
  tail -n "+$((xid_start_count + 1))" "$session_dir/system/xid-end.txt" > "$session_dir/system/xid-session.txt" 2>/dev/null || true

  for f in runtime-diagnostics.txt miner-exit-status.txt; do
    [[ -f "$LOG_ROOT/$f" ]] && cp -a "$LOG_ROOT/$f" "$session_dir/logs/" 2>/dev/null || true
  done
  for ((i=0;i<EXPECTED_GPU_COUNT;++i)); do
    for f in pepew.log stratum-proxy.log proxy-console.log; do
      p="$LOG_ROOT/gpu${i}/$f"
      startline="$(cat "$session_dir/status/gpu${i}-${f}.startline" 2>/dev/null || echo 0)"
      [[ "$startline" =~ ^[0-9]+$ ]] || startline=0
      [[ -f "$p" ]] && tail -n "+$((startline+1))" "$p" > "$session_dir/logs/gpu${i}-${f}" 2>/dev/null || true
    done
    [[ -f "$DIR/gpu${i}/miner-status.env" ]] && cp -a "$DIR/gpu${i}/miner-status.env" "$session_dir/status/gpu${i}-final.env" 2>/dev/null || true
    [[ -f "$DIR/gpu${i}/pepepow-debug.log" ]] && cp -a "$DIR/gpu${i}/pepepow-debug.log" "$session_dir/logs/gpu${i}-debug.log" 2>/dev/null || true
  done

  {
    echo '===== PepeW Miner v1.0.5 passive session summary ====='
    echo "START_UTC=$(date -u -d "@$start_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "$start_epoch")"
    echo "END_UTC=$(now_iso)"
    echo "SESSION_RESULT=$session_result"
    echo "TOTAL_DURATION_SEC=$elapsed"
    if (( ready_epoch > 0 )); then
      echo "READY_UTC=$(date -u -d "@$ready_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "$ready_epoch")"
      echo "READY_WAIT_SEC=$((ready_epoch-start_epoch))"
      echo "MINING_CAPTURE_SEC=$((end_epoch-ready_epoch))"
    else
      echo 'READY_UTC=never'
      echo 'MINING_CAPTURE_SEC=0'
    fi
    echo "EXPECTED_GPU_COUNT=$EXPECTED_GPU_COUNT"
    echo
    echo '--- GPU telemetry summary ---'
    awk -F',' 'NR>1 {g=$2; temp=$6+0; p=$8+0; u=$12+0; um=$13+0; n[g]++; if(temp>0){ts[g]+=temp;tn[g]++;if(!(g in tmin)||temp<tmin[g])tmin[g]=temp;if(temp>tmax[g])tmax[g]=temp} if(p>0){ps[g]+=p;pn[g]++;if(!(g in pmin)||p<pmin[g])pmin[g]=p;if(p>pmax[g])pmax[g]=p} us[g]+=u; ums[g]+=um} END{for(g in n)printf "GPU%s samples=%d temp_avg=%.1fC temp_min=%.1fC temp_max=%.1fC power_avg=%.1fW power_min=%.1fW power_max=%.1fW util_gpu_avg=%.1f%% util_mem_avg=%.1f%%\n",g,n[g],(tn[g]?ts[g]/tn[g]:0),tmin[g]+0,tmax[g]+0,(pn[g]?ps[g]/pn[g]:0),pmin[g]+0,pmax[g]+0,us[g]/n[g],ums[g]/n[g]}' "$session_dir/gpu-samples.csv" 2>/dev/null || true
    echo
    echo '--- Miner summary ---'
    awk -F',' 'NR>1 {g=$2;h=$4+0;a=$5+0;r=$6+0;n[g]++;if(h>0){hs[g]+=h;hn[g]++;if(!(g in hmin)||h<hmin[g])hmin[g]=h;if(h>hmax[g])hmax[g]=h}if(a>amax[g])amax[g]=a;if(r>rmax[g])rmax[g]=r} END{for(g in n)printf "GPU%s hashrate_avg=%.3fMH/s hashrate_min=%.3fMH/s hashrate_max=%.3fMH/s accepted=%d rejected=%d\n",g,(hn[g]?hs[g]/hn[g]:0),hmin[g]+0,hmax[g]+0,amax[g]+0,rmax[g]+0}' "$session_dir/miner-status.csv" 2>/dev/null || true
    echo
    echo '--- New NVIDIA Xid ---'
    if [[ -s "$session_dir/system/xid-session.txt" ]]; then cat "$session_dir/system/xid-session.txt"; else echo 'none'; fi
    echo
    echo '--- Session log counts ---'
    for ((i=0;i<EXPECTED_GPU_COUNT;++i)); do
      l="$session_dir/logs/gpu${i}-pepew.log"
      [[ -f "$l" ]] || continue
      printf 'GPU%s ACCEPTED=%s REJECTED=%s ERROR=%s JOB=%s MINING=%s STOP=%s\n' "$i" "$(grep -ac '^\[ACCEPTED\]' "$l" 2>/dev/null || true)" "$(grep -ac '^\[REJECTED\]' "$l" 2>/dev/null || true)" "$(grep -ac '^\[ERROR\]' "$l" 2>/dev/null || true)" "$(grep -ac '^\[JOB\]' "$l" 2>/dev/null || true)" "$(grep -ac '^\[MINING\]' "$l" 2>/dev/null || true)" "$(grep -ac 'STOP' "$l" 2>/dev/null || true)"
    done
  } > "$summary"

  tar -C "$(dirname "$session_dir")" -czf "$archive" "$(basename "$session_dir")" 2>/dev/null || true
  sha256sum "$archive" > "${archive}.sha256" 2>/dev/null || true
  echo
  echo '===== PASSIVE CAPTURE COMPLETE ====='
  cat "$summary"
  echo
  echo "SESSION_ARCHIVE=$archive"
  [[ -f "${archive}.sha256" ]] && echo "SESSION_ARCHIVE_SHA256=$(awk '{print $1}' "${archive}.sha256")"
  echo 'NOTE: miner was NOT stopped or restarted by this collector.'
}

trap 'session_result=INTERRUPTED; finalize; exit 130' INT TERM
trap 'finalize' EXIT

echo '===== PepeW Miner v1.0.5 PASSIVE collector ====='
echo "session_dir=$session_dir"
echo "capture=${CAPTURE_SECONDS}s interval=${SAMPLE_INTERVAL}s"
echo '[CAPTURE] miner control is disabled; existing mining process will not be touched.'
echo '[CAPTURE] waiting for positive HPS from all expected GPUs...'

while :; do
  now_epoch="$(date +%s)"
  elapsed=$((now_epoch-start_epoch))
  ready_gpu_count=0
  for ((i=0;i<EXPECTED_GPU_COUNT;++i)); do
    status="$DIR/gpu${i}/miner-status.env"
    hps=0
    if [[ -s "$status" ]]; then
      hps="$(status_value "$status" HPS)"; [[ "$hps" =~ ^[0-9]+$ ]] || hps=0
      (( hps > 0 )) && ready_gpu_count=$((ready_gpu_count+1))
    fi
  done
  worker_count="$(proc_count -x pepepowminer)"
  proxy_count="$(proc_count -f '[s]tratum-replay-proxy.py')"
  if (( ready_gpu_count == EXPECTED_GPU_COUNT && worker_count >= EXPECTED_GPU_COUNT && proxy_count >= EXPECTED_GPU_COUNT )); then
    ready_epoch="$(date +%s)"
    session_result='CAPTURING'
    echo "[CAPTURE] READY after ${elapsed}s. Passive ${CAPTURE_SECONDS}s timer starts now."
    break
  fi
  if (( elapsed >= READY_TIMEOUT )); then
    session_result='READY_TIMEOUT'
    echo "[CAPTURE] READY_TIMEOUT after ${elapsed}s. workers=${worker_count} proxies=${proxy_count} positive_hps=${ready_gpu_count}/${EXPECTED_GPU_COUNT}"
    exit 4
  fi
  sleep 2
done

while :; do
  now_epoch="$(date +%s)"
  mining_elapsed=$((now_epoch-ready_epoch))
  if (( mining_elapsed >= CAPTURE_SECONDS )); then session_result='COMPLETED'; break; fi
  ts="$(now_iso)"

  nvidia-smi --query-gpu=index,name,uuid,pci.bus_id,temperature.gpu,fan.speed,power.draw,power.limit,clocks.current.graphics,clocks.current.memory,utilization.gpu,utilization.memory,memory.used,memory.total,pstate --format=csv,noheader,nounits 2>/dev/null | while IFS= read -r line; do echo "$ts,$line" >> "$session_dir/gpu-samples.csv"; done

  for ((i=0;i<EXPECTED_GPU_COUNT;++i)); do
    status="$DIR/gpu${i}/miner-status.env"
    hps=0; accepted=0; rejected=0; updated=0; age=-1; miner_pid=''; proxy_pid=''
    if [[ -s "$status" ]]; then
      hps="$(status_value "$status" HPS)"; [[ "$hps" =~ ^[0-9]+$ ]] || hps=0
      accepted="$(status_value "$status" ACCEPTED)"; [[ "$accepted" =~ ^[0-9]+$ ]] || accepted=0
      rejected="$(status_value "$status" REJECTED)"; [[ "$rejected" =~ ^[0-9]+$ ]] || rejected=0
      updated="$(status_value "$status" UPDATED_EPOCH)"; [[ "$updated" =~ ^[0-9]+$ ]] || updated=0
      (( updated > 0 )) && age=$((now_epoch-updated))
      miner_pid="$(status_value "$status" MINER_PID)"
      proxy_pid="$(status_value "$status" PROXY_PID)"
    fi
    awk -v t="$ts" -v g="$i" -v h="$hps" -v a="$accepted" -v r="$rejected" -v u="$updated" -v age="$age" -v mp="$miner_pid" -v pp="$proxy_pid" 'BEGIN{printf "%s,%d,%d,%.6f,%d,%d,%d,%d,%s,%s\n",t,g,h,h/1000000.0,a,r,u,age,mp,pp}' >> "$session_dir/miner-status.csv"
  done

  read -r l1 l5 l15 _ < /proc/loadavg
  mem_avail="$(awk '/MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)"; mem_avail="${mem_avail:-0}"
  swap_free="$(awk '/SwapFree:/{print $2}' /proc/meminfo 2>/dev/null)"; swap_free="${swap_free:-0}"
  worker_count="$(proc_count -x pepepowminer)"
  proxy_count="$(proc_count -f '[s]tratum-replay-proxy.py')"
  miner_cpu="$(ps -C pepepowminer -o %cpu= 2>/dev/null | awk '{s+=$1} END{printf "%.1f",s+0}')"
  miner_mem="$(ps -C pepepowminer -o %mem= 2>/dev/null | awk '{s+=$1} END{printf "%.1f",s+0}')"
  echo "$ts,$l1,$l5,$l15,$mem_avail,$swap_free,$worker_count,$proxy_count,$miner_cpu,$miner_mem" >> "$session_dir/system-samples.csv"

  if (( worker_count < EXPECTED_GPU_COUNT || proxy_count < EXPECTED_GPU_COUNT )); then
    if (( process_loss_since == 0 )); then
      process_loss_since=$now_epoch
      echo "[CAPTURE] process loss detected at ${mining_elapsed}s; grace ${PROCESS_LOSS_GRACE}s" | tee -a "$session_dir/session-events.txt"
    elif (( now_epoch-process_loss_since >= PROCESS_LOSS_GRACE )); then
      session_result='PROCESS_LOST'
      echo "[CAPTURE] process loss persisted for ${PROCESS_LOSS_GRACE}s" | tee -a "$session_dir/session-events.txt"
      break
    fi
  else
    process_loss_since=0
  fi

  if (( mining_elapsed % 30 < SAMPLE_INTERVAL )); then
    h="$(awk -F',' 'NR>1 && $2==0 && $4>0 {v=$4} END{printf "%.3f",v+0}' "$session_dir/miner-status.csv")"
    echo "[CAPTURE] ${mining_elapsed}/${CAPTURE_SECONDS}s GPU0=${h} MH/s workers=${worker_count} proxies=${proxy_count}"
  fi
  sleep "$SAMPLE_INTERVAL"
done

finalize
exit 0
