#!/usr/bin/env bash

# HiveOS sources this callback. It must always define both khs and stats and
# must never terminate the parent agent shell.
khs=0
stats="null"

log_base="${CUSTOM_LOG_BASENAME:-/var/log/miner/custom/PepeW-Miner/pepew}"
log_file="${log_base}.log"

if [[ ! -s "${log_file}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# Do not keep reporting a stale speed after a stopped/crashed miner.
now_epoch=$(date +%s)
log_mtime=$(stat -c %Y "${log_file}" 2>/dev/null || echo 0)
if (( now_epoch - log_mtime > 30 )); then
  return 0 2>/dev/null || exit 0
fi

# The aggregate line is kept for backwards compatibility with the hardware
# test and is the authoritative source for total speed and pool share counts.
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
version="${CUSTOM_VERSION:-dev}"

# Miner emits one line per CUDA device: [GPU0], [GPU1], ... . Hive expects
# hs[] in GPU order. We use the currently visible NVIDIA device count and fall
# back to the aggregate speed when no per-GPU telemetry is available yet.
gpu_count=0
if command -v nvidia-smi >/dev/null 2>&1; then
  gpu_count=$(nvidia-smi -L 2>/dev/null | grep -c '^GPU ' || true)
fi
[[ "${gpu_count}" =~ ^[0-9]+$ ]] || gpu_count=0

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

# bus_numbers lets Hive map hs[0], hs[1], ... to the correct physical cards.
bus_values=()
if command -v nvidia-smi >/dev/null 2>&1; then
  while IFS=',' read -r smi_index pci_bus_id; do
    smi_index=$(printf '%s' "${smi_index}" | xargs)
    pci_bus_id=$(printf '%s' "${pci_bus_id}" | xargs)
    bus_hex=$(printf '%s' "${pci_bus_id}" | awk -F: '{if (NF >= 3) print $(NF-1)}')
    if [[ "${smi_index}" =~ ^[0-9]+$ && "${bus_hex}" =~ ^[0-9A-Fa-f]+$ ]]; then
      bus_dec=$((16#${bus_hex}))
      bus_values[10#${smi_index}]="${bus_dec}"
    fi
  done < <(nvidia-smi --query-gpu=index,pci.bus_id --format=csv,noheader,nounits 2>/dev/null)
fi

bus_json=""
if (( gpu_count > 0 && ${#hs_values[@]} == gpu_count )); then
  mapped_buses=()
  buses_complete=1
  for ((gpu_id=0; gpu_id<gpu_count; ++gpu_id)); do
    if [[ -n "${bus_values[gpu_id]:-}" ]]; then
      mapped_buses+=("${bus_values[gpu_id]}")
    else
      buses_complete=0
      break
    fi
  done
  if (( buses_complete == 1 )); then
    bus_json=$(IFS=,; printf '%s' "${mapped_buses[*]}")
  fi
fi

if [[ -n "${bus_json}" ]]; then
  stats=$(printf '{"hs":[%s],"hs_units":"khs","uptime":%s,"ar":[%s,%s],"ver":"%s","algo":"hoohash","bus_numbers":[%s]}' \
    "${hs_json}" "${uptime_seconds}" "${accepted}" "${rejected}" "${version}" "${bus_json}")
else
  stats=$(printf '{"hs":[%s],"hs_units":"khs","uptime":%s,"ar":[%s,%s],"ver":"%s","algo":"hoohash"}' \
    "${hs_json}" "${uptime_seconds}" "${accepted}" "${rejected}" "${version}")
fi
