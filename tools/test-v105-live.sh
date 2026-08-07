#!/usr/bin/env bash
set -u

NAME="${PEPEW_NAME:-PepeW-Miner-v1.0.5-HiveOS}"
DIR="/hive/miners/custom/${NAME}"
LOG_ROOT="/var/log/miner/custom/${NAME}"
MODE="${1:-live}"
EXPECTED_GPU_COUNT="${PEPEW_EXPECTED_GPU_COUNT:-$(nvidia-smi -L 2>/dev/null | grep -c '^GPU ' || true)}"
[[ "${EXPECTED_GPU_COUNT}" =~ ^[0-9]+$ ]] || EXPECTED_GPU_COUNT=0

CAPTURE_SECONDS="${PEPEW_CAPTURE_SECONDS:-300}"
SAMPLE_INTERVAL="${PEPEW_SAMPLE_INTERVAL:-5}"
RESTART_MINER="${PEPEW_RESTART_MINER:-1}"
STOP_AT_END="${PEPEW_STOP_AT_END:-1}"
SESSION_BASE="${PEPEW_SESSION_BASE:-/root/pepew-tests}"

[[ "$CAPTURE_SECONDS" =~ ^[0-9]+$ ]] || CAPTURE_SECONDS=300
[[ "$SAMPLE_INTERVAL" =~ ^[1-9][0-9]*$ ]] || SAMPLE_INTERVAL=5
[[ "$RESTART_MINER" =~ ^[01]$ ]] || RESTART_MINER=1
[[ "$STOP_AT_END" =~ ^[01]$ ]] || STOP_AT_END=1

failures=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; failures=$((failures+1)); }
now_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

live_validation() {
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
  nvidia-smi --query-gpu=index,pci.bus_id,name,temperature.gpu,fan.speed,power.draw,clocks.current.graphics,clocks.current.memory,utilization.gpu --format=csv,noheader 2>/dev/null || true

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
    return 0
  fi

  echo "PEPEW_V105_LIVE_GATE=FAIL failures=${failures}"
  return 1
}

capture_cmd() {
  local out="$1"; shift
  {
    printf 'timestamp_utc=%s\n' "$(now_iso)"
    printf 'command='
    printf '%q ' "$@"
    printf '\n'
    "$@" 2>&1 || true
  } >"$out"
}

status_value() {
  local file="$1" key="$2"
  sed -n "s/^${key}=//p" "$file" 2>/dev/null | tail -n1
}

