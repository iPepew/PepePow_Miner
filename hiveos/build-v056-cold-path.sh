#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_ROOT="${ROOT_DIR}/build-profiles-v056"
LINK_BUILD_DIR="${ROOT_DIR}/build-rtx3080-v056"
JOBS="${JOBS:-$(nproc)}"
DEPS_DIR="${ROOT_DIR}/.deps-v056"
PREPARE_SCRIPT="${ROOT_DIR}/hiveos/prepare-v056-source.py"
EXPECTED_EDITION="PepeW Cold Path Edition"
BENCH_NONCES="${BENCH_NONCES:-4194304}"
BENCH_RUNS="${BENCH_RUNS:-3}"
TARGET_HPS="${TARGET_HPS:-2000000}"
RESUME="${RESUME:-0}"

for cmd in nvidia-smi python3 cmake awk sort sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "$cmd is required" >&2; exit 1; }
done

chmod +x "$PREPARE_SCRIPT"
python3 "$PREPARE_SCRIPT"
VERSION="$(tr -d '[:space:]' < "${ROOT_DIR}/VERSION")"
[[ "$VERSION" == "0.5.6-PR" ]] || { echo "Expected VERSION=0.5.6-PR, found $VERSION" >&2; exit 1; }
PACKAGE_NAME="pepepowminer-v${VERSION}"
PACKAGE_DIR="${ROOT_DIR}/dist/${PACKAGE_NAME}"
ARCHIVE_PATH="${ROOT_DIR}/dist/${PACKAGE_NAME}-hiveos.tar.gz"

for marker in PEPEPOW_CUDA_COLD_NONLINEAR_MODE PEPEPOW_CUDA_HOT_BRANCH_FIRST PEPEPOW_HEADER80_LAUNCH_BOUNDS; do
  grep -Fq "$marker" "${ROOT_DIR}/native/src/cuda/header80_backend_v056.cu" || { echo "Missing v0.5.6 marker: $marker" >&2; exit 1; }
done

echo "== NVIDIA validation target =="
nvidia-smi --query-gpu=name,compute_cap,driver_version,memory.total,clocks.current.sm,clocks.current.memory,power.limit --format=csv,noheader

find_nvcc() {
  command -v nvcc >/dev/null 2>&1 && { command -v nvcc; return; }
  local p
  for p in /usr/local/cuda/bin/nvcc /usr/local/cuda-12.4/bin/nvcc /usr/local/cuda-12/bin/nvcc; do
    [[ -x "$p" ]] && { echo "$p"; return; }
  done
  return 1
}
NVCC_PATH="$(find_nvcc)" || { echo "CUDA nvcc compiler not found" >&2; exit 1; }
export PATH="$(dirname "$NVCC_PATH"):$PATH"
"$NVCC_PATH" --version

profile_hps() { sed -n 's/.* hps=\([0-9][0-9]*\).*/\1/p' <<<"$1" | tail -n1; }
median_hps() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{if(NR%2)print a[(NR+1)/2];else print int((a[NR/2]+a[NR/2+1])/2)}'; }
profile_registers() { awk '/Used [0-9]+ registers/{for(i=1;i<=NF;i++)if($i=="Used"){v=$(i+1)+0;if(v>m)m=v}}END{print m+0}' "$1"; }
profile_spills() { awk '/bytes spill stores/{for(i=1;i<=NF;i++)if($(i+1)=="bytes"&&$(i+2)=="spill"){v=$i+0;if(v>m)m=v}}END{print m+0}' "$1"; }

if [[ "$RESUME" == "1" ]]; then
  echo "RESUME=1: preserving completed profiles"
  rm -rf "$LINK_BUILD_DIR" "$PACKAGE_DIR" "$ARCHIVE_PATH" "$ARCHIVE_PATH.sha256"
else
  rm -rf "$PROFILE_ROOT" "$LINK_BUILD_DIR" "$PACKAGE_DIR" "$ARCHIVE_PATH" "$ARCHIVE_PATH.sha256"
fi
mkdir -p "$PROFILE_ROOT" "${ROOT_DIR}/dist"

