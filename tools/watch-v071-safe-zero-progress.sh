#!/usr/bin/env bash
set -u

LOG="${1:-/root/v071-safe-zero.log}"
REFRESH="${REFRESH:-10}"
SCREEN_NAME="${SCREEN_NAME:-v071-safe-zero}"
PUBLISHER_URL="https://raw.githubusercontent.com/iPepew/PepePow_Miner/experiment/v0.7.0-8h-autotune/tools/publish-test-results.sh"
PUBLISHER="/root/publish-pepepow-test-results.sh"

IDS=(baseline warm-zero-guard lazy-zero-update)
TITLES=(
  "Контрольный код v0.6.0"
  "Безопасный пропуск нулевой загрузки из таблицы"
  "Ленивая конвертация без раннего return"
)
TOTAL="${#IDS[@]}"

bar() {
  local done total width filled empty
  done="${1:-0}"
  total="${2:-1}"
  width="${3:-42}"
  [[ "$done" =~ ^[0-9]+$ ]] || done=0
  [[ "$total" =~ ^[1-9][0-9]*$ ]] || total=1
  [[ "$width" =~ ^[1-9][0-9]*$ ]] || width=42
  (( done > total )) && done=$total
  filled=$((done * width / total))
  empty=$((width - filled))
  printf '['
  printf '%*s' "$filled" '' | tr ' ' '#'
  printf '%*s' "$empty" '' | tr ' ' '-'
  printf ']'
}

field() {
  local line wanted token
  line="${1:-}"
  wanted="${2:-}"
  for token in $line; do
    if [[ "${token%%=*}" == "$wanted" ]]; then
      printf '%s\n' "${token#*=}"
      return 0
    fi
  done
  return 1
}

profile_index() {
  local wanted i
  wanted="${1:-}"
  for ((i=0; i<TOTAL; i++)); do
    if [[ "${IDS[$i]}" == "$wanted" ]]; then
      echo $((i + 1))
      return 0
    fi
  done
  echo 0
}

profile_result() {
  local profile="${1:-}"
  grep -a '^PROFILE_RESULT ' "$LOG" 2>/dev/null | grep " profile=${profile} " | tail -n1 || true
}

stage_description() {
  case "${1:-}" in
    PATCHING*) echo 'Подготовка экспериментального исходника' ;;
    BUILDING*) echo 'Сборка CUDA-ядра и тестовых бинарников' ;;
    VALIDATING*) echo 'Проверка ctest и CPU/CUDA consensus' ;;
    BENCHMARKING*) echo 'Измерение производительности' ;;
    *) echo "${1:-Подготовка}" ;;
  esac
}

