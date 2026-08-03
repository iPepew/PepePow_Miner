#!/usr/bin/env bash
set -o pipefail

LOG="${1:-/root/v080-grand.log}"
REFRESH="${REFRESH:-10}"
SCREEN_NAME="${SCREEN_NAME:-v080-grand}"

IDS=(
  baseline-t64-b2
  selector-t64-b2
  dual-seq-t64-b1
  dual-seq-t64-b2
  dual-ilp-t64-b1
  dual-ilp-t64-b2
  selector-dual-ilp-t64-b1
  selector-dual-ilp-t64-b2
  dual-ilp-t128-b1
  selector-dual-ilp-t128-b1
)
TITLES=(
  "Контрольное ядро v0.6.0"
  "Exact selector: один fraction decode вместо двух"
  "Два nonce на поток, последовательное исполнение, b1"
  "Два nonce на поток, последовательное исполнение, b2"
  "Два nonce на поток с межnonce ILP, b1"
  "Два nonce на поток с межnonce ILP, b2"
  "Exact selector + межnonce ILP, b1"
  "Exact selector + межnonce ILP, b2"
  "Межnonce ILP, 128 потоков, b1"
  "Exact selector + ILP, 128 потоков, b1"
)
TOTAL="${#IDS[@]}"
TARGET_HPS=2000000

bar() {
  local done="${1:-0}" total="${2:-1}" width="${3:-42}"
  local filled empty
  [[ "${done}" =~ ^[0-9]+$ ]] || done=0
  [[ "${total}" =~ ^[1-9][0-9]*$ ]] || total=1
  (( done > total )) && done="${total}"
  filled=$((done * width / total))
  empty=$((width - filled))
  printf '['
  printf '%*s' "${filled}" '' | tr ' ' '#'
  printf '%*s' "${empty}" '' | tr ' ' '-'
  printf ']'
}

field() {
  local line="${1:-}" wanted="${2:-}" token
  for token in ${line}; do
    if [[ "${token%%=*}" == "${wanted}" ]]; then
      echo "${token#*=}"
      return 0
    fi
  done
  return 1
}

profile_index() {
  local wanted="${1:-}" i
  for ((i=0; i<TOTAL; i++)); do
    if [[ "${IDS[$i]}" == "${wanted}" ]]; then
      echo $((i+1))
      return 0
    fi
  done
  echo 0
}

profile_result() {
  local profile="${1:-}"
  grep -a '^PROFILE_RESULT ' "${LOG}" 2>/dev/null \
    | grep " profile=${profile} " | tail -n1 || true
}

stage_description() {
  case "${1:-}" in
    PATCHING*) echo "Генерация нового CUDA-ядра" ;;
    BUILDING*) echo "Сборка CUDA-кода, тестов и benchmark" ;;
    VALIDATING*) echo "ctest и 32 768 CPU/CUDA consensus-проверок" ;;
    BENCHMARKING*) echo "Серия длинных benchmark-прогонов" ;;
    STRESS_TESTING*) echo "Длинный тест стабильности лучшего кандидата" ;;
    *) echo "${1:-Подготовка}" ;;
  esac
}

