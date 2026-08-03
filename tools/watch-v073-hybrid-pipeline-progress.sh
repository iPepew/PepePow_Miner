#!/usr/bin/env bash
set -u

LOG="${1:-/root/v073-hybrid-pipeline.log}"
REFRESH="${REFRESH:-10}"
SCREEN_NAME="${SCREEN_NAME:-v073-hybrid-pipeline}"
IDS=(mono-t64-b2 full-split-t64-b2 first-split-t64-b2 final-split-t64-b2)
TITLES=(
  "Монолитное ядро v0.6.0 — контроль"
  "Полное разделение: first + mix + final"
  "Разделён только первый BLAKE3: first | mix+final"
  "Разделён только финальный BLAKE3: first+mix | final"
)
TOTAL="${#IDS[@]}"

bar(){
  local d="${1:-0}" t="${2:-1}" w="${3:-42}" f e
  [[ "$d" =~ ^[0-9]+$ ]]||d=0; [[ "$t" =~ ^[1-9][0-9]*$ ]]||t=1
  ((d>t))&&d=$t; f=$((d*w/t)); e=$((w-f))
  printf '['; printf '%*s' "$f" ''|tr ' ' '#'; printf '%*s' "$e" ''|tr ' ' '-'; printf ']'
}
field(){ local l="${1:-}" k="${2:-}" x; for x in $l; do [[ ${x%%=*} == "$k" ]]&&{ echo "${x#*=}";return 0;};done;return 1; }
idx(){ local p="${1:-}" i; for ((i=0;i<TOTAL;i++));do [[ ${IDS[$i]} == "$p" ]]&&{ echo $((i+1));return;};done;echo 0; }
result(){ grep -a '^PROFILE_RESULT ' "$LOG" 2>/dev/null|grep " profile=$1 "|tail -1||true; }
stage_desc(){ case "${1:-}" in PATCHING*)echo 'Подготовка исходника';;BUILDING*)echo 'Сборка CUDA и тестов';;VALIDATING*)echo 'ctest и CPU/CUDA consensus';;BENCHMARKING*)echo 'Измерение производительности';;*)echo "${1:-Подготовка}";;esac; }

