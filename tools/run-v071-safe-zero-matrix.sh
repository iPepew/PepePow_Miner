#!/usr/bin/env bash
set -euo pipefail
umask 077

SOURCE_ROOT="${SOURCE_ROOT:-}"
OUT_ROOT="${OUT_ROOT:-/root/pepepow-tests}"
NONCES="${NONCES:-16777216}"
RUNS="${RUNS:-9}"
JOBS="${JOBS:-$(nproc)}"
STAMP="$(date +%Y%m%d_%H%M%S)"
NAME="v071-safe-zero-${STAMP}"
STAGE="${OUT_ROOT}/${NAME}"
ARCHIVE="${OUT_ROOT}/${NAME}.tar.gz"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "ERROR: required command not found: $1" >&2; exit 1; }; }
for c in bash awk sed grep sha256sum tar python3 nvidia-smi cmake ctest; do need "$c"; done

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
  local c; for c in /usr/local/cuda/bin/nvcc /usr/local/cuda-12.4/bin/nvcc /usr/local/cuda-12/bin/nvcc; do [[ -x "$c" ]] && { echo "$c"; return; }; done
  return 1
}

SOURCE_ROOT="$(find_source_root || true)"; [[ -n "$SOURCE_ROOT" ]] || { echo 'ERROR: v0.6.0 source tree not found' >&2; exit 1; }
NVCC="$(find_nvcc || true)"; [[ -n "$NVCC" ]] || { echo 'ERROR: nvcc not found' >&2; exit 1; }
export PATH="$(dirname "$NVCC"):$PATH"
SOURCE_FILE="$SOURCE_ROOT/native/src/cuda/header80_backend_v060.cu"
BACKUP_FILE="$SOURCE_FILE.v071-safe-zero-backup-$STAMP"
BUILD_ROOT="$SOURCE_ROOT/build-v071-safe-zero"
DEPS_DIR="$SOURCE_ROOT/.deps-v060"

GPU_APPS="$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null || true)"
if [[ -n "${GPU_APPS//[[:space:]]/}" ]]; then echo 'ERROR: GPU is busy. Use an empty flight sheet.' >&2; echo "$GPU_APPS" >&2; exit 2; fi

mkdir -p "$STAGE"/{profiles,source,nvidia}
cp -f "$SOURCE_FILE" "$BACKUP_FILE"
cp -f "$SOURCE_FILE" "$STAGE/source/header80_backend_v060.original.cu"
restore(){ [[ -f "$BACKUP_FILE" ]] && { cp -f "$BACKUP_FILE" "$SOURCE_FILE"; rm -f "$BACKUP_FILE"; }; }
trap restore EXIT INT TERM

cat > "$STAGE/MANIFEST.txt" <<META
name=$NAME
source_root=$SOURCE_ROOT
nonces=$NONCES
runs=$RUNS
profiles=baseline warm-zero-guard lazy-zero-update
started_at=$(date --iso-8601=seconds)
META
nvidia-smi -q > "$STAGE/nvidia/nvidia-smi-before.txt" 2>&1 || true
"$NVCC" --version > "$STAGE/nvcc-version.txt" 2>&1 || true
RESULTS="$STAGE/results.csv"
echo 'profile,valid,pow_registers,pow_stack_bytes,pow_spill_store_bytes,pow_spill_load_bytes,min_hps,median_hps,mean_hps,max_hps,stdev_hps,median_mhs,reason' > "$RESULTS"

patch_source(){
  local profile="$1"
  cp -f "$BACKUP_FILE" "$SOURCE_FILE"
  [[ "$profile" == baseline ]] && return
  python3 - "$SOURCE_FILE" "$profile" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); profile=sys.argv[2]; t=p.read_text(encoding='utf-8')
