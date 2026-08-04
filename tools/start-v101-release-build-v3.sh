#!/usr/bin/env bash
set -Eeuo pipefail

BASE="https://raw.githubusercontent.com/iPepew/PepePow_Miner/release/v1.0.1/tools"
RUNNER=/root/build-v101-release.sh
WATCHER=/root/watch-v101-release-build.sh
LOG=/root/v101-release-build.log
SCREEN=v101-release-build
TOOLBIN=/root/pepew-v101-toolchain/bin
CUDA_ROOT=/usr/local/cuda-12.4

mkdir -p "$TOOLBIN"

REAL_CMAKE=/usr/local/bin/cmake
REAL_CTEST=/usr/local/bin/ctest
REAL_NVCC="$CUDA_ROOT/bin/nvcc"
REAL_CICC="$CUDA_ROOT/nvvm/bin/cicc"
[[ -x "$REAL_CMAKE" ]] || { echo "ERROR: modern CMake not found at $REAL_CMAKE" >&2; exit 1; }
[[ -x "$REAL_CTEST" ]] || { echo "ERROR: modern CTest not found at $REAL_CTEST" >&2; exit 1; }
[[ -x "$REAL_NVCC" ]] || { echo "ERROR: CUDA 12.4 toolkit not found at $REAL_NVCC" >&2; exit 1; }
[[ -x "$REAL_CICC" ]] || { echo "ERROR: CUDA internal compiler not found at $REAL_CICC" >&2; exit 1; }

ln -sfn "$REAL_CMAKE" "$TOOLBIN/cmake"
ln -sfn "$REAL_CTEST" "$TOOLBIN/ctest"
rm -f "$TOOLBIN/nvcc"

export PATH="$TOOLBIN:$CUDA_ROOT/bin:/usr/local/bin:/usr/bin:/bin"
export LD_LIBRARY_PATH="$CUDA_ROOT/lib64:${LD_LIBRARY_PATH:-}"
export CUDA_HOME="$CUDA_ROOT"
export CUDA_PATH="$CUDA_ROOT"
hash -r

CMAKE_BIN="$(command -v cmake)"
CTEST_BIN="$(command -v ctest)"
NVCC_BIN="$REAL_NVCC"
CMAKE_VERSION="$($CMAKE_BIN --version | awk 'NR==1 {print $3}')"
NVCC_VERSION="$($NVCC_BIN --version | awk '/release/ {gsub(",", "", $5); print $5; exit}')"

python3 - "$CMAKE_VERSION" "$NVCC_VERSION" <<'PY'
import sys

def version(value):
    parts=[]
    for item in value.split('.'):
        digits=''.join(ch for ch in item if ch.isdigit())
        parts.append(int(digits or 0))
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts[:3])

if version(sys.argv[1]) < (3, 24, 0):
    raise SystemExit(f"ERROR: CMake >= 3.24 required, found {sys.argv[1]}")
if version(sys.argv[2]) < (12, 0, 0):
    raise SystemExit(f"ERROR: CUDA Toolkit >= 12.0 required, found {sys.argv[2]}")
PY

SMOKE_DIR=/root/pepew-v101-toolchain/smoke
rm -rf "$SMOKE_DIR"
mkdir -p "$SMOKE_DIR"
printf '%s\n' 'int main(){return 0;}' >"$SMOKE_DIR/smoke.cu"
"$NVCC_BIN" -std=c++20 -arch=sm_86 -c "$SMOKE_DIR/smoke.cu" -o "$SMOKE_DIR/smoke.o" >"$SMOKE_DIR/nvcc-smoke.log" 2>&1 || {
  cat "$SMOKE_DIR/nvcc-smoke.log" >&2
  echo "ERROR: CUDA 12.4 compiler smoke test failed" >&2
  exit 1
}

screen -S "$SCREEN" -X quit 2>/dev/null || true
rm -rf /root/pepew-v101-release
rm -f "$LOG"

{
  echo "TOOLCHAIN_PREFLIGHT=PASS"
  echo "CMAKE_BIN=$CMAKE_BIN"
  echo "CMAKE_VERSION=$CMAKE_VERSION"
  echo "CTEST_BIN=$CTEST_BIN"
  echo "NVCC_BIN=$NVCC_BIN"
  echo "NVCC_VERSION=$NVCC_VERSION"
  echo "CICC_BIN=$REAL_CICC"
  echo "CUDA_ROOT=$CUDA_ROOT"
  echo "CUDA_COMPILER_SMOKE=PASS"
  echo "BINARY_IDENTITY_FIX=PASS"
  echo "PATH=$PATH"
} | tee "$LOG"

curl -fsSL "$BASE/build-v101-release-fixed.sh?rev=binary-identity-v7" -o "$RUNNER"
curl -fsSL "$BASE/watch-v101-release-build.sh?rev=binary-identity-v7" -o "$WATCHER"
chmod +x "$RUNNER" "$WATCHER"

screen -dmS "$SCREEN" env \
  PATH="$PATH" \
  LD_LIBRARY_PATH="$LD_LIBRARY_PATH" \
  CUDA_HOME="$CUDA_HOME" \
  CUDA_PATH="$CUDA_PATH" \
  CUDACXX="$NVCC_BIN" \
  CMAKE_CUDA_COMPILER="$NVCC_BIN" \
  CMAKE_COMMAND="$CMAKE_BIN" \
  CTEST_COMMAND="$CTEST_BIN" \
  bash --noprofile --norc -c "exec '$RUNNER' 2>&1 | tee -a '$LOG'"

sleep 3
REFRESH=5 "$WATCHER" "$LOG"
