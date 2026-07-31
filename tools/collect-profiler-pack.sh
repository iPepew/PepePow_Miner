#!/usr/bin/env bash
# PepePow Miner Developer Diagnostics / Profiler Pack
# Read-only collector for HiveOS + NVIDIA. It does not stop or restart the miner.

set -u
set -o pipefail
umask 077

SCRIPT_VERSION="3.0.0"
DURATION="${DURATION:-180}"
INTERVAL="${INTERVAL:-1}"
MAX_SOURCE_MB="${MAX_SOURCE_MB:-200}"
INCLUDE_SOURCE="${INCLUDE_SOURCE:-1}"
OUTPUT_DIR="${OUTPUT_DIR:-$PWD}"
REQUESTED_PID="${1:-${MINER_PID:-}}"

case "$DURATION" in
  ''|*[!0-9]*) echo "ERROR: DURATION must be an integer number of seconds." >&2; exit 2 ;;
esac
case "$INTERVAL" in
  ''|*[!0-9]*) echo "ERROR: INTERVAL must be an integer number of seconds." >&2; exit 2 ;;
esac
if (( DURATION < 30 )); then DURATION=30; fi
if (( DURATION > 1800 )); then DURATION=1800; fi
if (( INTERVAL < 1 )); then INTERVAL=1; fi

TS="$(date +%Y%m%d_%H%M%S)"
HOST_SAFE="$(hostname 2>/dev/null | tr -cs 'A-Za-z0-9._-' '_' | sed 's/^_//;s/_$//' || true)"
HOST_SAFE="${HOST_SAFE:-rig}"
WORKDIR="/tmp/pepepow-profiler-${HOST_SAFE}-${TS}"
ARCHIVE="${OUTPUT_DIR%/}/pepepow-profiler-${HOST_SAFE}-${TS}.tar.gz"

mkdir -p "$WORKDIR" "$OUTPUT_DIR"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$WORKDIR/collector.log"; }
have() { command -v "$1" >/dev/null 2>&1; }
run() {
  local out="$1"; shift
  {
    printf '$'
    printf ' %q' "$@"
    printf '\n\n'
    timeout 90 "$@"
  } >"$WORKDIR/$out" 2>&1 || true
}
run_sh() {
  local out="$1"; shift
  {
    printf '$ %s\n\n' "$*"
    timeout 90 bash -lc "$*"
  } >"$WORKDIR/$out" 2>&1 || true
}
redact_stream() {
  sed -E \
    -e 's#((--?pass(word)?|-p|pass(word)?)[=[:space:]]+)[^[:space:]]+#\1<REDACTED>#Ig' \
    -e 's#(("?(pass(word)?|token|api[_-]?key|secret)"?[[:space:]]*[:=][[:space:]]*"?)[^",[:space:]]+)#\1<REDACTED>#Ig' \
    -e 's#(stratum\+tcp://[^/@:]+:)[^/@]+@#\1<REDACTED>@#Ig'
}

log "Profiler Pack v${SCRIPT_VERSION}; duration=${DURATION}s; interval=${INTERVAL}s"
log "Working directory: $WORKDIR"

# --- Miner process discovery -------------------------------------------------
MINER_PID=""
if [[ -n "$REQUESTED_PID" && "$REQUESTED_PID" =~ ^[0-9]+$ && -d "/proc/$REQUESTED_PID" ]]; then
  MINER_PID="$REQUESTED_PID"
fi

if [[ -z "$MINER_PID" ]] && have nvidia-smi; then
  while IFS=, read -r pid pname; do
    pid="$(echo "$pid" | xargs)"
    [[ "$pid" =~ ^[0-9]+$ && -d "/proc/$pid" ]] || continue
    exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
    cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
    if [[ "$exe $pname $cmd" =~ (pepepow|hoo[_-]?gpu|miner) ]]; then
      MINER_PID="$pid"
      break
    fi
  done < <(nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader,nounits 2>/dev/null || true)
fi

if [[ -z "$MINER_PID" ]]; then
  MINER_PID="$(pgrep -o -f 'pepepowminer|hoo[_-]?gpu|(^|/)(cuda-)?miner([[:space:]]|$)' 2>/dev/null || true)"
fi

MINER_EXE=""
MINER_CWD=""
if [[ -n "$MINER_PID" && -d "/proc/$MINER_PID" ]]; then
  MINER_EXE="$(readlink -f "/proc/$MINER_PID/exe" 2>/dev/null || true)"
  MINER_CWD="$(readlink -f "/proc/$MINER_PID/cwd" 2>/dev/null || true)"
  log "Detected miner PID=$MINER_PID exe=${MINER_EXE:-unknown}"