old=r'''__device__ __forceinline__ void accumulate(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    int cell_index, std::uint32_t nibble, double value,
    double hash_mod, double nonce_mod, double& sum, HooHashSwState& sw) {
    if (sw_state_is_cold(sw)) {
        if (nibble != 0U) {
            const double cell = matrix[cell_index];
            const double x = cell * hash_mod * value + nonce_mod;
            sum += safe_nonlinear(x) * value * 1234.0;
        }
    } else {
#if PEPEPOW_CUDA_SCALED_NIBBLE_TABLE
        // Cell-major layout makes the 32 lanes read from one contiguous
        // 128-byte group. The table value is computed on the host as exactly
        // (matrix[cell] * 0.0001) * nibble, preserving operation order and
        // rounding while replacing a hot FP64 multiply with a cached load.
        sum += __ldg(scaled_nibble_table +
                     static_cast<std::size_t>(cell_index) * 16U + nibble);
#elif PEPEPOW_CUDA_SCALED_MATRIX
        sum += kHeader80ScaledMatrix[cell_index] * value;
#else
        sum += matrix[cell_index] * 0.0001 * value;
#endif
    }
    update_sw_state(sw, sum);
}'''
warm=r'''__device__ __forceinline__ void accumulate(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    int cell_index, std::uint32_t nibble, double value,
    double hash_mod, double nonce_mod, double& sum, HooHashSwState& sw) {
    if (sw_state_is_cold(sw)) {
        if (nibble != 0U) {
            const double cell = matrix[cell_index];
            const double x = cell * hash_mod * value + nonce_mod;
            sum += safe_nonlinear(x) * value * 1234.0;
        }
    } else if (nibble != 0U) {
#if PEPEPOW_CUDA_SCALED_NIBBLE_TABLE
        sum += __ldg(scaled_nibble_table +
                     static_cast<std::size_t>(cell_index) * 16U + nibble);
#elif PEPEPOW_CUDA_SCALED_MATRIX
        sum += kHeader80ScaledMatrix[cell_index] * value;
#else
        sum += matrix[cell_index] * 0.0001 * value;
#endif
    }
    update_sw_state(sw, sum);
}'''
lazy=r'''__device__ __forceinline__ void accumulate(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    int cell_index, std::uint32_t nibble,
    double hash_mod, double nonce_mod, double& sum, HooHashSwState& sw) {
    if (sw_state_is_cold(sw)) {
        if (nibble != 0U) {
            const double value = nibble_to_double(nibble);
            const double cell = matrix[cell_index];
            const double x = cell * hash_mod * value + nonce_mod;
            sum += safe_nonlinear(x) * value * 1234.0;
        }
    } else if (nibble != 0U) {
#if PEPEPOW_CUDA_SCALED_NIBBLE_TABLE
        sum += __ldg(scaled_nibble_table +
                     static_cast<std::size_t>(cell_index) * 16U + nibble);
#elif PEPEPOW_CUDA_SCALED_MATRIX
        const double value = nibble_to_double(nibble);
        sum += kHeader80ScaledMatrix[cell_index] * value;
#else
        const double value = nibble_to_double(nibble);
        sum += matrix[cell_index] * 0.0001 * value;
#endif
    }
    update_sw_state(sw, sum);
}'''
if t.count(old)!=1: raise SystemExit(f'ERROR: accumulate block count={t.count(old)}')
t=t.replace(old, warm if profile=='warm-zero-guard' else lazy, 1)
if profile=='lazy-zero-update':
    old_calls=r'''            accumulate(matrix, scaled_nibble_table, high_cell, high_nibble,
                       nibble_to_double(high_nibble), hash_mod_fp64, nonce_mod, sum, sw);
            accumulate(matrix, scaled_nibble_table, high_cell + 1, low_nibble,
                       nibble_to_double(low_nibble), hash_mod_fp64, nonce_mod, sum, sw);'''
    new_calls=r'''            accumulate(matrix, scaled_nibble_table, high_cell, high_nibble,
                       hash_mod_fp64, nonce_mod, sum, sw);
            accumulate(matrix, scaled_nibble_table, high_cell + 1, low_nibble,
                       hash_mod_fp64, nonce_mod, sum, sw);'''
    if t.count(old_calls)!=1: raise SystemExit(f'ERROR: call pair count={t.count(old_calls)}')
    t=t.replace(old_calls,new_calls,1)
