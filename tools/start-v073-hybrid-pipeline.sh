#!/usr/bin/env bash
set -euo pipefail
BASE_URL="https://raw.githubusercontent.com/iPepew/PepePow_Miner/experiment/v0.7.0-8h-autotune/tools"
RUNNER="/root/run-v073-hybrid-pipeline-matrix.sh"
WATCHER="/root/watch-v073-hybrid-pipeline-progress.sh"
LOG="/root/v073-hybrid-pipeline.log"
SCREEN_NAME="v073-hybrid-pipeline"
screen -S "${SCREEN_NAME}" -X quit 2>/dev/null || true
curl -fsSL "${BASE_URL}/run-v073-hybrid-pipeline-matrix.sh" -o "${RUNNER}"
curl -fsSL "${BASE_URL}/watch-v073-hybrid-pipeline-progress.sh" -o "${WATCHER}"
chmod +x "${RUNNER}" "${WATCHER}"
rm -f "${LOG}"
screen -dmS "${SCREEN_NAME}" bash -lc "${RUNNER} 2>&1 | tee ${LOG}"
sleep 3
REFRESH=10 "${WATCHER}" "${LOG}"
