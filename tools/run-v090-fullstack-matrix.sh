#!/usr/bin/env bash
set -euo pipefail
umask 077

SOURCE_ROOT="${SOURCE_ROOT:-}"
OUT_ROOT="${OUT_ROOT:-/root/pepepow-tests}"
NONCES="${NONCES:-16777216}"
RUNS="${RUNS:-5}"
STRESS_RUNS="${STRESS_RUNS:-15}"
JOBS="${JOBS:-$(nproc)}"
BASE_PATCHER="${BASE_PATCHER:-/root/prepare-v080-grand-source.py}"
COMBINED_PATCHER="${COMBINED_PATCHER:-/root/prepare-v081-coldpath-source.py}"
FULL_PATCHER="${FULL_PATCHER:-/root/prepare-v090-fullstack-source.py}"
STAMP="$(date +%Y%m%d_%H%M%S)"
NAME="v090-fullstack-${STAMP}"
STAGE="${OUT_ROOT}/${NAME}"
ARCHIVE="${OUT_ROOT}/${NAME}.tar.gz"
RESULTS="${STAGE}/results.csv"
PUBLISHER_URL="https://raw.githubusercontent.com/iPepew/PepePow_Miner/experiment/v0.9.0-fullstack/tools/publish-test-results.sh"
PUBLISHER="/root/publish-pepepow-test-results.sh"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1" >&2; exit 1; }; }
for c in bash awk sed grep sha256sum tar python3 nvidia-smi cmake ctest curl; do need "$c"; done
for f in "$BASE_PATCHER" "$COMBINED_PATCHER" "$FULL_PATCHER"; do [[ -f "$f" ]] || { echo "ERROR: missing patcher: $f" >&2; exit 1; }; done

find_source_root(){
  local c
  if [[ -n "$SOURCE_ROOT" && -f "$SOURCE_ROOT/native/CMakeLists.txt" && -f "$SOURCE_ROOT/native/src/cuda/header80_backend_v060.cu" ]]; then readlink -f "$SOURCE_ROOT"; return 0; fi
  for c in /root/pepepow-v060-8h-src /root/pepepow-v060-src /root/pepepow-v0.6.0-src /root/PepePow_Miner; do
    [[ -f "$c/native/CMakeLists.txt" && -f "$c/native/src/cuda/header80_backend_v060.cu" ]] && { readlink -f "$c"; return 0; }
  done
  return 1
}
find_nvcc(){
  command -v nvcc >/dev/null 2>&1 && { command -v nvcc; return 0; }
  local c
  for c in /usr/local/cuda/bin/nvcc /usr/local/cuda-12.4/bin/nvcc /usr/local/cuda-12/bin/nvcc; do [[ -x "$c" ]] && { echo "$c"; return 0; }; done
  return 1
}

SOURCE_ROOT="$(find_source_root || true)"; [[ -n "$SOURCE_ROOT" ]] || { echo "ERROR: prepared source tree not found" >&2; exit 1; }
NVCC="$(find_nvcc || true)"; [[ -n "$NVCC" ]] || { echo "ERROR: nvcc not found" >&2; exit 1; }
export PATH="$(dirname "$NVCC"):$PATH"
SOURCE_FILE="$SOURCE_ROOT/native/src/cuda/header80_backend_v060.cu"
BACKUP_FILE="$SOURCE_FILE.v090-backup-$STAMP"
BUILD_ROOT="$SOURCE_ROOT/build-v090-fullstack"
DEPS_DIR="$SOURCE_ROOT/.deps-v060"

GPU_APPS="$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null || true)"
if [[ -n "${GPU_APPS//[[:space:]]/}" ]]; then echo "ERROR: GPU busy. Use an empty flight sheet." >&2; echo "$GPU_APPS" >&2; exit 2; fi