p.write_text(t,encoding='utf-8')
PY
}

extract_resource(){ local f="$1" key="$2"; awk -v key="$key" '/Function .*header80_pow_kernel/{x=1;next} x&&/REG:/{l=$0;if(key=="reg")sub(/^.*REG:/,"",l);else sub(/^.*STACK:/,"",l);sub(/[^0-9].*$/, "", l);print l+0;exit}' "$f"; }
extract_spill(){ local f="$1" kind="$2"; awk -v k="$kind" '/Compiling entry function .*header80_pow_kernel/{x=1;next} x&&/bytes stack frame, .* bytes spill stores, .* bytes spill loads/{if(k=="store"){for(i=1;i<=NF;i++)if($(i+1)=="bytes"&&$(i+2)=="spill"&&$(i+3)=="stores,"){print $i+0;exit}}else{for(i=1;i<=NF;i++)if($(i+1)=="bytes"&&$(i+2)=="spill"&&$(i+3)=="loads"){print $i+0;exit}}}' "$f"; }

run_profile(){
  local profile="$1" dir="$BUILD_ROOT/$profile" out="$STAGE/profiles/$profile" blog="$STAGE/profiles/$profile/build.log"
  mkdir -p "$out"; rm -rf "$dir"
  echo; echo "PROFILE=$profile"; echo "STATUS=PATCHING"
  patch_source "$profile"; cp -f "$SOURCE_FILE" "$out/header80_backend_v060.cu"
  args=(-S "$SOURCE_ROOT/native" -B "$dir" -DCMAKE_BUILD_TYPE=Release -DPEPEPOW_ENABLE_CUDA=ON -DPEPEPOW_BUILD_TESTS=ON -DPEPEPOW_CUDA_PTXAS_VERBOSE=ON -DPEPEPOW_CUDA_THREADS=64 -DPEPEPOW_CUDA_MIN_BLOCKS=2 -DPEPEPOW_CUDA_MAX_REGISTERS= -DPEPEPOW_CUDA_SCALED_MATRIX=ON -DPEPEPOW_CUDA_SPLIT_PIPELINE=OFF -DPEPEPOW_CUDA_FAST_FRACTION=ON -DPEPEPOW_CUDA_EXACT_BIT_CONVERSIONS=ON -DPEPEPOW_CUDA_BIT_SW_FRACTION=ON -DPEPEPOW_CUDA_DERIVE_TWO=OFF -DPEPEPOW_CUDA_NIBBLE_TABLE=OFF -DPEPEPOW_CUDA_SCALED_NIBBLE_TABLE=ON -DPEPEPOW_CUDA_ASSUME_FINITE=ON -DPEPEPOW_CUDA_SW_STATE_MODE=3 -DPEPEPOW_CUDA_BYTE_UNROLL=1 -DCMAKE_CUDA_ARCHITECTURES=86 -DCMAKE_CUDA_COMPILER="$NVCC" -DFETCHCONTENT_BASE_DIR="$DEPS_DIR")
  if command -v ccache >/dev/null 2>&1; then args+=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache -DCMAKE_CUDA_COMPILER_LAUNCHER=ccache); fi
  echo 'STATUS=BUILDING'
  if ! { cmake "${args[@]}" && cmake --build "$dir" --parallel "$JOBS" --target pepepow_core_tests pepepow_cuda_tests pepepow_cuda_header80_validation pepepow_header80_benchmark pepepowminer; } >"$blog" 2>&1; then
    echo "PROFILE_RESULT profile=$profile valid=0 reason=build_failed"; tail -n80 "$blog"; echo "$profile,0,0,0,0,0,0,0,0,0,0,0,build_failed" >> "$RESULTS"; return
  fi
  echo 'STATUS=VALIDATING'
  if ! ctest --test-dir "$dir" --output-on-failure >"$out/ctest.log" 2>&1 || ! "$dir/pepepow_cuda_header80_validation" >"$out/validation.log" 2>&1; then
    echo "PROFILE_RESULT profile=$profile valid=0 reason=validation_failed"; echo "$profile,0,0,0,0,0,0,0,0,0,0,0,validation_failed" >> "$RESULTS"; return
  fi
  resource="$out/resource-usage.txt"; command -v cuobjdump >/dev/null 2>&1 && cuobjdump --dump-resource-usage "$dir/pepepowminer" >"$resource" 2>&1 || : >"$resource"
  regs="$(extract_resource "$resource" reg || true)"; regs="${regs:-0}"; stack="$(extract_resource "$resource" stack || true)"; stack="${stack:-0}"
  ss="$(extract_spill "$blog" store || true)"; ss="${ss:-0}"; sl="$(extract_spill "$blog" load || true)"; sl="${sl:-0}"
  echo "STATUS=BENCHMARKING REGISTERS=$regs STACK=$stack SPILL_STORE=$ss SPILL_LOAD=$sl"
  : > "$out/benchmark.log"; speeds=()
  for ((r=1;r<=RUNS;r++)); do
    o="$("$dir/pepepow_header80_benchmark" "$NONCES" 2>&1)"; h="$(sed -n 's/.* hps=\([0-9][0-9]*\).*/\1/p' <<<"$o" | tail -n1)"
    [[ "$h" =~ ^[1-9][0-9]*$ ]] || { echo "PROFILE_RESULT profile=$profile valid=0 reason=benchmark_parse_failed"; return; }
    speeds+=("$h"); printf 'BENCH_RUN profile=%s run=%02d/%02d hps=%s %s\n' "$profile" "$r" "$RUNS" "$h" "$o" | tee -a "$out/benchmark.log"
  done
  stats="$(printf '%s\n' "${speeds[@]}" | python3 -c 'import sys,statistics as s;v=[int(x) for x in sys.stdin if x.strip()];print(min(v),int(s.median(v)),f"{s.mean(v):.2f}",max(v),f"{s.pstdev(v):.2f}",f"{s.median(v)/1e6:.6f}")')"
  read -r mn med mean mx sd mhs <<<"$stats"
  echo "$profile,1,$regs,$stack,$ss,$sl,$mn,$med,$mean,$mx,$sd,$mhs,ok" >> "$RESULTS"
  echo "PROFILE_RESULT profile=$profile valid=1 pow_regs=$regs stack=$stack spill_store=$ss spill_load=$sl median_hps=$med median_mhs=$mhs"
}