session_mode() {
  if (( EUID != 0 )); then
    echo 'ERROR: session mode must be run as root.' >&2
    return 2
  fi

  local stamp session_dir archive summary start_epoch end_epoch elapsed interrupted=0
  stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  session_dir="${SESSION_BASE%/}/PepeW-v105-session-${stamp}"
  archive="${session_dir}.tar.gz"
  summary="$session_dir/SUMMARY.txt"
  mkdir -p "$session_dir" "$session_dir/samples" "$session_dir/logs" "$session_dir/status" "$session_dir/system"

  printf '%s\n' '===== PepeW Miner v1.0.5 session capture ====='
  printf 'session_dir=%s\n' "$session_dir"
  printf 'capture_seconds=%s\nsample_interval=%s\nrestart_miner=%s\nstop_at_end=%s\n' \
    "$CAPTURE_SECONDS" "$SAMPLE_INTERVAL" "$RESTART_MINER" "$STOP_AT_END"

  if [[ ! -d "$DIR" ]]; then
    printf 'WARN: package directory %s does not exist before start; miner start may install it.\n' "$DIR"
  fi

  {
    echo "SESSION_START_UTC=$(now_iso)"
    echo "HOSTNAME=$(hostname 2>/dev/null || true)"
    echo "KERNEL=$(uname -a 2>/dev/null || true)"
    echo "HIVE_VERSION=$(cat /etc/hiveos-version 2>/dev/null || true)"
    echo "EXPECTED_GPU_COUNT=$EXPECTED_GPU_COUNT"
    echo "CAPTURE_SECONDS=$CAPTURE_SECONDS"
    echo "SAMPLE_INTERVAL=$SAMPLE_INTERVAL"
    echo "RESTART_MINER=$RESTART_MINER"
    echo "STOP_AT_END=$STOP_AT_END"
  } > "$session_dir/session.env"

  capture_cmd "$session_dir/system/date.txt" date
  capture_cmd "$session_dir/system/uptime.txt" uptime
  capture_cmd "$session_dir/system/uname.txt" uname -a
  capture_cmd "$session_dir/system/free-start.txt" free -h
  capture_cmd "$session_dir/system/lscpu.txt" lscpu
  capture_cmd "$session_dir/system/lsblk.txt" lsblk
  capture_cmd "$session_dir/system/lspci-nvidia.txt" bash -lc "lspci -nn 2>/dev/null | grep -Ei 'NVIDIA|VGA|3D'"
  capture_cmd "$session_dir/system/timedatectl.txt" timedatectl status
  capture_cmd "$session_dir/system/ip-address.txt" ip -br address
  capture_cmd "$session_dir/system/ip-route.txt" ip route
  capture_cmd "$session_dir/system/nvidia-smi-L.txt" nvidia-smi -L
  capture_cmd "$session_dir/system/nvidia-smi-start.txt" nvidia-smi
  capture_cmd "$session_dir/system/nvidia-topo.txt" nvidia-smi topo -m
  capture_cmd "$session_dir/system/nvidia-smi-q-start.txt" nvidia-smi -q
  capture_cmd "$session_dir/system/nvidia-smi-ecc-start.txt" nvidia-smi -q -d ECC
  capture_cmd "$session_dir/system/nvidia-smi-perf-start.txt" nvidia-smi -q -d PERFORMANCE,POWER,CLOCK,UTILIZATION,TEMPERATURE
  capture_cmd "$session_dir/system/ps-start.txt" ps auxww
  dmesg > "$session_dir/system/dmesg-start.txt" 2>&1 || true
  grep -E 'NVRM: Xid|Xid \(' "$session_dir/system/dmesg-start.txt" > "$session_dir/system/xid-start.txt" 2>/dev/null || true

  if [[ -d "$DIR" ]]; then
    for f in VERSION BUILD_PROFILE h-manifest.conf h-config.sh h-run.sh h-stats.sh console-monitor.sh pepepowminer.sha256; do
      [[ -f "$DIR/$f" ]] && cp -a "$DIR/$f" "$session_dir/" 2>/dev/null || true
    done
    "$DIR/pepepowminer" --version > "$session_dir/binary-version.txt" 2>&1 || true
    "$DIR/pepepowminer" --list-gpu > "$session_dir/list-gpu.txt" 2>&1 || true
    (cd "$DIR" && sha256sum -c pepepowminer.sha256) > "$session_dir/binary-sha-check.txt" 2>&1 || true
  fi

  # h-run.sh truncates worker logs on a clean restart. When attaching to an
  # existing miner, remember the current line so only new events are archived.
  for ((i=0; i<EXPECTED_GPU_COUNT; ++i)); do
    local logfile="$LOG_ROOT/gpu${i}/pepew.log"
    if (( RESTART_MINER == 1 )); then
      echo 0 > "$session_dir/logs/gpu${i}.start_line"
    elif [[ -f "$logfile" ]]; then
      wc -l < "$logfile" > "$session_dir/logs/gpu${i}.start_line"
    else
      echo 0 > "$session_dir/logs/gpu${i}.start_line"
    fi
  done

  if (( RESTART_MINER == 1 )); then
    echo '[CAPTURE] stopping miner before clean session start...'
    miner stop > "$session_dir/miner-stop-before.txt" 2>&1 || true
    sleep 2
    echo '[CAPTURE] starting miner...'
    miner start > "$session_dir/miner-start.txt" 2>&1 || true
  else
    echo '[CAPTURE] attaching to currently running miner without restart.'
  fi

  start_epoch="$(date +%s)"
  echo "$start_epoch" > "$session_dir/start_epoch"

  echo 'timestamp_utc,index,name,uuid,pci_bus,temperature_c,fan_pct,power_w,power_limit_w,graphics_clock_mhz,memory_clock_mhz,util_gpu_pct,util_mem_pct,memory_used_mib,memory_total_mib,pstate' > "$session_dir/gpu-samples.csv"
  echo 'timestamp_utc,gpu,hps,mhs,accepted,rejected,updated_epoch,status_age_sec,miner_pid,proxy_pid' > "$session_dir/miner-status.csv"
  echo 'timestamp_utc,load1,load5,load15,mem_available_kb,swap_free_kb,miner_processes,proxy_processes' > "$session_dir/system-samples.csv"

  finalize_session() {
    local reason="${1:-completed}"
    trap - INT TERM EXIT
    end_epoch="$(date +%s)"
    elapsed=$((end_epoch - start_epoch))

    if [[ "$reason" == "signal" ]]; then
      interrupted=1
    fi

    if (( STOP_AT_END == 1 )); then
      echo '[CAPTURE] stopping miner for clean session end...'
      miner stop > "$session_dir/miner-stop-after.txt" 2>&1 || true
      sleep 2
    fi

    capture_cmd "$session_dir/system/nvidia-smi-end.txt" nvidia-smi
    capture_cmd "$session_dir/system/nvidia-smi-q-end.txt" nvidia-smi -q
    capture_cmd "$session_dir/system/nvidia-smi-ecc-end.txt" nvidia-smi -q -d ECC
    capture_cmd "$session_dir/system/nvidia-smi-perf-end.txt" nvidia-smi -q -d PERFORMANCE,POWER,CLOCK,UTILIZATION,TEMPERATURE
    capture_cmd "$session_dir/system/free-end.txt" free -h
    capture_cmd "$session_dir/system/ps-end.txt" ps auxww
    dmesg > "$session_dir/system/dmesg-end.txt" 2>&1 || true
    grep -E 'NVRM: Xid|Xid \(' "$session_dir/system/dmesg-end.txt" > "$session_dir/system/xid-end.txt" 2>/dev/null || true
    local xid_start_count=0
    [[ -f "$session_dir/system/xid-start.txt" ]] && xid_start_count="$(wc -l < "$session_dir/system/xid-start.txt" | tr -d ' ')"
    [[ "$xid_start_count" =~ ^[0-9]+$ ]] || xid_start_count=0
    tail -n "+$((xid_start_count + 1))" "$session_dir/system/xid-end.txt" > "$session_dir/system/xid-session.txt" 2>/dev/null || true

    for f in runtime-diagnostics.txt miner-exit-status.txt; do
      [[ -f "$LOG_ROOT/$f" ]] && cp -a "$LOG_ROOT/$f" "$session_dir/logs/" 2>/dev/null || true
    done
    for f in active-workers.env config.txt; do
      [[ -f "$DIR/$f" ]] && cp -a "$DIR/$f" "$session_dir/" 2>/dev/null || true
    done

    for ((i=0; i<EXPECTED_GPU_COUNT; ++i)); do
      local logfile="$LOG_ROOT/gpu${i}/pepew.log"
      local start_line=0
      [[ -s "$session_dir/logs/gpu${i}.start_line" ]] && start_line="$(cat "$session_dir/logs/gpu${i}.start_line")"
      [[ "$start_line" =~ ^[0-9]+$ ]] || start_line=0
      if [[ -f "$logfile" ]]; then
        tail -n "+$((start_line + 1))" "$logfile" > "$session_dir/logs/gpu${i}-session.log" 2>/dev/null || true
        tail -n 500 "$logfile" > "$session_dir/logs/gpu${i}-tail500.log" 2>/dev/null || true
      fi
      for extra in stratum-proxy.log proxy-console.log; do
        [[ -f "$LOG_ROOT/gpu${i}/$extra" ]] && cp -a "$LOG_ROOT/gpu${i}/$extra" "$session_dir/logs/gpu${i}-$extra" 2>/dev/null || true
      done
      [[ -f "$DIR/gpu${i}/pepepow-debug.log" ]] && cp -a "$DIR/gpu${i}/pepepow-debug.log" "$session_dir/logs/gpu${i}-pepepow-debug.log" 2>/dev/null || true
      if [[ -s "$DIR/gpu${i}/miner-status.env" ]]; then
        cp -a "$DIR/gpu${i}/miner-status.env" "$session_dir/status/gpu${i}-final.env" 2>/dev/null || true
      fi
    done

    if [[ -x "$DIR/h-stats.sh" || -f "$DIR/h-stats.sh" ]]; then
      bash -c 'source "$1"; printf "TOTAL_KHS=%s\nSTATS=%s\n" "$khs" "$stats"' _ "$DIR/h-stats.sh" > "$session_dir/hive-stats-final.txt" 2>&1 || true
    fi

    {
      echo '===== PepeW Miner v1.0.5 session summary ====='
      echo "START_UTC=$(date -u -d "@$start_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "$start_epoch")"
      echo "END_UTC=$(now_iso)"
      echo "DURATION_SEC=$elapsed"
      echo "INTERRUPTED=$interrupted"
      echo "EXPECTED_GPU_COUNT=$EXPECTED_GPU_COUNT"
      echo
      echo '--- GPU telemetry summary ---'
      awk -F',' 'NR>1 {
        gsub(/^ +| +$/, "", $2); g=$2;
        temp=$6+0; power=$8+0; util=$12+0;
        n[g]++;
        if (temp>0) {ts[g]+=temp; if (!(g in tmin)||temp<tmin[g]) tmin[g]=temp; if (temp>tmax[g]) tmax[g]=temp}
        if (power>0) {ps[g]+=power; if (!(g in pmin)||power<pmin[g]) pmin[g]=power; if (power>pmax[g]) pmax[g]=power}
        if (util>=0) {us[g]+=util; un[g]++}
      } END {
        for (g in n) printf "GPU%s samples=%d temp_avg=%.1fC temp_min=%.1fC temp_max=%.1fC power_avg=%.1fW power_min=%.1fW power_max=%.1fW util_avg=%.1f%%\n", g,n[g],ts[g]/n[g],tmin[g],tmax[g],ps[g]/n[g],pmin[g],pmax[g],(un[g]?us[g]/un[g]:0)
      }' "$session_dir/gpu-samples.csv" 2>/dev/null || true
      echo
      echo '--- Miner summary ---'
      awk -F',' 'NR>1 {
        g=$2; h=$4+0; a=$5+0; r=$6+0;
        n[g]++;
        if (h>0) {hs[g]+=h; hn[g]++; if (!(g in hmin)||h<hmin[g]) hmin[g]=h; if (h>hmax[g]) hmax[g]=h}
        if (a>amax[g]) amax[g]=a; if (r>rmax[g]) rmax[g]=r;
      } END {
        for (g in n) printf "GPU%s hashrate_avg=%.3fMH/s hashrate_min=%.3fMH/s hashrate_max=%.3fMH/s accepted=%d rejected=%d\n", g,(hn[g]?hs[g]/hn[g]:0),hmin[g]+0,hmax[g]+0,amax[g]+0,rmax[g]+0
      }' "$session_dir/miner-status.csv" 2>/dev/null || true
      echo
      echo '--- Xid ---'
      if [[ -s "$session_dir/system/xid-session.txt" ]]; then
        cat "$session_dir/system/xid-session.txt"
      else
        echo 'No new NVIDIA Xid lines during this session.'
      fi
    } > "$summary"

    {
      echo
      echo '--- Log event counts ---'
      for ((i=0; i<EXPECTED_GPU_COUNT; ++i)); do
        local sl="$session_dir/logs/gpu${i}-session.log"
        if [[ -f "$sl" ]]; then
          printf 'GPU%s ACCEPTED=%s REJECTED=%s ERROR=%s JOB=%s MINING=%s\n' "$i" \
            "$(grep -ac '^\[ACCEPTED\]' "$sl" 2>/dev/null || true)" \
            "$(grep -ac '^\[REJECTED\]' "$sl" 2>/dev/null || true)" \
            "$(grep -ac '^\[ERROR\]' "$sl" 2>/dev/null || true)" \
            "$(grep -ac '^\[JOB\]' "$sl" 2>/dev/null || true)" \
            "$(grep -ac '^\[MINING\]' "$sl" 2>/dev/null || true)"
        fi
      done
    } >> "$summary"

    tar -C "$(dirname "$session_dir")" -czf "$archive" "$(basename "$session_dir")" 2>/dev/null || true
    sha256sum "$archive" > "${archive}.sha256" 2>/dev/null || true

    printf '\n%s\n' '===== SESSION COMPLETE ====='
    cat "$summary"
    printf '\nSESSION_DIR=%s\n' "$session_dir"
    printf 'SESSION_ARCHIVE=%s\n' "$archive"
    [[ -f "${archive}.sha256" ]] && printf 'SESSION_ARCHIVE_SHA256=%s\n' "$(awk '{print $1}' "${archive}.sha256")"
    printf '%s\n' 'Send SUMMARY.txt plus the session .tar.gz archive for analysis.'
  }

  trap 'finalize_session signal; exit 130' INT TERM
  trap 'finalize_session signal' EXIT

  local sample=0 now_epoch elapsed_now query_out load1 load5 load15 mem_avail swap_free miner_count proxy_count
  while :; do
    now_epoch="$(date +%s)"
    elapsed_now=$((now_epoch - start_epoch))
    if (( CAPTURE_SECONDS > 0 && elapsed_now >= CAPTURE_SECONDS )); then
      break
    fi
    sample=$((sample + 1))
    local ts
    ts="$(now_iso)"

    query_out="$(nvidia-smi --query-gpu=index,name,uuid,pci.bus_id,temperature.gpu,fan.speed,power.draw,power.limit,clocks.current.graphics,clocks.current.memory,utilization.gpu,utilization.memory,memory.used,memory.total,pstate --format=csv,noheader,nounits 2>/dev/null || true)"
    if [[ -n "$query_out" ]]; then
      while IFS= read -r line; do
        printf '%s,%s\n' "$ts" "$line" >> "$session_dir/gpu-samples.csv"
      done <<< "$query_out"
    fi

    for ((i=0; i<EXPECTED_GPU_COUNT; ++i)); do
      local status="$DIR/gpu${i}/miner-status.env"
      local hps=0 mhs=0 accepted=0 rejected=0 updated=0 age=-1 mpid='' ppid=''
      if [[ -s "$status" ]]; then
        hps="$(status_value "$status" HPS)"; [[ "$hps" =~ ^[0-9]+$ ]] || hps=0
        accepted="$(status_value "$status" ACCEPTED)"; [[ "$accepted" =~ ^[0-9]+$ ]] || accepted=0
        rejected="$(status_value "$status" REJECTED)"; [[ "$rejected" =~ ^[0-9]+$ ]] || rejected=0
        updated="$(status_value "$status" UPDATED_EPOCH)"; [[ "$updated" =~ ^[0-9]+$ ]] || updated=0
        mhs="$(awk -v h="$hps" 'BEGIN{printf "%.6f", h/1000000.0}')"
        if (( updated > 0 )); then age=$((now_epoch - updated)); fi
        cp -a "$status" "$session_dir/status/gpu${i}-sample$(printf '%05d' "$sample").env" 2>/dev/null || true
      fi
      mpid="$(pgrep -x pepepowminer 2>/dev/null | sed -n "$((i+1))p" || true)"
      ppid="$(pgrep -f '[s]tratum-replay-proxy.py' 2>/dev/null | sed -n "$((i+1))p" || true)"
      printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$ts" "$i" "$hps" "$mhs" "$accepted" "$rejected" "$updated" "$age" "$mpid" "$ppid" >> "$session_dir/miner-status.csv"
    done

    read -r load1 load5 load15 _ < /proc/loadavg || true
    mem_avail="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    swap_free="$(awk '/SwapFree:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    miner_count="$(pgrep -x pepepowminer 2>/dev/null | wc -l | tr -d ' ')"
    proxy_count="$(pgrep -f '[s]tratum-replay-proxy.py' 2>/dev/null | wc -l | tr -d ' ')"
    printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$ts" "${load1:-0}" "${load5:-0}" "${load15:-0}" "${mem_avail:-0}" "${swap_free:-0}" "$miner_count" "$proxy_count" >> "$session_dir/system-samples.csv"

    if (( sample == 1 || sample % 6 == 0 )); then
      ps -eo pid,ppid,etimes,pcpu,pmem,rss,vsz,stat,comm,args --sort=-pcpu > "$session_dir/samples/ps-$(printf '%05d' "$sample").txt" 2>&1 || true
      nvidia-smi -q -d PERFORMANCE,POWER,CLOCK,UTILIZATION,TEMPERATURE > "$session_dir/samples/nvidia-q-$(printf '%05d' "$sample").txt" 2>&1 || true
      ss -ntp > "$session_dir/samples/ss-$(printf '%05d' "$sample").txt" 2>&1 || true
      nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader > "$session_dir/samples/compute-apps-$(printf '%05d' "$sample").txt" 2>&1 || true
      if [[ -f "$DIR/h-stats.sh" ]]; then
        bash -c 'source "$1"; printf "TOTAL_KHS=%s\nSTATS=%s\n" "$khs" "$stats"' _ "$DIR/h-stats.sh" > "$session_dir/samples/hive-stats-$(printf '%05d' "$sample").txt" 2>&1 || true
      fi
    fi

    if (( elapsed_now >= 30 && RESTART_MINER == 1 && EXPECTED_GPU_COUNT > 0 && miner_count == 0 )); then
      echo '[CAPTURE] miner process disappeared; ending capture early.' | tee -a "$session_dir/session-events.txt"
      break
    fi

    sleep "$SAMPLE_INTERVAL"
  done

  finalize_session completed
  trap - INT TERM EXIT
}