else
  MINER_PID=""
  log "WARNING: active miner process was not detected; system/GPU data will still be collected."
fi

{
  echo "collector_version=$SCRIPT_VERSION"
  echo "timestamp=$(date --iso-8601=seconds 2>/dev/null || date)"
  echo "duration_seconds=$DURATION"
  echo "interval_seconds=$INTERVAL"
  echo "miner_pid=${MINER_PID:-not_detected}"
  echo "miner_exe=${MINER_EXE:-not_detected}"
  echo "miner_cwd=${MINER_CWD:-not_detected}"
  echo "kernel=$(uname -r 2>/dev/null || true)"
  echo "driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)"
} > "$WORKDIR/MANIFEST.txt"

# --- OS / HiveOS / hardware --------------------------------------------------
mkdir -p "$WORKDIR/system" "$WORKDIR/nvidia" "$WORKDIR/process" "$WORKDIR/binary" "$WORKDIR/logs" "$WORKDIR/build" "$WORKDIR/telemetry" "$WORKDIR/network"

run system/date.txt date --iso-8601=seconds
run system/uname.txt uname -a
[[ -r /etc/os-release ]] && cp -a /etc/os-release "$WORKDIR/system/os-release.txt"
[[ -r /etc/issue ]] && cp -a /etc/issue "$WORKDIR/system/issue.txt"
run_sh system/hive-version.txt 'for f in /hive/etc/hive-version /etc/hive-version /hive-config/version /etc/hive-release; do [[ -r "$f" ]] && { echo "### $f"; cat "$f"; }; done; command -v hive >/dev/null && hive --version || true; command -v agent-screen >/dev/null && agent-screen --version || true'
run system/lscpu.txt lscpu
run_sh system/cpuinfo-summary.txt 'grep -E "^(processor|model name|cpu MHz|cache size|microcode|flags)" /proc/cpuinfo'
run_sh system/memory.txt 'free -h; echo; cat /proc/meminfo'
run_sh system/numa.txt 'command -v numactl >/dev/null && numactl --hardware || true; echo; find /sys/devices/system/node -maxdepth 2 -type f \( -name cpulist -o -name meminfo \) -print -exec cat {} \; 2>/dev/null'
run_sh system/mounts.txt 'findmnt -A 2>/dev/null || mount'
run_sh system/disks.txt 'lsblk -O 2>/dev/null; echo; df -hT'
run_sh system/cpu-governor.txt 'for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_{governor,cur_freq,min_freq,max_freq}; do [[ -r "$f" ]] && echo "$f=$(cat "$f")"; done'
run_sh system/interrupts.txt 'cat /proc/interrupts; echo; cat /proc/softirqs'
run_sh system/sysctl-performance.txt 'sysctl kernel.numa_balancing vm.swappiness vm.dirty_ratio vm.dirty_background_ratio kernel.sched_autogroup_enabled 2>/dev/null || true'
run_sh system/kernel-cmdline.txt 'cat /proc/cmdline; echo; cat /sys/module/pcie_aspm/parameters/policy 2>/dev/null || true'
run_sh system/modules.txt 'lsmod; echo; modinfo nvidia 2>/dev/null || true; echo; modinfo nvidia_uvm 2>/dev/null || true'
run_sh system/tool-versions.txt 'for c in gcc g++ clang cmake make ninja nvcc ncu nsys cuobjdump nvdisasm perf python3; do if command -v "$c" >/dev/null; then echo "### $c"; "$c" --version 2>&1 | head -10; fi; done; ldd --version 2>&1 | head -2'
run_sh system/packages-nvidia-cuda.txt '(dpkg-query -W 2>/dev/null || true) | grep -Ei "nvidia|cuda|nsight|cupti" || true; (rpm -qa 2>/dev/null || true) | grep -Ei "nvidia|cuda|nsight|cupti" || true'
run_sh system/dmesg-full.txt 'dmesg -T 2>/dev/null || dmesg'
run_sh system/dmesg-nvidia.txt '(dmesg -T 2>/dev/null || dmesg) | grep -Ei "NVRM|NVIDIA|Xid|PCIe|AER|IOMMU|GPU|CUDA" || true'
run_sh system/journal-kernel.txt 'journalctl -k --no-pager 2>/dev/null || true'