run_profile baseline
run_profile warm-zero-guard
run_profile lazy-zero-update
restore; trap - EXIT INT TERM

echo "finished_at=$(date --iso-8601=seconds)" >> "$STAGE/MANIFEST.txt"
python3 - "$RESULTS" "$STAGE/summary.txt" <<'PY'
import csv,sys
rows=list(csv.DictReader(open(sys.argv[1]))); valid=[r for r in rows if r['valid']=='1']; base=next((r for r in valid if r['profile']=='baseline'),None); best=max(valid,key=lambda r:int(r['median_hps'])) if valid else None
with open(sys.argv[2],'w') as f:
 f.write(f'profiles_total={len(rows)}\nprofiles_valid={len(valid)}\n')
 if base:f.write(f"baseline_hps={base['median_hps']}\n")
 if best:
  f.write(f"best_profile={best['profile']}\nbest_hps={best['median_hps']}\nbest_mhs={best['median_mhs']}\nbest_regs={best['pow_registers']}\nbest_stack={best['pow_stack_bytes']}\nbest_spill_store={best['pow_spill_store_bytes']}\nbest_spill_load={best['pow_spill_load_bytes']}\n")
  if base:f.write(f"uplift_pct={(int(best['median_hps'])/int(base['median_hps'])-1)*100:.4f}\n")
PY

tar -C "$OUT_ROOT" -czf "$ARCHIVE" "$NAME"; sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"
echo; echo '========== V0.7.1 SAFE-ZERO MATRIX COMPLETE =========='; cat "$STAGE/summary.txt"; echo "RESULTS=$RESULTS"; echo "ARCHIVE=$ARCHIVE"; echo "SHA256_FILE=$ARCHIVE.sha256"
