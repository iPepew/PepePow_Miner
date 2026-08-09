#!/usr/bin/env bash
set -u

miner_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package_name="$(basename "${miner_dir}")"
status_root="${PEPEW_STATUS_ROOT:-${miner_dir}}"
log_root="${PEPEW_LOG_ROOT:-/var/log/miner/custom/${package_name}}"
now="${PEPEW_NOW_EPOCH:-$(date +%s)}"

trim_field() {
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s' "${value}"
}

read_numeric_from() {
  local file="$1" key="$2" value=""
  [[ -r "${file}" ]] && value="$(sed -n "s/^${key}=//p" "${file}" 2>/dev/null | tail -n1)"
  [[ "${value}" =~ ^[0-9]+$ ]] && printf '%s' "${value}" || printf '0'
}

array_json() {
  local IFS=,
  printf '[%s]' "$*"
}

nvidia_rows() {
  if [[ -n "${PEPEW_NVIDIA_SMI_FILE:-}" ]]; then
    cat "${PEPEW_NVIDIA_SMI_FILE}"
  else
    nvidia-smi --query-gpu=index,pci.bus_id,temperature.gpu,fan.speed \
      --format=csv,noheader,nounits 2>/dev/null || true
  fi
}

declare -a gpu_indices gpu_hs gpu_temp gpu_fan gpu_bus
total_accepted=0
total_rejected=0
uptime=0

while IFS=',' read -r raw_index raw_bus raw_temp raw_fan; do
  index="$(trim_field "${raw_index}")"
  bus="$(trim_field "${raw_bus}")"
  temp="$(trim_field "${raw_temp}")"
  fan="$(trim_field "${raw_fan}")"
  [[ "${index}" =~ ^[0-9]+$ ]] || continue

  status_file="${status_root}/gpu${index}/miner-status.env"
  pid_file="${status_root}/gpu${index}/miner.pid"
  console_log="${log_root}/gpu${index}/pepew.log"

  hps="$(read_numeric_from "${status_file}" HPS)"
  accepted="$(read_numeric_from "${status_file}" ACCEPTED)"
  rejected="$(read_numeric_from "${status_file}" REJECTED)"
  worker_uptime="$(read_numeric_from "${status_file}" UPTIME)"
  updated="$(read_numeric_from "${status_file}" UPDATED_EPOCH)"
  status_pid="$(read_numeric_from "${status_file}" PID)"
  file_pid="$(tr -dc '0-9' < "${pid_file}" 2>/dev/null || true)"
  [[ "${file_pid}" =~ ^[0-9]+$ ]] || file_pid=0

  pid=0
  if [[ "${PEPEW_STATS_SELFTEST:-0}" == "1" ]]; then
    pid=$$
    updated="${now}"
  else
    for candidate in "${status_pid}" "${file_pid}"; do
      if [[ "${candidate}" =~ ^[1-9][0-9]*$ ]] && kill -0 "${candidate}" 2>/dev/null; then
        exe="$(readlink -f "/proc/${candidate}/exe" 2>/dev/null || true)"
        if [[ "${exe}" == "${miner_dir}/pepepowminer" ]]; then
          pid="${candidate}"
          break
        fi
      fi
    done
  fi

  fresh=1
  if [[ ${pid} -eq 0 || ${updated} -eq 0 || ${now} -lt ${updated} || $((now-updated)) -gt 45 ]]; then
    fresh=0
  fi

  if [[ ${fresh} -eq 0 && ${pid} -ne 0 && -r "${console_log}" ]]; then
    latest_mhs="$(grep -a '\[MINING\]' "${console_log}" 2>/dev/null | tail -n1 | sed -nE 's/.*\[MINING\][[:space:]]+([0-9]+([.][0-9]+)?) MH\/s.*/\1/p')"
    if [[ "${latest_mhs}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      hps="$(awk -v value="${latest_mhs}" 'BEGIN { printf "%.0f", value*1000000 }')"
      fresh=1
    fi
  fi

  if [[ ${fresh} -eq 0 ]]; then
    hps=0
  elif [[ "${PEPEW_STATS_SELFTEST:-0}" != "1" ]]; then
    process_uptime="$(ps -o etimes= -p "${pid}" 2>/dev/null | tr -d ' ' || true)"
    [[ "${process_uptime}" =~ ^[0-9]+$ ]] && worker_uptime="${process_uptime}"
  fi

  gpu_indices+=("${index}")
  gpu_hs+=("$(((hps+500)/1000))")
  [[ "${temp}" =~ ^[0-9]+$ ]] || temp=0
  [[ "${fan}" =~ ^[0-9]+$ ]] || fan=0
  gpu_temp+=("${temp}")
  gpu_fan+=("${fan}")

  bus_tail="${bus#*:}"
  bus_hex="${bus_tail%%:*}"
  if [[ "${bus_hex}" =~ ^[0-9A-Fa-f]{1,2}$ ]]; then
    gpu_bus+=("$((16#${bus_hex}))")
  else
    gpu_bus+=("${index}")
  fi

  total_accepted=$((total_accepted + accepted))
  total_rejected=$((total_rejected + rejected))
  (( worker_uptime > uptime )) && uptime="${worker_uptime}"
done < <(nvidia_rows)

if (( ${#gpu_indices[@]} == 0 )); then
  gpu_hs=(0)
  gpu_temp=(0)
  gpu_fan=(0)
  gpu_bus=(0)
fi

khs=0
for value in "${gpu_hs[@]}"; do khs=$((khs + value)); done

hs_json="$(array_json "${gpu_hs[@]}")"
temp_json="$(array_json "${gpu_temp[@]}")"
fan_json="$(array_json "${gpu_fan[@]}")"
bus_json="$(array_json "${gpu_bus[@]}")"

stats=$(printf '{"hs":%s,"hs_units":"khs","temp":%s,"fan":%s,"uptime":%s,"ar":[%s,%s,0],"bus_numbers":%s,"ver":"1.0.5","algo":"hoohash"}' \
  "${hs_json}" "${temp_json}" "${fan_json}" "${uptime}" \
  "${total_accepted}" "${total_rejected}" "${bus_json}")
