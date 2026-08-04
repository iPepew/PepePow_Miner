#!/usr/bin/env bash
set -Eeuo pipefail

# HiveOS login shells may place /usr/bin before /usr/local/bin. The v1.0.1
# release build requires CMake >= 3.24, so pin the pip-installed CMake first.
export PATH="/usr/local/bin:/usr/local/cuda/bin:/usr/bin:/bin:${PATH:-}"
hash -r

BASE="https://raw.githubusercontent.com/iPepew/PepePow_Miner/release/v1.0.1/tools"
RUNNER=/root/build-v101-release.sh
WATCHER=/root/watch-v101-release-build.sh
LOG=/root/v101-release-build.log
SCREEN=v101-release-build

CMAKE_BIN="$(command -v cmake || true)"
[[ -n "$CMAKE_BIN" ]] || {
  echo "ERROR: cmake not found" >&2
  exit 1
}
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

echo "CMAKE_BIN=$CMAKE_BIN"
echo "CMAKE_VERSION=$CMAKE_VERSION"

screen -S "$SCREEN" -X quit 2>/dev/null || true
curl -fsSL "$BASE/build-v101-release.sh" -o "$RUNNER"
curl -fsSL "$BASE/watch-v101-release-build.sh" -o "$WATCHER"
chmod +x "$RUNNER" "$WATCHER"
rm -f "$LOG"

# Do not use a login shell here: /etc/profile on HiveOS can restore the old
# /usr/bin/cmake. Pass the validated PATH explicitly into the detached screen.
screen -dmS "$SCREEN" env PATH="$PATH" bash -c "$RUNNER 2>&1 | tee $LOG"
sleep 3
REFRESH=5 "$WATCHER" "$LOG"
