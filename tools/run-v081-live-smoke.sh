#!/usr/bin/env bash
set -euo pipefail
umask 077
OUT_ROOT="${OUT_ROOT:-/root/pepepow-tests}"; DURATION="${DURATION:-300}"; WARMUP="${WARMUP:-60}"; PORT="${PORT:-35581}"
STAMP="$(date +%Y%m%d_%H%M%S)"; NAME="v081-live-smoke-${STAMP}"; STAGE="${OUT_ROOT}/${NAME}"; ARCHIVE="${OUT_ROOT}/${NAME}.tar.gz"
PUB_URL="https://raw.githubusercontent.com/iPepew/PepePow_Miner/experiment/v0.8.1-coldpath/tools/publish-test-results.sh"
for c in bash grep sed awk python3 nvidia-smi tar sha256sum curl stdbuf; do command -v "$c" >/dev/null || { echo "ERROR: missing $c"; exit 1; }; done
(( DURATION>=180 && WARMUP>=30 && WARMUP<DURATION )) || { echo 'ERROR: invalid DURATION/WARMUP'; exit 1; }

stable=""; for d in /hive/miners/custom/pepepowminer-v0.6.0-PR /hive/miners/custom/pepepowminer /hive/miners/custom/pepepow; do
  [[ -x "$d/pepepowminer" && -f "$d/config.txt" && -x "$d/stratum-replay-proxy.py" ]] && { stable="$(readlink -f "$d")"; break; }
done
candidate=""; for d in /root/pepepow-v060-8h-src/build-v081-coldpath/selector-combined /root/pepepow-v060-src/build-v081-coldpath/selector-combined /root/PepePow_Miner/build-v081-coldpath/selector-combined; do
  [[ -x "$d/pepepowminer" && -x "$d/pepepow_cuda_header80_validation" ]] && { candidate="$(readlink -f "$d")"; break; }
done
[[ -n "$stable" ]] || { echo 'ERROR: stable config/proxy not found'; exit 1; }
[[ -n "$candidate" ]] || { echo 'ERROR: selector-combined build not found'; exit 1; }
# shellcheck disable=SC1090
source "$stable/config.txt"
declare -p PEPEPOW_ARGS >/dev/null 2>&1 || { echo 'ERROR: PEPEPOW_ARGS missing'; exit 1; }
: "${PEPEPOW_UPSTREAM:?missing PEPEPOW_UPSTREAM}"
apps="$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null || true)"
[[ -z "${apps//[[:space:]]/}" ]] || { echo 'ERROR: GPU busy; use empty flight sheet'; echo "$apps"; exit 2; }

mkdir -p "$STAGE"/{logs,metadata,nvidia}; raw="$STAGE/logs/miner.raw.log"; log="$STAGE/logs/miner.log"; praw="$STAGE/logs/proxy.raw.log"; plog="$STAGE/logs/proxy.log"; pcon="$STAGE/logs/proxy-console.log"; gpu="$STAGE/logs/gpu.csv"
status="$STAGE/status.env"; summary="$STAGE/summary.txt"; errpat='WORKER_ERROR|illegal memory access|unspecified launch failure|device-side assert|CUDA_ERROR|cudaError|CUDA error|out of memory|failed to launch|cudaMemcpy[^[:cntrl:]]*(failed|error)'
xids(){ dmesg 2>/dev/null | grep -Ec 'NVRM: Xid|Xid \(' || true; }
setstatus(){ printf 'STATE=%q\nREASON=%q\nELAPSED=%q\nDURATION=%q\n' "$1" "${2:-}" "${3:-0}" "$DURATION" >"$status"; }

