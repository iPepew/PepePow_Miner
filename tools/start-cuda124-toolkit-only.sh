#!/usr/bin/env bash
set -Eeuo pipefail

BASE=https://raw.githubusercontent.com/iPepew/PepePow_Miner/release/v1.0.1/tools
RUNNER=/root/install-cuda124-toolkit-only.sh
LOG=/root/cuda124-toolkit-install.log
SCREEN=cuda124-toolkit

screen -S "$SCREEN" -X quit 2>/dev/null || true
curl -fsSL "$BASE/install-cuda124-toolkit-only.sh?rev=cuda124-v1" -o "$RUNNER"
chmod +x "$RUNNER"
rm -f "$LOG"

screen -dmS "$SCREEN" bash --noprofile --norc -c "exec '$RUNNER'"
sleep 2

while screen -ls 2>/dev/null | grep -q "[.]$SCREEN"; do
  clear
  echo "============================================================"
  echo " CUDA 12.4 TOOLKIT-ONLY INSTALLATION — DRIVER IS NOT TOUCHED"
  echo "============================================================"
  echo
  tail -n 25 "$LOG" 2>/dev/null || true
  echo
  echo "Ctrl+C closes only this panel. Installation continues in screen."
  sleep 5
done

clear
echo "============================================================"
echo " CUDA 12.4 INSTALLATION FINISHED"
echo "============================================================"
tail -n 80 "$LOG" 2>/dev/null || true