mkdir -p "$STAGE"/{profiles,nvidia,source,stress,sanitizer}
cp -f "$SOURCE_FILE" "$BACKUP_FILE"
cp -f "$SOURCE_FILE" "$STAGE/source/header80_backend_v060.original.cu"
cp -f "$BASE_PATCHER" "$STAGE/source/prepare-v080-grand-source.py"
cp -f "$COMBINED_PATCHER" "$STAGE/source/prepare-v081-coldpath-source.py"
cp -f "$FULL_PATCHER" "$STAGE/source/prepare-v090-fullstack-source.py"
restore(){ if [[ -f "$BACKUP_FILE" ]]; then cp -f "$BACKUP_FILE" "$SOURCE_FILE"; rm -f "$BACKUP_FILE"; fi; }
trap restore EXIT INT TERM

IDS=(
  selector-combined-base
  hwfrac
  blake8
  blake8-cv
  blake8-cv-inplace
  blake-direct-inplace
  const-cold
  ldg-cold
  blake8-cv-inplace-const
  blake8-cv-inplace-ldg
  hwfrac-blake8-cv-const
  blake-direct-inplace-const
  full-u2
  full-u4
  full-ftz
  full-vector
  full-expensive
  full-compiler-combo
)
MODES=(
  base
  hwfrac
  blake8
  blake8+cvelide
  blake8+cvelide+inplace
  blakedirect+inplace
  constcold
  ldgcold
  blake8+cvelide+inplace+constcold
  blake8+cvelide+inplace+ldgcold
  hwfrac+blake8+cvelide+inplace+constcold
  blakedirect+inplace+constcold
  blake8+cvelide+inplace+constcold
  blake8+cvelide+inplace+constcold
  blake8+cvelide+inplace+constcold
  blake8+cvelide+inplace+constcold
  blake8+cvelide+inplace+constcold
  blake8+cvelide+inplace+constcold
)
BYTE_UNROLL=(1 1 1 1 1 1 1 1 1 1 1 1 2 4 1 1 1 1)
EXTRA_FLAGS=(
  "" "" "" "" "" "" "" "" "" "" "" "" "" ""
  "--ftz=true"
  "--extra-device-vectorization"
  "-Xptxas=--allow-expensive-optimizations=true"
  "--ftz=true --extra-device-vectorization -Xptxas=--allow-expensive-optimizations=true"
)
TOTAL="${#IDS[@]}"

cat >"$STAGE/MANIFEST.txt" <<META
name=$NAME
source_root=$SOURCE_ROOT
nonces=$NONCES
runs=$RUNS
stress_runs=$STRESS_RUNS
profiles_total=$TOTAL
target_hps=2000000
baseline=selector-combined
started_at=$(date --iso-8601=seconds)
META
nvidia-smi -q >"$STAGE/nvidia/nvidia-smi-before.txt" 2>&1 || true
dmesg 2>/dev/null | grep -E 'NVRM|Xid' >"$STAGE/nvidia/xid-before.txt" || true
"$NVCC" --version >"$STAGE/nvcc-version.txt" 2>&1 || true
printf '%s\n' 'profile,valid,mode,byte_unroll,extra_flags,registers,stack_bytes,spill_store_bytes,spill_load_bytes,min_hps,median_hps,mean_hps,max_hps,stdev_hps,median_mhs,clock_mean_mhz,power_mean_w,temp_mean_c,reason' >"$RESULTS"

