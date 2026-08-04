#!/usr/bin/env bash
set -Eeuo pipefail
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"
export PEPEW_BATCH_SIZE="${PEPEW_BATCH_SIZE:-1048576}"
export PEPEW_DIAGNOSTIC="${PEPEW_DIAGNOSTIC:-0}"

# The generic HiveOS custom dispatcher executes this file as a child process,
# so MINER_DIR is not guaranteed to be exported. The script location is the
# authoritative package directory.
miner_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${miner_dir}"

log_dir="/var/log/miner/custom/$(basename "${miner_dir}")"
console_log="${log_dir}/pepew.log"
runtime_log="${log_dir}/runtime-diagnostics.txt"
exit_file="${log_dir}/miner-exit-status.txt"
diagnostic_log="${miner_dir}/pepepow-debug.log"
status_file="${miner_dir}/miner-status.env"
miner_pid_file="${miner_dir}/miner.pid"
proxy_pid_file="${miner_dir}/proxy.pid"
proxy_console_log="${log_dir}/proxy-console.log"
mkdir -p "${log_dir}"

[[ -x ./pepepowminer ]] || { echo "pepepowminer binary is missing or not executable" >&2; exit 1; }
[[ -x ./stratum-replay-proxy.py ]] || { echo "stratum-replay-proxy.py is missing or not executable" >&2; exit 1; }

conf_file="${CUSTOM_CONFIG_FILENAME:-${miner_dir}/config.txt}"
if [[ ! -s "${conf_file}" ]]; then
  # Direct/manual start fallback. Normal HiveOS startup already sourced this
  # file through the generic custom dispatcher and generated config.txt.
  # shellcheck disable=SC1091
  source ./h-config.sh
fi
[[ -s "${conf_file}" ]] || { echo "HiveOS miner config is missing: ${conf_file}" >&2; exit 1; }

# shellcheck disable=SC1090
source "${conf_file}"
if ! declare -p PEPEPOW_ARGS >/dev/null 2>&1 || [[ ${#PEPEPOW_ARGS[@]} -eq 0 ]]; then
  echo "HiveOS miner argument array is empty or invalid" >&2
  exit 1
fi
: "${PEPEPOW_UPSTREAM:?missing PEPEPOW_UPSTREAM in config.txt}"
: "${PEPEPOW_PROXY_LOG:?missing PEPEPOW_PROXY_LOG in config.txt}"
: "${PEPEPOW_PROXY_PORT:?missing PEPEPOW_PROXY_PORT in config.txt}"

for file in "${diagnostic_log}" "${console_log}" "${PEPEPOW_PROXY_LOG}" "${proxy_console_log}"; do
  if [[ -s "${file}" ]]; then
    cp -f "${file}" "${file}.previous" 2>/dev/null || true
  fi
  : > "${file}"
done
rm -f "${status_file}" "${miner_pid_file}" "${proxy_pid_file}" "${exit_file}"

{
  echo "UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "PACKAGE_DIR=${miner_dir}"
  echo "PACKAGE_NAME=$(basename "${miner_dir}")"
  echo "MINER_VERSION=$(./pepepowminer --version 2>&1 | head -n1 || true)"
  echo "PROFILE=$(tr '\n' ' ' < ./BUILD_PROFILE 2>/dev/null || true)"
  echo "GPU_COUNT=$(nvidia-smi -L 2>/dev/null | grep -c '^GPU ' || true)"
} > "${runtime_log}"

./stratum-replay-proxy.py \
  --upstream "${PEPEPOW_UPSTREAM}" \
  --listen-host 127.0.0.1 \
  --listen-port "${PEPEPOW_PROXY_PORT}" \
  --log "${PEPEPOW_PROXY_LOG}" \
  >> "${proxy_console_log}" 2>&1 &
proxy_pid=$!
echo "${proxy_pid}" > "${proxy_pid_file}"

miner_pid=""
tail_pid=""
stop_requested=0

stop_miner() {
  stop_requested=1
  [[ -n "${miner_pid}" ]] && kill -TERM "${miner_pid}" 2>/dev/null || true
}

cleanup() {
  [[ -n "${tail_pid}" ]] && kill "${tail_pid}" 2>/dev/null || true
  [[ -n "${tail_pid}" ]] && wait "${tail_pid}" 2>/dev/null || true
  if [[ -n "${miner_pid}" ]] && kill -0 "${miner_pid}" 2>/dev/null; then
    kill -TERM "${miner_pid}" 2>/dev/null || true
    sleep 1
    kill -KILL "${miner_pid}" 2>/dev/null || true
    wait "${miner_pid}" 2>/dev/null || true
  fi
  if kill -0 "${proxy_pid}" 2>/dev/null; then
    kill "${proxy_pid}" 2>/dev/null || true
    wait "${proxy_pid}" 2>/dev/null || true
  fi
  rm -f "${miner_pid_file}" "${proxy_pid_file}"
}
trap stop_miner INT TERM
trap cleanup EXIT

sleep 1
if ! kill -0 "${proxy_pid}" 2>/dev/null; then
  echo "Passive Stratum proxy failed to start; see ${proxy_console_log}" >&2
  exit 70
fi

./pepepowminer "${PEPEPOW_ARGS[@]}" >> "${console_log}" 2>&1 &
miner_pid=$!
echo "${miner_pid}" > "${miner_pid_file}"

if tail --help 2>&1 | grep -q -- '--pid'; then
  tail -n +1 -F --pid="${miner_pid}" "${console_log}" &
else
  tail -n +1 -F "${console_log}" &
fi
tail_pid=$!

set +e
wait "${miner_pid}"
raw_status=$?
set -e

[[ -n "${tail_pid}" ]] && kill "${tail_pid}" 2>/dev/null || true
tail_pid=""

status=${raw_status}
reason="process_exit"
if [[ ${stop_requested} -eq 1 ]] && [[ ${raw_status} -eq 0 || ${raw_status} -eq 130 || ${raw_status} -eq 143 ]]; then
  status=0
  reason="graceful_hive_stop"
fi
printf 'exit_code=%s raw_exit_code=%s utc=%s reason=%s\n' \
  "${status}" "${raw_status}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${reason}" > "${exit_file}"

trap - INT TERM
exit "${status}"