while true; do
  printf '\033[H\033[2J'
  echo '================================================================================'
  echo ' PEPEPOW v0.8.0 GRAND UPDATE — EXACT SELECTOR + DUAL-NONCE ILP'
  echo ' ЦЕЛЬ: подтверждённые 2.000 MH/s, без CUDA/Xid и miner-caused rejects'
  echo '================================================================================'
  echo

  if [[ ! -f "${LOG}" ]]; then
    echo "Журнал ещё не создан: ${LOG}"
    echo "Следующая проверка через ${REFRESH} секунд."
    sleep "${REFRESH}"
    continue
  fi

  completed="$(grep -ac '^PROFILE_RESULT ' "${LOG}" 2>/dev/null || true)"
  valid="$(grep -a '^PROFILE_RESULT ' "${LOG}" 2>/dev/null | grep -c ' valid=1 ' || true)"
  failed="$(grep -a '^PROFILE_RESULT ' "${LOG}" 2>/dev/null | grep -c ' valid=0 ' || true)"
  current="$(grep -a '^PROFILE=' "${LOG}" 2>/dev/null | tail -n1 | cut -d= -f2-)"
  status_line="$(grep -a '^STATUS=' "${LOG}" 2>/dev/null | tail -n1)"
  status="${status_line#STATUS=}"
  config="$(grep -a '^PROFILE_CONFIG ' "${LOG}" 2>/dev/null | tail -n1)"
  [[ -n "${current}" ]] || current="инициализация"
  [[ -n "${status}" && "${status}" != "${status_line}" ]] || status="ПОДГОТОВКА"

  if screen -ls 2>/dev/null | grep -q "\.${SCREEN_NAME}[[:space:]]"; then
    state="РАБОТАЕТ"
  elif grep -aq 'V0.8.0 GRAND CAMPAIGN COMPLETE' "${LOG}" 2>/dev/null; then
    state="ЗАВЕРШЁН"
    completed="${TOTAL}"
  else
    state="ОСТАНОВЛЕН / ПРОВЕРЬТЕ ЖУРНАЛ"
  fi

  pct=$((completed * 100 / TOTAL))
  (( pct > 100 )) && pct=100

  echo 'ОБЩИЙ СТАТУС'
  echo '--------------------------------------------------------------------------------'
  echo "Состояние:          ${state}"
  echo "Всего профилей:     ${TOTAL}"
  echo "Завершено:          ${completed} из ${TOTAL} (валидных ${valid}, ошибок ${failed})"
  printf 'Общий прогресс:     '
  bar "${completed}" "${TOTAL}"
  printf ' %3d%%\n' "${pct}"
  echo "Обновление панели:  каждые ${REFRESH} секунд"
  echo

  index="$(profile_index "${current}")"
  echo 'ТЕКУЩЕЕ ЗАДАНИЕ'
  echo '--------------------------------------------------------------------------------'
  if (( index > 0 )); then
    echo "Профиль:            ${index} из ${TOTAL} — ${current}"
    echo "Назначение:         ${TITLES[$((index-1))]}"
  else
    echo "Профиль:            ${current}"
  fi
  echo "Этап:               ${status}"
  echo "Что выполняется:    $(stage_description "${status}")"
  if [[ -n "${config}" ]]; then
    echo "Конфигурация:       ${config#PROFILE_CONFIG }"
  fi

  last_bench="$(grep -a '^BENCH_RUN ' "${LOG}" 2>/dev/null \
    | grep " profile=${current} " | tail -n1 || true)"
  if [[ -n "${last_bench}" ]]; then
    run_token="$(field "${last_bench}" run || true)"
    hps="$(field "${last_bench}" hps || true)"
    run_now="${run_token%%/*}"
    run_total="${run_token##*/}"
    run_now=$((10#${run_now}))
    run_total=$((10#${run_total}))
    echo "Benchmark:          ${run_now} из ${run_total}"
    printf 'Прогресс benchmark: '
    bar "${run_now}" "${run_total}"
    printf '\n'
    if [[ "${hps}" =~ ^[0-9]+$ ]]; then
      mhs="$(awk -v h="${hps}" 'BEGIN{printf "%.6f",h/1000000}')"
      echo "Последний замер:    ${mhs} MH/s (${hps} H/s)"
      target_pct="$(awk -v h="${hps}" -v t="${TARGET_HPS}" 'BEGIN{printf "%.2f",100*h/t}')"
      echo "Доля цели 2 MH/s:   ${target_pct}%"
    fi
  else
    echo "Benchmark:          ещё не начался для текущего профиля"
  fi
  echo

  echo 'GPU RTX 3080'
  echo '--------------------------------------------------------------------------------'
  gpu="$(nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,clocks.current.sm,clocks.current.memory,power.draw,power.limit,fan.speed,memory.used \
    --format=csv,noheader,nounits 2>/dev/null | head -n1)"
  if [[ -n "${gpu}" ]]; then
    IFS=',' read -r temp util core mem power pl fan vram <<<"${gpu}"
    temp="${temp// /}"; util="${util// /}"; core="${core// /}"; mem="${mem// /}"
    power="${power// /}"; pl="${pl// /}"; fan="${fan// /}"; vram="${vram// /}"
    echo "Температура: ${temp}°C | Загрузка: ${util}% | Вентилятор: ${fan}%"
    echo "Core: ${core} MHz | Memory: ${mem} MHz | Мощность: ${power}/${pl} W | VRAM: ${vram} MiB"
  else
    echo "Данные nvidia-smi недоступны."
  fi
  echo

  echo 'РЕЗУЛЬТАТЫ ПРОФИЛЕЙ'
  echo '--------------------------------------------------------------------------------'
  printf '%-3s %-28s %-10s %-10s %-6s %-7s\n' \
    '#' 'Профиль' 'Статус' 'MH/s' 'Regs' 'Stack'
  for ((i=0; i<TOTAL; i++)); do
    profile="${IDS[$i]}"
    line="$(profile_result "${profile}")"
    if [[ -n "${line}" ]]; then
      ok="$(field "${line}" valid || echo 0)"
      if [[ "${ok}" == "1" ]]; then
        row_state="ГОТОВ"
        mh="$(field "${line}" median_mhs || echo -)"
        regs="$(field "${line}" registers || echo -)"
        stack="$(field "${line}" stack || echo -)"
      else
        row_state="ОШИБКА"; mh="-"; regs="-"; stack="-"
      fi
    elif [[ "${profile}" == "${current}" && "${state}" == "РАБОТАЕТ" ]]; then
      row_state="В РАБОТЕ"; mh="-"; regs="-"; stack="-"
    else
      row_state="ОЖИДАЕТ"; mh="-"; regs="-"; stack="-"
    fi
    printf '%-3d %-28s %-10s %-10s %-6s %-7s\n' \
      "$((i+1))" "${profile}" "${row_state}" "${mh}" "${regs}" "${stack}"
  done
  echo

  best="$(grep -a '^PROFILE_RESULT ' "${LOG}" 2>/dev/null | grep ' valid=1 ' | awk '
    {
      p="";h=0;m="";mode="";th="";bl="";rg="";st="";pw="";cl="";
      for(i=1;i<=NF;i++){
        split($i,a,"=");
        if(a[1]=="profile")p=a[2];
        else if(a[1]=="median_hps")h=a[2]+0;
        else if(a[1]=="median_mhs")m=a[2];
        else if(a[1]=="mode")mode=a[2];
        else if(a[1]=="threads")th=a[2];
        else if(a[1]=="min_blocks")bl=a[2];
        else if(a[1]=="registers")rg=a[2];
        else if(a[1]=="stack")st=a[2];
        else if(a[1]=="power_mean_w")pw=a[2];
        else if(a[1]=="clock_mean_mhz")cl=a[2];
      }
      if(h>best){best=h;bp=p;bm=m;bmode=mode;bth=th;bbl=bl;brg=rg;bst=st;bpw=pw;bcl=cl}
    }
    END{if(best>0)printf "%s|%s|%d|%s|%s|%s|%s|%s|%s|%s",bp,bm,best,bmode,bth,bbl,brg,bst,bpw,bcl}
  ')"
  baseline_line="$(profile_result baseline-t64-b2)"
  baseline_hps="$(field "${baseline_line}" median_hps 2>/dev/null || echo 0)"

  echo 'ЛУЧШИЙ РЕЗУЛЬТАТ НА ДАННЫЙ МОМЕНТ'
  echo '--------------------------------------------------------------------------------'
  if [[ -n "${best}" ]]; then
    IFS='|' read -r bp bm bh bmode bth bbl brg bst bpw bcl <<<"${best}"
    echo "Профиль:            ${bp}"
    echo "Хешрейт:            ${bm} MH/s (${bh} H/s)"
    echo "Архитектура:        ${bmode} | threads ${bth} | min blocks ${bbl}"
    echo "Ресурсы:            ${brg} регистров | stack ${bst} B"
    echo "Средние GPU:        ${bcl} MHz | ${bpw} W"
    if [[ "${baseline_hps}" =~ ^[1-9][0-9]*$ ]]; then
      delta="$(awk -v best="${bh}" -v base="${baseline_hps}" 'BEGIN{printf "%+.4f",(best/base-1)*100}')"
      echo "Прирост к baseline: ${delta}%"
    fi
    gap="$(awk -v best="${bh}" -v target="${TARGET_HPS}" 'BEGIN{printf "%.4f",(target-best)/target*100}')"
    echo "До 2.000 MH/s:      ${gap}%"
    progress_units=$((bh * 42 / TARGET_HPS))
    (( progress_units > 42 )) && progress_units=42
    printf 'Шкала цели:         '
    bar "${progress_units}" 42 42
    printf ' %.2f%%\n' "$(awk -v h="${bh}" -v t="${TARGET_HPS}" 'BEGIN{print 100*h/t}')"
  else
    echo "Пока нет завершённых валидных профилей."
  fi
  echo

  if [[ "${state}" == "ЗАВЕРШЁН" ]]; then
    echo 'ИТОГ, STRESS-GATE И ССЫЛКИ'
    echo '--------------------------------------------------------------------------------'
    grep -aE '^(profiles_|baseline_|best_|uplift_|target_|projected_|stress_gate|grand_gate|ARCHIVE=|SHA256_FILE=|LOCAL_|PUBLIC_|DOWNLOAD_)' \
      "${LOG}" 2>/dev/null | tail -n80 || true
    echo
    echo "Панель остановлена: кампания завершена."
    break
  fi

  if [[ "${state}" == "ОСТАНОВЛЕН / ПРОВЕРЬТЕ ЖУРНАЛ" ]]; then
    echo 'ПОСЛЕДНИЕ СТРОКИ ЖУРНАЛА'
    echo '--------------------------------------------------------------------------------'
    tail -n50 "${LOG}" 2>/dev/null || true
    echo
    echo "Тест завершился до полного результата."
    break
  fi

  echo "Журнал: ${LOG}"
  echo "Screen: ${SCREEN_NAME}"
  echo "Ctrl+C закрывает только панель; кампания продолжится в screen."
  sleep "${REFRESH}"
done