extract_hps(){ sed -n 's/.* hps=\([0-9][0-9]*\).*/\1/p' <<<"$1" | tail -n1; }
extract_resource(){ local f="$1" key="$2"; awk -v key="$key" '/Function .*header80_pow_kernel/{x=1;next} x&&/REG:/{l=$0;if(key=="reg")sub(/^.*REG:/,"",l);else sub(/^.*STACK:/,"",l);sub(/[^0-9].*$/, "",l);print l+0;exit}' "$f"; }
extract_spill(){ local f="$1" which="$2"; awk -v w="$which" '/Compiling entry function .*header80_pow_kernel/{x=1;next} x&&/bytes stack frame, .* bytes spill stores, .* bytes spill loads/{if(w=="store"){for(i=1;i<=NF;i++)if($(i+1)=="bytes"&&$(i+2)=="spill"&&$(i+3)=="stores,"){print $i+0;exit}}else{for(i=1;i<=NF;i++)if($(i+1)=="bytes"&&$(i+2)=="spill"&&$(i+3)=="loads"){print $i+0;exit}}}' "$f"; }
invalid(){ printf '%s,0,%s,%s,%q,0,0,0,0,0,0,0,0,0,0,0,0,0,%s\n' "$1" "$2" "$3" "$4" "$5" >>"$RESULTS"; }

