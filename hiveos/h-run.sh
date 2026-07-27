#!/usr/bin/env bash
set -euo pipefail

miner_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${miner_dir}"

console_log="${miner_dir}/miner-console.log"
runtime_log="${miner_dir}/runtime-diagnostics.txt"
exit_file="${miner_dir}/miner-exit-status.txt"
diagnostic_log="${miner_dir}/pepepow-debug.log"
status_file="${miner_dir}/miner-status.env"
miner_pid_file="${miner_dir}/miner.pid"
proxy_pid_file="${miner_dir}/proxy.pid"
proxy_console_log="${miner_dir}/proxy-console.log"

if [[ ! -x ./pepepowminer ]]; then
  echo "pepepowminer binary is missing or not executable" >&2
  exit 1
fi
if [[ ! -x ./stratum-replay-proxy.py ]]; then
  echo "stratum-replay-proxy.py is missing or not executable" >&2
  exit 1
fi

conf_file="${miner_dir}/config.txt"
if [[ ! -s "${conf_file}" ]]; then
  # shellcheck disable=SC1091
  source ./h-config.sh
fi
if [[ ! -s "${conf_file}" ]]; then
  echo "HiveOS miner config is missing after h-config.sh: ${conf_file}" >&2
  exit 1
fi

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
  echo "PWD=$(pwd)"
  echo "PACKAGE_DIR=${miner_dir}"
  echo "PROTOCOL=HooHashV110 matrix_seed=BLAKE3_MASKED_HEADER header_nonce=BE32 mix_nonce=LE32 submit_nonce=LE_HEX share_target=NBITS_DIV_DIFFICULTY proxy=passive"
  echo "OPTIMIZATION=BLAKE3_MIDSTATE GPU_TARGET_FILTER PERSISTENT_RESULT LIVE_HASHRATE FULL_BATCH AUTOTUNED_CUDA"
  echo "LIFECYCLE=DIRECT_FILE_OUTPUT PID_TRACKING GRACEFUL_SIGNAL_FORWARDING NO_TEE_PIPE"
  echo "== VERSION =="
  ./pepepowminer --version 2>&1 || true
  echo "== FILE =="
  if command -v file >/dev/null 2>&1; then file ./pepepowminer 2>&1 || true; else echo "file utility unavailable"; fi
  echo "== LDD =="
  ldd ./pepepowminer 2>&1 || true
  echo "== READELF DYNAMIC =="
  readelf -d ./pepepowminer 2>&1 || true
  echo "== GPU =="
  nvidia-smi -q 2>&1 || true
  echo "== ENVIRONMENT =="
  env | sort
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
  if [[ -n "${miner_pid}" ]] && kill -0 "${miner_pid}" 2>/dev/null; then
    kill -TERM "${miner_pid}" 2>/dev/null || true
  fi
}

cleanup() {
  if [[ -n "${tail_pid}" ]] && kill -0 "${tail_pid}" 2>/dev/null; then
    kill "${tail_pid}" 2>/dev/null || true
    wait "${tail_pid}" 2>/dev/null || true
  fi
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
  echo "exit_code=70 utc=$(date -u +%Y-%m-%dT%H:%M:%SZ) reason=proxy_start_failure" > "${exit_file}"
  exit 70
fi

{
  echo "Miner directory: ${miner_dir}"
  echo "Proxy PID: ${proxy_pid}"
  echo "Proxy mode: passive"
  echo "Proxy upstream: ${PEPEPOW_UPSTREAM}"
  echo "Proxy protocol log: ${PEPEPOW_PROXY_LOG}"
  echo "Proxy console log: ${proxy_console_log}"
  echo "Protocol: network nBits target divided by Stratum difficulty"
  echo "Optimizations: BLAKE3 midstate; GPU target filter; persistent result; 524K batch; CUDA profile autotune"
  echo "HiveOS stats: per-GPU hashrate, temperature, fan and PCI bus"
  echo "Lifecycle: direct log output; no miner-to-tee pipe; graceful signal forwarding"
  echo "Console log: ${console_log}"
  echo "Runtime status: ${status_file}"
  printf './pepepowminer'
  printf ' %q' "${PEPEPOW_ARGS[@]}"
  echo
} > "${miner_dir}/run.txt"

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
raw_status=0
while true; do
  wait "${miner_pid}"
  raw_status=$?
  if ! kill -0 "${miner_pid}" 2>/dev/null; then
    break
  fi
done
set -e

if kill -0 "${tail_pid}" 2>/dev/null; then
  kill "${tail_pid}" 2>/dev/null || true
  wait "${tail_pid}" 2>/dev/null || true
fi
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
