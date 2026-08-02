#!/usr/bin/env bash
set -u

LOG="${1:-/root/v070-zero-nibble.log}"
REFRESH="${REFRESH:-10}"
SCREEN_NAME="${SCREEN_NAME:-v070-zero-nibble}"
PUBLIC_UPLOAD="${PUBLIC_UPLOAD:-1}"
PUBLISHER_URL="https://raw.githubusercontent.com/iPepew/PepePow_Miner/experiment/v0.7.0-8h-autotune/tools/publish-test-results.sh"
PUBLISHER="/root/publish-pepepow-test-results.sh"

PROFILE_IDS=(baseline lazy-nibble lazy-zero-elide)
PROFILE_TITLES=(
  "Контрольный код v0.6.0"
  "Ленивая конвертация nibble"
  "Пропуск нулевых nibble"
)
TOTAL_PROFILES="${#PROFILE_IDS[@]}"
DEFAULT_RUNS="${RUNS:-9}"

bar() {
  local done="$1" total="$2" width="${3:-38}" filled empty
  (( total > 0 )) || total=1
  (( done < 0 )) && done=0
  (( done > total )) && done=$total
  filled=$((done * width / total))
  empty=$((width - filled))
  printf '['
  printf '%*s' "$filled" '' | tr ' ' '#'
  printf '%*s' "$empty" '' | tr ' ' '-'
  printf ']'
}

human_elapsed() {
  local seconds="$1" h m s
  (( seconds < 0 )) && seconds=0
  h=$((seconds / 3600)); m=$(((seconds % 3600) / 60)); s=$((seconds % 60))
  printf '%02d:%02d:%02d' "$h" "$m" "$s"
}

field_from_line() {
  local line="$1" wanted="$2" token key value
  for token in $line; do
    key="${token%%=*}"
    value="${token#*=}"
    [[ "$key" == "$wanted" ]] && { printf '%s\n' "$value"; return 0; }
  done
  return 1
}

profile_index() {
  local wanted="$1" i
  for ((i=0; i<TOTAL_PROFILES; i++)); do
    [[ "${PROFILE_IDS[$i]}" == "$wanted" ]] && { echo $((i+1)); return 0; }
  done
  echo 0
}

stage_title() {
  case "$1" in
    PATCHING*) echo 'Подготовка экспериментального исходника' ;;
    BUILDING*) echo 'Сборка CUDA-ядра, тестов и benchmark' ;;
    VALIDATING*) echo 'Проверка ctest и CPU/CUDA consensus' ;;
    BENCHMARKING*) echo 'Измерение производительности' ;;
    *) echo "$1" ;;
  esac
}

profile_result_line() {
  local profile="$1"
  grep -a '^PROFILE_RESULT ' "$LOG" 2>/dev/null | grep " profile=${profile} " | tail -n1 || true
}

bench_line_for() {
  local profile="$1"
  grep -a '^BENCH_RUN ' "$LOG" 2>/dev/null | grep " profile=${profile} " | tail -n1 || true
}

bench_stats_for() {
  local profile="$1"
  grep -a '^BENCH_RUN ' "$LOG" 2>/dev/null | grep " profile=${profile} " | \
    sed -n 's/.* hps=\([0-9][0-9]*\).*/\1/p' | \
    python3 -c 'import sys,statistics as s; v=[int(x) for x in sys.stdin if x.strip()]; print("0|0|0|0") if not v else print(f"{len(v)}|{int(s.median(v))}|{min(v)}|{max(v)}")' 2>/dev/null || echo '0|0|0|0'
}

publish_links_if_needed() {
  local archive="$1" links_file="${archive}.links.txt"
  [[ -f "$links_file" ]] && return 0
  command -v curl >/dev/null 2>&1 || return 0
  curl -fsSL "$PUBLISHER_URL" -o "$PUBLISHER" || return 0
  chmod +x "$PUBLISHER"
  PUBLIC_UPLOAD="$PUBLIC_UPLOAD" "$PUBLISHER" "$archive" >/tmp/pepepow-publish-links.out 2>&1 || true
}

