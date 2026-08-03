#!/usr/bin/env bash
set -euo pipefail
umask 077

SOURCE_ROOT="${SOURCE_ROOT:-}"
OUT_ROOT="${OUT_ROOT:-/root/pepepow-tests}"
NONCES="${NONCES:-8388608}"
RUNS="${RUNS:-5}"
STRESS_RUNS="${STRESS_RUNS:-20}"
STRESS_NONCES="${STRESS_NONCES:-33554432}"
JOBS="${JOBS:-$(nproc)}"
P080="${P080:-/root/prepare-v080-grand-source.py}"
P081="${P081:-/root/prepare-v081-coldpath-source.py}"
PZERO="${PZERO:-/root/prepare-v200-zero-safe-source.py}"
PSERVICE="${PSERVICE:-/root/prepare-v200-warp-service-source.py}"
STAMP="$(date +%Y%m%d_%H%M%S)"
NAME="v200-warp-service-${STAMP}"
STAGE="${OUT_ROOT}/${NAME}"
ARCHIVE="${OUT_ROOT}/${NAME}.tar.gz"
RESULTS="${STAGE}/results.csv"
PUBLISHER_URL="https://raw.githubusercontent.com/iPepew/PepePow_Miner/experiment/v2.0.0-warp-service/tools/publish-test-results.sh"
PUBLISHER="/root/publish-pepepow-test-results.sh"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1" >&2; exit 1; }; }
for c in bash awk sed grep sha256sum tar python3 nvidia-smi cmake ctest curl timeout; do need "$c"; done
for p in "$P080" "$P081" "$PZERO" "$PSERVICE"; do [[ -f "$p" ]] || { echo "ERROR: missing patcher: $p" >&2; exit 1; }; done

find_source_root(){
  local c
  if [[ -n "$SOURCE_ROOT" && -f "$SOURCE_ROOT/native/CMakeLists.txt" && -f "$SOURCE_ROOT/native/src/cuda/header80_backend_v060.cu" ]]; then readlink -f "$SOURCE_ROOT"; return; fi
  for c in /root/pepepow-v060-8h-src /root/pepepow-v060-src /root/pepepow-v0.6.0-src /root/PepePow_Miner; do
    [[ -f "$c/native/CMakeLists.txt" && -f "$c/native/src/cuda/header80_backend_v060.cu" ]] && { readlink -f "$c"; return; }
  done
  return 1
}
find_nvcc(){
  command -v nvcc >/dev/null 2>&1 && { command -v nvcc; return; }
  local c
  for c in /usr/local/cuda/bin/nvcc /usr/local/cuda-12.4/bin/nvcc /usr/local/cuda-12/bin/nvcc; do
    [[ -x "$c" ]] && { echo "$c"; return; }
  done
  return 1
}

SOURCE_ROOT="$(find_source_root || true)"
[[ -n "$SOURCE_ROOT" ]] || { echo "ERROR: prepared source tree not found" >&2; exit 1; }
NVCC="$(find_nvcc || true)"
[[ -n "$NVCC" ]] || { echo "ERROR: nvcc not found" >&2; exit 1; }
export PATH="$(dirname "$NVCC"):$PATH"

SOURCE_FILE="$SOURCE_ROOT/native/src/cuda/header80_backend_v060.cu"
BACKUP_FILE="$SOURCE_FILE.v200-backup-$STAMP"
BUILD_ROOT="$SOURCE_ROOT/build-v200-warp-service"
DEPS_DIR="$SOURCE_ROOT/.deps-v060"

apps="$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null || true)"
if [[ -n "${apps//[[:space:]]/}" ]]; then
  echo "ERROR: GPU busy. Use an empty flight sheet." >&2
  echo "$apps" >&2
  exit 2
fi

