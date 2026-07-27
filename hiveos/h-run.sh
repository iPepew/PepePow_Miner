#!/usr/bin/env bash
set -euo pipefail

miner_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${miner_dir}"

console_log="${miner_dir}/miner-console.log"
runtime_log="${miner_dir}/runtime-diagnostics.txt"
exit_file="${miner_dir}/miner-exit-status.txt"

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

{
  echo "UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "PWD=$(pwd)"
  echo "PACKAGE_DIR=${miner_dir}"
  echo "PROTOCOL=HooHashV110 matrix_seed=BLAKE3_MASKED_HEADER header_nonce=BE32 mix_nonce=LE32 submit_nonce=LE_HEX proxy=passive"
  echo "== VERSION =="
  ./pepepowminer --version 2>&1 || true
  echo "== FILE =="
  file ./pepepowminer 2>&1 || true
  echo "== LDD =="
  ldd ./pepepowminer 2>&1 || true
  echo "== READELF DYNAMIC =="
  readelf -d ./pepepowminer 2>&1 || true
  echo "== LOADER CACHE =="
  ldconfig -p 2>&1 || true
  echo "== GPU =="
  nvidia-smi -q 2>&1 || true
  echo "== ENVIRONMENT =="
  env | sort
} > "${runtime_log}"

rm -f "${miner_dir}/proxy.pid"
./stratum-replay-proxy.py \
  --upstream "${PEPEPOW_UPSTREAM}" \
  --listen-host 127.0.0.1 \
  --listen-port "${PEPEPOW_PROXY_PORT}" \
  --log "${PEPEPOW_PROXY_LOG}" &
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

sleep 1
if ! kill -0 "${proxy_pid}" 2>/dev/null; then
  echo "Passive Stratum proxy failed to start; see ${PEPEPOW_PROXY_LOG}" | tee -a "${console_log}" >&2
  echo "exit_code=70 utc=$(date -u +%Y-%m-%dT%H:%M:%SZ) reason=proxy_start_failure" > "${exit_file}"
  exit 70
fi

{
  echo "Miner directory: ${miner_dir}"
  echo "Proxy PID: ${proxy_pid}"
  echo "Proxy mode: passive"
  echo "Proxy upstream: ${PEPEPOW_UPSTREAM}"
  echo "Proxy log: ${PEPEPOW_PROXY_LOG}"
  echo "Protocol: matrix seed BLAKE3(masked Header80); Header80 nonce BE32; HooHash nonce LE32; mining.submit nonce LE hex"
  echo "Console log: ${console_log}"
  echo "Runtime diagnostics: ${runtime_log}"
  printf './pepepowminer'
  printf ' %q' "${PEPEPOW_ARGS[@]}"
  echo
} > "${miner_dir}/run.txt"

{
  echo "===== START $(date -u +%Y-%m-%dT%H:%M:%SZ) ====="
  cat "${miner_dir}/run.txt"
} >> "${console_log}"

tee_args=(-a "${console_log}")
if tee --help 2>&1 | grep -q -- '--output-error'; then
  tee_args=(--output-error=warn-nopipe -a "${console_log}")
fi

set +e
set +o pipefail
./pepepowminer "${PEPEPOW_ARGS[@]}" 2>&1 | tee "${tee_args[@]}"
raw_status=${PIPESTATUS[0]}
set -o pipefail
set -e

status=${raw_status}
reason="process_exit"
if [[ ${raw_status} -eq 141 ]]; then
  status=0
  reason="sigpipe_console_close_normalized"
fi

{
  echo "===== EXIT $(date -u +%Y-%m-%dT%H:%M:%SZ) raw=${raw_status} effective=${status} reason=${reason} ====="
} | tee -a "${console_log}"
printf 'exit_code=%s raw_exit_code=%s utc=%s reason=%s\n' \
  "${status}" "${raw_status}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${reason}" > "${exit_file}"

cleanup
trap - EXIT INT TERM
exit "${status}"