# --- NVIDIA / GPU / PCIe -----------------------------------------------------
if have nvidia-smi; then
  run nvidia/nvidia-smi.txt nvidia-smi
  run nvidia/nvidia-smi-q.txt nvidia-smi -q
  run nvidia/nvidia-smi-q.xml nvidia-smi -q -x
  run nvidia/nvidia-smi-topo.txt nvidia-smi topo -m
  run nvidia/nvidia-smi-supported-clocks.txt nvidia-smi -q -d SUPPORTED_CLOCKS
  run nvidia/nvidia-smi-compute-apps.txt nvidia-smi --query-compute-apps=pid,process_name,used_memory,gpu_uuid --format=csv
  run nvidia/nvidia-smi-accounting.txt nvidia-smi --query-accounted-apps=pid,gpu_utilization,memory_utilization,max_memory_usage,time --format=csv
  run_sh nvidia/gpu-query-supported.txt 'nvidia-smi --help-query-gpu 2>&1'
  run_sh nvidia/gpu-static.csv 'nvidia-smi --query-gpu=timestamp,index,uuid,name,serial,driver_version,vbios_version,pci.bus_id,pstate,persistence_mode,compute_mode,mig.mode.current,temperature.gpu,temperature.memory,fan.speed,power.draw,power.limit,power.default_limit,power.max_limit,clocks.current.graphics,clocks.current.sm,clocks.current.memory,clocks.max.graphics,clocks.max.sm,clocks.max.memory,utilization.gpu,utilization.memory,memory.total,memory.used,bar1_memory.total,bar1_memory.used,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max --format=csv 2>&1 || true'
fi
run_sh nvidia/lspci-nvidia.txt 'lspci -Dnn | grep -Ei "VGA|3D|NVIDIA" || true'
run_sh nvidia/lspci-verbose.txt 'for dev in $(lspci -Dnn | awk "/NVIDIA|VGA compatible controller|3D controller/{print \$1}"); do echo "### $dev"; lspci -s "$dev" -vvnnxxxx; done'
run_sh nvidia/pci-sysfs.txt 'for d in /sys/bus/pci/devices/*; do [[ -r "$d/vendor" ]] || continue; [[ "$(cat "$d/vendor")" == "0x10de" ]] || continue; echo "### $d"; for f in vendor device subsystem_vendor subsystem_device class numa_node current_link_speed current_link_width max_link_speed max_link_width resource irq local_cpulist; do [[ -r "$d/$f" ]] && { echo "-- $f"; cat "$d/$f"; }; done; done'

# --- Process snapshot ---------------------------------------------------------
if [[ -n "$MINER_PID" && -d "/proc/$MINER_PID" ]]; then
  run_sh process/identity.txt "ps -p '$MINER_PID' -o pid,ppid,user,group,lstart,etime,stat,ni,pri,psr,pcpu,pmem,rss,vsz,nlwp,comm,args --cols 400"
  tr '\0' ' ' < "/proc/$MINER_PID/cmdline" 2>/dev/null | redact_stream > "$WORKDIR/process/cmdline-redacted.txt" || true
  tr '\0' '\n' < "/proc/$MINER_PID/environ" 2>/dev/null | sort | redact_stream > "$WORKDIR/process/environment-redacted.txt" || true
  for f in status limits sched schedstat io cgroup mountinfo maps numa_maps smaps_rollup; do
    [[ -r "/proc/$MINER_PID/$f" ]] && cp -a "/proc/$MINER_PID/$f" "$WORKDIR/process/$f.txt" 2>/dev/null || true
  done
  run_sh process/threads.txt "ps -L -p '$MINER_PID' -o pid,tid,psr,stat,ni,pri,pcpu,time,comm,wchan:32 --sort=-pcpu --cols 300"
  run_sh process/fds.txt "ls -l /proc/'$MINER_PID'/fd 2>/dev/null"
  run_sh process/open-files.txt "command -v lsof >/dev/null && lsof -nP -p '$MINER_PID' || true"
  run_sh process/task-stack.txt "for t in /proc/'$MINER_PID'/task/*; do echo \"### TID=\${t##*/}\"; cat \"\$t/stack\" 2>/dev/null || true; done"
  run_sh process/sockets.txt "ss -tpn 2>/dev/null | grep -F 'pid=$MINER_PID,' || true"
fi

