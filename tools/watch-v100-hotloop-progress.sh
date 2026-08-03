#!/usr/bin/env bash
set -o pipefail
LOG="${1:-/root/v100-hotloop.log}"
REFRESH="${REFRESH:-10}"
SCREEN_NAME="${SCREEN_NAME:-v100-hotloop}"
TARGET=2000000
IDS=(selector-combined-base parity sw32 parity-sw32 pointer parity-pointer sw32-pointer parity-sw32-pointer parity-sw32-pointer-unlikely parity-sw32-unlikely parity-sw32-coldcall parity-sw32-coldcall-t64-b1 parity-sw32-coldcall-t128-b1)
TOTAL="${#IDS[@]}"

bar(){ local d="${1:-0}" t="${2:-1}" w="${3:-42}" f e; [[ "$d" =~ ^[0-9]+$ ]] || d=0; [[ "$t" =~ ^[1-9][0-9]*$ ]] || t=1; ((d>t))&&d=$t; f=$((d*w/t)); e=$((w-f)); printf '['; printf '%*s' "$f" ''|tr ' ' '#'; printf '%*s' "$e" ''|tr ' ' '-'; printf ']'; }
field(){ local l="${1:-}" k="${2:-}" x; for x in $l; do [[ "${x%%=*}" == "$k" ]] && { echo "${x#*=}"; return; }; done; }
result(){ grep -a '^PROFILE_RESULT ' "$LOG" 2>/dev/null|grep " profile=$1 "|tail -n1||true; }
indexof(){ local i; for ((i=0;i<TOTAL;i++)); do [[ "${IDS[$i]}" == "$1" ]]&&{ echo $((i+1));return;};done;echo 0; }

