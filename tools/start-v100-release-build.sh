#!/usr/bin/env bash
set -euo pipefail
BASE="https://raw.githubusercontent.com/iPepew/PepePow_Miner/release/v1.0.0/tools"
RUNNER=/root/build-v100-release.sh
WATCHER=/root/watch-v100-release-build.sh
LOG=/root/v100-release-build.log
SCREEN=v100-release-build

screen -S "$SCREEN" -X quit 2>/dev/null || true
curl -fsSL "$BASE/build-v100-release.sh" -o "$RUNNER"
curl -fsSL "$BASE/watch-v100-release-build.sh" -o "$WATCHER"
chmod +x "$RUNNER" "$WATCHER"
rm -f "$LOG"
screen -dmS "$SCREEN" bash -lc "$RUNNER 2>&1 | tee $LOG"
sleep 3
REFRESH=5 "$WATCHER" "$LOG"
