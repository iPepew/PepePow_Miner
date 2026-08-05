#!/usr/bin/env bash
set -Eeuo pipefail
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"
export CUDA_DEVICE_ORDER="${CUDA_DEVICE_ORDER:-PCI_BUS_ID}"

miner_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${miner_dir}"

package_name="$(basename "${miner_dir}")"
log_dir="/var/log/miner/custom/${package_name}"
runtime_log="${log_dir}/runtime-diagnostics.txt"
exit_file="${log_dir}/miner-exit-status.txt"
workers_file="${miner_dir}/active-workers.env"
mkdir -p "${log_dir}"

[[ -x ./pepepowminer ]] || { echo "pepepowminer binary is missing or not executable" >&2; exit 1; }
[[ -x ./stratum-replay-proxy.py ]] || { echo "stratum-replay-proxy.py is missing or not executable" >&2; exit 1; }
command -v nvidia-smi >/dev/null 2>&1 || { echo "nvidia-smi is required" >&2; exit 1; }

conf_file="${CUSTOM_CONFIG_FILENAME:-${miner_dir}/config.txt}"
if [[ ! -s "${conf_file}" ]]; then
  # shellcheck disable=SC1091
  source ./h-config.sh
fi
[[ -s "${conf_file}" ]] || { echo "HiveOS miner config is missing: ${conf_file}" >&2; exit 1; }

# shellcheck disable=SC1090
source "${conf_file}"
: "${PEPEPOW_UPSTREAM:?missing PEPEPOW_UPSTREAM in config.txt}"
: "${PEPEPOW_USER:?missing PEPEPOW_USER in config.txt}"
: "${PEPEPOW_PASS:?missing PEPEPOW_PASS in config.txt}"
: "${PEPEPOW_PROXY_PORT_BASE:?missing PEPEPOW_PROXY_PORT_BASE in config.txt}"
: "${PEPEPOW_DEVICES:?missing PEPEPOW_DEVICES in config.txt}"
: "${PEPEPOW_DIAGNOSTIC:?missing PEPEPOW_DIAGNOSTIC in config.txt}"
if ! declare -p PEPEPOW_EXTRA_ARGS >/dev/null 2>&1; then
  PEPEPOW_EXTRA_ARGS=()
fi

trim_field() {
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s' "${value}"
}

# CUDA_VISIBLE_DEVICES accepts UUIDs, which avoids ambiguity between CUDA and
# nvidia-smi numbering when PCI ordering differs.
declare -a all_indices all_uuids all_names all_buses
while IFS=',' read -r raw_index raw_uuid raw_name raw_bus; do
  index="$(trim_field "${raw_index}")"
  uuid="$(trim_field "${raw_uuid}")"
  name="$(trim_field "${raw_name}")"
  bus="$(trim_field "${raw_bus}")"
  [[ "${index}" =~ ^[0-9]+$ ]] || continue
  [[ -n "${uuid}" ]] || uuid="${index}"
  all_indices+=("${index}")
  all_uuids+=("${uuid}")
  all_names+=("${name}")
  all_buses+=("${bus}")
done < <(nvidia-smi --query-gpu=index,uuid,name,pci.bus_id --format=csv,noheader,nounits 2>/dev/null)