build_profile() {
  local name="$1" threads="$2" min_blocks="$3" hot_first="$4" cold_mode="$5" launch_bounds="$6" max_regs="$7"
  local dir="${PROFILE_ROOT}/${name}" log="${PROFILE_ROOT}/${name}.build.log"
  if [[ "$RESUME" == "1" && -s "$dir/profile.hps" && -s "$dir/profile.meta" ]] && grep -qx 'valid=1' "$dir/profile.meta"; then
    echo "PROFILE_REUSE name=$name hps=$(cat "$dir/profile.hps")"
    return
  fi
  rm -rf "$dir" "$log"
  echo "== PROFILE $name: threads=$threads min_blocks=$min_blocks hot_first=$hot_first cold_mode=$cold_mode launch_bounds=$launch_bounds max_regs=${max_regs:-auto} =="

  local args=(
    -S "${ROOT_DIR}/native" -B "$dir"
    -DCMAKE_BUILD_TYPE=Release
    -DPEPEPOW_ENABLE_CUDA=ON
    -DPEPEPOW_BUILD_TESTS=ON
    -DPEPEPOW_CUDA_PTXAS_VERBOSE=ON
    -DPEPEPOW_CUDA_THREADS="$threads"
    -DPEPEPOW_CUDA_MIN_BLOCKS="$min_blocks"
    -DPEPEPOW_CUDA_SCALED_MATRIX=ON
    -DPEPEPOW_CUDA_SPLIT_PIPELINE=OFF
    -DPEPEPOW_CUDA_FAST_FRACTION=ON
    -DPEPEPOW_CUDA_EXACT_BIT_CONVERSIONS=ON
    -DPEPEPOW_CUDA_BIT_SW_FRACTION=ON
    -DPEPEPOW_CUDA_DERIVE_TWO=OFF
    -DPEPEPOW_CUDA_NIBBLE_TABLE=OFF
    -DPEPEPOW_CUDA_SCALED_NIBBLE_TABLE=ON
    -DPEPEPOW_CUDA_ASSUME_FINITE=ON
    -DPEPEPOW_CUDA_COLD_NONLINEAR_MODE="$cold_mode"
    -DPEPEPOW_CUDA_HOT_BRANCH_FIRST="$hot_first"
    -DPEPEPOW_CUDA_USE_LAUNCH_BOUNDS="$launch_bounds"
    -DPEPEPOW_CUDA_BYTE_UNROLL=1
    -DCMAKE_CUDA_ARCHITECTURES=86
    -DCMAKE_CUDA_COMPILER="$NVCC_PATH"
    -DFETCHCONTENT_BASE_DIR="$DEPS_DIR"
  )
  [[ -n "$max_regs" ]] && args+=( -DPEPEPOW_CUDA_MAX_REGISTERS="$max_regs" )
  if command -v ccache >/dev/null 2>&1; then
    args+=( -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache -DCMAKE_CUDA_COMPILER_LAUNCHER=ccache )
  fi
  cmake "${args[@]}"
  cmake --build "$dir" --parallel "$JOBS" --target pepepow_core_tests pepepow_cuda_tests pepepow_cuda_header80_validation pepepow_header80_benchmark pepepowminer 2>&1 | tee "$log"

  if ! ctest --test-dir "$dir" --output-on-failure || ! "$dir/pepepow_cuda_header80_validation"; then
    printf 'name=%s\nvalid=0\nreason=validation_failed\n' "$name" > "$dir/profile.meta"
    echo "PROFILE_INVALID name=$name reason=validation_failed"
    return
  fi

  local speeds=() out hps
  for ((run=1; run<=BENCH_RUNS; run++)); do
    out="$("$dir/pepepow_header80_benchmark" "$BENCH_NONCES")"
    echo "BENCH_RUN profile=$name run=$run $out"
    hps="$(profile_hps "$out")"
    [[ "$hps" =~ ^[1-9][0-9]*$ ]] || { echo "Cannot parse benchmark for $name" >&2; exit 1; }
    speeds+=("$hps")
  done
  local median regs spills resource pow_regs
  median="$(median_hps "${speeds[@]}")"
  regs="$(profile_registers "$log")"
  spills="$(profile_spills "$log")"
  resource="$dir/cuobjdump-resource-usage.txt"
  command -v cuobjdump >/dev/null 2>&1 && cuobjdump --dump-resource-usage "$dir/pepepowminer" > "$resource" 2>&1 || true
  pow_regs="$(awk '/Function .*header80_pow_kernel/{f=1;next} f&&/REG:/{x=$0;sub(/^.*REG:/,"",x);sub(/[^0-9].*$/,"",x);print x;exit}' "$resource" 2>/dev/null || true)"
  pow_regs="${pow_regs:-0}"
  printf '%s\n' "$median" > "$dir/profile.hps"
  printf 'name=%s\nvalid=1\nthreads=%s\nmin_blocks=%s\nhot_first=%s\ncold_mode=%s\nlaunch_bounds=%s\nmax_regs=%s\nmax_registers=%s\npow_registers=%s\nmax_spill_bytes=%s\nbenchmark_hps=%s\nmedian_hps=%s\n' "$name" "$threads" "$min_blocks" "$hot_first" "$cold_mode" "$launch_bounds" "${max_regs:-auto}" "$regs" "$pow_regs" "$spills" "${speeds[*]}" "$median" > "$dir/profile.meta"
  echo "PROFILE_RESULT name=$name threads=$threads min_blocks=$min_blocks hot_first=$hot_first cold_mode=$cold_mode launch_bounds=$launch_bounds max_regs=${max_regs:-auto} registers=$regs pow_regs=$pow_regs spills=$spills median_hps=$median"
}

