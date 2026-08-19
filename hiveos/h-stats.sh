#!/usr/bin/env bash

# HiveOS sources this callback. It must always define both khs and stats and
# must never terminate the parent agent shell.
khs=0
stats="null"

miner_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log_base="${CUSTOM_LOG_BASENAME:-/var/log/miner/custom/PepeW-Miner/pepew}"
log_file="${log_base}.log"

if [[ ! -s "${log_file}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# Do not keep reporting stale miner telemetry after a stop/crash.
now_epoch=$(date +%s)
log_mtime=$(stat -c %Y "${log_file}" 2>/dev/null || echo 0)
if (( now_epoch - log_mtime > 30 )); then
  return 0 2>/dev/null || exit 0
fi

# Aggregate line is authoritative for total speed, uptime and pool counters.
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

# Hive normally exports CUSTOM_VERSION from h-manifest.conf. Fall back to the
# immutable BUILD_INFO written by CI so the dashboard never degrades to v.dev.
version="${CUSTOM_VERSION:-}"
if [[ -z "${version}" || "${version}" == "dev" ]]; then
  build_info="${miner_dir}/BUILD_INFO.txt"
  if [[ -s "${build_info}" ]]; then
    build_version=$(awk -F= '$1=="version" {print $2; exit}' "${build_info}")
    [[ -n "${build_version}" ]] && version="${build_version}"
  fi
fi
[[ -n "${version}" ]] || version="dev"

# Read hardware telemetry once. Arrays are keyed by CUDA/NVIDIA index so that
# hs[], temp[], fan[] and bus_numbers[] describe the same physical card.
gpu_count=0
declare -a gpu_temp=()
declare -a gpu_fan=()
declare -a gpu_bus=()
if command -v nvidia-smi >/dev/null 2>&1; then
  while IFS=',' read -r smi_index pci_bus_id smi_temp smi_fan; do
    smi_index=$(printf '%s' "${smi_index}" | xargs)
    pci_bus_id=$(printf '%s' "${pci_bus_id}" | xargs)
    smi_temp=$(printf '%s' "${smi_temp}" | xargs)
    smi_fan=$(printf '%s' "${smi_fan}" | xargs)

    [[ "${smi_index}" =~ ^[0-9]+$ ]] || continue
    gpu_id=$((10#${smi_index}))
    (( gpu_id + 1 > gpu_count )) && gpu_count=$((gpu_id + 1))

    [[ "${smi_temp}" =~ ^[0-9]+([.][0-9]+)?$ ]] && gpu_temp[gpu_id]="${smi_temp%.*}" || gpu_temp[gpu_id]=0
    [[ "${smi_fan}" =~ ^[0-9]+([.][0-9]+)?$ ]] && gpu_fan[gpu_id]="${smi_fan%.*}" || gpu_fan[gpu_id]=0

    bus_hex=$(printf '%s' "${pci_bus_id}" | awk -F: '{if (NF >= 3) print $(NF-1)}')
    if [[ "${bus_hex}" =~ ^[0-9A-Fa-f]+$ ]]; then
      gpu_bus[gpu_id]=$((16#${bus_hex}))
    fi
  done < <(nvidia-smi --query-gpu=index,pci.bus_id,temperature.gpu,fan.speed --format=csv,noheader,nounits 2>/dev/null)
fi

# Miner emits one line per CUDA device: [GPU0], [GPU1], ... . Hive expects hs[]
# in the same device order. Fall back to aggregate speed during early startup.
hs_values=()
if (( gpu_count > 0 )); then
  for ((gpu_id=0; gpu_id<gpu_count; ++gpu_id)); do
    gpu_line=$(grep -a "^\[GPU${gpu_id}\]" "${log_file}" 2>/dev/null | tail -n 1)
    gpu_mhs=$(printf '%s\n' "${gpu_line}" | awk '{print $2}')
    [[ "${gpu_mhs}" =~ ^[0-9]+([.][0-9]+)?$ ]] || gpu_mhs=0
    gpu_khs=$(awk -v mhs="${gpu_mhs}" 'BEGIN { printf "%.0f", mhs * 1000.0 }')
    hs_values+=("${gpu_khs}")
  done
fi
if (( ${#hs_values[@]} == 0 )); then
  hs_values=("${khs}")
fi
hs_json=$(IFS=,; printf '%s' "${hs_values[*]}")

# HiveOS custom-miner schema defines ar as exactly two aggregate counters:
# [accepted, rejected]. Keep this shape stable in every PepeW build so the
# dashboard can render A/R next to the miner version.
temp_json=""
fan_json=""
bus_json=""
if (( gpu_count > 0 && ${#hs_values[@]} == gpu_count )); then
  mapped_temp=()
  mapped_fan=()
  mapped_bus=()
  hardware_complete=1
  for ((gpu_id=0; gpu_id<gpu_count; ++gpu_id)); do
    if [[ -n "${gpu_temp[gpu_id]:-}" && -n "${gpu_fan[gpu_id]:-}" && -n "${gpu_bus[gpu_id]:-}" ]]; then
      mapped_temp+=("${gpu_temp[gpu_id]}")
      mapped_fan+=("${gpu_fan[gpu_id]}")
      mapped_bus+=("${gpu_bus[gpu_id]}")
    else
      hardware_complete=0
      break
    fi
  done
  if (( hardware_complete == 1 )); then
    temp_json=$(IFS=,; printf '%s' "${mapped_temp[*]}")
    fan_json=$(IFS=,; printf '%s' "${mapped_fan[*]}")
    bus_json=$(IFS=,; printf '%s' "${mapped_bus[*]}")
  fi
fi

if [[ -n "${bus_json}" ]]; then
  stats=$(printf '{"hs":[%s],"hs_units":"khs","temp":[%s],"fan":[%s],"uptime":%s,"ar":[%s,%s],"ver":"%s","algo":"hoohash","bus_numbers":[%s]}' \
    "${hs_json}" "${temp_json}" "${fan_json}" "${uptime_seconds}" "${accepted}" "${rejected}" "${version}" "${bus_json}")
else
  stats=$(printf '{"hs":[%s],"hs_units":"khs","uptime":%s,"ar":[%s,%s],"ver":"%s","algo":"hoohash"}' \
    "${hs_json}" "${uptime_seconds}" "${accepted}" "${rejected}" "${version}")
fi
