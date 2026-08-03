#!/usr/bin/env bash
set -euo pipefail
BASE="https://raw.githubusercontent.com/iPepew/PepePow_Miner/experiment/v2.0.0-warp-service/tools"
P080=/root/prepare-v080-grand-source.py
P081=/root/prepare-v081-coldpath-source.py
PZERO=/root/prepare-v200-zero-safe-source.py
PSERVICE=/root/prepare-v200-warp-service-source.py
RUNNER=/root/run-v200-warp-service-matrix.sh
WATCHER=/root/watch-v200-warp-service-progress.sh
LOG=/root/v200-warp-service.log
SCREEN=v200-warp-service

screen -S "$SCREEN" -X quit 2>/dev/null || true
curl -fsSL "$BASE/prepare-v080-grand-source.py" -o "$P080"
curl -fsSL "$BASE/prepare-v081-coldpath-source.py" -o "$P081"
curl -fsSL "$BASE/prepare-v200-zero-safe-source.py" -o "$PZERO"
curl -fsSL "$BASE/prepare-v200-warp-service-source.py" -o "$PSERVICE"
curl -fsSL "$BASE/run-v200-warp-service-matrix.sh" -o "$RUNNER"
curl -fsSL "$BASE/watch-v200-warp-service-progress.sh" -o "$WATCHER"
# Correct the harmless spelling error in the first published runner revision.
sed -i 's/sanitzer_gate/sanitizer_gate/g' "$RUNNER"
chmod +x "$RUNNER" "$WATCHER"
rm -f "$LOG"

screen -dmS "$SCREEN" bash -lc \
  "P080=$P080 P081=$P081 PZERO=$PZERO PSERVICE=$PSERVICE $RUNNER 2>&1 | tee $LOG"
sleep 3
REFRESH=10 "$WATCHER" "$LOG"