mkdir -p "$STAGE"/{profiles,nvidia,source,stress,sanitizer}
cp -f "$SOURCE_FILE" "$BACKUP_FILE"
cp -f "$SOURCE_FILE" "$STAGE/source/header80_backend_v060.original.cu"
cp -f "$P080" "$P081" "$PZERO" "$PSERVICE" "$STAGE/source/"
restore(){ [[ -f "$BACKUP_FILE" ]] && { cp -f "$BACKUP_FILE" "$SOURCE_FILE"; rm -f "$BACKUP_FILE"; }; }
trap restore EXIT INT TERM

IDS=(
 selector-combined-base
 zero-safe
 service64
 service64-zero
 service64-noinline
 service128
 service128-zero
 service128-noinline
 service256
 service256-zero
 service256-noinline
 service512
 service512-zero
 service512-noinline
)
COLD=(
 combined combined combined combined combined-noinline
 combined combined combined-noinline
 combined combined combined-noinline
 combined combined combined-noinline
)
SERVICE=(
 none none service service-zero service
 service service-zero service
 service service-zero service
 service service-zero service
)
ZERO=(
 0 1 0 0 0
 0 0 0
 0 0 0
 0 0 0
)
THREADS=(
 64 64 64 64 64
 128 128 128
 256 256 256
 512 512 512
)
BLOCKS=(
 2 2 1 1 1
 1 1 1
 1 1 1
 1 1 1
)
TOTAL="${#IDS[@]}"

cat >"$STAGE/MANIFEST.txt" <<META
name=$NAME
source_root=$SOURCE_ROOT
nonces=$NONCES
runs=$RUNS
stress_runs=$STRESS_RUNS
stress_nonces=$STRESS_NONCES
profiles_total=$TOTAL
target_hps=2000000
baseline=selector-combined-base
architecture=block_compacted_cold_service_warp
started_at=$(date --iso-8601=seconds)
META

nvidia-smi -q >"$STAGE/nvidia/nvidia-smi-before.txt" 2>&1 || true
dmesg 2>/dev/null | grep -E 'NVRM|Xid' >"$STAGE/nvidia/xid-before.txt" || true
"$NVCC" --version >"$STAGE/nvcc-version.txt" 2>&1 || true
printf '%s\n' 'profile,valid,cold_mode,service_mode,zero_safe,threads,min_blocks,registers,stack_bytes,spill_store_bytes,spill_load_bytes,min_hps,median_hps,mean_hps,max_hps,stdev_hps,median_mhs,clock_mean_mhz,power_mean_w,temp_mean_c,reason' >"$RESULTS"

extract_hps(){ sed -n 's/.* hps=\([0-9][0-9]*\).*/\1/p' <<<"$1" | tail -n1; }
extract_resource(){
  local f="$1" key="$2"
  awk -v key="$key" '/Function .*header80_pow_kernel/{x=1;next} x&&/REG:/{l=$0;if(key=="reg")sub(/^.*REG:/,"",l);else sub(/^.*STACK:/,"",l);sub(/[^0-9].*$/, "",l);print l+0;exit}' "$f"
}
extract_spill(){
  local f="$1" which="$2"
  awk -v w="$which" '/Compiling entry function .*header80_pow_kernel/{x=1;next} x&&/bytes stack frame, .* bytes spill stores, .* bytes spill loads/{if(w=="store"){for(i=1;i<=NF;i++)if($(i+1)=="bytes"&&$(i+2)=="spill"&&$(i+3)=="stores,"){print $i+0;exit}}else{for(i=1;i<=NF;i++)if($(i+1)=="bytes"&&$(i+2)=="spill"&&$(i+3)=="loads"){print $i+0;exit}}}' "$f"
}
invalid(){
  printf '%s,0,%s,%s,%s,%s,%s,0,0,0,0,0,0,0,0,0,0,0,0,0,%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" >>"$RESULTS"
}