profiles=()
add() { build_profile "$@"; profiles+=("$1"); }

add baseline-v054      64 1 OFF 0 ON 80
add hot-inline         64 1 ON  0 ON 80
add hot-outline-leaf   64 1 ON  1 ON 80
add hot-outline-core   64 1 ON  2 ON 80
add hot-outline-safe   64 1 ON  3 ON 80
add cold-outline-safe  64 1 OFF 3 ON 80

stage_best=""; stage_hps=0
for p in "${profiles[@]}"; do
  [[ -s "$PROFILE_ROOT/$p/profile.hps" ]] || continue
  h="$(cat "$PROFILE_ROOT/$p/profile.hps")"
  (( h > stage_hps )) && { stage_hps="$h"; stage_best="$p"; }
done
[[ -n "$stage_best" ]] || { echo "No valid cold-path profile" >&2; exit 1; }
source <(sed -n -E 's/^(hot_first|cold_mode)=(.*)$/BEST_\1=\2/p' "$PROFILE_ROOT/$stage_best/profile.meta")
echo "COLD_PATH_SELECTED profile=$stage_best hps=$stage_hps hot_first=$BEST_hot_first cold_mode=$BEST_cold_mode"

add best-nobounds-auto 64 1 "$BEST_hot_first" "$BEST_cold_mode" OFF ""
add best-nobounds-r80  64 1 "$BEST_hot_first" "$BEST_cold_mode" OFF 80
add best-nobounds-r72  64 1 "$BEST_hot_first" "$BEST_cold_mode" OFF 72
add best-nobounds-r64  64 1 "$BEST_hot_first" "$BEST_cold_mode" OFF 64
add best-t96-r80       96 1 "$BEST_hot_first" "$BEST_cold_mode" OFF 80
add best-t128-r80     128 1 "$BEST_hot_first" "$BEST_cold_mode" OFF 80
add best-bounds-b2     64 2 "$BEST_hot_first" "$BEST_cold_mode" ON  ""

best=""; best_hps=0
for p in "${profiles[@]}"; do
  [[ -s "$PROFILE_ROOT/$p/profile.hps" ]] || continue
  h="$(cat "$PROFILE_ROOT/$p/profile.hps")"
  (( h > best_hps )) && { best_hps="$h"; best="$p"; }
