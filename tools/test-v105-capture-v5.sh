#!/usr/bin/env bash
set -u

NAME="${PEPEW_NAME:-PepeW-Miner-v1.0.5-HiveOS}"
DIR="${PEPEW_DIR:-/hive/miners/custom/$NAME}"
LOG_ROOT="${PEPEW_LOG_ROOT:-/var/log/miner/custom/$NAME}"
GPU_COUNT="${PEPEW_EXPECTED_GPU_COUNT:-1}"
WAIT_SEC="${PEPEW_START_WAIT_SECONDS:-300}"
CAPTURE_SEC="${PEPEW_CAPTURE_SECONDS:-600}"
SAMPLE_SEC="${PEPEW_SAMPLE_INTERVAL:-2}"
DISPLAY_SEC="${PEPEW_DISPLAY_INTERVAL:-10}"
LOSS_GRACE="${PEPEW_PROCESS_LOSS_GRACE:-20}"
BASE="${PEPEW_SESSION_BASE:-/root/pepew-tests}"
MODE="${1:-capture}"

num(){ [[ "${1:-}" =~ ^[0-9]+$ ]]; }
pos(){ [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]; }
val(){ sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n1; }
workers(){ pgrep -x pepepowminer 2>/dev/null | wc -l | tr -d ' '; }
proxies(){ pgrep -f '[s]tratum-replay-proxy.py' 2>/dev/null | wc -l | tr -d ' '; }
mhs(){ local x="${1:-0}"; num "$x"||x=0; awk -v x="$x" 'BEGIN{printf "%.3f",x/1e6}'; }
timefmt(){ local s="${1:-0}"; num "$s"||s=0; printf '%02d:%02d' $((s/60)) $((s%60)); }
bar(){ local d=$1 t=$2 w=24 f e a b p; ((t>0))||t=1; ((d>t))&&d=$t; p=$((d*100/t)); f=$((d*w/t)); e=$((w-f)); printf -v a '%*s' "$f" ''; a=${a// /#}; printf -v b '%*s' "$e" ''; b=${b// /-}; printf '[%s%s] %3d%%' "$a" "$b" "$p"; }
trim(){ local x="${1:-}"; x="${x#${x%%[![:space:]]*}}"; x="${x%${x##*[![:space:]]}}"; printf '%s' "$x"; }

usage(){ cat <<'TXT'
Usage:
  ./test-v105-capture-v5.sh check
  ./test-v105-capture-v5.sh capture

Start CAPTURE first. When it prints [WAIT], launch the v1.0.5-test3 flight sheet manually in HiveOS.
The collector NEVER runs miner start/stop/restart.

Defaults:
  PEPEW_EXPECTED_GPU_COUNT=1
  PEPEW_START_WAIT_SECONDS=300
  PEPEW_CAPTURE_SECONDS=600
  PEPEW_SAMPLE_INTERVAL=2
  PEPEW_DISPLAY_INTERVAL=10
  PEPEW_PROCESS_LOSS_GRACE=20
TXT
}

settings(){
  pos "$GPU_COUNT" && pos "$WAIT_SEC" && pos "$CAPTURE_SEC" && pos "$SAMPLE_SEC" && pos "$DISPLAY_SEC" && pos "$LOSS_GRACE" || {
    echo 'ERROR: numeric PEPEW_* values must be positive integers.' >&2; return 2; }
}

preflight(){
  local fail=0 c n
  echo '===== CAPTURE v5 PREFLIGHT ====='
  for c in bash awk sed grep tail pgrep ps date tar sha256sum nvidia-smi head sort comm touch; do
    command -v "$c" >/dev/null 2>&1 && echo "[OK] $c" || { echo "[FAIL] missing $c"; fail=1; }
  done
  [[ -d "$DIR" ]] && echo "[OK] package $DIR" || { echo "[FAIL] package missing: $DIR"; fail=1; }
  [[ -x "$DIR/pepepowminer" ]] && echo '[OK] pepepowminer executable' || { echo '[FAIL] pepepowminer'; fail=1; }
  [[ -x "$DIR/h-run.sh" ]] && echo '[OK] h-run.sh executable' || { echo '[FAIL] h-run.sh'; fail=1; }
  [[ -x "$DIR/h-stats.sh" ]] && echo '[OK] h-stats.sh executable' || { echo '[FAIL] h-stats.sh'; fail=1; }
  n="$(nvidia-smi -L 2>/dev/null | grep -c '^GPU ' || true)"; num "$n"||n=0
  ((n>=GPU_COUNT)) && echo "[OK] NVIDIA GPUs=$n" || { echo "[FAIL] NVIDIA GPUs=$n expected=$GPU_COUNT"; fail=1; }
  if [[ -x "$DIR/pepepowminer" ]]; then
    echo '--- VERSION ---'; "$DIR/pepepowminer" --version 2>&1 | head -n5 || true
    echo '--- GPU LIST ---'; "$DIR/pepepowminer" --list-gpu 2>&1 || true
  fi
  [[ -f "$DIR/BUILD_PROFILE" ]] && { echo '--- BUILD_PROFILE ---'; cat "$DIR/BUILD_PROFILE"; }
  if [[ -f "$DIR/pepepowminer.sha256" ]]; then
    echo '--- SHA256 ---'; (cd "$DIR" && sha256sum -c pepepowminer.sha256) || fail=1
  fi
  echo "workers=$(workers) proxies=$(proxies)"
  ((fail==0)) && { echo 'PEPEW_CAPTURE_V5_CHECK=PASS'; return 0; }
  echo 'PEPEW_CAPTURE_V5_CHECK=FAIL'; return 1
}

settings || exit $?
case "$MODE" in
  help|-h|--help) usage; exit 0;;
  check) preflight; exit $?;;
  capture) ;;
  *) usage; exit 2;;