# --- Binary/static CUDA data --------------------------------------------------
if [[ -n "$MINER_EXE" && -r "$MINER_EXE" ]]; then
  cp -a "$MINER_EXE" "$WORKDIR/binary/$(basename "$MINER_EXE").bin" 2>/dev/null || true
  run binary/file.txt file "$MINER_EXE"
  run binary/stat.txt stat "$MINER_EXE"
  run binary/sha256.txt sha256sum "$MINER_EXE"
  run_sh binary/size.txt "size '$MINER_EXE' 2>&1 || true"
  run_sh binary/ldd.txt "ldd '$MINER_EXE' 2>&1 || true"
  run_sh binary/readelf-header.txt "readelf -h -l -S -d -n '$MINER_EXE' 2>&1 || true"
  run_sh binary/readelf-symbols.txt "readelf -Ws '$MINER_EXE' 2>&1 || true"
  run_sh binary/objdump.txt "objdump -x '$MINER_EXE' 2>&1 || true"
  run_sh binary/strings.txt "strings -a -n 8 '$MINER_EXE' 2>&1 | head -200000"
  if have cuobjdump; then
    run_sh binary/cuobjdump-list.txt "cuobjdump --list-elf '$MINER_EXE' 2>&1; cuobjdump --list-ptx '$MINER_EXE' 2>&1"
    run_sh binary/cuobjdump-resource-usage.txt "cuobjdump --dump-resource-usage '$MINER_EXE' 2>&1"
    timeout 180 cuobjdump --dump-sass "$MINER_EXE" > "$WORKDIR/binary/cuobjdump-sass.txt" 2>&1 || true
    timeout 180 cuobjdump --dump-ptx "$MINER_EXE" > "$WORKDIR/binary/cuobjdump-ptx.txt" 2>&1 || true
  fi
fi

# --- Current miner / HiveOS logs ---------------------------------------------
# Copy text logs only; redact common password/token forms. Files are capped to the
# last 20 MiB each so a runaway log cannot fill /tmp.
copy_log_tail() {
  local src="$1" dst="$2"
  [[ -r "$src" && -f "$src" ]] || return 0
  mkdir -p "$(dirname "$dst")"
  tail -c $((20*1024*1024)) "$src" 2>/dev/null | redact_stream > "$dst" || true
}

if [[ -n "$MINER_PID" ]]; then
  for fd in 1 2; do
    target="$(readlink -f "/proc/$MINER_PID/fd/$fd" 2>/dev/null || true)"
    [[ -f "$target" ]] && copy_log_tail "$target" "$WORKDIR/logs/process-fd${fd}-$(basename "$target").log"
  done
fi

for base in /var/log/miner /var/log/hive /hive/miners/custom /hive-config "$MINER_CWD" "$(dirname "${MINER_EXE:-/}")"; do
  [[ -n "$base" && -d "$base" ]] || continue
  while IFS= read -r -d '' f; do
    rel="$(echo "$f" | sed 's#^/##; s#[^A-Za-z0-9._/-]#_#g; s#/#__#g')"
    copy_log_tail "$f" "$WORKDIR/logs/$rel"
  done < <(find "$base" -maxdepth 3 -type f \( -iname '*.log' -o -iname '*log.txt' -o -iname 'miner.log' -o -iname 'screenlog.*' \) -mmin -1440 -print0 2>/dev/null | head -z -c $((10*1024*1024)) || true)
done

# --- Build metadata and source snapshot --------------------------------------
CANDIDATE_ROOTS=()
[[ -n "$MINER_CWD" && -d "$MINER_CWD" ]] && CANDIDATE_ROOTS+=("$MINER_CWD")
[[ -n "$MINER_EXE" ]] && CANDIDATE_ROOTS+=("$(dirname "$MINER_EXE")")
CANDIDATE_ROOTS+=("$PWD")

SOURCE_ROOT=""
for root in "${CANDIDATE_ROOTS[@]}"; do
  probe="$root"
  for _ in 1 2 3 4; do
    if [[ -d "$probe/.git" || -f "$probe/CMakeLists.txt" || -d "$probe/native" ]]; then SOURCE_ROOT="$probe"; break 2; fi
    probe="$(dirname "$probe")"
  done
done

