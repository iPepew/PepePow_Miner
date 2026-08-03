#!/usr/bin/env bash
set -euo pipefail
BASE="https://raw.githubusercontent.com/iPepew/PepePow_Miner/experiment/v1.0.0-hotloop/tools"
P080=/root/prepare-v080-grand-source.py
P081=/root/prepare-v081-coldpath-source.py
PHOT=/root/prepare-v100-hotloop-source.py
PSW=/root/prepare-v100-sw32-source.py
RUNNER=/root/run-v100-hotloop-matrix.sh
WATCHER=/root/watch-v100-hotloop-progress.sh
LOG=/root/v100-hotloop.log
SCREEN=v100-hotloop
screen -S "$SCREEN" -X quit 2>/dev/null || true
curl -fsSL "$BASE/prepare-v080-grand-source.py" -o "$P080"
curl -fsSL "$BASE/prepare-v081-coldpath-source.py" -o "$P081"
curl -fsSL "$BASE/prepare-v100-hotloop-source.py" -o "$PHOT"
curl -fsSL "$BASE/prepare-v100-sw32-source.py" -o "$PSW"
curl -fsSL "$BASE/run-v100-hotloop-matrix.sh" -o "$RUNNER"
curl -fsSL "$BASE/watch-v100-hotloop-progress.sh" -o "$WATCHER"
chmod +x "$RUNNER" "$WATCHER"
rm -f "$LOG"
screen -dmS "$SCREEN" bash -lc "P080=$P080 P081=$P081 PHOT=$PHOT PSW=$PSW $RUNNER 2>&1 | tee $LOG"
sleep 3
REFRESH=10 "$WATCHER" "$LOG"