while true; do
  printf '\033[H\033[2J'
  echo '================================================================================'
  echo ' PEPEPOW v0.7.1 — SAFE ZERO-NIBBLE MATRIX'
  echo ' Pepew - твоя монета. Твои правила.'
  echo '================================================================================'
  echo

  if [[ ! -f "$LOG" ]]; then
    echo "Журнал ещё не создан: $LOG"
    echo "Повторная проверка через ${REFRESH} секунд."
    sleep "$REFRESH"
    continue
  fi

  completed="$(grep -ac '^PROFILE_RESULT ' "$LOG" 2>/dev/null || true)"
  valid="$(grep -a '^PROFILE_RESULT ' "$LOG" 2>/dev/null | grep -c ' valid=1 ' || true)"
  failed="$(grep -a '^PROFILE_RESULT ' "$LOG" 2>/dev/null | grep -c ' valid=0 ' || true)"
  [[ "$completed" =~ ^[0-9]+$ ]] || completed=0
  [[ "$valid" =~ ^[0-9]+$ ]] || valid=0
  [[ "$failed" =~ ^[0-9]+$ ]] || failed=0

  current="$(grep -a '^PROFILE=' "$LOG" 2>/dev/null | tail -n1 | cut -d= -f2-)"
  status="$(grep -a '^STATUS=' "$LOG" 2>/dev/null | tail -n1 | cut -d= -f2-)"
  [[ -n "$current" ]] || current='инициализация'
  [[ -n "$status" ]] || status='ПОДГОТОВКА'

  if screen -ls 2>/dev/null | grep -q "\.${SCREEN_NAME}[[:space:]]"; then
    state='РАБОТАЕТ'
  elif grep -aq 'V0.7.1 SAFE-ZERO MATRIX COMPLETE' "$LOG" 2>/dev/null; then
    state='ЗАВЕРШЁН'
    completed="$TOTAL"
  else
    state='ОСТАНОВЛЕН / ПРОВЕРЬТЕ ЖУРНАЛ'
  fi

  overall_pct=$((completed * 100 / TOTAL))
  (( overall_pct > 100 )) && overall_pct=100

  echo 'ОБЩИЙ СТАТУС'
  echo '--------------------------------------------------------------------------------'
  printf 'Состояние:          %s\n' "$state"
  printf 'Всего профилей:     %d\n' "$TOTAL"
  printf 'Завершено:          %d из %d  (успешно %d, ошибок %d)\n' "$completed" "$TOTAL" "$valid" "$failed"
  printf 'Общий прогресс:     '
  bar "$completed" "$TOTAL"
  printf ' %3d%%\n' "$overall_pct"
  printf 'Обновление:         каждые %s секунд\n' "$REFRESH"
  echo

  current_index="$(profile_index "$current")"
  echo 'ТЕКУЩЕЕ ЗАДАНИЕ'
  echo '--------------------------------------------------------------------------------'
  if (( current_index > 0 )); then
    printf 'Профиль:            %d из %d — %s\n' "$current_index" "$TOTAL" "$current"
    printf 'Назначение:         %s\n' "${TITLES[$((current_index - 1))]}"
  else
    printf 'Профиль:            %s\n' "$current"
  fi
  printf 'Этап:               %s\n' "$status"
  printf 'Что выполняется:    %s\n' "$(stage_description "$status")"

  last_bench="$(grep -a '^BENCH_RUN ' "$LOG" 2>/dev/null | grep " profile=${current} " | tail -n1 || true)"
  if [[ -n "$last_bench" ]]; then
    run_token="$(field "$last_bench" run || true)"
    hps="$(field "$last_bench" hps || true)"
    run_no="${run_token%%/*}"
    run_total="${run_token##*/}"
    [[ "$run_no" =~ ^[0-9]+$ ]] || run_no=0
    [[ "$run_total" =~ ^[1-9][0-9]*$ ]] || run_total=1
    run_no=$((10#$run_no))
    run_total=$((10#$run_total))
    printf 'Benchmark:          %d из %d\n' "$run_no" "$run_total"
    printf 'Прогресс benchmark: '
    bar "$run_no" "$run_total"
    printf '\n'
    if [[ "$hps" =~ ^[0-9]+$ ]]; then
      printf 'Последний хеш:      %.6f MH/s  (%s H/s)\n' "$(awk -v h="$hps" 'BEGIN{print h/1000000}')" "$hps"
    fi
  else
    echo 'Benchmark:          ещё не начался'
  fi
  echo

  echo 'GPU RTX 3080'
  echo '--------------------------------------------------------------------------------'
  gpu="$(nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,clocks.current.sm,clocks.current.memory,power.draw,power.limit,fan.speed --format=csv,noheader,nounits 2>/dev/null | head -n1)"
  if [[ -n "$gpu" ]]; then
    echo "$gpu"
  else
    echo 'Данные nvidia-smi недоступны.'
  fi
  echo

  echo 'ТАБЛИЦА ПРОФИЛЕЙ'
  echo '--------------------------------------------------------------------------------'
  printf '%-3s %-22s %-12s %-12s %-6s %-7s\n' '#' 'Профиль' 'Статус' 'MH/s' 'Regs' 'Stack'
  for ((i=0; i<TOTAL; i++)); do
    profile="${IDS[$i]}"
    line="$(profile_result "$profile")"
    if [[ -n "$line" ]]; then
      ok="$(field "$line" valid || echo 0)"
      if [[ "$ok" == '1' ]]; then
        row_state='ГОТОВ'
        mh="$(field "$line" median_mhs || echo '-')"
        regs="$(field "$line" pow_regs || echo '-')"
        stack="$(field "$line" stack || echo '-')"
      else
        row_state='ОШИБКА'; mh='-'; regs='-'; stack='-'
      fi
    elif [[ "$profile" == "$current" && "$state" == 'РАБОТАЕТ' ]]; then
      row_state='В РАБОТЕ'; mh='-'; regs='-'; stack='-'
    else
      row_state='ОЖИДАЕТ'; mh='-'; regs='-'; stack='-'
    fi
    printf '%-3d %-22s %-12s %-12s %-6s %-7s\n' "$((i + 1))" "$profile" "$row_state" "$mh" "$regs" "$stack"
  done
  echo

  best="$(grep -a '^PROFILE_RESULT ' "$LOG" 2>/dev/null | grep ' valid=1 ' | awk '
    {
      p=""; h=0; m="";
      for(i=1;i<=NF;i++){
        split($i,a,"=");
        if(a[1]=="profile") p=a[2];
        else if(a[1]=="median_hps") h=a[2]+0;
        else if(a[1]=="median_mhs") m=a[2];
      }
      if(h>b){b=h;bp=p;bm=m}
    }
    END{if(b>0) print bp"|"bm"|"b}
  ')"
  echo 'ЛУЧШИЙ РЕЗУЛЬТАТ'
  echo '--------------------------------------------------------------------------------'
  if [[ -n "$best" ]]; then
    IFS='|' read -r best_profile best_mhs best_hps <<<"$best"
    echo "Профиль:            $best_profile"
    echo "Хешрейт:            $best_mhs MH/s ($best_hps H/s)"
  else
    echo 'Пока нет завершённых валидных профилей.'
  fi
  echo

  if [[ "$state" == 'ЗАВЕРШЁН' ]]; then
    archive="$(grep -a '^ARCHIVE=' "$LOG" 2>/dev/null | tail -n1 | cut -d= -f2-)"
    if [[ -n "$archive" && -f "$archive" ]]; then
      links="${archive}.links.txt"
      if [[ ! -f "$links" ]]; then
        curl -fsSL "$PUBLISHER_URL" -o "$PUBLISHER" && chmod +x "$PUBLISHER" && "$PUBLISHER" "$archive" >/tmp/v071-publish.out 2>&1 || true
      fi
      echo 'ССЫЛКИ НА СКАЧИВАНИЕ'
      echo '--------------------------------------------------------------------------------'
      [[ -f "$links" ]] && cat "$links" || echo "Архив: $archive"
    fi
    echo
    echo 'Панель остановлена: тест завершён.'
    break
  fi

  if [[ "$state" == 'ОСТАНОВЛЕН / ПРОВЕРЬТЕ ЖУРНАЛ' ]]; then
    echo 'ПОСЛЕДНИЕ СТРОКИ ЖУРНАЛА'
    echo '--------------------------------------------------------------------------------'
    tail -n 30 "$LOG" 2>/dev/null || true
    echo
    echo 'Тестовый процесс завершился до получения результата. Панель больше не обновляется.'
    break
  fi

  echo "Журнал: $LOG"
  echo 'Ctrl+C закрывает только панель.'
  sleep "$REFRESH"
done
