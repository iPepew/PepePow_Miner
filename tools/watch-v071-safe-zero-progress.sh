#!/usr/bin/env bash
set -u
LOG="${1:-/root/v071-safe-zero.log}"
REFRESH="${REFRESH:-10}"
SCREEN_NAME="${SCREEN_NAME:-v071-safe-zero}"
PUBLISHER_URL="https://raw.githubusercontent.com/iPepew/PepePow_Miner/experiment/v0.7.0-8h-autotune/tools/publish-test-results.sh"
PUBLISHER="/root/publish-pepepow-test-results.sh"
IDS=(baseline warm-zero-guard lazy-zero-update)
TITLES=("Контрольный код v0.6.0" "Безопасный пропуск нулевого table-load" "Ленивая конвертация без раннего return")
TOTAL=3
bar(){ local d=$1 t=$2 w=${3:-42} f=$((d*w/t)); ((f>w))&&f=$w; printf '['; printf '%*s' "$f" ''|tr ' ' '#'; printf '%*s' "$((w-f))" ''|tr ' ' '-'; printf ']'; }
field(){ local l="$1" k="$2" x; for x in $l; do [[ ${x%%=*} == "$k" ]]&&{ echo "${x#*=}";return;}; done; }
idx(){ local p=$1 i; for ((i=0;i<TOTAL;i++));do [[ ${IDS[$i]} == "$p" ]]&&{ echo $((i+1));return;};done;echo 0; }
result(){ grep -a '^PROFILE_RESULT ' "$LOG" 2>/dev/null|grep " profile=$1 "|tail -1||true; }
while true; do
 printf '\033[H\033[2J'; echo '================================================================================'; echo ' PEPEPOW v0.7.1 — SAFE ZERO-NIBBLE MATRIX'; echo ' Pepew - твоя монета. Твои правила.'; echo '================================================================================'; echo
 [[ -f $LOG ]]||{ echo "Журнал ещё не создан: $LOG"; sleep "$REFRESH"; continue; }
 completed=$(grep -ac '^PROFILE_RESULT ' "$LOG" 2>/dev/null||true); valid=$(grep -a '^PROFILE_RESULT ' "$LOG"|grep -c ' valid=1 '||true); failed=$(grep -a '^PROFILE_RESULT ' "$LOG"|grep -c ' valid=0 '||true)
 current=$(grep -a '^PROFILE=' "$LOG"|tail -1|cut -d= -f2-); status=$(grep -a '^STATUS=' "$LOG"|tail -1|cut -d= -f2-); [[ -n $current ]]||current=инициализация; [[ -n $status ]]||status=ПОДГОТОВКА
 if screen -ls 2>/dev/null|grep -q "\.$SCREEN_NAME[[:space:]]";then state=РАБОТАЕТ; elif grep -aq 'V0.7.1 SAFE-ZERO MATRIX COMPLETE' "$LOG";then state=ЗАВЕРШЁН;completed=$TOTAL;else state='ОСТАНОВЛЕН / ПРОВЕРЬТЕ ЖУРНАЛ';fi
 echo 'ОБЩИЙ СТАТУС'; echo '--------------------------------------------------------------------------------'; echo "Состояние:          $state"; echo "Всего профилей:     $TOTAL"; echo "Завершено:          $completed из $TOTAL (успешно $valid, ошибок $failed)"; printf 'Общий прогресс:     ';bar "$completed" "$TOTAL";printf ' %d%%\n' "$((completed*100/TOTAL))"; echo "Обновление:         каждые $REFRESH секунд"; echo
 ci=$(idx "$current"); echo 'ТЕКУЩЕЕ ЗАДАНИЕ'; echo '--------------------------------------------------------------------------------'; if ((ci>0));then echo "Профиль:            $ci из $TOTAL — $current";echo "Назначение:         ${TITLES[$((ci-1))]}";else echo "Профиль:            $current";fi;echo "Этап:               $status"
 last=$(grep -a '^BENCH_RUN ' "$LOG"|grep " profile=$current "|tail -1||true); if [[ -n $last ]];then rt=$(field "$last" run);h=$(field "$last" hps);r=${rt%%/*};tt=${rt##*/};r=$((10#$r));tt=$((10#$tt));echo "Benchmark:          $r из $tt";printf 'Прогресс benchmark: ';bar "$r" "$tt";printf '\n';echo "Последний хеш:      $(awk -v h="$h" 'BEGIN{printf "%.6f",h/1e6}') MH/s ($h H/s)";else echo 'Benchmark:          ещё не начался';fi;echo
 gpu=$(nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,clocks.current.sm,clocks.current.memory,power.draw,power.limit,fan.speed --format=csv,noheader,nounits 2>/dev/null|head -1); echo 'GPU RTX 3080';echo '--------------------------------------------------------------------------------';echo "$gpu";echo
 echo 'ТАБЛИЦА ПРОФИЛЕЙ';echo '--------------------------------------------------------------------------------';printf '%-3s %-22s %-12s %-12s %-6s %-7s\n' '#' 'Профиль' 'Статус' 'MH/s' 'Regs' 'Stack';for ((i=0;i<TOTAL;i++));do p=${IDS[$i]};l=$(result "$p");if [[ -n $l ]];then ok=$(field "$l" valid);if [[ $ok == 1 ]];then st=ГОТОВ;mh=$(field "$l" median_mhs);rg=$(field "$l" pow_regs);sk=$(field "$l" stack);else st=ОШИБКА;mh=-;rg=-;sk=-;fi;elif [[ $p == "$current" && $state == РАБОТАЕТ ]];then st='В РАБОТЕ';mh=-;rg=-;sk=-;else st=ОЖИДАЕТ;mh=-;rg=-;sk=-;fi;printf '%-3d %-22s %-12s %-12s %-6s %-7s\n' "$((i+1))" "$p" "$st" "$mh" "$rg" "$sk";done;echo
 best=$(grep -a '^PROFILE_RESULT ' "$LOG"|grep ' valid=1 '|awk '{p="";h=0;m="";for(i=1;i<=NF;i++){split($i,a,"=");if(a[1]=="profile")p=a[2];else if(a[1]=="median_hps")h=a[2]+0;else if(a[1]=="median_mhs")m=a[2]}if(h>b){b=h;bp=p;bm=m}}END{if(b)print bp"|"bm"|"b}')
 echo 'ЛУЧШИЙ РЕЗУЛЬТАТ';echo '--------------------------------------------------------------------------------';if [[ -n $best ]];then IFS='|' read -r bp bm bh<<<"$best";echo "Профиль:            $bp";echo "Хешрейт:            $bm MH/s ($bh H/s)";else echo 'Пока нет завершённых валидных профилей.';fi;echo
 if [[ $state == ЗАВЕРШЁН ]];then archive=$(grep -a '^ARCHIVE=' "$LOG"|tail -1|cut -d= -f2-);if [[ -n $archive && -f $archive ]];then links="$archive.links.txt";if [[ ! -f $links ]];then curl -fsSL "$PUBLISHER_URL" -o "$PUBLISHER"&&chmod +x "$PUBLISHER"&&"$PUBLISHER" "$archive" >/tmp/v071-publish.out 2>&1||true;fi;echo 'ССЫЛКИ НА СКАЧИВАНИЕ';echo '--------------------------------------------------------------------------------';[[ -f $links ]]&&cat "$links"||echo "Архив: $archive";fi;echo;echo 'Панель остановлена: тест завершён.';break;fi
 echo "Журнал: $LOG";echo 'Ctrl+C закрывает только панель.';sleep "$REFRESH"
done