run_profile(){
  local idx="$1"
  local profile mode unroll flags dir out blog resource regs stack ss sl run output hps stats mn med mean mx sd mhs sampler stop gpu_stats clock power temp
  local -a speeds args
  profile="${IDS[$idx]}"; mode="${MODES[$idx]}"; unroll="${BYTE_UNROLL[$idx]}"; flags="${EXTRA_FLAGS[$idx]}"
  dir="$BUILD_ROOT/$profile"; out="$STAGE/profiles/$profile"; blog="$out/build.log"
  mkdir -p "$out"; rm -rf "$dir"
  echo; echo "PROFILE_INDEX=$((idx+1))"; echo "PROFILE_TOTAL=$TOTAL"; echo "PROFILE=$profile"; echo "PROFILE_CONFIG mode=$mode byte_unroll=$unroll flags=${flags:-none}"; echo "STATUS=PATCHING"
  cp -f "$BACKUP_FILE" "$SOURCE_FILE"
  if ! python3 "$BASE_PATCHER" "$SOURCE_FILE" selector >"$out/selector-patch.log" 2>&1; then echo "PROFILE_RESULT profile=$profile valid=0 mode=$mode reason=selector_patch_failed"; cat "$out/selector-patch.log"; invalid "$profile" "$mode" "$unroll" "$flags" selector_patch_failed; return 0; fi
  if ! python3 "$COMBINED_PATCHER" "$SOURCE_FILE" combined >"$out/combined-patch.log" 2>&1; then echo "PROFILE_RESULT profile=$profile valid=0 mode=$mode reason=combined_patch_failed"; cat "$out/combined-patch.log"; invalid "$profile" "$mode" "$unroll" "$flags" combined_patch_failed; return 0; fi
  if [[ "$mode" != base ]]; then
    if ! python3 "$FULL_PATCHER" "$SOURCE_FILE" "$mode" >"$out/full-patch.log" 2>&1; then echo "PROFILE_RESULT profile=$profile valid=0 mode=$mode reason=full_patch_failed"; cat "$out/full-patch.log"; invalid "$profile" "$mode" "$unroll" "$flags" full_patch_failed; return 0; fi
  fi
  cp -f "$SOURCE_FILE" "$out/header80_backend_v060.cu"

  args=(-S "$SOURCE_ROOT/native" -B "$dir" -DCMAKE_BUILD_TYPE=Release -DPEPEPOW_ENABLE_CUDA=ON -DPEPEPOW_BUILD_TESTS=ON -DPEPEPOW_CUDA_PTXAS_VERBOSE=ON -DPEPEPOW_CUDA_THREADS=64 -DPEPEPOW_CUDA_MIN_BLOCKS=2 -DPEPEPOW_CUDA_MAX_REGISTERS= -DPEPEPOW_CUDA_SCALED_MATRIX=ON -DPEPEPOW_CUDA_SPLIT_PIPELINE=OFF -DPEPEPOW_CUDA_FAST_FRACTION=ON -DPEPEPOW_CUDA_EXACT_BIT_CONVERSIONS=ON -DPEPEPOW_CUDA_BIT_SW_FRACTION=ON -DPEPEPOW_CUDA_DERIVE_TWO=OFF -DPEPEPOW_CUDA_NIBBLE_TABLE=OFF -DPEPEPOW_CUDA_SCALED_NIBBLE_TABLE=ON -DPEPEPOW_CUDA_ASSUME_FINITE=ON -DPEPEPOW_CUDA_SW_STATE_MODE=3 -DPEPEPOW_CUDA_BYTE_UNROLL="$unroll" -DCMAKE_CUDA_ARCHITECTURES=86 -DCMAKE_CUDA_COMPILER="$NVCC" -DFETCHCONTENT_BASE_DIR="$DEPS_DIR")
  [[ -n "$flags" ]] && args+=("-DCMAKE_CUDA_FLAGS=$flags")
  command -v ccache >/dev/null 2>&1 && args+=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache -DCMAKE_CUDA_COMPILER_LAUNCHER=ccache)
  echo "STATUS=BUILDING"
  if ! { cmake "${args[@]}" && cmake --build "$dir" --parallel "$JOBS" --target pepepow_core_tests pepepow_cuda_tests pepepow_cuda_header80_validation pepepow_header80_benchmark pepepowminer; } >"$blog" 2>&1; then echo "PROFILE_RESULT profile=$profile valid=0 mode=$mode reason=build_failed"; tail -n120 "$blog" || true; invalid "$profile" "$mode" "$unroll" "$flags" build_failed; return 0; fi

  echo "STATUS=VALIDATING"
  if ! ctest --test-dir "$dir" --output-on-failure >"$out/ctest.log" 2>&1; then echo "PROFILE_RESULT profile=$profile valid=0 mode=$mode reason=ctest_failed"; cat "$out/ctest.log"; invalid "$profile" "$mode" "$unroll" "$flags" ctest_failed; return 0; fi
  if ! "$dir/pepepow_cuda_header80_validation" >"$out/validation.log" 2>&1; then echo "PROFILE_RESULT profile=$profile valid=0 mode=$mode reason=consensus_failed"; cat "$out/validation.log"; invalid "$profile" "$mode" "$unroll" "$flags" consensus_failed; return 0; fi

  resource="$out/resource-usage.txt"; if command -v cuobjdump >/dev/null 2>&1; then cuobjdump --dump-resource-usage "$dir/pepepowminer" >"$resource" 2>&1 || true; else : >"$resource"; fi
  regs="$(extract_resource "$resource" reg || true)"; stack="$(extract_resource "$resource" stack || true)"; ss="$(extract_spill "$blog" store || true)"; sl="$(extract_spill "$blog" load || true)"
  regs="${regs:-0}"; stack="${stack:-0}"; ss="${ss:-0}"; sl="${sl:-0}"
  echo "STATUS=BENCHMARKING REGISTERS=$regs STACK=$stack SPILL_STORE=$ss SPILL_LOAD=$sl"
  : >"$out/benchmark.log"; echo 'timestamp,temperature_c,util_pct,clock_mhz,power_w' >"$out/gpu-samples.csv"; stop="$out/stop-sampler"; rm -f "$stop"
  (while [[ ! -f "$stop" ]]; do printf '%s,' "$(date +%s)" >>"$out/gpu-samples.csv"; nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,clocks.current.sm,power.draw --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' >>"$out/gpu-samples.csv" || true; sleep 2; done) & sampler=$!
  speeds=()
  for ((run=1;run<=RUNS;run++)); do
    output="$("$dir/pepepow_header80_benchmark" "$NONCES" 2>&1)"; hps="$(extract_hps "$output")"
    if [[ ! "$hps" =~ ^[1-9][0-9]*$ ]]; then touch "$stop"; wait "$sampler" 2>/dev/null || true; echo "PROFILE_RESULT profile=$profile valid=0 mode=$mode reason=benchmark_parse_failed"; invalid "$profile" "$mode" "$unroll" "$flags" benchmark_parse_failed; return 0; fi
    speeds+=("$hps"); printf 'BENCH_RUN profile=%s run=%02d/%02d hps=%s %s\n' "$profile" "$run" "$RUNS" "$hps" "$output" | tee -a "$out/benchmark.log"
  done
  touch "$stop"; wait "$sampler" 2>/dev/null || true
  stats="$(printf '%s\n' "${speeds[@]}" | python3 -c 'import sys,statistics as s;v=[int(x) for x in sys.stdin if x.strip()];print(min(v),int(s.median(v)),f"{s.mean(v):.2f}",max(v),f"{s.pstdev(v):.2f}",f"{s.median(v)/1e6:.6f}")')"; read -r mn med mean mx sd mhs <<<"$stats"
  gpu_stats="$(python3 - "$out/gpu-samples.csv" <<'PY'
import csv,statistics,sys
rows=[]
for r in csv.DictReader(open(sys.argv[1])):
    try:
        if float(r['util_pct'])>=80: rows.append(r)
    except Exception: pass
if not rows: print('0 0 0')
else: print(f"{statistics.mean(float(r['clock_mhz']) for r in rows):.2f} {statistics.mean(float(r['power_w']) for r in rows):.2f} {statistics.mean(float(r['temperature_c']) for r in rows):.2f}")
PY
)"; read -r clock power temp <<<"$gpu_stats"
  printf '%s,1,%s,%s,%q,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,ok\n' "$profile" "$mode" "$unroll" "$flags" "$regs" "$stack" "$ss" "$sl" "$mn" "$med" "$mean" "$mx" "$sd" "$mhs" "$clock" "$power" "$temp" >>"$RESULTS"
  echo "PROFILE_RESULT profile=$profile valid=1 mode=$mode byte_unroll=$unroll flags=${flags:-none} registers=$regs stack=$stack spill_store=$ss spill_load=$sl median_hps=$med median_mhs=$mhs clock_mean_mhz=$clock power_mean_w=$power temp_mean_c=$temp"
}