done
[[ -n "$best" && -s "$PROFILE_ROOT/baseline-v054/profile.hps" ]] || { echo "No valid selected profile" >&2; exit 1; }
baseline_hps="$(cat "$PROFILE_ROOT/baseline-v054/profile.hps")"
uplift="$(awk -v b="$best_hps" -v a="$baseline_hps" 'BEGIN{printf "%.2f",(b/a-1)*100}')"
SELECTED="$PROFILE_ROOT/$best"
ln -s "$SELECTED" "$LINK_BUILD_DIR"
echo "AUTOTUNE_SELECTED profile=$best hps=$best_hps baseline_hps=$baseline_hps uplift_pct=$uplift build=$SELECTED"
if (( best_hps >= TARGET_HPS )); then echo "TARGET_2MH=PASS measured_hps=$best_hps"; else echo "TARGET_2MH=PENDING measured_hps=$best_hps"; fi

BUILD_ID="$("$SELECTED/pepepowminer" --version | head -n1)"
[[ "$BUILD_ID" == *"$VERSION"* && "$BUILD_ID" == *"$EXPECTED_EDITION"* ]] || { echo "Binary identity mismatch: $BUILD_ID" >&2; exit 1; }
mkdir -p "$PACKAGE_DIR"
install -m 0755 "$SELECTED/pepepowminer" "$PACKAGE_DIR/pepepowminer"
for f in h-run.sh h-config.sh h-stats.sh diagnostic-summary.sh forensic-audit.sh collect-forensics.sh collect-and-serve.sh capture-stratum.sh stratum-replay-proxy.py; do
  [[ -f "$ROOT_DIR/hiveos/$f" ]] && install -m 0755 "$ROOT_DIR/hiveos/$f" "$PACKAGE_DIR/$f"
done
[[ -f "$ROOT_DIR/hiveos/h-manifest.conf" ]] && install -m 0644 "$ROOT_DIR/hiveos/h-manifest.conf" "$PACKAGE_DIR/h-manifest.conf"
install -m 0644 "$ROOT_DIR/VERSION" "$PACKAGE_DIR/VERSION"
for f in collect-profiler-pack-v4.sh collect-v056-profiler.sh; do
  [[ -f "$ROOT_DIR/tools/$f" ]] && install -m 0755 "$ROOT_DIR/tools/$f" "$PACKAGE_DIR/$f"
done
{
  echo "version=$VERSION"
  echo "selected_profile=$best"
  echo "selected_hps=$best_hps"
  echo "baseline_hps=$baseline_hps"
  echo "uplift_pct=$uplift"
  (( best_hps >= TARGET_HPS )) && echo 'target_2mh=PASS' || echo 'target_2mh=PENDING'
  echo 'source_backend=header80_backend_v056.cu'
  echo 'strategy=cold_nonlinear_outlining_hot_branch_true_register_caps'
  for p in "${profiles[@]}"; do echo; echo "--- $p ---"; cat "$PROFILE_ROOT/$p/profile.meta" 2>/dev/null || echo 'valid=0'; done
} > "$PACKAGE_DIR/BUILD_PROFILE"
cat > "$PACKAGE_DIR/README-v056.txt" <<EOF
PepeW Miner $VERSION
Selected profile: $best
Internal benchmark: $best_hps H/s
v0.5.4 baseline in this run: $baseline_hps H/s
Measured uplift: $uplift%
Target: $TARGET_HPS H/s

This prerelease is consensus-gated. It does not claim 2 MH/s unless both
TARGET_2MH=PASS and a live-pool run confirm the target with valid shares.
EOF

tar -C "${ROOT_DIR}/dist" -czf "$ARCHIVE_PATH" "$PACKAGE_NAME"
sha256sum "$ARCHIVE_PATH" > "$ARCHIVE_PATH.sha256"
echo "PASS: PepeW Cold Path Edition $VERSION package completed"
echo "AUTOTUNE_PROFILE=$best"
echo "AUTOTUNE_HPS=$best_hps"
echo "AUTOTUNE_BASELINE_HPS=$baseline_hps"
echo "AUTOTUNE_UPLIFT_PCT=$uplift"
(( best_hps >= TARGET_HPS )) && echo 'TARGET_2MH=PASS' || echo 'TARGET_2MH=PENDING'
echo "ARCHIVE=$ARCHIVE_PATH"
echo "SHA256=$(awk '{print $1}' "$ARCHIVE_PATH.sha256")"
echo "DOWNLOAD_COMMAND=cd ${ROOT_DIR}/dist && python3 -m http.server 8080 --bind 0.0.0.0"
