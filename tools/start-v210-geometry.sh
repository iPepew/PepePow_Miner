#!/usr/bin/env bash
set -euo pipefail
BASE210="https://raw.githubusercontent.com/iPepew/PepePow_Miner/experiment/v2.1.0-geometry/tools"
BASE200="https://raw.githubusercontent.com/iPepew/PepePow_Miner/experiment/v2.0.0-warp-service/tools"
P080=/root/prepare-v080-grand-source.py
P081=/root/prepare-v081-coldpath-source.py
PZERO=/root/prepare-v200-zero-safe-source.py
PSERVICE=/root/prepare-v200-warp-service-source.py
TRANSFORM=/root/prepare-v210-geometry-runner.py
BASE_RUNNER=/root/run-v200-warp-service-base.sh
RUNNER=/root/run-v210-geometry-matrix.sh
WATCHER=/root/watch-v210-geometry-progress.sh
LOG=/root/v210-geometry.log
SCREEN=v210-geometry

screen -S "$SCREEN" -X quit 2>/dev/null || true
curl -fsSL "$BASE200/prepare-v080-grand-source.py" -o "$P080"
curl -fsSL "$BASE200/prepare-v081-coldpath-source.py" -o "$P081"
curl -fsSL "$BASE200/prepare-v200-zero-safe-source.py" -o "$PZERO"
curl -fsSL "$BASE200/prepare-v200-warp-service-source.py" -o "$PSERVICE"
curl -fsSL "$BASE210/prepare-v210-geometry-runner.py" -o "$TRANSFORM"
curl -fsSL "$BASE200/run-v200-warp-service-matrix.sh" -o "$BASE_RUNNER"
curl -fsSL "$BASE200/watch-v200-warp-service-progress.sh" -o "$WATCHER"
python3 "$TRANSFORM" "$BASE_RUNNER" "$RUNNER"
sed -i 's/v200-warp-service/v210-geometry/g; s/v2\.0\.0/v2.1.0/g; s/BLOCK-COMPACTED COLD SERVICE/EXTENDED SERVICE GEOMETRY/g' "$WATCHER"
chmod +x "$RUNNER" "$WATCHER"
rm -f "$LOG"

screen -dmS "$SCREEN" bash -lc \
  "P080=$P080 P081=$P081 PZERO=$PZERO PSERVICE=$PSERVICE $RUNNER 2>&1 | tee $LOG"
sleep 3
REFRESH=10 "$WATCHER" "$LOG"
