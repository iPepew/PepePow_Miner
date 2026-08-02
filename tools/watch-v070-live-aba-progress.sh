#!/usr/bin/env bash
set -u

LOG="${1:-/root/v070-live-aba.log}"
REFRESH="${REFRESH:-10}"
SCREEN_NAME="${SCREEN_NAME:-v070-live-aba}"

STAGE_IDS=(baseline-a1 candidate-b baseline-a2)
STAGE_VARIANTS=(baseline lazy-zero-elide baseline)
STAGE_TITLES=(
  "Контрольный замер v0.6.0-PR до кандидата"
  "Кандидат v0.7.0 lazy-zero-elide"
  "Повторный контрольный замер v0.6.0-PR"
)
TOTAL=3

bar() {
  local done="$1" total="$2" width="${3:-42}" filled empty
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

human() {
  local s="$1" h m
  (( s < 0 )) && s=0
  h=$((s/3600)); m=$(((s%3600)/60)); s=$((s%60))
  printf '%02d:%02d:%02d' "$h" "$m" "$s"
}

field() {
  local line="$1" wanted="$2" token
  for token in $line; do
    [[ "${token%%=*}" == "$wanted" ]] && { printf '%s\n' "${token#*=}"; return 0; }
  done
  return 1
}

while true; do
  printf '\033[H\033[2J'
  echo '================================================================================'
  echo ' PEPEPOW v0.7.0 — LIVE POOL A/B/A VALIDATION'
  echo ' Pepew - твоя монета. Твои правила.'
  echo '================================================================================'
  echo

  if [[ ! -f "$LOG" ]]; then
    echo "Журнал ещё не создан: $LOG"
    echo "Повторная проверка через ${REFRESH} секунд."
    sleep "$REFRESH"
    continue
  fi

  root="$(grep -a '^ARCHIVE=' "$LOG" 2>/dev/null | tail -n1 | sed 's#^ARCHIVE=##;s#\.tar\.gz$##' || true)"
  status_file=""
  if [[ -n "$root" && -d "$root" ]]; then
    status_file="${root}/status.env"
  else
    candidate_root="$(grep -a '^RESULTS=' "$LOG" 2>/dev/null | tail -n1 | sed 's#^RESULTS=##;s#/results.csv$##' || true)"
    [[ -d "$candidate_root" ]] && { root="$candidate_root"; status_file="${root}/status.env"; }
  fi
  if [[ -z "$status_file" ]]; then
    latest_root="$(find /root/pepepow-tests -maxdepth 1 -type d -name 'v070-live-aba-*' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
    [[ -n "$latest_root" ]] && { root="$latest_root"; status_file="${root}/status.env"; }
  fi

  STATE="STARTING"; STAGE_INDEX=0; STAGE_TOTAL=3; STAGE_ID=""; VARIANT=""; STAGE_START_EPOCH=0; STAGE_SECONDS=720; WARMUP_SECONDS=120
  [[ -f "$status_file" ]] && source "$status_file"

  if screen -ls 2>/dev/null | grep -q "\.${SCREEN_NAME}[[:space:]]"; then
    run_state='РАБОТАЕТ'
  elif grep -aq 'V0.7.0 LIVE A/B/A COMPLETE' "$LOG" 2>/dev/null; then
    run_state='ЗАВЕРШЁН'
  else
    run_state='ОСТАНОВЛЕН / ПРОВЕРЬТЕ ЖУРНАЛ'
  fi

  completed="$(grep -ac '^LIVE_STAGE_RESULT ' "$LOG" 2>/dev/null || true)"
  valid="$(grep -a '^LIVE_STAGE_RESULT ' "$LOG" 2>/dev/null | grep -c ' valid=1 ' || true)"
  failed="$(grep -a '^LIVE_STAGE_RESULT ' "$LOG" 2>/dev/null | grep -c ' valid=0 ' || true)"
  overall_pct=$((completed*100/TOTAL))
  (( overall_pct > 100 )) && overall_pct=100

  echo 'ОБЩИЙ СТАТУС'
  echo '--------------------------------------------------------------------------------'
  printf 'Состояние:          %s\n' "$run_state"
  printf 'Этапов теста:       %d\n' "$TOTAL"
  printf 'Завершено:          %d из %d  (успешно %d, ошибок %d)\n' "$completed" "$TOTAL" "$valid" "$failed"
  printf 'Общий прогресс:     '; bar "$completed" "$TOTAL"; printf ' %3d%%\n' "$overall_pct"
  printf 'Обновление панели:  каждые %s секунд\n' "$REFRESH"
  echo

  now="$(date +%s)"
  stage_elapsed=$((now - STAGE_START_EPOCH))
  (( STAGE_START_EPOCH <= 0 )) && stage_elapsed=0
  stage_pct=$((stage_elapsed*100/STAGE_SECONDS))
  (( stage_pct > 100 )) && stage_pct=100
  measured_elapsed=$((stage_elapsed-WARMUP_SECONDS))
  (( measured_elapsed < 0 )) && measured_elapsed=0

  echo 'ТЕКУЩЕЕ ЗАДАНИЕ'
  echo '--------------------------------------------------------------------------------'
  if (( STAGE_INDEX >= 1 && STAGE_INDEX <= TOTAL )); then
    printf 'Этап:               %d из %d — %s\n' "$STAGE_INDEX" "$TOTAL" "$STAGE_ID"
    printf 'Назначение:         %s\n' "${STAGE_TITLES[$((STAGE_INDEX-1))]}"
    printf 'Бинарник:           %s\n' "$VARIANT"
  else
    printf 'Этап:               подготовка\n'
  fi
  printf 'Состояние этапа:    %s\n' "$STATE"
  printf 'Время этапа:        %s из %s\n' "$(human "$stage_elapsed")" "$(human "$STAGE_SECONDS")"
  printf 'Прогресс этапа:     '; bar "$stage_elapsed" "$STAGE_SECONDS"; printf ' %3d%%\n' "$stage_pct"
  if (( stage_elapsed < WARMUP_SECONDS )); then
    printf 'Прогрев:            %s из %s\n' "$(human "$stage_elapsed")" "$(human "$WARMUP_SECONDS")"
  else
    printf 'Чистое измерение:   %s\n' "$(human "$measured_elapsed")"
  fi
  echo

  console=""
  if [[ -n "$root" && -n "$STAGE_ID" ]]; then
    console="${root}/stages/${STAGE_ID}/miner-console.raw.log"
    [[ -f "$console" ]] || console="${root}/stages/${STAGE_ID}/miner-console.log"
  fi

  echo 'LIVE ДАННЫЕ ТЕКУЩЕГО ЭТАПА'
  echo '--------------------------------------------------------------------------------'
  if [[ -f "$console" ]]; then
    last_mining="$(python3 - "$console" <<'PY' 2>/dev/null || true
import re,sys
text=open(sys.argv[1],errors="replace").read()
text=re.sub(r"\x1b\[[0-9;]*m","",text)
matches=list(re.finditer(r"\[MINING\]\s*\|\s*([0-9.]+)\s+MH/s\s*\|\s*A\s+(\d+)\s*\|\s*R\s+(\d+)\s*\|\s*Uptime\s+([0-9:]+)",text))
if matches:
    m=matches[-1]
    print("|".join(m.groups()))
PY
)"
    if [[ -n "$last_mining" ]]; then
      IFS='|' read -r live_mhs live_a live_r live_uptime <<<"$last_mining"
      printf 'Текущий хешрейт:    %s MH/s\n' "$live_mhs"
      printf 'Шары:               Accepted %s | Rejected %s\n' "$live_a" "$live_r"
      printf 'Uptime майнера:     %s\n' "$live_uptime"
      warm_stats="$(python3 - "$console" "$WARMUP_SECONDS" <<'PY' 2>/dev/null || true
