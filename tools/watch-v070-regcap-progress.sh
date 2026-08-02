#!/usr/bin/env bash
set -u

LOG="${1:-/root/v070-regcap.log}"
REFRESH="${REFRESH:-2}"
TOTAL="${TOTAL:-9}"
SCREEN_NAME="${SCREEN_NAME:-v070-regcap}"

bar() {
  local done="$1" total="$2" width=34 filled empty
  (( total > 0 )) || total=1
  filled=$(( done * width / total ))
  (( filled > width )) && filled=$width
  empty=$(( width - filled ))
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

while true; do
  clear
  printf '%s\n' '======================================================================'
  printf '%s\n' ' PEPEPOW v0.7.0 EXPERIMENT — REAL REGISTER-CAP MATRIX'
  printf '%s\n' '======================================================================'
  echo

  if [[ ! -f "$LOG" ]]; then
    echo "Журнал ещё не создан: $LOG"
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

  start_epoch="$(stat -c %W "$LOG" 2>/dev/null || echo 0)"
  [[ "$start_epoch" =~ ^[0-9]+$ ]] || start_epoch=0
  (( start_epoch > 0 )) || start_epoch="$(stat -c %Y "$LOG" 2>/dev/null || date +%s)"
  now="$(date +%s)"
  elapsed=$((now - start_epoch))

  if screen -ls 2>/dev/null | grep -q "\.${SCREEN_NAME}[[:space:]]"; then
    run_state='РАБОТАЕТ'
  elif grep -aq 'V0.7.0 REAL REGISTER-CAP MATRIX COMPLETE' "$LOG" 2>/dev/null; then
    run_state='ЗАВЕРШЁН'
    completed="$TOTAL"
  else
    run_state='ОСТАНОВЛЕН / ПРОВЕРЬТЕ ЖУРНАЛ'
  fi

  pct=$(( completed * 100 / TOTAL ))
  (( pct > 100 )) && pct=100

  echo "СОСТОЯНИЕ:       $run_state"
  echo "ТЕКУЩИЙ ПРОФИЛЬ: $current"
  echo "ЭТАП:            $status"
  printf 'ПРОГРЕСС:        '; bar "$completed" "$TOTAL"; printf ' %3d%%  (%d/%d)\n' "$pct" "$completed" "$TOTAL"
  echo "УСПЕШНО:         $valid"
  echo "ОШИБОК:          $failed"
  echo "ВРЕМЯ:           $(human_elapsed "$elapsed")"
  echo

  gpu="$(nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,clocks.current.sm,power.draw --format=csv,noheader,nounits 2>/dev/null | head -n1)"
  if [[ -n "$gpu" ]]; then
    IFS=',' read -r temp util clock power <<<"$gpu"
    temp="${temp// /}"; util="${util// /}"; clock="${clock// /}"; power="${power// /}"
    echo "GPU: ${temp}°C | ${util}% | ${clock} MHz | ${power} W"
  else
    echo 'GPU: данные nvidia-smi недоступны'
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

  echo 'ЛУЧШИЙ ПРОФИЛЬ'
  echo '----------------------------------------------------------------------'
  if [[ -n "$best" ]]; then
    IFS='|' read -r bp bm bh br bst bss bsl <<<"$best"
    echo "Профиль: $bp"
    echo "Хешрейт: $bm MH/s  ($bh H/s)"
    echo "Регистры: $br | Stack: $bst B | Spills store/load: $bss/$bsl B"
  else
    echo 'Пока нет завершённых валидных профилей.'
  fi
  echo

  echo 'ПОСЛЕДНИЕ РЕЗУЛЬТАТЫ'
  echo '----------------------------------------------------------------------'
  grep -a '^PROFILE_RESULT ' "$LOG" 2>/dev/null | tail -n5 || true
  echo
  echo "Журнал: $LOG"
  echo "Screen: $SCREEN_NAME"
  echo 'Ctrl+C закрывает только эту панель; тест продолжится в screen.'

  [[ "$run_state" == 'ЗАВЕРШЁН' ]] && break
  sleep "$REFRESH"
done