for ((i=0;i<TOTAL;i++)); do run_profile "$i"; done
restore; trap - EXIT INT TERM
nvidia-smi -q >"$STAGE/nvidia/nvidia-smi-after.txt" 2>&1 || true
dmesg 2>/dev/null | grep -E 'NVRM|Xid' >"$STAGE/nvidia/xid-after.txt" || true

python3 - "$RESULTS" "$STAGE/summary.txt" "$BUILD_ROOT" <<'PY'
import csv,sys
rows=list(csv.DictReader(open(sys.argv[1],encoding='utf-8'))); valid=[r for r in rows if r['valid']=='1']; base=next((r for r in valid if r['profile']=='selector-combined-base'),None); best=max(valid,key=lambda r:int(r['median_hps'])) if valid else None
with open(sys.argv[2],'w',encoding='utf-8') as f:
    f.write(f'profiles_total={len(rows)}\nprofiles_valid={len(valid)}\n')
    if base: f.write(f"baseline_hps={base['median_hps']}\nbaseline_mhs={base['median_mhs']}\n")
    if best:
        for k in ('profile','mode','byte_unroll','registers','stack_bytes','spill_store_bytes','spill_load_bytes','median_hps','median_mhs','clock_mean_mhz','power_mean_w','temp_mean_c'):
            f.write(f'best_{k}={best[k]}\n')
        if base and int(base['median_hps']): f.write(f"uplift_pct={(int(best['median_hps'])/int(base['median_hps'])-1)*100:.4f}\n")
        f.write(f"target_2mh_gap_pct={(2000000-int(best['median_hps']))/2000000*100:.4f}\n")
        clock=float(best['clock_mean_mhz'] or 0)
        if clock>0:
            projected=int(int(best['median_hps'])*1950.0/clock); f.write(f'projected_hps_at_1950mhz={projected}\nprojected_mhs_at_1950mhz={projected/1e6:.6f}\n')
        f.write(f"best_build_dir={sys.argv[3]}/{best['profile']}\n")