if [[ -n "$SOURCE_ROOT" && -d "$SOURCE_ROOT" ]]; then
  echo "$SOURCE_ROOT" > "$WORKDIR/build/source-root.txt"
  run_sh build/git-status.txt "cd '$SOURCE_ROOT' && git status --short --branch 2>&1; git rev-parse HEAD 2>&1; git remote -v 2>&1"
  run_sh build/source-file-list.txt "cd '$SOURCE_ROOT' && find . -type f \( -name '*.cu' -o -name '*.cuh' -o -name '*.cpp' -o -name '*.cc' -o -name '*.c' -o -name '*.hpp' -o -name '*.h' -o -name 'CMakeLists.txt' -o -name '*.cmake' -o -name 'Makefile' -o -name '*.sh' \) -not -path './.git/*' -not -path './build/*' -not -path './dist/*' -printf '%s %TY-%Tm-%Td %TH:%TM:%TS %p\n' | sort"
  run_sh build/source-sha256.txt "cd '$SOURCE_ROOT' && find . -type f \( -name '*.cu' -o -name '*.cuh' -o -name '*.cpp' -o -name '*.cc' -o -name '*.c' -o -name '*.hpp' -o -name '*.h' -o -name 'CMakeLists.txt' -o -name '*.cmake' -o -name 'Makefile' -o -name '*.sh' \) -not -path './.git/*' -not -path './build/*' -not -path './dist/*' -print0 | sort -z | xargs -0 -r sha256sum"
  while IFS= read -r -d '' f; do
    rel="${f#$SOURCE_ROOT/}"
    mkdir -p "$WORKDIR/build/metadata/$(dirname "$rel")"
    cp -a "$f" "$WORKDIR/build/metadata/$rel" 2>/dev/null || true
  done < <(find "$SOURCE_ROOT" -maxdepth 6 -type f \( -name 'CMakeCache.txt' -o -name 'compile_commands.json' -o -name 'CMakeLists.txt' -o -name '*.cmake' -o -name 'Makefile' -o -name '*.sh' \) -not -path '*/.git/*' -size -20M -print0 2>/dev/null)

  if [[ "$INCLUDE_SOURCE" == "1" ]]; then
    src_size_kb="$(find "$SOURCE_ROOT" -type f \( -name '*.cu' -o -name '*.cuh' -o -name '*.cpp' -o -name '*.cc' -o -name '*.c' -o -name '*.hpp' -o -name '*.h' -o -name 'CMakeLists.txt' -o -name '*.cmake' -o -name 'Makefile' -o -name '*.sh' \) -not -path '*/.git/*' -not -path '*/build/*' -not -path '*/dist/*' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{printf "%.0f",s/1024}')"
    src_size_kb="${src_size_kb:-0}"
    if (( src_size_kb <= MAX_SOURCE_MB * 1024 )); then
      mkdir -p "$WORKDIR/source_snapshot"
      while IFS= read -r -d '' f; do
        rel="${f#$SOURCE_ROOT/}"
        mkdir -p "$WORKDIR/source_snapshot/$(dirname "$rel")"
        cp -a "$f" "$WORKDIR/source_snapshot/$rel" 2>/dev/null || true
      done < <(find "$SOURCE_ROOT" -type f \( -name '*.cu' -o -name '*.cuh' -o -name '*.cpp' -o -name '*.cc' -o -name '*.c' -o -name '*.hpp' -o -name '*.h' -o -name 'CMakeLists.txt' -o -name '*.cmake' -o -name 'Makefile' -o -name '*.sh' \) -not -path '*/.git/*' -not -path '*/build/*' -not -path '*/dist/*' -print0 2>/dev/null)
    else
      echo "Source snapshot skipped: estimated ${src_size_kb} KiB exceeds MAX_SOURCE_MB=${MAX_SOURCE_MB}." > "$WORKDIR/build/source-snapshot-skipped.txt"
    fi
  fi
else
  echo "No source/build root detected. Run the collector from the source tree or set INCLUDE_SOURCE=0." > "$WORKDIR/build/source-root-not-found.txt"
fi

# --- Timed telemetry ----------------------------------------------------------
log "Starting ${DURATION}s telemetry while the miner keeps running..."
PIDS=()
if have nvidia-smi; then
  timeout "$((DURATION + 10))" nvidia-smi dmon -s pucvmet -d "$INTERVAL" -c "$((DURATION / INTERVAL))" > "$WORKDIR/telemetry/nvidia-dmon.log" 2>&1 & PIDS+=("$!")
  timeout "$((DURATION + 10))" nvidia-smi pmon -s um -d "$INTERVAL" -c "$((DURATION / INTERVAL))" > "$WORKDIR/telemetry/nvidia-pmon.log" 2>&1 & PIDS+=("$!")
  timeout "$((DURATION + 10))" nvidia-smi --query-gpu=timestamp,index,pstate,temperature.gpu,temperature.memory,fan.speed,utilization.gpu,utilization.memory,memory.used,power.draw,power.limit,clocks.current.graphics,clocks.current.sm,clocks.current.memory,pcie.link.gen.current,pcie.link.width.current --format=csv -l "$INTERVAL" > "$WORKDIR/telemetry/gpu-timeseries.csv" 2>&1 & PIDS+=("$!")