esac
((EUID==0)) || { echo 'ERROR: run as root.' >&2; exit 2; }
preflight || exit 3

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SD="$BASE/PepeW-v105-capture-v5-$STAMP"; ARC="$SD.tar.gz"; SUM="$SD/SUMMARY.txt"
mkdir -p "$SD/system" "$SD/logs" "$SD/status"
START="$(date +%s)"; READY=0; END_TARGET=0; RESULT=WAITING_FOR_MINER; FINAL=0; LOST=0; LAST_PRINT=0
declare -a TPIDS=()

capture(){ local o=$1; shift; { echo "UTC=$(date -u +%FT%TZ)"; printf 'CMD='; printf '%q ' "$@"; echo; "$@" 2>&1||true; } >"$o"; }

hps_for(){
  local i=$1 s="$DIR/gpu$i/miner-status.env" h=0 u=0 p=0 now log latest
  if [[ -s "$s" ]]; then
    h="$(val "$s" HPS)"; num "$h"||h=0; u="$(val "$s" UPDATED_EPOCH)"; num "$u"||u=0; p="$(val "$s" PID)"; num "$p"||p=0
  fi
  now=$(date +%s)
  if ((h>0&&u>0&&now>=u&&now-u<=45&&p>0)) && kill -0 "$p" 2>/dev/null; then echo "$h"; return; fi
  log="$LOG_ROOT/gpu$i/pepew.log"
  latest="$(grep -a '\[MINING\]' "$log" 2>/dev/null|tail -n1|sed -nE 's/.*\[MINING\][[:space:]]+([0-9]+([.][0-9]+)?) MH\/s.*/\1/p')"
  [[ "$latest" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v x="$latest" 'BEGIN{printf "%.0f",x*1e6}' || echo 0
}

status_line(){
  local i=$1 s="$DIR/gpu$i/miner-status.env" h a r row t p u c m ps
  h="$(hps_for "$i")"; a=0;r=0
  [[ -s "$s" ]] && { a="$(val "$s" ACCEPTED)";r="$(val "$s" REJECTED)"; }; num "$a"||a=0;num "$r"||r=0
  row="$(nvidia-smi -i "$i" --query-gpu=temperature.gpu,power.draw,utilization.gpu,clocks.current.graphics,clocks.current.memory,pstate --format=csv,noheader,nounits 2>/dev/null|head -n1)"
  IFS=',' read -r t p u c m ps <<<"$row"
  printf 'GPU%d %sMH/s A%s R%s T=%sC P=%sW U=%s%% C=%s M=%s %s' "$i" "$(mhs "$h")" "$a" "$r" "$(trim "$t")" "$(trim "$p")" "$(trim "$u")" "$(trim "$c")" "$(trim "$m")" "$(trim "$ps")"
}

ready(){
  local i h ok=0; (( $(workers)>=GPU_COUNT && $(proxies)>=GPU_COUNT ))||return 1
  for((i=0;i<GPU_COUNT;i++));do h="$(hps_for "$i")";num "$h"||h=0;((h>0))&&ok=$((ok+1));done
  ((ok==GPU_COUNT))
}

sample(){
  local phase=$1 ts i s h a r u age pid ppid l1 l5 l15 ma sf wc pc cpu pm x
  ts="$(date -u +%FT%TZ)"
  while IFS= read -r row; do [[ -n "$row" ]]&&echo "$ts,$phase,$row">>"$SD/gpu.csv"; done < <(nvidia-smi --query-gpu=index,name,uuid,pci.bus_id,temperature.gpu,fan.speed,power.draw,power.limit,clocks.current.graphics,clocks.current.memory,utilization.gpu,utilization.memory,memory.used,memory.total,pstate --format=csv,noheader,nounits 2>/dev/null||true)
  for((i=0;i<GPU_COUNT;i++));do
    s="$DIR/gpu$i/miner-status.env";h="$(hps_for "$i")";a=0;r=0;u=0;pid=0;ppid=0
    if [[ -s "$s" ]];then a="$(val "$s" ACCEPTED)";r="$(val "$s" REJECTED)";u="$(val "$s" UPDATED_EPOCH)";pid="$(val "$s" PID)";fi
    for x in h a r u pid;do num "${!x}"||printf -v "$x" 0;done
    [[ -r "$DIR/gpu$i/proxy.pid" ]]&&ppid="$(tr -dc 0-9<"$DIR/gpu$i/proxy.pid" 2>/dev/null||true)";num "$ppid"||ppid=0
    age=-1;((u>0))&&age=$(( $(date +%s)-u ))
    echo "$ts,$phase,$i,$h,$(mhs "$h"),$a,$r,$u,$age,$pid,$ppid">>"$SD/miner.csv"
  done
  read -r l1 l5 l15 _ </proc/loadavg;ma="$(awk '/MemAvailable:/{print $2;exit}' /proc/meminfo)";sf="$(awk '/SwapFree:/{print $2;exit}' /proc/meminfo)"
  wc=$(workers);pc=$(proxies);cpu="$(ps -C pepepowminer -o %cpu= 2>/dev/null|awk '{s+=$1}END{printf "%.1f",s+0}')";pm="$(ps -C pepepowminer -o %mem= 2>/dev/null|awk '{s+=$1}END{printf "%.1f",s+0}')"
  echo "$ts,$phase,$l1,$l5,$l15,$ma,$sf,$wc,$pc,$cpu,$pm">>"$SD/system.csv"
}

start_tails(){ local i f p;for((i=0;i<GPU_COUNT;i++));do for f in pepew.log stratum-proxy.log proxy-console.log;do p="$LOG_ROOT/gpu$i/$f";mkdir -p "$(dirname "$p")";touch "$p";tail -n0 -F "$p">"$SD/logs/gpu$i-$f" 2>/dev/null&TPIDS+=("$!");done;done; }
stop_tails(){ local p;for p in "${TPIDS[@]:-}";do kill "$p" 2>/dev/null||true;done;for p in "${TPIDS[@]:-}";do wait "$p" 2>/dev/null||true;done; }

finish(){
  ((FINAL==0))||return;FINAL=1;trap - INT TERM EXIT;stop_tails
  local now mining=0 i f
  now=$(date +%s);((READY>0))&&mining=$((now-READY))
  capture "$SD/system/nvidia-smi-end.txt" nvidia-smi;capture "$SD/system/nvidia-smi-q-end.txt" nvidia-smi -q;capture "$SD/system/ecc-end.txt" nvidia-smi -q -d ECC;capture "$SD/system/perf-end.txt" nvidia-smi -q -d PERFORMANCE,POWER,CLOCK,UTILIZATION,TEMPERATURE;dmesg>"$SD/system/dmesg-end.txt" 2>&1||true
  grep -E 'NVRM: Xid|Xid \(' "$SD/system/dmesg-end.txt">"$SD/system/xid-end.txt" 2>/dev/null||true
  comm -13 <(sort "$SD/system/xid-start.txt" 2>/dev/null) <(sort "$SD/system/xid-end.txt" 2>/dev/null)>"$SD/system/xid-new.txt" 2>/dev/null||true
  for((i=0;i<GPU_COUNT;i++));do [[ -f "$DIR/gpu$i/miner-status.env" ]]&&cp "$DIR/gpu$i/miner-status.env" "$SD/status/gpu$i-final.env";done
  [[ -f "$LOG_ROOT/runtime-diagnostics.txt" ]]&&cp "$LOG_ROOT/runtime-diagnostics.txt" "$SD/logs/";[[ -f "$LOG_ROOT/miner-exit-status.txt" ]]&&cp "$LOG_ROOT/miner-exit-status.txt" "$SD/logs/"
  {
    echo '===== PepeW v1.0.5 capture-v5 summary =====';echo "RESULT=$RESULT";echo "TOTAL_SEC=$((now-START))";echo "READY_WAIT_SEC=$((READY>0?READY-START:0))";echo "MINING_CAPTURE_SEC=$mining"
    echo '--- GPU ---'
    awk -F',' 'NR>1&&$2=="RUN"{g=$3;t=$7+0;p=$9+0;u=$13+0;n[g]++;ts[g]+=t;ps[g]+=p;us[g]+=u;if(!(g in tmin)||t<tmin[g])tmin[g]=t;if(t>tmax[g])tmax[g]=t;if(!(g in pmin)||p<pmin[g])pmin[g]=p;if(p>pmax[g])pmax[g]=p}END{for(g in n)printf "GPU%s samples=%d temp_avg=%.1f min=%.1f max=%.1f power_avg=%.1f min=%.1f max=%.1f util_avg=%.1f%%\n",g,n[g],ts[g]/n[g],tmin[g],tmax[g],ps[g]/n[g],pmin[g],pmax[g],us[g]/n[g]}' "$SD/gpu.csv"
    echo '--- MINER ---'
    awk -F',' 'NR>1&&$2=="RUN"{g=$3;h=$5+0;a=$6+0;r=$7+0;n[g]++;hs[g]+=h;if(!(g in hmin)||h<hmin[g])hmin[g]=h;if(h>hmax[g])hmax[g]=h;if(!(g in af)){af[g]=a;rf[g]=r}al[g]=a;rl[g]=r}END{for(g in n)printf "GPU%s hash_avg=%.3fMH/s min=%.3f max=%.3f A_start=%d A_end=%d A_delta=%d R_start=%d R_end=%d R_delta=%d\n",g,hs[g]/n[g],hmin[g],hmax[g],af[g],al[g],al[g]-af[g],rf[g],rl[g],rl[g]-rf[g]}' "$SD/miner.csv"
    echo '--- NEW XID ---';[[ -s "$SD/system/xid-new.txt" ]]&&cat "$SD/system/xid-new.txt"||echo none
  } >"$SUM"
  tar -C "$(dirname "$SD")" -czf "$ARC" "$(basename "$SD")";sha256sum "$ARC">"$ARC.sha256"
  echo;echo '===== CAPTURE COMPLETE =====';cat "$SUM";echo "SESSION_ARCHIVE=$ARC";echo "SESSION_ARCHIVE_SHA256=$(awk '{print $1}' "$ARC.sha256")";echo 'MINER_CONTROL=NONE'
}
trap 'RESULT=INTERRUPTED;finish;exit 130' INT TERM
trap finish EXIT

echo 'timestamp_utc,phase,index,name,uuid,pci_bus,temp_c,fan_pct,power_w,power_limit_w,core_mhz,mem_mhz,util_gpu_pct,util_mem_pct,mem_used_mib,mem_total_mib,pstate'>"$SD/gpu.csv"
echo 'timestamp_utc,phase,gpu,hps,mhs,accepted,rejected,updated_epoch,status_age,pid,proxy_pid'>"$SD/miner.csv"
echo 'timestamp_utc,phase,load1,load5,load15,mem_available_kb,swap_free_kb,workers,proxies,miner_cpu_pct,miner_mem_pct'>"$SD/system.csv"
capture "$SD/system/nvidia-smi-start.txt" nvidia-smi;capture "$SD/system/nvidia-smi-q-start.txt" nvidia-smi -q;capture "$SD/system/ecc-start.txt" nvidia-smi -q -d ECC;capture "$SD/system/perf-start.txt" nvidia-smi -q -d PERFORMANCE,POWER,CLOCK,UTILIZATION,TEMPERATURE;capture "$SD/system/topo.txt" nvidia-smi topo -m;capture "$SD/system/free.txt" free -h;capture "$SD/system/uname.txt" uname -a;dmesg>"$SD/system/dmesg-start.txt" 2>&1||true;grep -E 'NVRM: Xid|Xid \(' "$SD/system/dmesg-start.txt">"$SD/system/xid-start.txt" 2>/dev/null||true
for f in VERSION BUILD_PROFILE config.txt active-workers.env pepepowminer.sha256;do [[ -f "$DIR/$f" ]]&&cp "$DIR/$f" "$SD/";done
"$DIR/pepepowminer" --version>"$SD/binary-version.txt" 2>&1||true;"$DIR/pepepowminer" --list-gpu>"$SD/list-gpu.txt" 2>&1||true
start_tails

echo;echo '===== PepeW CAPTURE v5 =====';echo "session=$SD";echo "wait=$(timefmt "$WAIT_SEC") capture=$(timefmt "$CAPTURE_SEC") sample=${SAMPLE_SEC}s display=${DISPLAY_SEC}s";echo 'MINER_CONTROL=NONE';echo;echo '[STEP 1] Collector is running.';echo '[STEP 2] NOW launch v1.0.5-test3 manually from the HiveOS flight sheet.';echo '[STEP 3] Return here and wait for [READY].';echo

while ((READY==0));do
  now=$(date +%s);e=$((now-START));sample WAIT
  if ready;then READY=$now;END_TARGET=$((READY+CAPTURE_SEC));RESULT=CAPTURING;echo;echo "[READY] after $(timefmt "$e"). Measurement starts NOW.";for((i=0;i<GPU_COUNT;i++));do echo "        $(status_line "$i")";done;echo;LAST_PRINT=0;break;fi
  ((e>=WAIT_SEC))&&{ RESULT=START_TIMEOUT;echo "[ERROR] START_TIMEOUT after $(timefmt "$e")";exit 4; }
  if ((now-LAST_PRINT>=DISPLAY_SEC));then printf '[WAIT] %s/%s workers=%s/%s proxies=%s/%s' "$(timefmt "$e")" "$(timefmt "$WAIT_SEC")" "$(workers)" "$GPU_COUNT" "$(proxies)" "$GPU_COUNT";for((i=0;i<GPU_COUNT;i++));do printf ' | %s' "$(status_line "$i")";done;echo;LAST_PRINT=$now;fi
  sleep "$SAMPLE_SEC"
done

while :;do
  now=$(date +%s);e=$((now-READY));sample RUN;wc=$(workers);pc=$(proxies)
  if ((wc<GPU_COUNT||pc<GPU_COUNT));then if ((LOST==0));then LOST=$now;echo "[WARN] process count dropped, grace=${LOSS_GRACE}s";elif ((now-LOST>=LOSS_GRACE));then RESULT=PROCESS_LOST;echo '[ERROR] process loss persisted';break;fi;else ((LOST>0))&&echo '[INFO] processes recovered';LOST=0;fi
  if ((now-LAST_PRINT>=DISPLAY_SEC));then left=$((CAPTURE_SEC-e));((left<0))&&left=0;printf '[RUN] %s elapsed=%s left=%s' "$(bar "$e" "$CAPTURE_SEC")" "$(timefmt "$e")" "$(timefmt "$left")";for((i=0;i<GPU_COUNT;i++));do printf ' | %s' "$(status_line "$i")";done;echo;LAST_PRINT=$now;fi
  ((now>=END_TARGET))&&{ RESULT=COMPLETED;break; };sleep "$SAMPLE_SEC"
done
finish