run_profile(){
  local i="$1" profile cold service zero threads blocks dir out blog resource regs stack ss sl run output hps stats mn med mean mx sd mhs sampler stop gpu_stats clock power temp
  local -a speeds args
  profile="${IDS[$i]}"; cold="${COLD[$i]}"; service="${SERVICE[$i]}"; zero="${ZERO[$i]}"; threads="${THREADS[$i]}"; blocks="${BLOCKS[$i]}"
  dir="$BUILD_ROOT/$profile"; out="$STAGE/profiles/$profile"; blog="$out/build.log"
  mkdir -p "$out"; rm -rf "$dir"

  echo
  echo "PROFILE_INDEX=$((i+1))"
  echo "PROFILE_TOTAL=$TOTAL"
  echo "PROFILE=$profile"
  echo "PROFILE_CONFIG cold=$cold service=$service zero=$zero threads=$threads min_blocks=$blocks"
  echo "STATUS=PATCHING"

  cp -f "$BACKUP_FILE" "$SOURCE_FILE"
  if ! python3 "$P080" "$SOURCE_FILE" selector >"$out/selector-patch.log" 2>&1; then
    echo "PROFILE_RESULT profile=$profile valid=0 reason=selector_patch_failed"
    cat "$out/selector-patch.log"; invalid "$profile" "$cold" "$service" "$zero" "$threads" "$blocks" selector_patch_failed; return
  fi
  if ! python3 "$P081" "$SOURCE_FILE" "$cold" >"$out/combined-patch.log" 2>&1; then
    echo "PROFILE_RESULT profile=$profile valid=0 reason=combined_patch_failed"
    cat "$out/combined-patch.log"; invalid "$profile" "$cold" "$service" "$zero" "$threads" "$blocks" combined_patch_failed; return
  fi
  if [[ "$zero" == 1 ]]; then
    if ! python3 "$PZERO" "$SOURCE_FILE" >"$out/zero-patch.log" 2>&1; then
      echo "PROFILE_RESULT profile=$profile valid=0 reason=zero_patch_failed"
      cat "$out/zero-patch.log"; invalid "$profile" "$cold" "$service" "$zero" "$threads" "$blocks" zero_patch_failed; return
    fi
  fi
  if [[ "$service" != none ]]; then
    if ! python3 "$PSERVICE" "$SOURCE_FILE" "$service" >"$out/service-patch.log" 2>&1; then
      echo "PROFILE_RESULT profile=$profile valid=0 reason=service_patch_failed"
      cat "$out/service-patch.log"; invalid "$profile" "$cold" "$service" "$zero" "$threads" "$blocks" service_patch_failed; return
    fi
  fi
  cp -f "$SOURCE_FILE" "$out/header80_backend_v060.cu"

  args=(-S "$SOURCE_ROOT/native" -B "$dir"
    -DCMAKE_BUILD_TYPE=Release
    -DPEPEPOW_ENABLE_CUDA=ON
    -DPEPEPOW_BUILD_TESTS=ON
    -DPEPEPOW_CUDA_PTXAS_VERBOSE=ON
    -DPEPEPOW_CUDA_THREADS="$threads"
    -DPEPEPOW_CUDA_MIN_BLOCKS="$blocks"
    -DPEPEPOW_CUDA_MAX_REGISTERS=
    -DPEPEPOW_CUDA_SCALED_MATRIX=ON
    -DPEPEPOW_CUDA_SPLIT_PIPELINE=OFF
    -DPEPEPOW_CUDA_FAST_FRACTION=ON
    -DPEPEPOW_CUDA_EXACT_BIT_CONVERSIONS=ON
    -DPEPEPOW_CUDA_BIT_SW_FRACTION=ON
    -DPEPEPOW_CUDA_DERIVE_TWO=OFF
    -DPEPEPOW_CUDA_NIBBLE_TABLE=OFF
    -DPEPEPOW_CUDA_SCALED_NIBBLE_TABLE=ON
    -DPEPEPOW_CUDA_ASSUME_FINITE=ON
    -DPEPEPOW_CUDA_SW_STATE_MODE=3
    -DPEPEPOW_CUDA_BYTE_UNROLL=1
    -DCMAKE_CUDA_ARCHITECTURES=86
    -DCMAKE_CUDA_COMPILER="$NVCC"
    -DFETCHCONTENT_BASE_DIR="$DEPS_DIR")
  command -v ccache >/dev/null 2>&1 && args+=(
    -DCMAKE_C_COMPILER_LAUNCHER=ccache
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
    -DCMAKE_CUDA_COMPILER_LAUNCHER=ccache)

  echo "STATUS=BUILDING"
  if ! {
    cmake "${args[@]}"
    cmake --build "$dir" --parallel "$JOBS" --target \
      pepepow_core_tests pepepow_cuda_tests pepepow_cuda_header80_validation \
      pepepow_header80_benchmark pepepowminer
  } >"$blog" 2>&1; then
    echo "PROFILE_RESULT profile=$profile valid=0 reason=build_failed"
    tail -n140 "$blog"
    invalid "$profile" "$cold" "$service" "$zero" "$threads" "$blocks" build_failed
    return
  fi

  echo "STATUS=VALIDATING"
  if ! ctest --test-dir "$dir" --output-on-failure >"$out/ctest.log" 2>&1 ||
     ! timeout 300 "$dir/pepepow_cuda_header80_validation" >"$out/validation.log" 2>&1; then
    echo "PROFILE_RESULT profile=$profile valid=0 reason=consensus_failed"
    cat "$out/ctest.log" "$out/validation.log" 2>/dev/null || true
    invalid "$profile" "$cold" "$service" "$zero" "$threads" "$blocks" consensus_failed
    return
  fi

  resource="$out/resource-usage.txt"
  if command -v cuobjdump >/dev/null 2>&1; then cuobjdump --dump-resource-usage "$dir/pepepowminer" >"$resource" 2>&1 || true; else : >"$resource"; fi
  regs="$(extract_resource "$resource" reg || true)"; stack="$(extract_resource "$resource" stack || true)"
  ss="$(extract_spill "$blog" store || true)"; sl="$(extract_spill "$blog" load || true)"
  regs="${regs:-0}"; stack="${stack:-0}"; ss="${ss:-0}"; sl="${sl:-0}"

  echo "STATUS=BENCHMARKING REGISTERS=$regs STACK=$stack SPILL_STORE=$ss SPILL_LOAD=$sl"
  : >"$out/benchmark.log"
  echo 'timestamp,temperature_c,util_pct,clock_mhz,power_w' >"$out/gpu-samples.csv"
  stop="$out/stop"; rm -f "$stop"
  (
    while [[ ! -f "$stop" ]]; do
      printf '%s,' "$(date +%s)" >>"$out/gpu-samples.csv"
      nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,clocks.current.sm,power.draw \
        --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' >>"$out/gpu-samples.csv" || true
      sleep 2
    done
  ) & sampler=$!

  speeds=()
  for ((run=1;run<=RUNS;run++)); do
    output="$(timeout 420 "$dir/pepepow_header80_benchmark" "$NONCES" 2>&1 || true)"
    hps="$(extract_hps "$output")"
    if [[ ! "$hps" =~ ^[1-9][0-9]*$ ]]; then
      touch "$stop"; wait "$sampler" 2>/dev/null || true
      echo "$output" >>"$out/benchmark.log"
      echo "PROFILE_RESULT profile=$profile valid=0 reason=benchmark_failed"
      invalid "$profile" "$cold" "$service" "$zero" "$threads" "$blocks" benchmark_failed
      return
    fi
    speeds+=("$hps")
    printf 'BENCH_RUN profile=%s run=%02d/%02d hps=%s %s\n' "$profile" "$run" "$RUNS" "$hps" "$output" | tee -a "$out/benchmark.log"
  done
  touch "$stop"; wait "$sampler" 2>/dev/null || true

  stats="$(printf '%s\n' "${speeds[@]}" | python3 -c 'import sys,statistics as s;v=[int(x) for x in sys.stdin if x.strip()];print(min(v),int(s.median(v)),f"{s.mean(v):.2f}",max(v),f"{s.pstdev(v):.2f}",f"{s.median(v)/1e6:.6f}")')"
  read -r mn med mean mx sd mhs <<<"$stats"
  gpu_stats="$(python3 - "$out/gpu-samples.csv" <<'PY'
import csv,statistics,sys
rows=[]
for r in csv.DictReader(open(sys.argv[1])):
    try:
        if float(r['util_pct']) >= 50: rows.append(r)
    except Exception:
        pass
if not rows:
    print('0 0 0')
else:
    print(f"{statistics.mean(float(r['clock_mhz']) for r in rows):.2f} "
          f"{statistics.mean(float(r['power_w']) for r in rows):.2f} "
          f"{statistics.mean(float(r['temperature_c']) for r in rows):.2f}")
PY
)"
  read -r clock power temp <<<"$gpu_stats"

  printf '%s,1,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,ok\n' \
    "$profile" "$cold" "$service" "$zero" "$threads" "$blocks" "$regs" "$stack" "$ss" "$sl" \
    "$mn" "$med" "$mean" "$mx" "$sd" "$mhs" "$clock" "$power" "$temp" >>"$RESULTS"
  echo "PROFILE_RESULT profile=$profile valid=1 cold=$cold service=$service zero=$zero threads=$threads min_blocks=$blocks registers=$regs stack=$stack spill_store=$ss spill_load=$sl median_hps=$med median_mhs=$mhs clock_mean_mhz=$clock power_mean_w=$power temp_mean_c=$temp"
}

