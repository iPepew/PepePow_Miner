#!/usr/bin/env bash
set -euo pipefail
BASE="https://raw.githubusercontent.com/iPepew/PepePow_Miner/experiment/v0.9.0-fullstack/tools"
P080=/root/prepare-v080-grand-source.py
P081=/root/prepare-v081-coldpath-source.py
P090=/root/prepare-v090-fullstack-source.py
RUNNER=/root/run-v090-fullstack-matrix.sh
WATCHER=/root/watch-v090-fullstack-progress.sh
LOG=/root/v090-fullstack.log
SCREEN=v090-fullstack
screen -S "$SCREEN" -X quit 2>/dev/null || true
curl -fsSL "$BASE/prepare-v080-grand-source.py" -o "$P080"
curl -fsSL "$BASE/prepare-v081-coldpath-source.py" -o "$P081"
curl -fsSL "$BASE/prepare-v090-fullstack-source.py" -o "$P090"
curl -fsSL "$BASE/run-v090-fullstack-matrix.sh" -o "$RUNNER"
curl -fsSL "$BASE/watch-v090-fullstack-progress.sh" -o "$WATCHER"
chmod +x "$RUNNER" "$WATCHER"
rm -f "$LOG"
screen -dmS "$SCREEN" bash -lc "BASE_PATCHER=$P080 COMBINED_PATCHER=$P081 FULL_PATCHER=$P090 $RUNNER 2>&1 | tee $LOG"
sleep 3
REFRESH=10 "$WATCHER" "$LOG"