PY

source "$STAGE/summary.txt"
STRESS_GATE=SKIPPED; SANITIZER_GATE=SKIPPED
if [[ "${best_profile:-selector-combined-base}" != selector-combined-base ]] && awk -v u="${uplift_pct:-0}" 'BEGIN{exit !(u>=0.3)}'; then
  echo "STATUS=STRESS_TESTING PROFILE=$best_profile RUNS=$STRESS_RUNS"
  STRESS_GATE=PASS; xid_before="$(dmesg 2>/dev/null | grep -Ec 'NVRM: Xid|Xid \(' || true)"; : >"$STAGE/stress/benchmark.log"
  for ((run=1;run<=STRESS_RUNS;run++)); do
    if ! output="$("$best_build_dir/pepepow_header80_benchmark" 33554432 2>&1)"; then STRESS_GATE=FAILED; echo "STRESS_RUN run=$run/$STRESS_RUNS status=FAILED $output" | tee -a "$STAGE/stress/benchmark.log"; break; fi
    hps="$(extract_hps "$output")"; echo "STRESS_RUN run=$run/$STRESS_RUNS status=PASS hps=${hps:-0} $output" | tee -a "$STAGE/stress/benchmark.log"
  done
  xid_after="$(dmesg 2>/dev/null | grep -Ec 'NVRM: Xid|Xid \(' || true)"; (( xid_after>xid_before )) && STRESS_GATE=FAILED_NEW_XID
  if [[ "$STRESS_GATE" == PASS ]] && command -v compute-sanitizer >/dev/null 2>&1; then
    echo "STATUS=SANITIZER PROFILE=$best_profile"; if compute-sanitizer --tool memcheck --error-exitcode=99 "$best_build_dir/pepepow_header80_benchmark" 4096 >"$STAGE/sanitizer/memcheck.log" 2>&1; then SANITIZER_GATE=PASS; else SANITIZER_GATE=FAILED; fi
  fi
fi
printf 'stress_gate=%s\nsanitizer_gate=%s\n' "$STRESS_GATE" "$SANITIZER_GATE" >>"$STAGE/summary.txt"
if [[ "$STRESS_GATE" == PASS && "$SANITIZER_GATE" != FAILED ]]; then
  echo 'full_gate=OFFLINE_PASS' >>"$STAGE/summary.txt"; ln -sfn "$best_build_dir" /root/pepepow-v090-best; cat > /root/v090-best.env <<ENV
BEST_PROFILE=$best_profile
BEST_BUILD_DIR=$best_build_dir
UPLIFT_PCT=${uplift_pct:-0}
ENV
else echo 'full_gate=NO_LIVE_CANDIDATE' >>"$STAGE/summary.txt"; fi
echo 'TARGET_2MH=PENDING' >>"$STAGE/summary.txt"
printf 'finished_at=%s\n' "$(date --iso-8601=seconds)" >>"$STAGE/MANIFEST.txt"
tar -C "$OUT_ROOT" -czf "$ARCHIVE" "$NAME"; sha256sum "$ARCHIVE" >"$ARCHIVE.sha256"
echo; echo '========== V0.9.0 FULL-STACK COMPLETE =========='; cat "$STAGE/summary.txt"; echo "RESULTS=$RESULTS"; echo "ARCHIVE=$ARCHIVE"; echo "SHA256_FILE=$ARCHIVE.sha256"; echo 'NOTE=No stable miner or GPU clocks were changed.'
if curl -fsSL "$PUBLISHER_URL" -o "$PUBLISHER"; then chmod +x "$PUBLISHER"; PUBLIC_UPLOAD="${PUBLIC_UPLOAD:-1}" "$PUBLISHER" "$ARCHIVE" || true; fi