while true; do
  printf '\033[H\033[2J'
  printf '%s\n' '================================================================================'
  printf '%s\n' ' PEPEPOW v0.7.0 EXPERIMENT — ZERO-NIBBLE / LAZY-CONVERSION MATRIX'
  printf '%s\n' ' Pepew - твоя монета. Твои правила.'
  printf '%s\n' '================================================================================'
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
  current="$(grep -a '^PROFILE=' "$LOG" 2>/dev/null | tail -n1 | cut -d= -f2-)"
  status_line="$(grep -a '^STATUS=' "$LOG" 2>/dev/null | tail -n1)"
  status="${status_line#STATUS=}"
  [[ -n "$current" ]] || current='инициализация'
  [[ -n "$status" && "$status" != "$status_line" ]] || status='ПОДГОТОВКА'
  current_index="$(profile_index "$current")"

  start_epoch="$(stat -c %W "$LOG" 2>/dev/null || echo 0)"
  [[ "$start_epoch" =~ ^[0-9]+$ ]] || start_epoch=0
  (( start_epoch > 0 )) || start_epoch="$(stat -c %Y "$LOG" 2>/dev/null || date +%s)"
  now="$(date +%s)"
  elapsed=$((now - start_epoch))

  if screen -ls 2>/dev/null | grep -q "\.${SCREEN_NAME}[[:space:]]"; then
    run_state='РАБОТАЕТ'
  elif grep -aq 'V0.7.0 ZERO-NIBBLE MATRIX COMPLETE' "$LOG" 2>/dev/null; then
    run_state='ЗАВЕРШЁН'
    completed="$TOTAL_PROFILES"
  else
    run_state='ОСТАНОВЛЕН / ПРОВЕРЬТЕ ЖУРНАЛ'
  fi

  pct=$((completed * 100 / TOTAL_PROFILES))
  (( pct > 100 )) && pct=100

  echo 'ОБЩИЙ СТАТУС'
  echo '--------------------------------------------------------------------------------'
  printf 'Состояние:          %s\n' "$run_state"
  printf 'Всего профилей:     %d\n' "$TOTAL_PROFILES"
  printf 'Завершено:          %d из %d  (успешно %d, ошибок %d)\n' "$completed" "$TOTAL_PROFILES" "$valid" "$failed"
  printf 'Общий прогресс:     '; bar "$completed" "$TOTAL_PROFILES" 42; printf ' %3d%%\n' "$pct"
  printf 'Время тестирования: %s\n' "$(human_elapsed "$elapsed")"
  printf 'Обновление панели:  каждые %s секунд\n' "$REFRESH"
  echo

  echo 'ТЕКУЩЕЕ ЗАДАНИЕ'
  echo '--------------------------------------------------------------------------------'
  if (( current_index > 0 )); then
    printf 'Профиль:            %d из %d — %s\n' "$current_index" "$TOTAL_PROFILES" "$current"
    printf 'Назначение:         %s\n' "${PROFILE_TITLES[$((current_index-1))]}"
  else
    printf 'Профиль:            %s\n' "$current"
  fi
  printf 'Технический этап:   %s\n' "$status"
  printf 'Что выполняется:    %s\n' "$(stage_title "$status")"

  bench_line="$(bench_line_for "$current")"
  IFS='|' read -r bench_count bench_median bench_min bench_max <<<"$(bench_stats_for "$current")"
  bench_total="$DEFAULT_RUNS"
  bench_run='0'
  bench_hps='0'
  if [[ -n "$bench_line" ]]; then
    run_token="$(field_from_line "$bench_line" run || true)"
    bench_hps="$(field_from_line "$bench_line" hps || true)"
    bench_run="${run_token%%/*}"
    bench_total="${run_token##*/}"
    bench_run=$((10#$bench_run))
    bench_total=$((10#$bench_total))
  fi
  if [[ "$status" == BENCHMARKING* || "$bench_count" -gt 0 ]]; then
    printf 'Benchmark-прогоны:  %d из %d\n' "$bench_run" "$bench_total"
    printf 'Прогресс benchmark: '; bar "$bench_run" "$bench_total" 42; printf '\n'
    if (( bench_hps > 0 )); then
      printf 'Последний замер:    %.6f MH/s  (%s H/s)\n' "$(awk -v h="$bench_hps" 'BEGIN{print h/1000000}')" "$bench_hps"
    fi
    if (( bench_median > 0 )); then
      printf 'Медиана сейчас:     %.6f MH/s  (%s H/s)\n' "$(awk -v h="$bench_median" 'BEGIN{print h/1000000}')" "$bench_median"
      printf 'Диапазон замеров:   %s — %s H/s\n' "$bench_min" "$bench_max"
    fi
  else
    echo 'Benchmark-прогоны:  ещё не начались для этого профиля'
  fi
  echo

  gpu="$(nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,clocks.current.sm,clocks.current.memory,power.draw,power.limit,fan.speed,memory.used --format=csv,noheader,nounits 2>/dev/null | head -n1)"
  echo 'GPU RTX 3080'
  echo '--------------------------------------------------------------------------------'
  if [[ -n "$gpu" ]]; then
    IFS=',' read -r temp util clock memclock power pl fan memused <<<"$gpu"
    for name in temp util clock memclock power pl fan memused; do
      printf -v "$name" '%s' "${!name// /}"
    done
    printf 'Температура: %s°C | Загрузка: %s%% | Вентилятор: %s%%\n' "$temp" "$util" "$fan"
    printf 'Core: %s MHz | Memory: %s MHz | Мощность: %s / %s W | VRAM: %s MiB\n' \
      "$clock" "$memclock" "$power" "$pl" "$memused"
  else
    echo 'Данные nvidia-smi недоступны.'
  fi
  echo

  best="$(grep -a '^PROFILE_RESULT ' "$LOG" 2>/dev/null | grep ' valid=1 ' | awk '
    {
      p=""; h=0; m=""; r=""; st=""; ss=""; sl="";
      for(i=1;i<=NF;i++){
        split($i,a,"=");
        if(a[1]=="profile") p=a[2];
        else if(a[1]=="median_hps") h=a[2]+0;
        else if(a[1]=="median_mhs") m=a[2];
        else if(a[1]=="pow_regs") r=a[2];
        else if(a[1]=="stack") st=a[2];
        else if(a[1]=="spill_store") ss=a[2];
        else if(a[1]=="spill_load") sl=a[2];
      }
      if(h>best){best=h; bp=p; bm=m; br=r; bst=st; bss=ss; bsl=sl}
    }
    END{if(best>0) printf "%s|%s|%d|%s|%s|%s|%s",bp,bm,best,br,bst,bss,bsl}
  ')"
  baseline_line="$(profile_result_line baseline)"
  baseline_hps="$(field_from_line "$baseline_line" median_hps 2>/dev/null || echo 0)"

  echo 'СРАВНЕНИЕ ЗАВЕРШЁННЫХ ПРОФИЛЕЙ'
  echo '--------------------------------------------------------------------------------'
  printf '%-3s %-20s %-12s %-12s %-8s %-8s\n' '#' 'Профиль' 'Статус' 'MH/s' 'Regs' 'Stack'
  printf '%-3s %-20s %-12s %-12s %-8s %-8s\n' '---' '--------------------' '------------' '------------' '--------' '--------'
  for ((i=0; i<TOTAL_PROFILES; i++)); do
    pid="${PROFILE_IDS[$i]}"
    result="$(profile_result_line "$pid")"
    if [[ -n "$result" ]]; then
      ok="$(field_from_line "$result" valid || echo 0)"
      if [[ "$ok" == '1' ]]; then
        mh="$(field_from_line "$result" median_mhs || echo '-')"
        regs="$(field_from_line "$result" pow_regs || echo '-')"
        stack="$(field_from_line "$result" stack || echo '-')"
        pstate='ГОТОВ'
      else
        mh='-'; regs='-'; stack='-'; pstate='ОШИБКА'
      fi
    elif [[ "$pid" == "$current" && "$run_state" == 'РАБОТАЕТ' ]]; then
      mh='-'; regs='-'; stack='-'; pstate='В РАБОТЕ'
    else
      mh='-'; regs='-'; stack='-'; pstate='ОЖИДАЕТ'
    fi
    printf '%-3d %-20s %-12s %-12s %-8s %-8s\n' "$((i+1))" "$pid" "$pstate" "$mh" "$regs" "$stack"
  done
  echo

  echo 'ЛУЧШИЙ РЕЗУЛЬТАТ НА ДАННЫЙ МОМЕНТ'
  echo '--------------------------------------------------------------------------------'
  if [[ -n "$best" ]]; then
    IFS='|' read -r bp bm bh br bst bss bsl <<<"$best"
    printf 'Профиль:           %s\n' "$bp"
    printf 'Хешрейт:           %s MH/s  (%s H/s)\n' "$bm" "$bh"
    if (( baseline_hps > 0 )); then
      delta="$(awk -v best="$bh" -v base="$baseline_hps" 'BEGIN{printf "%+.4f",(best/base-1)*100}')"
      printf 'Относительно base: %s%%\n' "$delta"
    fi
    printf 'Ресурсы ядра:      %s регистров | stack %s B | spills %s/%s B\n' "$br" "$bst" "$bss" "$bsl"
  else
    echo 'Пока нет завершённых валидных профилей.'
  fi
  echo

  if [[ "$run_state" == 'ЗАВЕРШЁН' ]]; then
    archive="$(grep -a '^ARCHIVE=' "$LOG" 2>/dev/null | tail -n1 | cut -d= -f2-)"
    sha_file="$(grep -a '^SHA256_FILE=' "$LOG" 2>/dev/null | tail -n1 | cut -d= -f2-)"
    if [[ -n "$archive" && -f "$archive" ]]; then
      echo 'ПОДГОТОВКА ССЫЛОК НА СКАЧИВАНИЕ...'
      publish_links_if_needed "$archive"
      links_file="${archive}.links.txt"
      printf '\033[H\033[2J'
      printf '%s\n' '================================================================================'
      printf '%s\n' ' PEPEPOW v0.7.0 — ТЕСТ ЗАВЕРШЁН'
      printf '%s\n' '================================================================================'
      echo
      summary_start="$(grep -an '^profiles_total=' "$LOG" | tail -n1 | cut -d: -f1)"
      if [[ -n "$summary_start" ]]; then
        sed -n "${summary_start},$((summary_start+11))p" "$LOG" | grep -aE '^(profiles_|baseline_|best_|uplift_)' || true
      fi
      echo
      echo "Архив: $archive"
      echo "SHA256: ${sha_file:-${archive}.sha256}"
      echo
      echo 'ССЫЛКИ НА СКАЧИВАНИЕ'
      echo '--------------------------------------------------------------------------------'
      if [[ -f "$links_file" ]]; then
        public_archive="$(sed -n 's/^PUBLIC_ARCHIVE_URL=//p' "$links_file" | tail -n1)"
        public_sha="$(sed -n 's/^PUBLIC_SHA256_URL=//p' "$links_file" | tail -n1)"
        local_archive="$(sed -n 's/^LOCAL_ARCHIVE_URL=//p' "$links_file" | tail -n1)"
        local_sha="$(sed -n 's/^LOCAL_SHA256_URL=//p' "$links_file" | tail -n1)"
        expiry="$(sed -n 's/^PUBLIC_LINKS_EXPIRE_HOURS=//p' "$links_file" | tail -n1)"
        if [[ -n "$public_archive" ]]; then
          echo "Архив (публичная временная ссылка):"
          echo "$public_archive"
          echo
          echo "SHA256 (публичная временная ссылка):"
          echo "$public_sha"
          echo
          echo "Срок действия: ${expiry:-24} часа"
        else
          echo 'Публичную ссылку создать не удалось. Используй локальные ссылки:'
        fi
        echo
        echo "Архив (локальная сеть): $local_archive"
        echo "SHA256 (локальная сеть): $local_sha"
      else
        echo 'Файл ссылок не создан. Архив и SHA256 сохранены на риге.'
      fi
      echo
      echo "Журнал: $LOG"
      echo 'Панель больше не обновляется: тест завершён.'
    else
      echo 'Тест завершён, но путь к архиву пока не найден в журнале.'
    fi
    break
  fi

  echo "Журнал: $LOG"
  echo "Screen: $SCREEN_NAME"
  echo 'Ctrl+C закрывает только панель; тест продолжится в screen.'
  echo "Следующее обновление через ${REFRESH} секунд."
  sleep "$REFRESH"
done
