#!/usr/bin/env bash
set -Eeuo pipefail

BASE="https://raw.githubusercontent.com/iPepew/PepePow_Miner/release/v1.0.1/tools"
RUNNER=/root/build-v101-release.sh
WATCHER=/root/watch-v101-release-build.sh
LOG=/root/v101-release-build.log
SCREEN=v101-release-build
TOOLBIN=/root/pepew-v101-toolchain/bin

mkdir -p "$TOOLBIN"

REAL_CMAKE=/usr/local/bin/cmake
REAL_CTEST=/usr/local/bin/ctest
[[ -x "$REAL_CMAKE" ]] || {
  echo "ERROR: modern CMake not found at $REAL_CMAKE" >&2
  exit 1
}
[[ -x "$REAL_CTEST" ]] || {
  echo "ERROR: modern CTest not found at $REAL_CTEST" >&2
  exit 1
}

ln -sfn "$REAL_CMAKE" "$TOOLBIN/cmake"
ln -sfn "$REAL_CTEST" "$TOOLBIN/ctest"
export PATH="$TOOLBIN:/usr/local/bin:/usr/local/cuda/bin:/usr/bin:/bin"
hash -r

CMAKE_BIN="$(command -v cmake)"
CTEST_BIN="$(command -v ctest)"
CMAKE_VERSION="$($CMAKE_BIN --version | awk 'NR==1 {print $3}')"
python3 - "$CMAKE_VERSION" <<'PY'
import sys
parts=[]
for item in sys.argv[1].split('.'):
    digits=''.join(ch for ch in item if ch.isdigit())
    parts.append(int(digits or 0))
while len(parts) < 3:
    parts.append(0)
if tuple(parts[:3]) < (3, 24, 0):
    raise SystemExit(f"ERROR: CMake >= 3.24 required, found {sys.argv[1]}")
PY

screen -S "$SCREEN" -X quit 2>/dev/null || true
rm -rf /root/pepew-v101-release
rm -f "$LOG"

{
  echo "TOOLCHAIN_PREFLIGHT=PASS"
  echo "CMAKE_BIN=$CMAKE_BIN"
  echo "CMAKE_VERSION=$CMAKE_VERSION"
  echo "CTEST_BIN=$CTEST_BIN"
  echo "PATH=$PATH"
} | tee "$LOG"

curl -fsSL "$BASE/build-v101-release.sh?rev=toolchain-v3" -o "$RUNNER"
curl -fsSL "$BASE/watch-v101-release-build.sh?rev=toolchain-v3" -o "$WATCHER"
chmod +x "$RUNNER" "$WATCHER"

# Run without login/profile initialization so HiveOS cannot restore the old
# /usr/bin/cmake. Append to the log so the watcher keeps the preflight lines.
screen -dmS "$SCREEN" env \
  PATH="$PATH" \
  CMAKE_COMMAND="$CMAKE_BIN" \
  CTEST_COMMAND="$CTEST_BIN" \
  bash --noprofile --norc -c "exec '$RUNNER' 2>&1 | tee -a '$LOG'"

sleep 3
REFRESH=5 "$WATCHER" "$LOG"