for ((i=0;i<TOTAL;i++)); do run_profile "$i"; done
restore
trap - EXIT INT TERM

nvidia-smi -q >"$STAGE/nvidia/nvidia-smi-after.txt" 2>&1 || true
dmesg 2>/dev/null | grep -E 'NVRM|Xid' >"$STAGE/nvidia/xid-after.txt" || true

python3 - "$RESULTS" "$STAGE/summary.txt" "$BUILD_ROOT" <<'PY'
import csv,sys
rows=list(csv.DictReader(open(sys.argv[1])))
valid=[r for r in rows if r['valid']=='1']
base=next((r for r in valid if r['profile']=='selector-combined-base'),None)
best=max(valid,key=lambda r:int(r['median_hps'])) if valid else None
with open(sys.argv[2],'w') as f:
    f.write(f"profiles_total={len(rows)}\nprofiles_valid={len(valid)}\n")
    if not base or not best:
        f.write("candidate_gate=INVALID\nTARGET_2MH=PENDING\n")
        raise SystemExit
    bh=int(base['median_hps']); h=int(best['median_hps'])
    up=(h/bh-1)*100
    gap=(2_000_000/h-1)*100
    proj=h*1950/float(best['clock_mean_mhz'] or 1650)
    for k in ('profile','cold_mode','service_mode','zero_safe','threads','min_blocks','registers','stack_bytes','spill_store_bytes','spill_load_bytes','median_hps','median_mhs','clock_mean_mhz','power_mean_w','temp_mean_c'):
        f.write(f"best_{k}={best[k]}\n")
    f.write(f"baseline_hps={bh}\n")
    f.write(f"uplift_pct={up:.4f}\n")
    f.write(f"target_2mh_gap_pct={gap:.4f}\n")
    f.write(f"projected_hps_at_1950mhz={proj:.0f}\n")
    f.write(f"projected_mhs_at_1950mhz={proj/1e6:.6f}\n")
    f.write(f"best_build_dir={sys.argv[3]}/{best['profile']}\n")
    f.write("stress_gate=PENDING\nsanitzer_gate=PENDING\ncandidate_gate=OFFLINE_ONLY\nTARGET_2MH=PENDING\n")
