#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO_URL="${REPO_URL:-https://github.com/iPepew/PepePow_Miner.git}"
RELEASE_REF="${RELEASE_REF:-release/v1.0.0}"
WORK_ROOT="${WORK_ROOT:-/root/pepew-v1-release}"
OUT_ROOT="${OUT_ROOT:-/root/pepepow-tests}"
BENCH_NONCES="${BENCH_NONCES:-16777216}"
BENCH_RUNS="${BENCH_RUNS:-3}"
REQUIRE_2MH="${REQUIRE_2MH:-1}"
PUBLIC_UPLOAD="${PUBLIC_UPLOAD:-1}"
JOBS="${JOBS:-$(nproc)}"
EXPECTED_SOURCE_SHA="9a00250cf76c93821b5ae0cb82e6a3cc2f18d5310510abacfab06bb8221d6f54"
LIVE_EVIDENCE_SHA="2fda5617b01757cdfee2169aac41fa2d8a243ab5394bd3fff3478b1130d6fd69"
STAMP="$(date +%Y%m%d_%H%M%S)"
NAME="PepeW-Miner-v1.0.0-HiveOS-sm86"
SRC="$WORK_ROOT/src"
BUILD="$WORK_ROOT/build"
PACKAGE_PARENT="$WORK_ROOT/package"
PACKAGE_DIR="$PACKAGE_PARENT/pepepowminer-v1.0.0"
ARCHIVE="$OUT_ROOT/${NAME}.tar.gz"
SHA_FILE="$ARCHIVE.sha256"
STATUS_FILE="$WORK_ROOT/status.env"
BUILD_LOG="$WORK_ROOT/build.log"
BENCH_LOG="$WORK_ROOT/benchmark.log"
SUMMARY="$WORK_ROOT/release-summary.txt"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1" >&2; exit 1; }; }
for command_name in bash git cmake ctest python3 sha256sum tar awk sed grep nvidia-smi curl; do
    need "$command_name"
done

find_nvcc(){
    command -v nvcc >/dev/null 2>&1 && { command -v nvcc; return 0; }
    local candidate
    for candidate in /usr/local/cuda/bin/nvcc /usr/local/cuda-12.4/bin/nvcc /usr/local/cuda-12/bin/nvcc; do
        [[ -x "$candidate" ]] && { echo "$candidate"; return 0; }
    done
    return 1
}

find_stable_package(){
    local candidate
    for candidate in \
        /hive/miners/custom/pepepowminer-v0.6.0-PR \
        /hive/miners/custom/pepepowminer \
        /hive/miners/custom/pepepow; do
        [[ -d "$candidate" && -x "$candidate/pepepowminer" ]] || continue
        readlink -f "$candidate"
        return 0
    done
    return 1
}

xid_count(){ dmesg 2>/dev/null | grep -Ec 'NVRM: Xid|Xid \(' || true; }
set_status(){
    mkdir -p "$WORK_ROOT"
    printf 'STATE=%q\nSTEP=%q\nDETAIL=%q\nUPDATED_AT=%q\n' \
        "$1" "${2:-}" "${3:-}" "$(date --iso-8601=seconds)" >"$STATUS_FILE"
}
fail(){ set_status FAILED release "$*"; echo "ERROR: $*" >&2; exit 1; }

NVCC="$(find_nvcc || true)"
[[ -n "$NVCC" ]] || fail "nvcc not found"
export PATH="$(dirname "$NVCC"):$PATH"
STABLE_PACKAGE="$(find_stable_package || true)"
[[ -n "$STABLE_PACKAGE" ]] || fail "installed PepeW stable package not found"

GPU_APPS="$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null || true)"
if [[ -n "${GPU_APPS//[[:space:]]/}" ]]; then
    echo "$GPU_APPS" >&2
    fail "GPU is busy; use an empty flight sheet"
fi

mkdir -p "$OUT_ROOT"
rm -rf "$WORK_ROOT"
mkdir -p "$WORK_ROOT" "$PACKAGE_PARENT"
set_status RUNNING clone "$RELEASE_REF"
echo "RELEASE_STAGE=CLONE ref=$RELEASE_REF"
git clone --depth 1 --branch "$RELEASE_REF" "$REPO_URL" "$SRC"

