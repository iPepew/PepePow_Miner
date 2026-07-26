#!/usr/bin/env bash
set -euo pipefail

miner_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${miner_dir}"

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

rm -f "${miner_dir}/proxy.pid"
./stratum-replay-proxy.py \
  --upstream "${PEPEPOW_UPSTREAM}" \
  --listen-host 127.0.0.1 \
  --listen-port "${PEPEPOW_PROXY_PORT}" \
  --log "${PEPEPOW_PROXY_LOG}" \
  --rewrite-submit-nonce &
proxy_pid=$!
echo "${proxy_pid}" > "${miner_dir}/proxy.pid"

cleanup() {
  if kill -0 "${proxy_pid}" 2>/dev/null; then
    kill "${proxy_pid}" 2>/dev/null || true
    wait "${proxy_pid}" 2>/dev/null || true
  fi
  rm -f "${miner_dir}/proxy.pid"
}
trap cleanup EXIT INT TERM

# Fail early if the proxy does not stay alive.
sleep 1
if ! kill -0 "${proxy_pid}" 2>/dev/null; then
  echo "Forensic Stratum proxy failed to start; see ${PEPEPOW_PROXY_LOG}" >&2
  exit 1
fi

{
  echo "Miner directory: ${miner_dir}"
  echo "Proxy PID: ${proxy_pid}"
  echo "Proxy upstream: ${PEPEPOW_UPSTREAM}"
  echo "Proxy log: ${PEPEPOW_PROXY_LOG}"
  printf './pepepowminer'
  printf ' %q' "${PEPEPOW_ARGS[@]}"
  echo
} > "${miner_dir}/run.txt"

set +e
./pepepowminer "${PEPEPOW_ARGS[@]}"
status=$?
set -e
cleanup
trap - EXIT INT TERM
exit "${status}"
