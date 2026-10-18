#!/usr/bin/env bash
set -Eeuo pipefail
export LANG=C
export LC_ALL=C
export CUDA_DEVICE_ORDER="${CUDA_DEVICE_ORDER:-PCI_BUS_ID}"

miner_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${miner_dir}"

package_name="$(basename "${miner_dir}")"
log_dir="${PEPEW_LOG_ROOT:-/var/log/miner/custom/${package_name}}"
runtime_log="${log_dir}/runtime-diagnostics.txt"
exit_file="${log_dir}/miner-exit-status.txt"
workers_file="${miner_dir}/active-workers.env"
package_version="$(cat "${miner_dir}/VERSION")"
if [[ "${PEPEW_WRAPPER_SELFTEST:-0}" != "1" && "${PEPEW_ALLOW_UNVERIFIED:-0}" != "1" ]]; then
  echo "[ERROR] Preparation package: exact GPU validation is pending. See README.md." >&2
  exit 78
fi
if [[ -n "${CUDA_VISIBLE_DEVICES:-}" ]]; then
  echo "[ERROR] Use PEPEW_DEVICES in HiveOS configuration; inherited CUDA_VISIBLE_DEVICES is unsupported." >&2
  exit 78
fi
umask 077
mkdir -p "${log_dir}"

[[ -x ./pepepowminer ]] || { echo "[ERROR] pepepowminer binary is missing or not executable" >&2; exit 1; }
[[ -x ./libexec/stratum-replay-proxy.py ]] || { echo "[ERROR] stratum-replay-proxy.py is missing or not executable" >&2; exit 1; }
[[ -x ./libexec/console-monitor.sh ]] || { echo "[ERROR] console-monitor.sh is missing or not executable" >&2; exit 1; }
command -v nvidia-smi >/dev/null 2>&1 || { echo "[ERROR] nvidia-smi is required" >&2; exit 1; }

conf_file="${CUSTOM_CONFIG_FILENAME:-${miner_dir}/config.txt}"
if [[ ! -s "${conf_file}" ]]; then
  # shellcheck disable=SC1091
  source ./h-config.sh
fi
[[ -s "${conf_file}" ]] || { echo "[ERROR] HiveOS miner config is missing: ${conf_file}" >&2; exit 1; }

# shellcheck disable=SC1090
source "${conf_file}"
: "${PEPEPOW_UPSTREAM:?missing PEPEPOW_UPSTREAM in config.txt}"
: "${PEPEPOW_USER:?missing PEPEPOW_USER in config.txt}"
: "${PEPEPOW_PASS:?missing PEPEPOW_PASS in config.txt}"
: "${PEPEPOW_PROXY_PORT_BASE:?missing PEPEPOW_PROXY_PORT_BASE in config.txt}"
: "${PEPEPOW_DEVICES:?missing PEPEPOW_DEVICES in config.txt}"
: "${PEPEPOW_DIAGNOSTIC:?missing PEPEPOW_DIAGNOSTIC in config.txt}"
PEPEPOW_PROFILE="${PEPEPOW_PROFILE:-auto}"
PEPEPOW_CUDA_THREADS_RUNTIME="${PEPEPOW_CUDA_THREADS_RUNTIME:-auto}"
PEPEPOW_STATS_INTERVAL="${PEPEPOW_STATS_INTERVAL:-10}"
if ! declare -p PEPEPOW_EXTRA_ARGS >/dev/null 2>&1; then
  PEPEPOW_EXTRA_ARGS=()
fi

trim_field() {
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s' "${value}"
}

profile_for_sm() {
  case "$1" in
    61) printf 'pascal-auto' ;;
    70) printf 'volta-auto' ;;
    75) printf 'turing-auto' ;;
    80) printf 'ampere-datacenter-auto' ;;
    86) printf 'ampere-auto' ;;
    89) printf 'ada-auto' ;;
    120) printf 'blackwell-auto' ;;
    *) printf 'generic-auto' ;;
  esac
}

threads_for_sm() {
  case "$1" in
    70|120) printf '512' ;;
    *) printf '768' ;;
  esac
}

