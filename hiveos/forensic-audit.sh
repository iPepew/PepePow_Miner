#!/usr/bin/env bash
set -euo pipefail

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="${1:-${self_dir}/forensic-audit.txt}"
version="unknown"
[[ -r "${self_dir}/VERSION" ]] && version="$(head -n1 "${self_dir}/VERSION" | tr -d '\r\n')"

pid="$(pgrep -f "${self_dir}/pepepowminer" | head -n1 || true)"
log_file="${self_dir}/pepepow-debug.log"

{
  echo "PepePow Forensic Audit"
  date -u +"UTC: %Y-%m-%dT%H:%M:%SZ"
  echo "Expected package dir: ${self_dir}"
  echo "Expected version: ${version}"
  echo

  echo "== Package identity =="
  "${self_dir}/pepepowminer" --version 2>&1 || true
  cat "${self_dir}/VERSION" 2>/dev/null || true
  cat "${self_dir}/h-manifest.conf" 2>/dev/null || true
  echo

  echo "== File ownership and permissions =="
  stat -c '%A %U:%G %s %n' "${self_dir}"/* 2>/dev/null || true
  echo

  echo "== Runtime process =="
  if [[ -n "${pid}" ]]; then
    echo "PID=${pid}"
    tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null; echo
    echo "cwd=$(readlink -f "/proc/${pid}/cwd" 2>/dev/null || true)"
    echo "exe=$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)"
    echo "elapsed=$(ps -o etimes= -p "${pid}" 2>/dev/null | tr -d ' ')"
  else
    echo "miner process not running"
  fi
  echo

  echo "== HiveOS generated files =="
  for f in config.txt setup.txt run.txt; do
    echo "--- ${f} ---"
    cat "${self_dir}/${f}" 2>/dev/null || echo "MISSING: ${self_dir}/${f}"
  done
  echo

  echo "== HiveOS stats callback =="
  MINER_DIR="${self_dir}" bash -c 'source "$MINER_DIR/h-stats.sh"; echo "hps=${hps:-0}"; echo "$stats"' 2>&1 || true
  echo

  echo "== Optimization markers =="
  grep -E 'OPTIMIZATION=|Optimizations:' "${self_dir}/runtime-diagnostics.txt" "${self_dir}/run.txt" 2>/dev/null || true
  echo

  echo "== Path contamination scan =="
  grep -R --line-number -E '0\.1\.4|0\.3\.7-consensus-math|/hive/miners/custom/pepepow-debug\.log|/hive/miners/custom/diagnostic-summary\.txt' "${self_dir}" 2>/dev/null || true
  echo

  echo "== GPU =="
  nvidia-smi --query-gpu=index,name,pci.bus_id,uuid,driver_version,compute_cap,temperature.gpu,power.draw,clocks.sm,clocks.mem,utilization.gpu --format=csv,noheader 2>&1 || true
  echo

  echo "== Diagnostic log status =="
  if [[ -f "${log_file}" ]]; then
    stat -c 'size=%s modified=%y path=%n' "${log_file}"
    echo "accepted=$(grep -c 'Share accepted' "${log_file}" || true)"
    echo "rejected=$(grep -c 'Share rejected' "${log_file}" || true)"
    echo "candidate=$(grep -c 'CANDIDATE ' "${log_file}" || true)"
    echo "gpu_cpu_mismatch=$(grep -c 'match=0' "${log_file}" || true)"
    echo "target_fail=$(grep -c 'target_ok=0' "${log_file}" || true)"
    echo "latest hashrate:"
    grep ' HASHRATE hps=' "${log_file}" | tail -n 20 || true
    echo "latest records:"
    grep -E 'BUILD_ID|JOB |JOB_HEADER|HASHRATE|CANDIDATE|SHARE_TRACE|SUBMIT|Share accepted|Share rejected|WORKER_ERROR|Fatal' "${log_file}" | tail -n 300 || true
  else
    echo "diagnostic log missing: ${log_file}"
  fi
} > "${out}"

echo "${out}"
