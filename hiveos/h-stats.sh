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

hps="$(read_numeric HPS)"
accepted="$(read_numeric ACCEPTED)"
rejected="$(read_numeric REJECTED)"
uptime="$(read_numeric UPTIME)"
updated="$(read_numeric UPDATED_EPOCH)"
status_pid="$(read_numeric PID)"
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
if [[ ${pid} -eq 0 ]]; then
  hps=0
  uptime=0
else
  process_uptime="$(ps -o etimes= -p "${pid}" 2>/dev/null | tr -d ' ' || true)"
  [[ "${process_uptime}" =~ ^[0-9]+$ ]] && uptime="${process_uptime}"

  # Do not display a stale speed if the miner is alive but status publishing has
  # stopped. A fresh status record is written every three seconds.
  if [[ ${updated} -eq 0 || ${now} -lt ${updated} || $((now - updated)) -gt 20 ]]; then
    hps=0
  fi
fi

khs=$((hps / 1000))

# HiveOS already displays the short custom package name before "(c)". Keeping
# ver empty prevents duplicate text and preserves the mobile layout.
stats=$(printf '{"hs":[%s],"hs_units":"hs","ar":[%s,%s,0],"uptime":%s,"ver":"","algo":"hoohash"}' \
  "${hps}" "${accepted}" "${rejected}" "${uptime}")
