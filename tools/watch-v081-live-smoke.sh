#!/usr/bin/env bash
set -o pipefail
LOG="${1:-/root/v081-live-smoke.log}"; REFRESH="${REFRESH:-5}"; SCREEN_NAME="${SCREEN_NAME:-v081-live-smoke}"
bar(){ local d="${1:-0}" t="${2:-300}" w=42 f e; [[ "$d" =~ ^[0-9]+$ ]]||d=0; [[ "$t" =~ ^[1-9][0-9]*$ ]]||t=300; ((d>t))&&d=$t; f=$((d*w/t)); e=$((w-f)); printf '['; printf '%*s' "$f" ''|tr ' ' '#'; printf '%*s' "$e" ''|tr ' ' '-'; printf ']'; }
while :; do
 printf '\033[H\033[2J'; echo '================================================================================'; echo ' PEPEPOW v0.8.1 — SELECTOR-COMBINED LIVE SMOKE'; echo ' 5 минут, мгновенная остановка при CUDA-ошибке или новом Xid'; echo '================================================================================'; echo
 stage="$(find /root/pepepow-tests -maxdepth 1 -type d -name 'v081-live-smoke-*' 2>/dev/null|sort|tail -n1)"; status="${stage}/status.env"
 state=ПОДГОТОВКА; reason=''; elapsed=0; duration=300
 if [[ -f "$status" ]]; then source "$status"; state="${STATE:-ПОДГОТОВКА}"; reason="${REASON:-}"; elapsed="${ELAPSED:-0}"; duration="${DURATION:-300}"; fi
 if screen -ls 2>/dev/null|grep -q "\.${SCREEN_NAME}[[:space:]]"; then process=РАБОТАЕТ; elif grep -aq 'V0.8.1 LIVE SMOKE COMPLETE' "$LOG" 2>/dev/null; then process=ЗАВЕРШЁН; else process='ОСТАНОВЛЕН / ПРОВЕРЬТЕ ЖУРНАЛ'; fi
 echo 'ОБЩИЙ СТАТУС'; echo '--------------------------------------------------------------------------------'; echo "Процесс:            $process"; echo "Этап:               $state"; [[ -n "$reason" ]]&&echo "Причина:            $reason"; printf 'Прогресс:           '; bar "$elapsed" "$duration"; printf ' %s/%s сек\n' "$elapsed" "$duration"; echo
 line="$(grep -a '\[MINING\]' "$LOG" 2>/dev/null|tail -n1||true)"; echo 'МАЙНИНГ'; echo '--------------------------------------------------------------------------------'; if [[ -n "$line" ]]; then echo "$line"; else echo 'Хешрейт ещё не получен.'; fi; echo
 echo 'GPU RTX 3080'; echo '--------------------------------------------------------------------------------'; nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,clocks.current.sm,clocks.current.memory,power.draw,power.limit,fan.speed --format=csv,noheader,nounits 2>/dev/null|head -n1||echo 'nvidia-smi недоступен'; echo
 if [[ "$process" == ЗАВЕРШЁН ]]; then echo 'ИТОГ И ССЫЛКИ'; echo '--------------------------------------------------------------------------------'; grep -aE '^(candidate=|gate=|reason=|samples=|mean_mhs=|median_mhs=|min_mhs=|max_mhs=|stdev_mhs=|accepted=|rejected=|jobs=|clock_mean_mhz=|power_mean_w=|temp_mean_c=|new_xid_count=|LIVE_GATE=|TARGET_2MH=|ARCHIVE=|SHA256_FILE=|PUBLIC_|DOWNLOAD_)' "$LOG" 2>/dev/null|tail -n60; break; fi
 if [[ "$process" == 'ОСТАНОВЛЕН / ПРОВЕРЬТЕ ЖУРНАЛ' ]]; then echo 'ПОСЛЕДНИЕ СТРОКИ ЖУРНАЛА'; echo '--------------------------------------------------------------------------------'; tail -n40 "$LOG" 2>/dev/null||true; break; fi
 echo "Журнал: $LOG"; echo 'Ctrl+C закрывает только панель; тест продолжится в screen.'; sleep "$REFRESH"
done