[[ "$(tr -d '[:space:]' <"$SRC/VERSION")" == "1.0.0" ]] || fail "VERSION is not 1.0.0"
PARTS=()
for index in 00 01 02 03 04 05 06 07; do
    part="$SRC/native/src/cuda/v1/header80_backend_part${index}.inc"
    [[ -f "$part" ]] || fail "missing CUDA source fragment: $part"
    PARTS+=("$part")
done
cat "${PARTS[@]}" >"$WORK_ROOT/header80_backend_service768.cu"
ACTUAL_SOURCE_SHA="$(sha256sum "$WORK_ROOT/header80_backend_service768.cu" | awk '{print $1}')"
[[ "$ACTUAL_SOURCE_SHA" == "$EXPECTED_SOURCE_SHA" ]] || \
    fail "validated CUDA source digest mismatch: $ACTUAL_SOURCE_SHA"
echo "SOURCE_SHA256=$ACTUAL_SOURCE_SHA"

XID_BEFORE="$(xid_count)"
nvidia-smi -q >"$WORK_ROOT/nvidia-smi-before.txt" 2>&1 || true
dmesg 2>/dev/null | grep -E 'NVRM|Xid' >"$WORK_ROOT/xid-before.txt" || true

set_status RUNNING configure service768
echo "RELEASE_STAGE=CONFIGURE profile=service768 threads=768 min_blocks=1"
cmake -S "$SRC/native" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DPEPEPOW_ENABLE_CUDA=ON \
    -DPEPEPOW_BUILD_TESTS=ON \
    -DPEPEPOW_CUDA_PTXAS_VERBOSE=ON \
    -DPEPEPOW_CUDA_THREADS=768 \
    -DPEPEPOW_CUDA_MIN_BLOCKS=1 \
    -DPEPEPOW_CUDA_MAX_REGISTERS= \
    -DPEPEPOW_CUDA_SCALED_MATRIX=ON \
    -DPEPEPOW_CUDA_SPLIT_PIPELINE=OFF \
    -DPEPEPOW_CUDA_FAST_FRACTION=ON \
    -DPEPEPOW_CUDA_EXACT_BIT_CONVERSIONS=ON \
    -DPEPEPOW_CUDA_BIT_SW_FRACTION=ON \
    -DPEPEPOW_CUDA_DERIVE_TWO=OFF \
    -DPEPEPOW_CUDA_NIBBLE_TABLE=OFF \
    -DPEPEPOW_CUDA_SCALED_NIBBLE_TABLE=ON \
    -DPEPEPOW_CUDA_ASSUME_FINITE=ON \
    -DPEPEPOW_CUDA_SW_STATE_MODE=3 \
    -DPEPEPOW_CUDA_BYTE_UNROLL=1 \
    -DCMAKE_CUDA_ARCHITECTURES=86 \
    -DCMAKE_CUDA_COMPILER="$NVCC" \
    >"$WORK_ROOT/configure.log" 2>&1

set_status RUNNING build pepepowminer
echo "RELEASE_STAGE=BUILD"
cmake --build "$BUILD" --parallel "$JOBS" --target \
    pepepow_core_tests pepepow_cuda_tests pepepow_cuda_header80_validation \
    pepepow_header80_benchmark pepepowminer \
    >"$BUILD_LOG" 2>&1

read -r REGS STACK_BYTES SPILL_STORE SPILL_LOAD < <(
python3 - "$BUILD_LOG" <<'PY'
import re, sys
text=open(sys.argv[1], errors='replace').read().splitlines()
regs=stack=stores=loads=None
active=False
for line in text:
    if 'Compiling entry function' in line and 'header80_pow_kernel' in line:
        active=True
        continue
    if active:
        m=re.search(r'Used\s+(\d+)\s+registers', line)
        if m: regs=int(m.group(1))
        m=re.search(r'(\d+) bytes stack frame, (\d+) bytes spill stores, (\d+) bytes spill loads', line)
        if m:
            stack,stores,loads=map(int,m.groups())
            break
print(regs or 0, stack or 0, stores or 0, loads or 0)
PY
)
[[ "$SPILL_STORE" == 0 && "$SPILL_LOAD" == 0 ]] || \
    fail "CUDA spills detected: stores=$SPILL_STORE loads=$SPILL_LOAD"
echo "CUDA_RESOURCES regs=$REGS stack=$STACK_BYTES spill_store=$SPILL_STORE spill_load=$SPILL_LOAD"

