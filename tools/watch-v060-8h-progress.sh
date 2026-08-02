#!/usr/bin/env bash
set -euo pipefail

LOG="${1:-/root/v060-8h-matrix.log}"
REFRESH="${REFRESH:-2}"
SESSION="${SESSION:-v060-8h-matrix}"
TMP="/tmp/watch-v060-8h-progress.$$"
trap 'rm -f "$TMP"; printf "\033[?25h"' EXIT INT TERM
printf '\033[?25l'

bar() {
  local current="$1" total="$2" width=30 filled=0 empty=30
  if [[ "$total" =~ ^[1-9][0-9]*$ && "$current" =~ ^[0-9]+$ ]]; then
    filled=$(( current * width / total ))
    (( filled > width )) && filled=$width
    empty=$(( width - filled ))
  fi
  printf '%*s' "$filled" '' | tr ' ' '#'
  printf '%*s' "$empty" '' | tr ' ' '-'
}

while true; do
  if [[ ! -s "$LOG" ]]; then
    clear
    echo "PEPEW MINER v0.6.0-PR — 8H MATRIX AUTOTUNE"
    echo
    echo "Ожидание журнала: $LOG"
    sleep "$REFRESH"
    continue
  fi

  sed -r 's/\x1B\[[0-9;?]*[ -\/]*[@-~]//g' "$LOG" > "$TMP"

  profile_line="$(grep -aE '\[PROFILE[[:space:]]+[0-9]+/[0-9]+\]|PROFILE[[:space:]]+[0-9]+/[0-9]+' "$TMP" | tail -n1 || true)"
  current="$(sed -nE 's/.*\[?PROFILE[[:space:]]+0*([0-9]+)\/0*([0-9]+)\]?.*/\1/p' <<<"$profile_line")"
  total="$(sed -nE 's/.*\[?PROFILE[[:space:]]+0*([0-9]+)\/0*([0-9]+)\]?.*/\2/p' <<<"$profile_line")"
  current="${current:-0}"
  total="${total:-40}"

  name="$(sed -nE 's/.*\[?PROFILE[[:space:]]+[0-9]+\/[0-9]+\]?[[:space:]:-]+([^[:space:]].*)/\1/p' <<<"$profile_line")"
  [[ -n "$name" ]] || name="ожидание маркера профиля"

  status_line="$(grep -aE 'Status[[:space:]]*:|Status:|BUILDING|VALIDATING|BENCHMARKING|PASSED|FAILED|LIVE TEST|COMPLETE' "$TMP" | tail -n1 || true)"
  status="$(sed -nE 's/.*Status[[:space:]]*:[[:space:]]*//p' <<<"$status_line")"
  [[ -n "$status" ]] || status="$status_line"
  [[ -n "$status" ]] || status="STARTING"

  completed="$(grep -acE '^PROFILE_RESULT|PROFILE_RESULT' "$TMP" || true)"
  failed="$(grep -acE '^PROFILE_INVALID|FAILED:' "$TMP" || true)"

  best_line="$(awk '
    /PROFILE_RESULT/ {
      h=0; n="unknown";
      for(i=1;i<=NF;i++) {
        if($i ~ /^median_hps=/) {split($i,a,"="); h=a[2]+0}
        if($i ~ /^name=/) {split($i,a,"="); n=a[2]}
      }
      if(h>best){best=h; name=n; line=$0}
    }
    END {if(best>0) printf "%s|%d", name, best}
  ' "$TMP")"
  best_name="${best_line%%|*}"
  best_hps="${best_line##*|}"
  if [[ -n "$best_line" && "$best_hps" =~ ^[0-9]+$ ]]; then
    best_mhs="$(awk -v h="$best_hps" 'BEGIN{printf "%.3f",h/1000000}')"
  else
    best_name="нет завершённых профилей"
    best_mhs="—"
  fi

  elapsed="$(ps -eo etime,args | awk '/[s]tart-v060-8h-matrix.sh|[v]060-8h-matrix/ {print $1; exit}')"
  elapsed="${elapsed:-завершён или ожидает}"
  gpu="$(nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,clocks.current.sm,power.draw --format=csv,noheader 2>/dev/null | head -n1 || true)"
  gpu="${gpu:-нет данных}"

  percent=0
  if [[ "$total" =~ ^[1-9][0-9]*$ && "$current" =~ ^[0-9]+$ ]]; then
    percent=$(( current * 100 / total ))
    (( percent > 100 )) && percent=100
  fi

  clear
  cat <<EOF
╔════════════════════════════════════════════════════════════════════╗
║       PEPEW MINER v0.6.0-PR — 8-HOUR RTX 3080 AUTOTUNE           ║
╚════════════════════════════════════════════════════════════════════╝

┌────────────────────────────────────────────────────────────────────┐
│ CURRENT PROFILE: $(printf '%02d' "$current") OF $(printf '%02d' "$total")
│ NAME:     $name
│ STATUS:   $status
│ PROGRESS: [$(bar "$current" "$total")] ${percent}%
└────────────────────────────────────────────────────────────────────┘

Completed: $completed    Failed: $failed    Elapsed: $elapsed
GPU: $gpu

BEST VALID PROFILE
--------------------------------------------------------------------
$best_name    $best_mhs MH/s

LAST PROFILE RESULTS
--------------------------------------------------------------------
EOF
  grep -aE 'PROFILE_RESULT|PROFILE_INVALID|TARGET_2MH|BEST_PROFILE|BEST_HPS|LIVE_STATUS|ACCEPTED_EVENTS|REJECTED_EVENTS|COMPLETE' "$TMP" | tail -n12 || true

  echo
  echo "Log: $LOG"
  echo "Screen: $SESSION"
  echo "Ctrl+C закроет только панель; тест продолжится в screen."

  if ! screen -ls 2>/dev/null | grep -qE "[.]${SESSION}[[:space:]]"; then
    if grep -aqE 'COMPLETE|TARGET_2MH|LIVE_STATUS' "$TMP"; then
      echo
      echo "Фоновая сессия завершена. Показаны финальные результаты."
    fi
  fi

  sleep "$REFRESH"
done