PY

baseline_hps="$(grep '^baseline_hps=' "$STAGE/summary.txt" | cut -d= -f2- || true)"
best_hps="$(grep '^best_median_hps=' "$STAGE/summary.txt" | cut -d= -f2- || true)"
best_profile="$(grep '^best_profile=' "$STAGE/summary.txt" | cut -d= -f2- || true)"
best_dir="$(grep '^best_build_dir=' "$STAGE/summary.txt" | cut -d= -f2- || true)"
uplift="$(grep '^uplift_pct=' "$STAGE/summary.txt" | cut -d= -f2- || true)"
stress_gate=SKIPPED
sanitizer_gate=SKIPPED

if [[ "$best_hps" =~ ^[0-9]+$ && "$baseline_hps" =~ ^[0-9]+$ ]] &&
   python3 - "$uplift" <<'PY'
import sys
raise SystemExit(0 if float(sys.argv[1]) >= 0.5 else 1)
PY
then
  echo "STATUS=STRESS_TESTING PROFILE=$best_profile"
  : >"$STAGE/stress/benchmark.log"
  stress_ok=1
  for ((run=1;run<=STRESS_RUNS;run++)); do
    output="$(timeout 900 "$best_dir/pepepow_header80_benchmark" "$STRESS_NONCES" 2>&1 || true)"
    hps="$(extract_hps "$output")"
    if [[ ! "$hps" =~ ^[1-9][0-9]*$ ]]; then stress_ok=0; fi
    printf 'STRESS_RUN profile=%s run=%02d/%02d hps=%s %s\n' "$best_profile" "$run" "$STRESS_RUNS" "${hps:-0}" "$output" | tee -a "$STAGE/stress/benchmark.log"
    (( stress_ok==1 )) || break
  done
  if (( stress_ok==1 )); then stress_gate=PASS; else stress_gate=FAIL; fi

  if command -v compute-sanitizer >/dev/null 2>&1; then
    echo "STATUS=SANITIZING PROFILE=$best_profile"
    if timeout 900 compute-sanitizer --tool memcheck --error-exitcode=97 \
      "$best_dir/pepepow_header80_benchmark" 65536 >"$STAGE/sanitizer/memcheck.log" 2>&1; then
      sanitizer_gate=PASS
    else
      sanitizer_gate=FAIL
    fi
  else
    sanitizer_gate=UNAVAILABLE
  fi