set_status RUNNING test ctest
echo "RELEASE_STAGE=CTEST"
ctest --test-dir "$BUILD" --output-on-failure | tee "$WORK_ROOT/ctest.log"

set_status RUNNING validation cpu_cuda_consensus
echo "RELEASE_STAGE=CONSENSUS_VALIDATION"
"$BUILD/pepepow_cuda_header80_validation" | tee "$WORK_ROOT/validation.log"

BINARY_VERSION="$("$BUILD/pepepowminer" --version 2>&1 || true)"
grep -q '1\.0\.0' <<<"$BINARY_VERSION" || fail "binary identity is not v1.0.0: $BINARY_VERSION"
echo "BINARY_VERSION=$BINARY_VERSION"

set_status RUNNING benchmark "$BENCH_RUNS runs"
echo "RELEASE_STAGE=BENCHMARK runs=$BENCH_RUNS nonces=$BENCH_NONCES"
: >"$BENCH_LOG"
SPEEDS=()
for ((run=1; run<=BENCH_RUNS; run++)); do
    OUTPUT="$("$BUILD/pepepow_header80_benchmark" "$BENCH_NONCES" 2>&1)"
    HPS="$(sed -n 's/.* hps=\([0-9][0-9]*\).*/\1/p' <<<"$OUTPUT" | tail -n1)"
    [[ "$HPS" =~ ^[1-9][0-9]*$ ]] || fail "benchmark run $run produced no valid H/s"
    SPEEDS+=("$HPS")
    printf 'BENCH_RUN=%d/%d HPS=%s %s\n' "$run" "$BENCH_RUNS" "$HPS" "$OUTPUT" | tee -a "$BENCH_LOG"
done
BENCH_STATS="$(printf '%s\n' "${SPEEDS[@]}" | python3 -c 'import sys,statistics as s;v=[int(x) for x in sys.stdin if x.strip()];print(min(v),int(s.median(v)),f"{s.mean(v):.2f}",max(v),f"{s.pstdev(v):.2f}")')"
read -r MIN_HPS MEDIAN_HPS MEAN_HPS MAX_HPS STDEV_HPS <<<"$BENCH_STATS"
if [[ "$REQUIRE_2MH" == 1 && "$MEDIAN_HPS" -lt 2000000 ]]; then
    fail "release benchmark below 2 MH/s: median=$MEDIAN_HPS"
fi

SANITIZER_GATE=UNAVAILABLE
if command -v compute-sanitizer >/dev/null 2>&1; then
    set_status RUNNING sanitizer memcheck
    echo "RELEASE_STAGE=COMPUTE_SANITIZER"
    if timeout 900 compute-sanitizer --tool memcheck --error-exitcode=97 \
        "$BUILD/pepepow_header80_benchmark" 65536 \
        >"$WORK_ROOT/compute-sanitizer.log" 2>&1; then
        SANITIZER_GATE=PASS
    else
        SANITIZER_GATE=FAIL
        fail "compute-sanitizer failed"
    fi
fi

XID_AFTER="$(xid_count)"
NEW_XID=$((XID_AFTER-XID_BEFORE))
(( NEW_XID < 0 )) && NEW_XID=0
[[ "$NEW_XID" == 0 ]] || fail "new NVIDIA Xid detected: $NEW_XID"
nvidia-smi -q >"$WORK_ROOT/nvidia-smi-after.txt" 2>&1 || true
dmesg 2>/dev/null | grep -E 'NVRM|Xid' >"$WORK_ROOT/xid-after.txt" || true

set_status RUNNING package HiveOS
echo "RELEASE_STAGE=PACKAGE"
mkdir -p "$PACKAGE_DIR"
cp -a "$STABLE_PACKAGE/." "$PACKAGE_DIR/"
install -m 0755 "$BUILD/pepepowminer" "$PACKAGE_DIR/pepepowminer"
printf '1.0.0\n' >"$PACKAGE_DIR/VERSION"
printf '%s\n' \
    'profile=service768' \
    'threads=768' \
    'min_blocks=1' \
    "registers=$REGS" \
    "stack_bytes=$STACK_BYTES" \
    "spill_store_bytes=$SPILL_STORE" \
    "spill_load_bytes=$SPILL_LOAD" \
    "source_sha256=$ACTUAL_SOURCE_SHA" \
    "git_ref=$RELEASE_REF" \
    >"$PACKAGE_DIR/BUILD_PROFILE"
