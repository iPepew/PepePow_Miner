#!/usr/bin/env bash
set -u

miner_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
status_file="${PEPEW_STATUS_FILE:-${miner_dir}/miner-status.env}"
miner_pid_file="${miner_dir}/miner.pid"
console_log="/var/log/miner/custom/$(basename "${miner_dir}")/pepew.log"

if [[ ! -r "${status_file}" && -r /tmp/miner-status.env ]]; then
  status_file=/tmp/miner-status.env
fi

read_numeric() {
  local key="$1" value=""
  [[ -r "${status_file}" ]] && value="$(sed -n "s/^${key}=//p" "${status_file}" 2>/dev/null | tail -n1)"
  [[ "${value}" =~ ^[0-9]+$ ]] && printf '%s' "${value}" || printf '0'
}
trim_field() {
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s' "${value}"
}
array_json() { local IFS=,; printf '[%s]' "$*"; }

accepted="$(read_numeric ACCEPTED)"
rejected="$(read_numeric REJECTED)"
uptime="$(read_numeric UPTIME)"
updated="$(read_numeric UPDATED_EPOCH)"
status_pid="$(read_numeric PID)"
total_hps="$(read_numeric HPS)"
status_gpu_count="$(read_numeric GPU_COUNT)"
nvidia_gpu_count="$(nvidia-smi -L 2>/dev/null | grep -c '^GPU ' || true)"
[[ "${nvidia_gpu_count}" =~ ^[0-9]+$ ]] || nvidia_gpu_count=0
[[ "${status_gpu_count}" =~ ^[0-9]+$ ]] || status_gpu_count=0

gpu_count="${status_gpu_count}"
(( nvidia_gpu_count > gpu_count )) && gpu_count="${nvidia_gpu_count}"
(( gpu_count >= 1 && gpu_count <= 16 )) || gpu_count=1

file_pid=0
if [[ -r "${miner_pid_file}" ]]; then
  candidate="$(tr -dc '0-9' < "${miner_pid_file}" 2>/dev/null || true)"
  [[ "${candidate}" =~ ^[0-9]+$ ]] && file_pid="${candidate}"
fi
pid=0
for candidate in "${status_pid}" "${file_pid}"; do
  if [[ "${candidate}" =~ ^[1-9][0-9]*$ ]] && kill -0 "${candidate}" 2>/dev/null; then
    exe="$(readlink -f "/proc/${candidate}/exe" 2>/dev/null || true)"
    [[ "${exe}" == "${miner_dir}/pepepowminer" ]] && { pid="${candidate}"; break; }
  fi
done

now="$(date +%s)"
if [[ "${PEPEW_STATS_SELFTEST:-0}" == "1" ]]; then
  pid=$$
  updated="${now}"
fi
fresh=1
if [[ ${pid} -eq 0 || ${updated} -eq 0 || ${now} -lt ${updated} || $((now-updated)) -gt 45 ]]; then
  fresh=0
fi
if [[ ${pid} -eq 0 ]]; then
  uptime=0
elif [[ "${PEPEW_STATS_SELFTEST:-0}" != "1" ]]; then
  process_uptime="$(ps -o etimes= -p "${pid}" 2>/dev/null | tr -d ' ' || true)"
  [[ "${process_uptime}" =~ ^[0-9]+$ ]] && uptime="${process_uptime}"
fi

if [[ ${fresh} -eq 0 && ${pid} -ne 0 && -r "${console_log}" ]]; then
  latest_mhs="$(grep -a '\[MINING\]' "${console_log}" 2>/dev/null | tail -n1 | sed -nE 's/.*\|[[:space:]]*([0-9]+([.][0-9]+)?) MH\/s.*/\1/p')"
  if [[ "${latest_mhs}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    total_hps="$(awk -v value="${latest_mhs}" 'BEGIN { printf "%.0f", value*1000000 }')"
    fresh=1
  fi
fi
[[ ${fresh} -eq 1 ]] || total_hps=0

declare -a gpu_hs gpu_temp gpu_fan gpu_bus
for ((i=0; i<gpu_count; ++i)); do
  device_hps="$(read_numeric "GPU${i}_HPS")"
  [[ ${device_hps} -eq 0 && ${gpu_count} -eq 1 ]] && device_hps="${total_hps}"
  [[ ${fresh} -eq 1 ]] || device_hps=0
  gpu_hs[$i]=$(((device_hps+500)/1000))
  gpu_temp[$i]=0
  gpu_fan[$i]=0
  gpu_bus[$i]="${i}"
done

while IFS=',' read -r raw_index raw_bus raw_temp raw_fan; do
  index="$(trim_field "${raw_index}")"
  [[ "${index}" =~ ^[0-9]+$ ]] || continue
  (( index < gpu_count )) || continue
  temp="$(trim_field "${raw_temp}")"
  fan="$(trim_field "${raw_fan}")"
  bus="$(trim_field "${raw_bus}")"
  [[ "${temp}" =~ ^[0-9]+$ ]] && gpu_temp[$index]="${temp}"
  [[ "${fan}" =~ ^[0-9]+$ ]] && gpu_fan[$index]="${fan}"
  bus_tail="${bus#*:}"
  bus_hex="${bus_tail%%:*}"
  [[ "${bus_hex}" =~ ^[0-9A-Fa-f]{1,2}$ ]] && gpu_bus[$index]=$((16#${bus_hex}))
done < <(nvidia-smi --query-gpu=index,pci.bus_id,temperature.gpu,fan.speed --format=csv,noheader,nounits 2>/dev/null || true)

hs_json="$(array_json "${gpu_hs[@]}")"
temp_json="$(array_json "${gpu_temp[@]}")"
fan_json="$(array_json "${gpu_fan[@]}")"
bus_json="$(array_json "${gpu_bus[@]}")"

khs=0
for value in "${gpu_hs[@]}"; do khs=$((khs+value)); done
[[ ${khs} -eq 0 && ${total_hps} -gt 0 ]] && khs=$(((total_hps+500)/1000))

stats=$(printf '{"hs":%s,"hs_units":"khs","temp":%s,"fan":%s,"uptime":%s,"ar":[%s,%s,0],"bus_numbers":%s,"ver":"1.0.3","algo":"hoohash"}' \
  "${hs_json}" "${temp_json}" "${fan_json}" "${uptime}" \
  "${accepted}" "${rejected}" "${bus_json}")
