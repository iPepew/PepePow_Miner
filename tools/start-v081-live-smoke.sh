#!/usr/bin/env bash
set -euo pipefail
BASE="https://raw.githubusercontent.com/iPepew/PepePow_Miner/experiment/v0.8.1-coldpath/tools"
RUNNER=/root/run-v081-live-smoke.sh; WATCHER=/root/watch-v081-live-smoke.sh; LOG=/root/v081-live-smoke.log; SCREEN=v081-live-smoke
screen -S "$SCREEN" -X quit 2>/dev/null || true
curl -fsSL "$BASE/run-v081-live-smoke.sh" -o "$RUNNER"
curl -fsSL "$BASE/watch-v081-live-smoke.sh" -o "$WATCHER"
chmod +x "$RUNNER" "$WATCHER"; rm -f "$LOG"
screen -dmS "$SCREEN" bash -lc "$RUNNER 2>&1 | tee $LOG"
sleep 3; REFRESH=5 "$WATCHER" "$LOG"
