#!/usr/bin/env bash

miner_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${miner_dir}"
conf_file="${CUSTOM_CONFIG_FILENAME:-${miner_dir}/config.txt}"
log_base="${CUSTOM_LOG_BASENAME:-/var/log/miner/custom/PepeW-Miner/pepew}"
log_file="${log_base}.log"

if [[ ! -x ./pepepowminer ]]; then
  echo "pepepowminer binary is missing or not executable" >&2
  return 1 2>/dev/null || exit 1
fi
if [[ ! -s "${conf_file}" ]]; then
  echo "HiveOS miner config is missing: ${conf_file}" >&2
  return 1 2>/dev/null || exit 1
fi

mkdir -p "$(dirname "${log_file}")"
touch "${log_file}"

# h-config.sh writes shell-escaped CLI arguments.
args=$(cat "${conf_file}")

# Preserve the live HiveOS console while also keeping a parseable log for
# h-stats.sh and automated hardware-test reports.
eval "./pepepowminer ${args}" 2>&1 | tee -a "${log_file}"
status=${PIPESTATUS[0]}

return "${status}" 2>/dev/null || exit "${status}"
