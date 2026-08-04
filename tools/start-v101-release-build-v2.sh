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
[[ -x "$REAL_CMAKE" ]] || {
  echo "ERROR: modern CMake not found at $REAL_CMAKE" >&2
  exit 1
}
[[ -x "$REAL_CTEST" ]] || {
  echo "ERROR: modern CTest not found at $REAL_CTEST" >&2
  exit 1
}
[[ -x "$REAL_NVCC" ]] || {
  echo "ERROR: CUDA 12.4 toolkit not found at $REAL_NVCC" >&2
  echo "Run start-cuda124-toolkit-only.sh first." >&2
  exit 1
}

ln -sfn "$REAL_CMAKE" "$TOOLBIN/cmake"
ln -sfn "$REAL_CTEST" "$TOOLBIN/ctest"
ln -sfn "$REAL_NVCC" "$TOOLBIN/nvcc"
export PATH="$TOOLBIN:$CUDA_ROOT/bin:/usr/local/bin:/usr/bin:/bin"
export LD_LIBRARY_PATH="$CUDA_ROOT/lib64:${LD_LIBRARY_PATH:-}"
hash -r

CMAKE_BIN="$(command -v cmake)"
CTEST_BIN="$(command -v ctest)"
NVCC_BIN="$(command -v nvcc)"
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
  echo "CUDA_ROOT=$CUDA_ROOT"
  echo "PATH=$PATH"
} | tee "$LOG"

curl -fsSL "$BASE/build-v101-release.sh?rev=cuda124-cxx20-v5" -o "$RUNNER"
curl -fsSL "$BASE/watch-v101-release-build.sh?rev=cuda124-cxx20-v5" -o "$WATCHER"
chmod +x "$RUNNER" "$WATCHER"

screen -dmS "$SCREEN" env \
  PATH="$PATH" \
  LD_LIBRARY_PATH="$LD_LIBRARY_PATH" \
  CUDACXX="$NVCC_BIN" \
  CMAKE_CUDA_COMPILER="$NVCC_BIN" \
  CMAKE_COMMAND="$CMAKE_BIN" \
  CTEST_COMMAND="$CTEST_BIN" \
  bash --noprofile --norc -c "exec '$RUNNER' 2>&1 | tee -a '$LOG'"

sleep 3
REFRESH=5 "$WATCHER" "$LOG"
