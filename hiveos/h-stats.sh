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

line=$(grep -a '\[MINING\]' "${log_file}" 2>/dev/null | tail -n 1)
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

stats=$(printf '{"hs":[%s],"hs_units":"khs","uptime":%s,"ar":[%s,%s],"ver":"%s","algo":"hoohash"}' \
  "${khs}" "${uptime_seconds}" "${accepted}" "${rejected}" "${version}")