# CUDA_VISIBLE_DEVICES accepts UUIDs, which avoids ambiguity between CUDA and
# nvidia-smi numbering when PCI ordering differs.
declare -a all_indices all_uuids all_names all_buses all_memory
while IFS=',' read -r raw_index raw_uuid raw_name raw_bus raw_memory; do
  index="$(trim_field "${raw_index}")"
  uuid="$(trim_field "${raw_uuid}")"
  name="$(trim_field "${raw_name}")"
  bus="$(trim_field "${raw_bus}")"
  memory="$(trim_field "${raw_memory}")"
  [[ "${index}" =~ ^[0-9]+$ ]] || continue
  [[ "${uuid}" =~ ^GPU-[A-Za-z0-9-]+$ ]] || { echo "[ERROR] Missing GPU UUID" >&2; exit 1; }
  all_indices+=("${index}")
  all_uuids+=("${uuid}")
  all_names+=("${name}")
  all_buses+=("${bus}")
  all_memory+=("${memory}")
done < <(nvidia-smi --query-gpu=index,uuid,name,pci.bus_id,memory.total --format=csv,noheader,nounits 2>/dev/null)

(( ${#all_indices[@]} > 0 )) || { echo "[ERROR] No NVIDIA GPUs detected" >&2; exit 1; }

declare -A selected_lookup=()
if [[ "${PEPEPOW_DEVICES}" == "all" ]]; then
  for index in "${all_indices[@]}"; do selected_lookup["${index}"]=1; done
else
  IFS=',' read -r -a requested_devices <<<"${PEPEPOW_DEVICES}"
  for index in "${requested_devices[@]}"; do selected_lookup["${index}"]=1; done
fi

declare -a gpu_indices gpu_uuids gpu_names gpu_buses gpu_memory gpu_sm gpu_profiles gpu_threads gpu_backends
for ((position=0; position<${#all_indices[@]}; ++position)); do
  index="${all_indices[$position]}"
  if [[ -n "${selected_lookup[$index]:-}" ]]; then
    # Probe each physical UUID in isolation: CUDA ordinal zero now refers to
    # this GPU, regardless of nvidia-smi ordering or PCI enumeration order.
    if ! gpu_info="$(CUDA_VISIBLE_DEVICES="${all_uuids[$position]}" timeout --kill-after=2s 15s ./bin/general/pepepowminer --list-gpu 2>/dev/null)"; then
      echo "[ERROR] GPU ${index}: CUDA enumeration failed" >&2
      exit 1
    fi
    # Native --list-gpu includes a build banner before the device records.
    gpu_info="$(printf '%s\n' "${gpu_info}" | sed -n '/^\[[0-9][0-9]*\][[:space:]]/p')"
    if [[ "${gpu_info}" != *$'\n'* && "${gpu_info}" =~ ^\[0\][[:space:]]+(.+)[[:space:]]sm_([0-9]+)$ ]]; then
      sm="${BASH_REMATCH[2]}"
    else
      echo "[ERROR] GPU ${index}: expected exactly one CUDA device" >&2
      exit 1
    fi
    backend=general
    if [[ "${sm}" == 70 && "${all_names[$position]}" == *V100* ]]; then backend=v100; fi
    if [[ ! "${sm}" =~ ^(61|70|75|80|86|89|120)$ ]]; then
      echo "[ERROR] GPU ${index} ${all_names[$position]} uses unsupported or undetected architecture sm_${sm}" >&2
      echo "[ERROR] General build contains sm_61, sm_70, sm_75, sm_80, sm_86, sm_89 and sm_120" >&2
      exit 1
    fi

    if [[ "${PEPEPOW_PROFILE}" == "auto" ]]; then
      profile="$(profile_for_sm "${sm}")"
      [[ "${backend}" == v100 ]] && profile=v100-hotrun8
    else
      profile="${PEPEPOW_PROFILE}"
    fi
    if [[ "${PEPEPOW_CUDA_THREADS_RUNTIME}" == "auto" ]]; then
      threads="$(threads_for_sm "${sm}")"
    else
      threads="${PEPEPOW_CUDA_THREADS_RUNTIME}"
    fi
    if [[ "${backend}" == v100 ]]; then
      if [[ "${PEPEPOW_CUDA_THREADS_RUNTIME}" != auto && "${PEPEPOW_CUDA_THREADS_RUNTIME}" != 128 ]]; then
        echo "[ERROR] V100 optimized profile requires 128 threads; use auto for mixed GPUs" >&2
        exit 1
      fi
      threads=128
    fi
    gpu_backends+=("${backend}")
    gpu_indices+=("${index}")
    gpu_uuids+=("${all_uuids[$position]}")
    gpu_names+=("${all_names[$position]}")
    gpu_buses+=("${all_buses[$position]}")
    gpu_memory+=("${all_memory[$position]} MiB")
    gpu_sm+=("${sm}")
    gpu_profiles+=("${profile}")
    gpu_threads+=("${threads}")
    unset 'selected_lookup[$index]'
  fi
done

if (( ${#selected_lookup[@]} > 0 )); then
  echo "[ERROR] Requested GPU index not found: ${!selected_lookup[*]}" >&2
  exit 1
fi
(( ${#gpu_indices[@]} > 0 )) || { echo "[ERROR] No selected NVIDIA GPUs" >&2; exit 1; }
if (( PEPEPOW_PROXY_PORT_BASE + ${#gpu_indices[@]} - 1 > 65535 )); then
  echo "[ERROR] Proxy port range exceeds 65535" >&2
  exit 1
fi

miner_version="${package_version}"
driver_version="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 | tr -d ' ' || true)"
pool_display="${PEPEPOW_UPSTREAM#*://}"
pool_display="${pool_display%%/*}"

printf '%s\n' 'PepeW Miner startup'
printf '%-12s: %s\n' Miner 'PepeW Miner'
printf '%-12s: %s\n' Version "${miner_version}"
printf '%-12s: %s\n' Algorithm 'HooHash V110'
printf '%-12s: %s\n' Pool 'configured'
printf '%-12s: %s\n' 'GPU mining' enabled
printf '%-12s: %s\n' 'CPU mining' disabled
printf '%-12s: %s\n' Supervision 'worker/proxy process exit detection'
printf '%-12s: %s\n' 'Dev fee' '0.00%'
printf '%-12s: %s\n' Driver "${driver_version:-unknown}"
printf '%-12s: %s\n' 'GPU count' "${#gpu_indices[@]}"
printf '%s\n' 'Detected GPUs:'
for ((position=0; position<${#gpu_indices[@]}; ++position)); do
  printf 'GPU %s | %s | sm_%s | %s | BUS %s | profile=%s | threads=%s | chunk=262144\n' \
    "${gpu_indices[$position]}" "${gpu_names[$position]}" "${gpu_sm[$position]}" \
    "${gpu_memory[$position]}" "${gpu_buses[$position]}" "${gpu_profiles[$position]}" \
    "${gpu_threads[$position]}"
done

if printf '%s\n' "${gpu_names[@]}" | grep -qi 'CMP'; then
  cmp_state='unknown'
  if [[ -r /run/cmp90hx-persistent-batch.status ]]; then
    cmp_state="$(tail -n1 /run/cmp90hx-persistent-batch.status 2>/dev/null || true)"
  fi
  printf '%-12s: %s\n' 'CMP unlock' "${cmp_state:-unknown}"
  printf '%s\n' 'Note: PepeW Miner does not modify drivers or unlock CMP cards automatically.'
fi

if [[ "${PEPEW_WRAPPER_SELFTEST:-0}" == "1" ]]; then
  echo "PEPEW_PROFILE_WRAPPER_GATE=PASS"
  exit 0
fi

{
  echo "UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "PACKAGE_DIR=${miner_dir}"
  echo "PACKAGE_NAME=${package_name}"
  echo "MINER_VERSION=${miner_version}"
  echo "DRIVER_VERSION=${driver_version}"
  echo "PROFILE=$(tr '\n' ' ' < ./BUILD_PROFILE 2>/dev/null || true)"
  echo "MULTI_GPU_MODE=one_process_per_gpu"
  echo "SELECTED_GPU_COUNT=${#gpu_indices[@]}"
  for ((position=0; position<${#gpu_indices[@]}; ++position)); do
    echo "GPU${gpu_indices[$position]}=${gpu_names[$position]} uuid=${gpu_uuids[$position]} bus=${gpu_buses[$position]} sm=${gpu_sm[$position]} backend=${gpu_backends[$position]} profile=${gpu_profiles[$position]} threads=${gpu_threads[$position]} chunk=262144"
  done
} > "${runtime_log}"

rm -f "${workers_file}" "${exit_file}"
declare -a miner_pids proxy_pids monitor_pids worker_dirs worker_ports
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
  for pid in "${monitor_pids[@]:-}"; do terminate_pid "${pid}"; done
  for pid in "${miner_pids[@]:-}"; do terminate_pid "${pid}"; done
  sleep 1
  for pid in "${miner_pids[@]:-}"; do kill -KILL "${pid}" 2>/dev/null || true; done
  for pid in "${proxy_pids[@]:-}"; do terminate_pid "${pid}"; done
  sleep 1
  for pid in "${monitor_pids[@]:-}" "${proxy_pids[@]:-}"; do
    [[ "${pid}" =~ ^[1-9][0-9]*$ ]] && kill -KILL "${pid}" 2>/dev/null || true
  done
  for pid in "${monitor_pids[@]:-}" "${miner_pids[@]:-}" "${proxy_pids[@]:-}"; do
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
  gpu_profile="${gpu_profiles[$position]}"
  gpu_backend="${gpu_backends[$position]}"
  gpu_thread_count="${gpu_threads[$position]}"
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

  worker_dirs+=("${worker_dir}")
  ./libexec/stratum-replay-proxy.py \
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
    echo "[ERROR] GPU ${gpu_index}: proxy failed to start on port ${proxy_port}" >&2
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

  printf '[START] GPU %s %s sm_%s profile=%s proxy_port=%s\n' \
    "${gpu_index}" "${gpu_name}" "${gpu_sm[$position]}" "${gpu_profile}" "${proxy_port}"
  CUDA_VISIBLE_DEVICES="${gpu_uuid}" \
    PEPEW_BINARY_PROFILE="${gpu_backend}" \
    PEPEW_PHYSICAL_GPU_INDEX="${gpu_index}" \
    PEPEPOW_PROFILE="${gpu_profile}" \
    PEPEPOW_CUDA_THREADS_RUNTIME="${gpu_thread_count}" \
    PEPEPOW_STATS_INTERVAL="${PEPEPOW_STATS_INTERVAL}" \
    ./pepepowminer "${args[@]}" >> "${console_log}" 2>&1 &
  miner_pid=$!
  miner_pids+=("${miner_pid}")
  echo "${miner_pid}" > "${worker_dir}/miner.pid"

  worker_ports+=("${proxy_port}")
done

gpu_list_csv="$(IFS=,; printf '%s' "${gpu_indices[*]}")"
{
  printf 'GPU_COUNT=%q\n' "${#gpu_indices[@]}"
  printf 'GPU_LIST=%q\n' "${gpu_list_csv}"
  for ((position=0; position<${#gpu_indices[@]}; ++position)); do
    index="${gpu_indices[$position]}"
    printf 'GPU%s_PID=%q\n' "${index}" "${miner_pids[$position]}"
    printf 'GPU%s_PROXY_PID=%q\n' "${index}" "${proxy_pids[$position]}"
    printf 'GPU%s_PORT=%q\n' "${index}" "${worker_ports[$position]}"
    printf 'GPU%s_UUID=%q\n' "${index}" "${gpu_uuids[$position]}"
    printf 'GPU%s_NAME=%q\n' "${index}" "${gpu_names[$position]}"
    printf 'GPU%s_SM=%q\n' "${index}" "${gpu_sm[$position]}"
    printf 'GPU%s_BINARY_PROFILE=%q\n' "${index}" "${gpu_backends[$position]}"
    printf 'GPU%s_PROFILE=%q\n' "${index}" "${gpu_profiles[$position]}"
  done
} > "${workers_file}"

./libexec/console-monitor.sh "${miner_dir}" "${PEPEPOW_STATS_INTERVAL}" &
monitor_pids+=("$!")

echo "[READY] PepeW Miner ${package_version} workers started: ${#miner_pids[@]}"

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
      echo "[ERROR] GPU ${gpu_index} proxy exited"
      tail -n 40 "${log_dir}/gpu${gpu_index}/proxy-console.log" 2>/dev/null || true
      break 2
    fi
    if ! kill -0 "${miner_pid}" 2>/dev/null; then
      set +e; wait "${miner_pid}"; failure_status=$?; set -e
      (( failure_status == 0 )) && failure_status=71
      failure_reason="gpu${gpu_index}_miner_exit"
      echo "[ERROR] GPU ${gpu_index} miner exited"
      tail -n 60 "${log_dir}/gpu${gpu_index}/pepew.log" 2>/dev/null || true
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