import re,statistics,sys
text=open(sys.argv[1],errors="replace").read()
text=re.sub(r"\x1b\[[0-9;]*m","",text)
warm=int(sys.argv[2]); v=[]
for m in re.finditer(r"\[MINING\]\s*\|\s*([0-9.]+)\s+MH/s\s*\|\s*A\s+\d+\s*\|\s*R\s+\d+\s*\|\s*Uptime\s+([0-9:]+)",text):
    sec=0
    for p in map(int,m.group(2).split(":")): sec=sec*60+p
    if sec>=warm: v.append(float(m.group(1)))
if v: print(f"{len(v)}|{statistics.mean(v):.6f}|{statistics.median(v):.6f}|{min(v):.6f}|{max(v):.6f}")
PY
)"
      if [[ -n "$warm_stats" ]]; then
        IFS='|' read -r sample_count mean median min max <<<"$warm_stats"
        printf 'После прогрева:     %s замеров\n' "$sample_count"
        printf 'Среднее / медиана:  %s / %s MH/s\n' "$mean" "$median"
        printf 'Диапазон:           %s — %s MH/s\n' "$min" "$max"
      else
        echo 'После прогрева:     данных пока недостаточно'
      fi
    else
      echo 'Ожидание первой строки [MINING] от майнера.'
    fi
  else
    echo 'Журнал текущего майнера ещё не создан.'
  fi
  echo

  gpu="$(nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,clocks.current.sm,clocks.current.memory,power.draw,power.limit,fan.speed,memory.used --format=csv,noheader,nounits 2>/dev/null | head -n1)"
  echo 'GPU RTX 3080'
  echo '--------------------------------------------------------------------------------'
  if [[ -n "$gpu" ]]; then
    IFS=',' read -r temp util clock memclock power pl fan memused <<<"$gpu"
    temp="${temp// /}"; util="${util// /}"; clock="${clock// /}"; memclock="${memclock// /}"
    power="${power// /}"; pl="${pl// /}"; fan="${fan// /}"; memused="${memused// /}"
    printf 'Температура: %s°C | Загрузка: %s%% | Вентилятор: %s%%\n' "$temp" "$util" "$fan"
    printf 'Core: %s MHz | Memory: %s MHz | Мощность: %s / %s W | VRAM: %s MiB\n' "$clock" "$memclock" "$power" "$pl" "$memused"
  else
    echo 'Данные nvidia-smi недоступны.'
  fi
  echo

  echo 'РЕЗУЛЬТАТЫ ЭТАПОВ'
  echo '--------------------------------------------------------------------------------'
  printf '%-3s %-15s %-17s %-10s %-8s %-8s\n' '#' 'Этап' 'Вариант' 'MH/s' 'A' 'R'
  printf '%-3s %-15s %-17s %-10s %-8s %-8s\n' '---' '---------------' '-----------------' '----------' '--------' '--------'
  for ((i=0;i<TOTAL;i++)); do
    id="${STAGE_IDS[$i]}"; variant="${STAGE_VARIANTS[$i]}"
    line="$(grep -a '^LIVE_STAGE_RESULT ' "$LOG" 2>/dev/null | grep " stage=${id} " | tail -n1 || true)"
    if [[ -n "$line" ]]; then
      ok="$(field "$line" valid || echo 0)"
      mh="$(field "$line" median_mhs || echo '-')"
      a="$(field "$line" accepted || echo '-')"
      r="$(field "$line" rejected || echo '-')"
      [[ "$ok" == 1 ]] && label='ГОТОВ' || label='ОШИБКА'
    elif [[ "$id" == "$STAGE_ID" && "$run_state" == 'РАБОТАЕТ' ]]; then
      label='В РАБОТЕ'; mh='-'; a='-'; r='-'
    else
      label='ОЖИДАЕТ'; mh='-'; a='-'; r='-'
    fi
    printf '%-3d %-15s %-17s %-10s %-8s %-8s  %s\n' "$((i+1))" "$id" "$variant" "$mh" "$a" "$r" "$label"
  done
  echo

  if [[ "$run_state" == 'ЗАВЕРШЁН' ]]; then
    archive="$(grep -a '^ARCHIVE=' "$LOG" | tail -n1 | cut -d= -f2-)"
    links="${archive}.links.txt"
    echo 'ФИНАЛЬНЫЙ РЕЗУЛЬТАТ'
    echo '--------------------------------------------------------------------------------'
    summary="${archive%.tar.gz}/summary.txt"
    [[ -f "$summary" ]] && cat "$summary"
    echo
    echo "Архив: $archive"
    echo "SHA256: ${archive}.sha256"
    echo
    echo 'ССЫЛКИ НА СКАЧИВАНИЕ'
    echo '--------------------------------------------------------------------------------'
    if [[ -f "$links" ]]; then
      pub_a="$(sed -n 's/^PUBLIC_ARCHIVE_URL=//p' "$links" | tail -n1)"
      pub_s="$(sed -n 's/^PUBLIC_SHA256_URL=//p' "$links" | tail -n1)"
      loc_a="$(sed -n 's/^LOCAL_ARCHIVE_URL=//p' "$links" | tail -n1)"
      loc_s="$(sed -n 's/^LOCAL_SHA256_URL=//p' "$links" | tail -n1)"
      [[ -n "$pub_a" ]] && { echo "Публичный архив: $pub_a"; echo "Публичный SHA256: $pub_s"; echo; }
      echo "Локальный архив: $loc_a"
      echo "Локальный SHA256: $loc_s"
    else
      echo 'Файл ссылок ещё не создан. Подождите 10 секунд и снова откройте панель.'
    fi
    echo
    echo 'Панель больше не обновляется: тест завершён.'
    break
  fi

  echo "Журнал: $LOG"
  echo "Screen: $SCREEN_NAME"
  echo 'Ctrl+C закрывает только панель; A/B/A-тест продолжится в screen.'
  echo "Следующее обновление через ${REFRESH} секунд."
  sleep "$REFRESH"
done
