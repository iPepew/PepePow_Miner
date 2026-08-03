#!/usr/bin/env bash
set -euo pipefail

BASE_URL="https://raw.githubusercontent.com/iPepew/PepePow_Miner/experiment/v0.8.0-grand/tools"
PATCHER="/root/prepare-v080-grand-source.py"
RUNNER="/root/run-v080-grand-campaign.sh"
WATCHER="/root/watch-v080-grand-progress.sh"
LOG="/root/v080-grand.log"
SCREEN_NAME="v080-grand"

screen -S "${SCREEN_NAME}" -X quit 2>/dev/null || true
curl -fsSL "${BASE_URL}/prepare-v080-grand-source.py" -o "${PATCHER}"
curl -fsSL "${BASE_URL}/run-v080-grand-campaign.sh" -o "${RUNNER}"
curl -fsSL "${BASE_URL}/watch-v080-grand-progress.sh" -o "${WATCHER}"
chmod +x "${RUNNER}" "${WATCHER}"
rm -f "${LOG}"
screen -dmS "${SCREEN_NAME}" bash -lc \
  "PATCHER=${PATCHER} ${RUNNER} 2>&1 | tee ${LOG}"
sleep 3
REFRESH=10 "${WATCHER}" "${LOG}"
