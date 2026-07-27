#!/usr/bin/env bash
set -u

miner_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
status_file="${miner_dir}/miner-status.env"
miner_pid_file="${miner_dir}/miner.pid"

read_numeric() {
  local key="$1"
  local value=""
  if [[ -r "${status_file}" ]]; then
    value="$(sed -n "s/^${key}=//p" "${status_file}" 2>/dev/null | tail -n1)"
  fi
  [[ "${value}" =~ ^[0-9]+$ ]] && printf '%s' "${value}" || printf '0'
}

accepted="$(read_numeric ACCEPTED)"
rejected="$(read_numeric REJECTED)"
uptime="$(read_numeric UPTIME)"
updated="$(read_numeric UPDATED_EPOCH)"
status_pid="$(read_numeric PID)"
gpu_count="$(read_numeric GPU_COUNT)"

if [[ ! "${gpu_count}" =~ ^[1-9][0-9]*$ ]] || [[ ${gpu_count} -gt 16 ]]; then
  gpu_count="$(nvidia-smi -L 2>/dev/null | grep -c '^GPU ' || true)"
fi
[[ "${gpu_count}" =~ ^[1-9][0-9]*$ ]] || gpu_count=1

file_pid=0
if [[ -r "${miner_pid_file}" ]]; then
  candidate="$(tr -dc '0-9' < "${miner_pid_file}" 2>/dev/null || true)"
  [[ "${candidate}" =~ ^[0-9]+$ ]] && file_pid="${candidate}"
fi

pid=0
for candidate in "${status_pid}" "${file_pid}"; do
  if [[ "${candidate}" =~ ^[1-9][0-9]*$ ]] && kill -0 "${candidate}" 2>/dev/null; then
    exe="$(readlink -f "/proc/${candidate}/exe" 2>/dev/null || true)"
    if [[ "${exe}" == "${miner_dir}/pepepowminer" ]]; then
      pid="${candidate}"
      break
    fi
  fi
done

now="$(date +%s)"
fresh=1
if [[ ${pid} -eq 0 || ${updated} -eq 0 || ${now} -lt ${updated} || $((now - updated)) -gt 20 ]]; then
  fresh=0
fi
if [[ ${pid} -eq 0 ]]; then
  uptime=0
else
  process_uptime="$(ps -o etimes= -p "${pid}" 2>/dev/null | tr -d ' ' || true)"
  [[ "${process_uptime}" =~ ^[0-9]+$ ]] && uptime="${process_uptime}"
fi

declare -a gpu_hps gpu_temp gpu_fan gpu_bus
for ((i=0; i<gpu_count; ++i)); do
  value="$(read_numeric "GPU${i}_HPS")"
  [[ ${fresh} -eq 1 ]] || value=0
  gpu_hps[$i]="${value}"
  gpu_temp[$i]=0
  gpu_fan[$i]=0
  gpu_bus[$i]="${i}"
done

trim_field() {
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s' "${value}"
}

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
  if [[ "${bus_hex}" =~ ^[0-9A-Fa-f]{1,2}$ ]]; then
    gpu_bus[$index]=$((16#${bus_hex}))
  fi
done < <(nvidia-smi --query-gpu=index,pci.bus_id,temperature.gpu,fan.speed --format=csv,noheader,nounits 2>/dev/null || true)

array_json() {
  local IFS=,
  printf '[%s]' "$*"
}

hs_json="$(array_json "${gpu_hps[@]}")"
temp_json="$(array_json "${gpu_temp[@]}")"
fan_json="$(array_json "${gpu_fan[@]}")"
bus_json="$(array_json "${gpu_bus[@]}")"

total_hps=0
for value in "${gpu_hps[@]}"; do
  total_hps=$((total_hps + value))
done
khs=$((total_hps / 1000))

# HiveOS expects one hashrate value per device plus matching temperature, fan
# and PCI bus arrays. The empty version prevents a duplicate suffix after (c).
stats=$(printf '{"hs":%s,"hs_units":"hs","temp":%s,"fan":%s,"uptime":%s,"ar":[%s,%s,0],"bus_numbers":%s,"ver":"","algo":"hoohash"}' \
  "${hs_json}" "${temp_json}" "${fan_json}" "${uptime}" \
  "${accepted}" "${rejected}" "${bus_json}")