args=("${PEPEPOW_ARGS[@]}"); found=0
for ((i=0;i<${#args[@]};i++)); do if [[ "${args[$i]}" == -o || "${args[$i]}" == --pool ]]; then args[$((i+1))]="stratum+tcp://127.0.0.1:${PORT}"; found=1; break; fi; done
(( found==1 )) || { echo 'ERROR: pool argument not found'; exit 1; }
wallet=""; for ((i=0;i<${#PEPEPOW_ARGS[@]};i++)); do [[ "${PEPEPOW_ARGS[$i]}" == -u ]] && { wallet="${PEPEPOW_ARGS[$((i+1))]}"; break; }; done

mpid=""; ppid=""; cleanup(){ for p in "${mpid:-}" "${ppid:-}"; do [[ -n "$p" ]] && kill -TERM "$p" 2>/dev/null || true; done; sleep 1; for p in "${mpid:-}" "${ppid:-}"; do [[ -n "$p" ]] && kill -KILL "$p" 2>/dev/null || true; done; }; trap cleanup EXIT INT TERM
setstatus PRECHECK
"$candidate/pepepow_cuda_header80_validation" >"$STAGE/metadata/validation.log" 2>&1
sha256sum "$candidate/pepepowminer" >"$STAGE/metadata/binary.sha256"; "$candidate/pepepowminer" --version >"$STAGE/metadata/version.txt" 2>&1 || true
nvidia-smi -q >"$STAGE/nvidia/before.txt" 2>&1 || true; dmesg 2>/dev/null | grep -E 'NVRM|Xid' >"$STAGE/nvidia/xid-before.txt" || true; xb="$(xids)"
printf 'name=%s\ncandidate=selector-combined\nduration=%s\nwarmup=%s\nstarted_at=%s\n' "$NAME" "$DURATION" "$WARMUP" "$(date --iso-8601=seconds)" >"$STAGE/MANIFEST.txt"
: >"$raw"; : >"$praw"; echo 'elapsed,temp,util,core,power' >"$gpu"
"$stable/stratum-replay-proxy.py" --upstream "$PEPEPOW_UPSTREAM" --listen-host 127.0.0.1 --listen-port "$PORT" --log "$praw" >"$pcon" 2>&1 & ppid=$!; sleep 2
kill -0 "$ppid" 2>/dev/null || { cat "$pcon"; exit 1; }
start="$(date +%s)"; (cd "$stable"; exec stdbuf -oL -eL "$candidate/pepepowminer" "${args[@]}") >"$raw" 2>&1 & mpid=$!
fail=""; setstatus RUNNING '' 0; echo "SMOKE_START pid=$mpid duration=$DURATION"
while :; do
  now="$(date +%s)"; elapsed=$((now-start)); setstatus RUNNING '' "$elapsed"
  nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,clocks.current.sm,power.draw --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' | sed "s/^/${elapsed},/" >>"$gpu" || true
  kill -0 "$mpid" 2>/dev/null || { fail=miner_exited_early; break; }
  kill -0 "$ppid" 2>/dev/null || { fail=proxy_exited_early; break; }
  grep -Eaiq "$errpat" "$raw" 2>/dev/null && { fail=cuda_or_worker_error; break; }
  xn="$(xids)"; (( xn>xb )) && { fail=new_nvidia_xid; break; }
  (( elapsed>=DURATION )) && break
  sleep 2
done
setstatus STOPPING "$fail" "$elapsed"; cleanup; trap - EXIT INT TERM
python3 - "$raw" "$log" "$praw" "$plog" "$pcon" "$wallet" <<'PY'
from pathlib import Path
import sys
pairs=((sys.argv[1],sys.argv[2]),(sys.argv[3],sys.argv[4]),(sys.argv[5],sys.argv[5]))
for s,d in pairs:
 t=Path(s).read_text(errors='replace') if Path(s).exists() else ''
 if sys.argv[6]: t=t.replace(sys.argv[6],'<REDACTED_WALLET_WORKER>')
 Path(d).write_text(t,encoding='utf-8')
PY
rm -f "$raw" "$praw"; nvidia-smi -q >"$STAGE/nvidia/after.txt" 2>&1 || true; dmesg 2>/dev/null | grep -E 'NVRM|Xid' >"$STAGE/nvidia/xid-after.txt" || true; xa="$(xids)"
python3 - "$log" "$gpu" "$summary" "$WARMUP" "$fail" "$xb" "$xa" <<'PY'
import csv,re,statistics,sys
from pathlib import Path
log,gpu,out,warm,fail,xb,xa=sys.argv[1:]; warm=int(warm); xb=int(xb); xa=int(xa)
t=re.sub(r'\x1b\[[0-9;]*m','',Path(log).read_text(errors='replace'))
def sec(s):
 v=0
 for x in s.split(':'): v=v*60+int(x)
 return v
s=[(float(m.group(1)),int(m.group(2)),int(m.group(3)),sec(m.group(4))) for m in re.finditer(r'\[MINING\]\s*\|\s*([0-9.]+)\s+MH/s\s*\|\s*A\s+(\d+)\s*\|\s*R\s+(\d+)\s*\|\s*Uptime\s+([0-9:]+)',t)]
r=[x[0] for x in s if x[3]>=warm]; a=s[-1][1] if s else 0; rej=s[-1][2] if s else 0
rows=[]
try:
 for x in csv.DictReader(open(gpu)):
  if int(x['elapsed'])>=warm and float(x['util'])>=50: rows.append(x)
except Exception: pass
def avg(k):
 v=[float(x[k]) for x in rows]
 return statistics.mean(v) if v else 0
if fail: gate,reason='FAIL',fail
elif xa>xb: gate,reason='FAIL','new_nvidia_xid'
elif not r: gate,reason='FAIL','no_warm_hashrate_samples'
elif rej: gate,reason='FAIL','rejected_shares'
elif not a: gate,reason='INCONCLUSIVE','no_accepted_shares'
else: gate,reason='PASS','ok'
data={'candidate':'selector-combined','gate':gate,'reason':reason,'samples':len(r),'mean_mhs':statistics.mean(r) if r else 0,'median_mhs':statistics.median(r) if r else 0,'min_mhs':min(r) if r else 0,'max_mhs':max(r) if r else 0,'stdev_mhs':statistics.pstdev(r) if r else 0,'accepted':a,'rejected':rej,'jobs':len(re.findall(r'\[JOB\]',t)),'clock_mean_mhz':avg('core'),'power_mean_w':avg('power'),'temp_mean_c':avg('temp'),'xid_before':xb,'xid_after':xa,'new_xid_count':max(0,xa-xb)}
with open(out,'w') as f:
 for k,v in data.items(): f.write(f'{k}={v}\n')
 f.write('LIVE_GATE='+('SMOKE_PASS' if gate=='PASS' else 'PENDING')+'\nTARGET_2MH=PENDING\n')
PY
printf 'finished_at=%s\n' "$(date --iso-8601=seconds)" >>"$STAGE/MANIFEST.txt"; setstatus COMPLETE "$(grep '^reason=' "$summary"|cut -d= -f2-)" "$elapsed"
tar -C "$OUT_ROOT" -czf "$ARCHIVE" "$NAME"; sha256sum "$ARCHIVE" >"$ARCHIVE.sha256"
echo; echo '========== V0.8.1 LIVE SMOKE COMPLETE =========='; cat "$summary"; echo "ARCHIVE=$ARCHIVE"; echo "SHA256_FILE=$ARCHIVE.sha256"; echo 'NOTE=Stable miner was not restarted automatically.'
if curl -fsSL "$PUB_URL" -o /root/publish-pepepow-test-results.sh; then chmod +x /root/publish-pepepow-test-results.sh; PUBLIC_UPLOAD="${PUBLIC_UPLOAD:-1}" /root/publish-pepepow-test-results.sh "$ARCHIVE" || true; fi