while true; do
 printf '\033[H\033[2J'
 echo '================================================================================'
 echo ' PEPEPOW v1.0.0 HOT LOOP — EXACT PARITY + 32-BIT SW + POINTER WALK'
 echo ' ЦЕЛЬ: 2.000 MH/s live, Accepted > 0, Rejected 0, CUDA/Xid 0'
 echo '================================================================================'; echo
 if [[ ! -f "$LOG" ]]; then echo "Журнал ещё не создан: $LOG"; sleep "$REFRESH"; continue; fi
 completed="$(grep -ac '^PROFILE_RESULT ' "$LOG" 2>/dev/null||true)"; valid="$(grep -a '^PROFILE_RESULT ' "$LOG" 2>/dev/null|grep -c ' valid=1 '||true)"; failed="$(grep -a '^PROFILE_RESULT ' "$LOG" 2>/dev/null|grep -c ' valid=0 '||true)"
 current="$(grep -a '^PROFILE=' "$LOG" 2>/dev/null|tail -n1|cut -d= -f2-)"; status="$(grep -a '^STATUS=' "$LOG" 2>/dev/null|tail -n1|cut -d= -f2-)"; config="$(grep -a '^PROFILE_CONFIG ' "$LOG" 2>/dev/null|tail -n1)"
 [[ -n "$current" ]]||current=инициализация; [[ -n "$status" ]]||status=ПОДГОТОВКА
 if screen -ls 2>/dev/null|grep -q "\.$SCREEN_NAME[[:space:]]"; then state=РАБОТАЕТ; elif grep -aq 'V1.0.0 HOTLOOP MATRIX COMPLETE' "$LOG"; then state=ЗАВЕРШЁН; completed=$TOTAL; else state='ОСТАНОВЛЕН / ПРОВЕРЬТЕ ЖУРНАЛ'; fi
 echo 'ОБЩИЙ СТАТУС'; echo '--------------------------------------------------------------------------------'; echo "Состояние:          $state"; echo "Профилей:           $completed из $TOTAL (валидных $valid, ошибок $failed)"; printf 'Общий прогресс:     '; bar "$completed" "$TOTAL"; printf ' %d%%\n' "$((completed*100/TOTAL))"; echo
 idx="$(indexof "$current")"; echo 'ТЕКУЩЕЕ ЗАДАНИЕ'; echo '--------------------------------------------------------------------------------'; echo "Профиль:            $idx из $TOTAL — $current"; echo "Этап:               $status"; [[ -n "$config" ]]&&echo "Конфигурация:       ${config#PROFILE_CONFIG }"
 bline="$(grep -a '^BENCH_RUN ' "$LOG" 2>/dev/null|grep " profile=$current "|tail -n1||true)"; if [[ -n "$bline" ]]; then rt="$(field "$bline" run)"; h="$(field "$bline" hps)"; rn="${rt%%/*}"; rr="${rt##*/}"; rn=$((10#$rn)); rr=$((10#$rr)); echo "Benchmark:          $rn из $rr"; printf 'Прогресс benchmark: '; bar "$rn" "$rr"; echo; [[ "$h" =~ ^[0-9]+$ ]]&&echo "Последний хеш:      $(awk -v h="$h" 'BEGIN{printf "%.6f MH/s",h/1e6}')"; else echo 'Benchmark:          ещё не начался'; fi; echo
 echo 'GPU RTX 3080'; echo '--------------------------------------------------------------------------------'; gpu="$(nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,clocks.current.sm,clocks.current.memory,power.draw,power.limit,fan.speed --format=csv,noheader,nounits 2>/dev/null|head -n1)"; echo "${gpu:-данные недоступны}"; echo
 echo 'ТАБЛИЦА ПРОФИЛЕЙ'; echo '--------------------------------------------------------------------------------'; printf '%-3s %-31s %-10s %-10s %-6s %-7s\n' '#' 'Профиль' 'Статус' 'MH/s' 'Regs' 'Stack'
 for ((i=0;i<TOTAL;i++)); do p="${IDS[$i]}"; l="$(result "$p")"; if [[ -n "$l" ]]; then ok="$(field "$l" valid)"; if [[ "$ok" == 1 ]]; then st=ГОТОВ; mh="$(field "$l" median_mhs)"; rg="$(field "$l" registers)"; sk="$(field "$l" stack)"; else st=ОШИБКА; mh=-; rg=-; sk=-; fi; elif [[ "$p" == "$current" && "$state" == РАБОТАЕТ ]]; then st='В РАБОТЕ';mh=-;rg=-;sk=-;else st=ОЖИДАЕТ;mh=-;rg=-;sk=-;fi; printf '%-3d %-31s %-10s %-10s %-6s %-7s\n' "$((i+1))" "$p" "$st" "$mh" "$rg" "$sk"; done; echo
 best="$(grep -a '^PROFILE_RESULT ' "$LOG" 2>/dev/null|grep ' valid=1 '|awk '{p="";h=0;m="";rg="";st="";for(i=1;i<=NF;i++){split($i,a,"=");if(a[1]=="profile")p=a[2];else if(a[1]=="median_hps")h=a[2]+0;else if(a[1]=="median_mhs")m=a[2];else if(a[1]=="registers")rg=a[2];else if(a[1]=="stack")st=a[2]}if(h>b){b=h;bp=p;bm=m;br=rg;bs=st}}END{if(b>0)printf "%s|%s|%d|%s|%s",bp,bm,b,br,bs}')"; base="$(field "$(result selector-combined-base)" median_hps)"
 echo 'ЛУЧШИЙ РЕЗУЛЬТАТ'; echo '--------------------------------------------------------------------------------'; if [[ -n "$best" ]]; then IFS='|' read -r bp bm bh br bs <<<"$best"; echo "Профиль:            $bp"; echo "Результат:          $bm MH/s ($bh H/s)"; echo "Ресурсы:            $br регистров, stack $bs B"; [[ "$base" =~ ^[1-9][0-9]*$ ]]&&echo "К baseline:         $(awk -v b="$bh" -v a="$base" 'BEGIN{printf "%+.4f%%",(b/a-1)*100}')"; echo "До 2 MH/s:          $(awk -v h="$bh" 'BEGIN{printf "%.4f%%",(2000000-h)/2000000*100}')"; else echo 'Пока нет валидных результатов.'; fi; echo
 if [[ "$state" == ЗАВЕРШЁН ]]; then echo 'ИТОГ И ССЫЛКИ'; echo '--------------------------------------------------------------------------------'; grep -aE '^(profiles_|baseline_|best_|uplift_|target_|projected_|stress_gate|sanitizer_gate|candidate_gate|TARGET_|ARCHIVE=|SHA256_FILE=|PUBLIC_|DOWNLOAD_)' "$LOG"|tail -n100||true; break; fi
 if [[ "$state" == 'ОСТАНОВЛЕН / ПРОВЕРЬТЕ ЖУРНАЛ' ]]; then echo 'ПОСЛЕДНИЕ СТРОКИ ЖУРНАЛА'; echo '--------------------------------------------------------------------------------'; tail -n50 "$LOG"; break; fi
 echo "Журнал: $LOG | Screen: $SCREEN_NAME | Ctrl+C закрывает только панель"; sleep "$REFRESH"
done
