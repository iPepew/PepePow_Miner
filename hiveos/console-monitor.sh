#!/usr/bin/env bash
set -u

miner_dir="${1:?miner directory required}"
interval="${2:-10}"
workers_file="${miner_dir}/active-workers.env"

[[ -r "${workers_file}" ]] || { echo "[ERROR] active workers file is missing" >&2; exit 1; }
# shellcheck disable=SC1090
source "${workers_file}"

trim_field() {
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s' "${value}"
}

read_value() {
  local file="$1" key="$2" value=""
  [[ -r "${file}" ]] && value="$(sed -n "s/^${key}=//p" "${file}" 2>/dev/null | tail -n1)"
  printf '%s' "${value}"
}

short_name() {
  local value="$1" max="${2:-19}"
  if (( ${#value} > max )); then
    printf '%s' "${value:0:max-1}~"
  else
    printf '%s' "${value}"
  fi
}

format_mhs() {
  local hps="${1:-0}"
  [[ "${hps}" =~ ^[0-9]+$ ]] || hps=0
  awk -v value="${hps}" 'BEGIN { printf "%.3f", value/1000000.0 }'
}

format_eff() {
  local hps="${1:-0}" power="${2:-0}"
  [[ "${hps}" =~ ^[0-9]+$ ]] || hps=0
  [[ "${power}" =~ ^[0-9]+([.][0-9]+)?$ ]] || power=0
  awk -v hps="${hps}" -v power="${power}" 'BEGIN { if (power > 0) printf "%.1f", hps/1000.0/power; else printf "0.0" }'
}

declare -a gpu_list event_logs
IFS=',' read -r -a gpu_list <<<"${GPU_LIST:-}"
(( ${#gpu_list[@]} > 0 )) || { echo "[ERROR] no active GPUs in workers file" >&2; exit 1; }

package_name="$(basename "${miner_dir}")"
log_root="/var/log/miner/custom/${package_name}"
for index in "${gpu_list[@]}"; do
  event_logs+=("${log_root}/gpu${index}/pepew.log")
done

event_fifo="${miner_dir}/.console-events.$$.fifo"
rm -f "${event_fifo}"
mkfifo "${event_fifo}"
tail -n 0 -q -F "${event_logs[@]}" >"${event_fifo}" 2>/dev/null &
event_tail_pid=$!
(
  while IFS= read -r event_line; do
    case "${event_line}" in
      \[HOOHASH\]*|\[POOL\]*|\[DIFF\]*|\[JOB\]*|\[ACCEPTED\]*|\[REJECTED\]*|\[ERROR\]*)
        printf '%s\n' "${event_line}"
        ;;
    esac
  done <"${event_fifo}"
) &
event_reader_pid=$!

cleanup_monitor() {
  kill "${event_reader_pid}" "${event_tail_pid}" 2>/dev/null || true
  wait "${event_reader_pid}" "${event_tail_pid}" 2>/dev/null || true
  rm -f "${event_fifo}"
}
trap cleanup_monitor EXIT INT TERM

while :; do
  declare -A temp fan power core mem
  while IFS=',' read -r raw_index raw_temp raw_fan raw_power raw_core raw_mem; do
    index="$(trim_field "${raw_index}")"
    [[ "${index}" =~ ^[0-9]+$ ]] || continue
    temp["${index}"]="$(trim_field "${raw_temp}")"
    fan["${index}"]="$(trim_field "${raw_fan}")"
    power["${index}"]="$(trim_field "${raw_power}")"
    core["${index}"]="$(trim_field "${raw_core}")"
    mem["${index}"]="$(trim_field "${raw_mem}")"
  done < <(nvidia-smi \
    --query-gpu=index,temperature.gpu,fan.speed,power.draw,clocks.current.graphics,clocks.current.memory \
    --format=csv,noheader,nounits 2>/dev/null || true)

  cols="$(tput cols 2>/dev/null || printf '120')"
  [[ "${cols}" =~ ^[0-9]+$ ]] || cols=120
  total_hps=0
  total_power=0
  total_a=0
  total_r=0
  max_uptime=0

  printf '\n[STATS] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  if (( cols >= 100 )); then
    printf '%-3s %-20s %10s %5s %5s %7s %6s %6s %5s %5s %9s\n' \
      ID GPU HASHRATE TEMP FAN POWER CORE MEM A R EFF_kH_W
    printf '%s\n' '------------------------------------------------------------------------------------------------'
  fi

  for index in "${gpu_list[@]}"; do
    status_file="${miner_dir}/gpu${index}/miner-status.env"
    hps="$(read_value "${status_file}" HPS)"
    accepted="$(read_value "${status_file}" ACCEPTED)"
    rejected="$(read_value "${status_file}" REJECTED)"
    uptime="$(read_value "${status_file}" UPTIME)"
    state="$(read_value "${status_file}" STATE)"
    profile="$(read_value "${status_file}" PROFILE)"
    name_var="GPU${index}_NAME"
    profile_var="GPU${index}_PROFILE"
    name="${!name_var:-GPU ${index}}"
    [[ -n "${profile}" ]] || profile="${!profile_var:-unknown}"

    [[ "${hps}" =~ ^[0-9]+$ ]] || hps=0
    [[ "${accepted}" =~ ^[0-9]+$ ]] || accepted=0
    [[ "${rejected}" =~ ^[0-9]+$ ]] || rejected=0
    [[ "${uptime}" =~ ^[0-9]+$ ]] || uptime=0
    gpu_power="${power[${index}]:-0}"
    [[ "${gpu_power}" =~ ^[0-9]+([.][0-9]+)?$ ]] || gpu_power=0

    mhs="$(format_mhs "${hps}")"
    eff="$(format_eff "${hps}" "${gpu_power}")"
    total_hps=$((total_hps + hps))
    total_a=$((total_a + accepted))
    total_r=$((total_r + rejected))
    (( uptime > max_uptime )) && max_uptime="${uptime}"
    total_power="$(awk -v a="${total_power}" -v b="${gpu_power}" 'BEGIN { printf "%.1f", a+b }')"

    if (( cols >= 100 )); then
      printf '%-3s %-20s %7s MH/s %4sC %4s%% %6sW %6s %6s %5s %5s %9s\n' \
        "${index}" "$(short_name "${name}" 20)" "${mhs}" \
        "${temp[${index}]:-0}" "${fan[${index}]:-0}" "${gpu_power}" \
        "${core[${index}]:-0}" "${mem[${index}]:-0}" \
        "${accepted}" "${rejected}" "${eff}"
      printf '    state=%s profile=%s\n' "${state:-waiting}" "${profile:-unknown}"
    else
      printf 'GPU%s %s MH/s %sC %s%% %sW A%s R%s %s kH/W %s\n' \
        "${index}" "${mhs}" "${temp[${index}]:-0}" "${fan[${index}]:-0}" \
        "${gpu_power}" "${accepted}" "${rejected}" "${eff}" "${state:-waiting}"
    fi
  done

  total_mhs="$(format_mhs "${total_hps}")"
  printf '%s\n' '------------------------------------------------------------------------------------------------'
  printf 'TOTAL %s MH/s | POWER %s W | A %s | R %s | UP %ss\n' \
    "${total_mhs}" "${total_power}" "${total_a}" "${total_r}" "${max_uptime}"

  sleep "${interval}" || exit 0
done