fi

xid_before="$(wc -l <"$STAGE/nvidia/xid-before.txt" 2>/dev/null || echo 0)"
xid_after="$(wc -l <"$STAGE/nvidia/xid-after.txt" 2>/dev/null || echo 0)"
new_xid=$((xid_after-xid_before))
(( new_xid < 0 )) && new_xid=0

sed -i '/^stress_gate=/d;/^sanitizer_gate=/d;/^candidate_gate=/d' "$STAGE/summary.txt"
{
  echo "stress_gate=$stress_gate"
  echo "sanitizer_gate=$sanitizer_gate"
  echo "xid_before_lines=$xid_before"
  echo "xid_after_lines=$xid_after"
  echo "new_xid_lines=$new_xid"
  if [[ "$stress_gate" == PASS && "$sanitizer_gate" != FAIL && "$new_xid" == 0 ]]; then
    echo "candidate_gate=LIVE_SMOKE_READY"
  else
    echo "candidate_gate=NO_LIVE_CANDIDATE"
  fi
  echo "TARGET_2MH=PENDING"
} >>"$STAGE/summary.txt"

printf 'finished_at=%s\n' "$(date --iso-8601=seconds)" >>"$STAGE/MANIFEST.txt"
tar -C "$OUT_ROOT" -czf "$ARCHIVE" "$NAME"
sha256sum "$ARCHIVE" >"$ARCHIVE.sha256"

echo
echo "========== V2.0.0 WARP SERVICE COMPLETE =========="
cat "$STAGE/summary.txt"
echo "ARCHIVE=$ARCHIVE"
echo "SHA256_FILE=$ARCHIVE.sha256"
echo "NOTE=Stable miner was not installed or restarted."

if curl -fsSL "$PUBLISHER_URL" -o "$PUBLISHER"; then
  chmod +x "$PUBLISHER"
  PUBLIC_UPLOAD="${PUBLIC_UPLOAD:-1}" "$PUBLISHER" "$ARCHIVE" || true
fi