case "$MODE" in
  live|check)
    live_validation
    ;;
  session|capture)
    session_mode
    ;;
  help|-h|--help)
    cat <<'HELP'
Usage:
  test-v105-live.sh live
      One-shot validation of the currently running miner.

  test-v105-live.sh session
      Full mining-session capture. Defaults to a clean 5-minute run:
      PEPEW_CAPTURE_SECONDS=300
      PEPEW_SAMPLE_INTERVAL=5
      PEPEW_RESTART_MINER=1
      PEPEW_STOP_AT_END=1

Examples:
  PEPEW_EXPECTED_GPU_COUNT=1 ./test-v105-live.sh session
  PEPEW_CAPTURE_SECONDS=600 PEPEW_SAMPLE_INTERVAL=2 ./test-v105-live.sh session
  PEPEW_CAPTURE_SECONDS=0 ./test-v105-live.sh session   # until Ctrl+C
  PEPEW_RESTART_MINER=0 PEPEW_STOP_AT_END=0 ./test-v105-live.sh session

Output:
  /root/pepew-tests/PepeW-v105-session-<UTC>.tar.gz
  /root/pepew-tests/PepeW-v105-session-<UTC>/SUMMARY.txt
HELP
    ;;
  *)
    echo "Unknown mode: $MODE" >&2
    echo "Use: $0 help" >&2
    exit 2
    ;;
esac
