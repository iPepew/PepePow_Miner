#!/usr/bin/env bash
set -Eeuo pipefail

BASE="https://raw.githubusercontent.com/iPepew/PepePow_Miner/release/v1.0.1/tools"
RUNNER=/root/build-v101-release.sh
WATCHER=/root/watch-v101-release-build.sh
LOG=/root/v101-release-build.log
SCREEN=v101-release-build

screen -S "$SCREEN" -X quit 2>/dev/null || true
curl -fsSL "$BASE/build-v101-release.sh" -o "$RUNNER"
curl -fsSL "$BASE/watch-v101-release-build.sh" -o "$WATCHER"
chmod +x "$RUNNER" "$WATCHER"
rm -f "$LOG"

screen -dmS "$SCREEN" bash -lc "$RUNNER 2>&1 | tee $LOG"
sleep 3
REFRESH=5 "$WATCHER" "$LOG"
