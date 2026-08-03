#!/usr/bin/env bash
set -euo pipefail
BASE="https://raw.githubusercontent.com/iPepew/PepePow_Miner/experiment/v0.8.1-coldpath/tools"
BASE_PATCHER="/root/prepare-v080-grand-source.py"
COLD_PATCHER="/root/prepare-v081-coldpath-source.py"
RUNNER="/root/run-v081-coldpath-matrix.sh"
WATCHER="/root/watch-v081-coldpath-progress.sh"
LOG="/root/v081-coldpath.log"
SCREEN_NAME="v081-coldpath"
screen -S "$SCREEN_NAME" -X quit 2>/dev/null || true
curl -fsSL "$BASE/prepare-v080-grand-source.py" -o "$BASE_PATCHER"
curl -fsSL "$BASE/prepare-v081-coldpath-source.py" -o "$COLD_PATCHER"
curl -fsSL "$BASE/run-v081-coldpath-matrix.sh" -o "$RUNNER"
curl -fsSL "$BASE/watch-v081-coldpath-progress.sh" -o "$WATCHER"
chmod +x "$RUNNER" "$WATCHER"
rm -f "$LOG"
screen -dmS "$SCREEN_NAME" bash -lc "BASE_PATCHER=$BASE_PATCHER COLD_PATCHER=$COLD_PATCHER $RUNNER 2>&1 | tee $LOG"
sleep 3
REFRESH=10 "$WATCHER" "$LOG"