(( ${#all_indices[@]} > 0 )) || { echo "No NVIDIA GPUs detected" >&2; exit 1; }

declare -A selected_lookup=()
if [[ "${PEPEPOW_DEVICES}" == "all" ]]; then
  for index in "${all_indices[@]}"; do selected_lookup["${index}"]=1; done
else
  IFS=',' read -r -a requested_devices <<<"${PEPEPOW_DEVICES}"
  for index in "${requested_devices[@]}"; do selected_lookup["${index}"]=1; done
fi

declare -a gpu_indices gpu_uuids gpu_names gpu_buses
for ((position=0; position<${#all_indices[@]}; ++position)); do
  index="${all_indices[$position]}"
  if [[ -n "${selected_lookup[$index]:-}" ]]; then
    gpu_indices+=("${index}")
    gpu_uuids+=("${all_uuids[$position]}")
    gpu_names+=("${all_names[$position]}")
    gpu_buses+=("${all_buses[$position]}")
    unset 'selected_lookup[$index]'
  fi
done

if (( ${#selected_lookup[@]} > 0 )); then
  echo "Requested GPU index not found: ${!selected_lookup[*]}" >&2
  exit 1
fi
(( ${#gpu_indices[@]} > 0 )) || { echo "No selected NVIDIA GPUs" >&2; exit 1; }
if (( PEPEPOW_PROXY_PORT_BASE + ${#gpu_indices[@]} - 1 > 65535 )); then
  echo "Proxy port range exceeds 65535" >&2
  exit 1
fi

{
  echo "UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "PACKAGE_DIR=${miner_dir}"
  echo "PACKAGE_NAME=${package_name}"
  echo "MINER_VERSION=$(./pepepowminer --version 2>&1 | head -n1 || true)"
  echo "PROFILE=$(tr '\n' ' ' < ./BUILD_PROFILE 2>/dev/null || true)"
  echo "MULTI_GPU_MODE=one_process_per_gpu"
  echo "SELECTED_GPU_COUNT=${#gpu_indices[@]}"
  for ((position=0; position<${#gpu_indices[@]}; ++position)); do
    echo "GPU${gpu_indices[$position]}=${gpu_names[$position]} uuid=${gpu_uuids[$position]} bus=${gpu_buses[$position]}"
  done
} > "${runtime_log}"

rm -f "${workers_file}" "${exit_file}"
declare -a miner_pids proxy_pids tail_pids worker_logs worker_dirs worker_ports
stop_requested=0
failure_status=0
failure_reason=""

terminate_pid() {
  local pid="${1:-}"
  [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || return 0
  kill -TERM "${pid}" 2>/dev/null || true
}

request_stop() {
  stop_requested=1
  for pid in "${miner_pids[@]:-}"; do terminate_pid "${pid}"; done
}

cleanup() {
  local pid
  for pid in "${tail_pids[@]:-}"; do kill "${pid}" 2>/dev/null || true; done
  for pid in "${miner_pids[@]:-}"; do terminate_pid "${pid}"; done
  sleep 1
  for pid in "${miner_pids[@]:-}"; do kill -KILL "${pid}" 2>/dev/null || true; done
  for pid in "${proxy_pids[@]:-}"; do terminate_pid "${pid}"; done
  for pid in "${tail_pids[@]:-}" "${miner_pids[@]:-}" "${proxy_pids[@]:-}"; do
    [[ "${pid}" =~ ^[1-9][0-9]*$ ]] && wait "${pid}" 2>/dev/null || true
  done
  for dir in "${worker_dirs[@]:-}"; do
    rm -f "${dir}/miner.pid" "${dir}/proxy.pid"
  done
}
trap request_stop INT TERM
trap cleanup EXIT

for ((position=0; position<${#gpu_indices[@]}; ++position)); do
  gpu_index="${gpu_indices[$position]}"
  gpu_uuid="${gpu_uuids[$position]}"
  gpu_name="${gpu_names[$position]}"
  proxy_port=$((PEPEPOW_PROXY_PORT_BASE + position))
  worker_dir="${miner_dir}/gpu${gpu_index}"
  worker_log_dir="${log_dir}/gpu${gpu_index}"
  diagnostic_log="${worker_dir}/pepepow-debug.log"
  status_file="${worker_dir}/miner-status.env"
  console_log="${worker_log_dir}/pepew.log"
  proxy_log="${worker_log_dir}/stratum-proxy.log"
  proxy_console_log="${worker_log_dir}/proxy-console.log"
  mkdir -p "${worker_dir}" "${worker_log_dir}"

  for file in "${diagnostic_log}" "${console_log}" "${proxy_log}" "${proxy_console_log}"; do
    if [[ -s "${file}" ]]; then cp -f "${file}" "${file}.previous" 2>/dev/null || true; fi
    : > "${file}"
  done
  rm -f "${status_file}" "${worker_dir}/miner.pid" "${worker_dir}/proxy.pid"

  ./stratum-replay-proxy.py \
    --upstream "${PEPEPOW_UPSTREAM}" \
    --listen-host 127.0.0.1 \
    --listen-port "${proxy_port}" \
    --log "${proxy_log}" \
    >> "${proxy_console_log}" 2>&1 &
  proxy_pid=$!
  proxy_pids+=("${proxy_pid}")
  echo "${proxy_pid}" > "${worker_dir}/proxy.pid"

  sleep 0.25
  if ! kill -0 "${proxy_pid}" 2>/dev/null; then
    echo "GPU ${gpu_index}: proxy failed to start on port ${proxy_port}" >&2
    tail -n 40 "${proxy_console_log}" >&2 || true
    exit 70
  fi

  args=(
    "-o" "stratum+tcp://127.0.0.1:${proxy_port}"
    "-u" "${PEPEPOW_USER}"
    "-p" "${PEPEPOW_PASS}"
    "--diagnostic-log" "${diagnostic_log}"
  )
  if [[ "${PEPEPOW_DIAGNOSTIC}" == "1" ]]; then args+=("--diagnostic"); fi
  args+=("${PEPEPOW_EXTRA_ARGS[@]}")

  echo "[GPU ${gpu_index}] starting ${gpu_name} (${gpu_uuid}) proxy_port=${proxy_port}"
  CUDA_VISIBLE_DEVICES="${gpu_uuid}" \
    PEPEW_PHYSICAL_GPU_INDEX="${gpu_index}" \
    ./pepepowminer "${args[@]}" >> "${console_log}" 2>&1 &
  miner_pid=$!
  miner_pids+=("${miner_pid}")
  echo "${miner_pid}" > "${worker_dir}/miner.pid"

  worker_dirs+=("${worker_dir}")
  worker_logs+=("${console_log}")
  worker_ports+=("${proxy_port}")
done

{
  echo "GPU_COUNT=${#gpu_indices[@]}"
  for ((position=0; position<${#gpu_indices[@]}; ++position)); do
    echo "GPU${gpu_indices[$position]}_PID=${miner_pids[$position]}"
    echo "GPU${gpu_indices[$position]}_PROXY_PID=${proxy_pids[$position]}"
    echo "GPU${gpu_indices[$position]}_PORT=${worker_ports[$position]}"
    echo "GPU${gpu_indices[$position]}_UUID=${gpu_uuids[$position]}"
  done
} > "${workers_file}"

# Show all worker logs in the HiveOS miner screen. GNU tail prints a filename
# header when several files are followed, making GPU output distinguishable.
tail -n +1 -F "${worker_logs[@]}" &
tail_pids+=("$!")

echo "PepeW Miner v1.0.4 multi-GPU workers started: ${#miner_pids[@]}"

while (( stop_requested == 0 )); do
  for ((position=0; position<${#miner_pids[@]}; ++position)); do
    miner_pid="${miner_pids[$position]}"
    proxy_pid="${proxy_pids[$position]}"
    gpu_index="${gpu_indices[$position]}"
    if ! kill -0 "${proxy_pid}" 2>/dev/null; then
      set +e; wait "${proxy_pid}"; failure_status=$?; set -e
      failure_status=${failure_status:-70}
      (( failure_status == 0 )) && failure_status=70
      failure_reason="gpu${gpu_index}_proxy_exit"
      break 2
    fi
    if ! kill -0 "${miner_pid}" 2>/dev/null; then
      set +e; wait "${miner_pid}"; failure_status=$?; set -e
      (( failure_status == 0 )) && failure_status=71
      failure_reason="gpu${gpu_index}_miner_exit"
      break 2
    fi
  done
  sleep 2 || true
done

if (( stop_requested == 1 )); then
  failure_status=0
  failure_reason="graceful_hive_stop"
else
  for pid in "${miner_pids[@]}"; do terminate_pid "${pid}"; done
fi

printf 'exit_code=%s utc=%s reason=%s active_workers=%s\n' \
  "${failure_status}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "${failure_reason:-unknown}" "${#miner_pids[@]}" > "${exit_file}"

trap - INT TERM
exit "${failure_status}"
