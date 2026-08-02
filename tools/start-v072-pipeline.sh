#!/usr/bin/env bash
set -euo pipefail

BASE_URL="https://raw.githubusercontent.com/iPepew/PepePow_Miner/experiment/v0.7.0-8h-autotune/tools"
RUNNER="/root/run-v072-pipeline-matrix.sh"
WATCHER="/root/watch-v072-pipeline-progress.sh"
LOG="/root/v072-pipeline.log"
SCREEN_NAME="v072-pipeline"

screen -S "${SCREEN_NAME}" -X quit 2>/dev/null || true
curl -fsSL "${BASE_URL}/run-v072-pipeline-matrix.sh" -o "${RUNNER}"
curl -fsSL "${BASE_URL}/watch-v072-pipeline-progress.sh" -o "${WATCHER}"
chmod +x "${RUNNER}" "${WATCHER}"
rm -f "${LOG}"
screen -dmS "${SCREEN_NAME}" bash -lc "${RUNNER} 2>&1 | tee ${LOG}"
sleep 3
REFRESH=10 "${WATCHER}" "${LOG}"