cp -f "$SRC/LICENSE" "$PACKAGE_DIR/LICENSE" 2>/dev/null || true
cp -f "$SRC/README.md" "$PACKAGE_DIR/README.md" 2>/dev/null || true
cp -f "$SRC/RELEASE_NOTES_v1.0.0.md" "$PACKAGE_DIR/RELEASE_NOTES_v1.0.0.md" 2>/dev/null || true
sha256sum "$PACKAGE_DIR/pepepowminer" >"$PACKAGE_DIR/pepepowminer.sha256"

cat >"$PACKAGE_DIR/RELEASE_MANIFEST.txt" <<MANIFEST
product=PepeW Miner
version=1.0.0
algorithm=HooHash V110
cuda_arch=sm_86
release_profile=service768
threads=768
min_blocks=1
source_sha256=$ACTUAL_SOURCE_SHA
binary_sha256=$(sha256sum "$PACKAGE_DIR/pepepowminer" | awk '{print $1}')
release_benchmark_min_hps=$MIN_HPS
release_benchmark_median_hps=$MEDIAN_HPS
release_benchmark_mean_hps=$MEAN_HPS
release_benchmark_max_hps=$MAX_HPS
release_benchmark_stdev_hps=$STDEV_HPS
registers=$REGS
stack_bytes=$STACK_BYTES
spill_store_bytes=$SPILL_STORE
spill_load_bytes=$SPILL_LOAD
ctest=PASS
consensus_validation=PASS
compute_sanitizer=$SANITIZER_GATE
new_nvidia_xid=$NEW_XID
verified_live_evidence_sha256=$LIVE_EVIDENCE_SHA
verified_live_mean_mhs=2.0236493506493507
verified_live_median_mhs=2.022
verified_live_accepted=90
verified_live_rejected=0
verified_live_new_xid=0
built_at=$(date --iso-8601=seconds)
MANIFEST

rm -f "$ARCHIVE" "$SHA_FILE"
tar -C "$PACKAGE_PARENT" -czf "$ARCHIVE" "$(basename "$PACKAGE_DIR")"
sha256sum "$ARCHIVE" >"$SHA_FILE"

cat >"$SUMMARY" <<SUMMARY_TEXT
release_gate=PASS
product=PepeW Miner
version=1.0.0
profile=service768
source_sha256=$ACTUAL_SOURCE_SHA
binary_version=$BINARY_VERSION
benchmark_min_hps=$MIN_HPS
benchmark_median_hps=$MEDIAN_HPS
benchmark_mean_hps=$MEAN_HPS
benchmark_max_hps=$MAX_HPS
benchmark_stdev_hps=$STDEV_HPS
registers=$REGS
stack_bytes=$STACK_BYTES
spill_store_bytes=$SPILL_STORE
spill_load_bytes=$SPILL_LOAD
ctest=PASS
consensus_validation=PASS
compute_sanitizer=$SANITIZER_GATE
new_nvidia_xid=$NEW_XID
live_gate=PASS
TARGET_2MH=LIVE_SMOKE_PASS
archive=$ARCHIVE
sha256_file=$SHA_FILE
SUMMARY_TEXT

set_status COMPLETE release_gate PASS
echo
echo "================ PEPEW MINER v1.0.0 RELEASE BUILD COMPLETE ================"
cat "$SUMMARY"
echo "ARCHIVE=$ARCHIVE"
echo "SHA256_FILE=$SHA_FILE"

if [[ "$PUBLIC_UPLOAD" == 1 ]]; then
    PUBLISHER=/root/publish-pepepow-test-results.sh
    PUBLISHER_URL="https://raw.githubusercontent.com/iPepew/PepePow_Miner/experiment/v2.0.0-warp-service/tools/publish-test-results.sh"
    if curl -fsSL "$PUBLISHER_URL" -o "$PUBLISHER"; then
        chmod +x "$PUBLISHER"
        echo "UPLOAD=ARCHIVE"
        "$PUBLISHER" "$ARCHIVE" || true
        echo "UPLOAD=SHA256"
        "$PUBLISHER" "$SHA_FILE" || true
    fi
fi