fi

timeout "$((DURATION + 10))" vmstat "$INTERVAL" "$((DURATION / INTERVAL + 1))" > "$WORKDIR/telemetry/vmstat.log" 2>&1 & PIDS+=("$!")
if have iostat; then timeout "$((DURATION + 10))" iostat -x -y "$INTERVAL" "$((DURATION / INTERVAL))" > "$WORKDIR/telemetry/iostat.log" 2>&1 & PIDS+=("$!"); fi
if have mpstat; then timeout "$((DURATION + 10))" mpstat -P ALL "$INTERVAL" "$((DURATION / INTERVAL))" > "$WORKDIR/telemetry/mpstat.log" 2>&1 & PIDS+=("$!"); fi
if [[ -n "$MINER_PID" && -d "/proc/$MINER_PID" ]]; then
  if have pidstat; then timeout "$((DURATION + 10))" pidstat -h -u -r -w -p "$MINER_PID" "$INTERVAL" "$((DURATION / INTERVAL))" > "$WORKDIR/telemetry/pidstat.log" 2>&1 & PIDS+=("$!"); fi
  if have perf; then timeout "$((DURATION + 10))" perf stat -p "$MINER_PID" -e task-clock,context-switches,cpu-migrations,page-faults,cycles,instructions,branches,branch-misses -o "$WORKDIR/telemetry/perf-stat.txt" -- sleep "$DURATION" >/dev/null 2>&1 & PIDS+=("$!"); fi
fi

for p in "${PIDS[@]}"; do wait "$p" 2>/dev/null || true; done
log "Telemetry complete."

# Post-run snapshots
if have nvidia-smi; then
  run nvidia/nvidia-smi-q-after.txt nvidia-smi -q
  run_sh nvidia/nvidia-errors-after.txt 'nvidia-smi; echo; (dmesg -T 2>/dev/null || dmesg) | grep -Ei "NVRM|Xid|fallen off|GPU fault|AER" || true'
fi
if [[ -n "$MINER_PID" && -d "/proc/$MINER_PID" ]]; then
  run_sh process/identity-after.txt "ps -p '$MINER_PID' -o pid,ppid,lstart,etime,stat,ni,pri,psr,pcpu,pmem,rss,vsz,nlwp,comm,args --cols 400"
fi

# --- Lightweight summary ------------------------------------------------------
{
  echo "PepePow Profiler Pack v$SCRIPT_VERSION"
  echo "Generated: $(date --iso-8601=seconds 2>/dev/null || date)"
  echo "Miner PID: ${MINER_PID:-not detected}"
  echo "Miner binary: ${MINER_EXE:-not detected}"
  echo "Duration: ${DURATION}s"
  echo
  echo "=== NVIDIA ==="
  nvidia-smi --query-gpu=index,name,driver_version,pstate,temperature.gpu,utilization.gpu,utilization.memory,power.draw,power.limit,clocks.current.sm,clocks.current.memory,pcie.link.gen.current,pcie.link.width.current --format=csv 2>/dev/null || true
  echo
  echo "=== Archive contents ==="
  du -h -d 2 "$WORKDIR" 2>/dev/null | sort -h
  echo
  echo "NOTE: The archive can contain wallet addresses, pool hostnames and source code. Common passwords/tokens are redacted, but review before sharing publicly."
} > "$WORKDIR/SUMMARY.txt"

# Remove empty files and package the result.
find "$WORKDIR" -type f -empty -delete 2>/dev/null || true
log "Creating archive: $ARCHIVE"
tar -C "$(dirname "$WORKDIR")" -czf "$ARCHIVE" "$(basename "$WORKDIR")"
sha256sum "$ARCHIVE" | tee "${ARCHIVE}.sha256"

printf '\nDONE\nArchive: %s\nSHA256: %s\n\n' "$ARCHIVE" "${ARCHIVE}.sha256"
printf 'Upload both files. The miner was not stopped or restarted.\n'
