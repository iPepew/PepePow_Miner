#!/usr/bin/env bash
set -euo pipefail

LOG="${1:-/root/v060-build.log}"
REFRESH="${REFRESH:-2}"

while true; do
  clear 2>/dev/null || printf '\033[2J\033[H'

  printf '╔══════════════════════════════════════════════════════════════╗\n'
  printf '║          PEPEW MINER v0.6.0-PR — RTX 3080 AUTOTUNE          ║\n'
  printf '╚══════════════════════════════════════════════════════════════╝\n\n'

  if [[ ! -s "${LOG}" ]]; then
    printf 'LOG: %s\nSTATUS: waiting for log data...\n' "${LOG}"
    sleep "${REFRESH}"
    continue
  fi

  current_line="$(grep -E '^\[PROFILE [0-9]{2}/[0-9]{2}\] [A-Za-z0-9_.-]+$' "${LOG}" | tail -n1 || true)"
  if [[ -n "${current_line}" ]]; then
    index="$(sed -E 's/^\[PROFILE ([0-9]{2})\/([0-9]{2})\].*/\1/' <<<"${current_line}")"
    total="$(sed -E 's/^\[PROFILE ([0-9]{2})\/([0-9]{2})\].*/\2/' <<<"${current_line}")"
    name="$(sed -E 's/^\[PROFILE [0-9]{2}\/[0-9]{2}\] //' <<<"${current_line}")"
    index_num=$((10#${index}))
    total_num=$((10#${total}))
    percent=$((index_num * 100 / total_num))
    filled=$((percent / 5))
    empty=$((20 - filled))
    bar="$(printf '%*s' "${filled}" '' | tr ' ' '#')$(printf '%*s' "${empty}" '' | tr ' ' '-')"

    status="$(grep -E "^\[PROFILE ${index}/${total}\] (Status:|PASSED:|FAILED:)" "${LOG}" | tail -n1 || true)"
    status="${status#*] }"
    [[ -n "${status}" ]] || status='Status: BUILDING'

    start_line="$(grep -nF "${current_line}" "${LOG}" | tail -n1 | cut -d: -f1 || true)"
    description=''
    if [[ -n "${start_line}" ]]; then
      description="$(sed -n "$((start_line+1)),$((start_line+8))p" "${LOG}" | sed -n 's/^Description[[:space:]]*:[[:space:]]*//p' | head -n1)"
    fi

    printf '┌──────────────────────────────────────────────────────────────┐\n'
    printf '│ CURRENT PROFILE: %02d OF %02d                                \n' "${index_num}" "${total_num}"
    printf '│ NAME:    %-50s\n' "${name}"
    printf '│ STATUS:  %-50s\n' "${status}"
    printf '│ INFO:    %-50s\n' "${description:-n/a}"
    printf '│ PROGRESS [%s] %3d%%                              \n' "${bar}" "${percent}"
    printf '└──────────────────────────────────────────────────────────────┘\n\n'
  else
    printf 'STATUS: source preparation / startup\n\n'
  fi

  completed="$(grep -c '^PROFILE_RESULT ' "${LOG}" 2>/dev/null || true)"
  failed="$(grep -c '^PROFILE_INVALID ' "${LOG}" 2>/dev/null || true)"
  printf 'Completed: %s    Failed: %s\n\n' "${completed}" "${failed}"

  printf 'LAST PROFILE RESULTS\n'
  printf '%s\n' '--------------------------------------------------------------'
  grep '^PROFILE_RESULT ' "${LOG}" | tail -n5 | awk '
    {
      name=""; hps=""; regs=""; spills="";
      for (i=1; i<=NF; i++) {
        split($i,a,"=");
        if (a[1]=="name") name=a[2];
        if (a[1]=="median_hps") hps=a[2];
        if (a[1]=="registers") regs=a[2];
        if (a[1]=="spills") spills=a[2];
      }
      if (name!="") printf "%-28s %7.3f MH/s  regs=%s  spills=%s\n", name, hps/1000000, regs, spills;
    }'

  printf '\nIMPORTANT EVENTS\n'
  printf '%s\n' '--------------------------------------------------------------'
  grep -E '^STATE_MODE_SELECTED|^AUTOTUNE_SELECTED|^AUTOTUNE_|^TARGET_2MH|^ARCHIVE=|^SHA256=' "${LOG}" | tail -n10 || true

  printf '\nUpdated: %s | Ctrl+C closes only this dashboard\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  sleep "${REFRESH}"
done