while true;do
 printf '\033[H\033[2J'
 echo '================================================================================'
 echo ' PEPEPOW v0.7.3 — HYBRID PIPELINE MATRIX'
 echo ' Pepew - твоя монета. Твои правила.'
 echo '================================================================================';echo
 [[ -f "$LOG" ]]||{ echo "Журнал ещё не создан: $LOG";sleep "$REFRESH";continue; }
 completed=$(grep -ac '^PROFILE_RESULT ' "$LOG" 2>/dev/null||true)
 valid=$(grep -a '^PROFILE_RESULT ' "$LOG" 2>/dev/null|grep -c ' valid=1 '||true)
 failed=$(grep -a '^PROFILE_RESULT ' "$LOG" 2>/dev/null|grep -c ' valid=0 '||true)
 current=$(grep -a '^PROFILE=' "$LOG" 2>/dev/null|tail -1|cut -d= -f2-)
 status=$(grep -a '^STATUS=' "$LOG" 2>/dev/null|tail -1|cut -d= -f2-)
 config=$(grep -a '^PROFILE_CONFIG ' "$LOG" 2>/dev/null|tail -1)
 [[ -n "$current" ]]||current=инициализация;[[ -n "$status" ]]||status=ПОДГОТОВКА
 if screen -ls 2>/dev/null|grep -q "\.${SCREEN_NAME}[[:space:]]";then state=РАБОТАЕТ
 elif grep -aq 'V0.7.3 HYBRID PIPELINE MATRIX COMPLETE' "$LOG";then state=ЗАВЕРШЁН;completed=$TOTAL
 else state='ОСТАНОВЛЕН / ПРОВЕРЬТЕ ЖУРНАЛ';fi
 pct=$((completed*100/TOTAL));((pct>100))&&pct=100
 echo 'ОБЩИЙ СТАТУС';echo '--------------------------------------------------------------------------------'
 echo "Состояние:          $state"
 echo "Всего профилей:     $TOTAL"
 echo "Завершено:          $completed из $TOTAL (успешно $valid, ошибок $failed)"
 printf 'Общий прогресс:     ';bar "$completed" "$TOTAL";printf ' %3d%%\n' "$pct"
 echo "Обновление:         каждые $REFRESH секунд";echo
 ci=$(idx "$current")
 echo 'ТЕКУЩЕЕ ЗАДАНИЕ';echo '--------------------------------------------------------------------------------'
 if ((ci>0));then echo "Профиль:            $ci из $TOTAL — $current";echo "Назначение:         ${TITLES[$((ci-1))]}";else echo "Профиль:            $current";fi
 echo "Этап:               $status"
 echo "Что выполняется:    $(stage_desc "$status")"
 [[ -n "$config" ]]&&echo "Конфигурация:       ${config#PROFILE_CONFIG }"
 last=$(grep -a '^BENCH_RUN ' "$LOG" 2>/dev/null|grep " profile=$current "|tail -1||true)
 if [[ -n "$last" ]];then
  rt=$(field "$last" run||true);h=$(field "$last" hps||true);rn=${rt%%/*};tt=${rt##*/};rn=$((10#$rn));tt=$((10#$tt))
  echo "Benchmark:          $rn из $tt";printf 'Прогресс benchmark: ';bar "$rn" "$tt";printf '\n'
  [[ "$h" =~ ^[0-9]+$ ]]&&echo "Последний хеш:      $(awk -v h="$h" 'BEGIN{printf "%.6f",h/1e6}') MH/s ($h H/s)"
 else echo 'Benchmark:          ещё не начался';fi;echo
 echo 'GPU RTX 3080';echo '--------------------------------------------------------------------------------'
 gpu=$(nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,clocks.current.sm,clocks.current.memory,power.draw,power.limit,fan.speed,memory.used --format=csv,noheader,nounits 2>/dev/null|head -1)
 if [[ -n "$gpu" ]];then IFS=',' read -r temp util core mem power pl fan vram<<<"$gpu";echo "Температура:${temp}°C | Загрузка:${util}% | Вентилятор:${fan}%";echo "Core:${core} MHz | Memory:${mem} MHz | Мощность:${power}/${pl} W | VRAM:${vram} MiB";else echo 'Данные nvidia-smi недоступны.';fi;echo
 echo 'ТАБЛИЦА ПРОФИЛЕЙ';echo '--------------------------------------------------------------------------------'
 printf '%-3s %-23s %-11s %-11s %-6s %-7s\n' '#' 'Профиль' 'Статус' 'MH/s' 'Regs' 'Stack'
 for ((i=0;i<TOTAL;i++));do
  p=${IDS[$i]};l=$(result "$p")
  if [[ -n "$l" ]];then ok=$(field "$l" valid||echo 0);if [[ $ok == 1 ]];then st=ГОТОВ;mh=$(field "$l" median_mhs||echo -);rg=$(field "$l" registers||echo -);sk=$(field "$l" stack||echo -);else st=ОШИБКА;mh=-;rg=-;sk=-;fi
  elif [[ $p == "$current" && $state == РАБОТАЕТ ]];then st='В РАБОТЕ';mh=-;rg=-;sk=-;else st=ОЖИДАЕТ;mh=-;rg=-;sk=-;fi
  printf '%-3d %-23s %-11s %-11s %-6s %-7s\n' "$((i+1))" "$p" "$st" "$mh" "$rg" "$sk"
 done;echo
 best=$(grep -a '^PROFILE_RESULT ' "$LOG" 2>/dev/null|grep ' valid=1 '|awk '{p="";h=0;m="";md="";r="";s="";for(i=1;i<=NF;i++){split($i,a,"=");if(a[1]=="profile")p=a[2];else if(a[1]=="median_hps")h=a[2]+0;else if(a[1]=="median_mhs")m=a[2];else if(a[1]=="mode")md=a[2];else if(a[1]=="registers")r=a[2];else if(a[1]=="stack")s=a[2]}if(h>b){b=h;bp=p;bm=m;bmd=md;br=r;bs=s}}END{if(b)print bp"|"bm"|"b"|"bmd"|"br"|"bs}')
 base=$(result mono-t64-b2);baseh=$(field "$base" median_hps 2>/dev/null||echo 0)
 echo 'ЛУЧШИЙ РЕЗУЛЬТАТ';echo '--------------------------------------------------------------------------------'
 if [[ -n "$best" ]];then IFS='|' read -r bp bm bh bmd br bs<<<"$best";echo "Профиль:            $bp";echo "Режим:              $bmd";echo "Хешрейт:            $bm MH/s ($bh H/s)";echo "Ресурсы:            $br регистров | stack $bs B";[[ "$baseh" =~ ^[1-9][0-9]*$ ]]&&echo "Относительно base:  $(awk -v b="$bh" -v a="$baseh" 'BEGIN{printf "%+.4f%%",(b/a-1)*100}')";else echo 'Пока нет завершённых валидных профилей.';fi;echo
 if [[ $state == ЗАВЕРШЁН ]];then echo 'ИТОГ И ССЫЛКИ НА СКАЧИВАНИЕ';echo '--------------------------------------------------------------------------------';grep -aE '^(profiles_|baseline_|best_|uplift_|ARCHIVE=|SHA256_FILE=|LOCAL_|PUBLIC_|DOWNLOAD_)' "$LOG"|tail -40||true;echo;echo 'Панель остановлена: тест завершён.';break;fi
 if [[ $state == 'ОСТАНОВЛЕН / ПРОВЕРЬТЕ ЖУРНАЛ' ]];then echo 'ПОСЛЕДНИЕ СТРОКИ ЖУРНАЛА';echo '--------------------------------------------------------------------------------';tail -n40 "$LOG"||true;break;fi
 echo "Журнал: $LOG";echo "Screen: $SCREEN_NAME";echo 'Ctrl+C закрывает только панель; тест продолжится.';sleep "$REFRESH"
done
