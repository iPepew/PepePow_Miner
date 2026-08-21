#!/usr/bin/env bash

khs=0
stats="null"

miner_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log_base="${CUSTOM_LOG_BASENAME:-/var/log/miner/custom/PepeW-Miner/pepew}"
log_file="${log_base}.log"

if [[ ! -s "${log_file}" ]]; then
  return 0 2>/dev/null || exit 0
fi

now_epoch=$(date +%s)
log_mtime=$(stat -c %Y "${log_file}" 2>/dev/null || echo 0)
if (( now_epoch - log_mtime > 30 )); then
  return 0 2>/dev/null || exit 0
fi

line=$(grep -a '^\[MINING\]' "${log_file}" 2>/dev/null | tail -n 1)
if [[ -z "${line}" ]]; then
  return 0 2>/dev/null || exit 0
fi

mhs=$(printf '%s\n' "${line}" | awk '{print $2}')
accepted=$(printf '%s\n' "${line}" | awk '{for (i=1;i<=NF;i++) if ($i=="A") {print $(i+1); exit}}')
rejected=$(printf '%s\n' "${line}" | awk '{for (i=1;i<=NF;i++) if ($i=="R") {print $(i+1); exit}}')
uptime_text=$(printf '%s\n' "${line}" | awk '{for (i=1;i<=NF;i++) if ($i=="UP") {print $(i+1); exit}}')

[[ "${mhs}" =~ ^[0-9]+([.][0-9]+)?$ ]] || mhs=0
[[ "${accepted}" =~ ^[0-9]+$ ]] || accepted=0
[[ "${rejected}" =~ ^[0-9]+$ ]] || rejected=0
[[ "${uptime_text}" =~ ^[0-9]+:[0-9][0-9]:[0-9][0-9]$ ]] || uptime_text="00:00:00"

IFS=: read -r uptime_hours uptime_minutes uptime_seconds_part <<< "${uptime_text}"
uptime_seconds=$((10#${uptime_hours} * 3600 + 10#${uptime_minutes} * 60 + 10#${uptime_seconds_part}))
khs=$(awk -v mhs="${mhs}" 'BEGIN { printf "%.0f", mhs * 1000.0 }')

version="${CUSTOM_VERSION:-}"
if [[ -z "${version}" || "${version}" == "dev" ]]; then
  build_info="${miner_dir}/BUILD_INFO.txt"
  if [[ -s "${build_info}" ]]; then
    build_version=$(awk -F= '$1=="version" {print $2; exit}' "${build_info}")
    [[ -n "${build_version}" ]] && version="${build_version}"
  fi
fi
[[ -n "${version}" ]] || version="v1.0.4-recovery"
display_version="${version} A${accepted}/R${rejected}"

gpu_temp=0
gpu_fan=0
gpu_bus=0
if command -v nvidia-smi >/dev/null 2>&1; then
  IFS=',' read -r pci_bus_id smi_temp smi_fan < <(nvidia-smi --query-gpu=pci.bus_id,temperature.gpu,fan.speed --format=csv,noheader,nounits -i 0 2>/dev/null | head -n1)
  pci_bus_id=$(printf '%s' "${pci_bus_id:-}" | xargs)
  smi_temp=$(printf '%s' "${smi_temp:-}" | xargs)
  smi_fan=$(printf '%s' "${smi_fan:-}" | xargs)
  [[ "${smi_temp}" =~ ^[0-9]+([.][0-9]+)?$ ]] && gpu_temp="${smi_temp%.*}"
  [[ "${smi_fan}" =~ ^[0-9]+([.][0-9]+)?$ ]] && gpu_fan="${smi_fan%.*}"
  bus_hex=$(printf '%s' "${pci_bus_id}" | awk -F: '{if (NF >= 3) print $(NF-1)}')
  [[ "${bus_hex}" =~ ^[0-9A-Fa-f]+$ ]] && gpu_bus=$((16#${bus_hex}))
fi

stats=$(printf '{"hs":[%s],"hs_units":"khs","temp":[%s],"fan":[%s],"uptime":%s,"ar":[%s,%s],"ver":"%s","algo":"hoohash","bus_numbers":[%s]}' \
  "${khs}" "${gpu_temp}" "${gpu_fan}" "${uptime_seconds}" "${accepted}" "${rejected}" "${display_version}" "${gpu_bus}")
