#!/usr/bin/env bash
set -euo pipefail

miner_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
diagnostic_log="${1:-${miner_dir}/pepepow-debug.log}"
out_file="${2:-${miner_dir}/diagnostic-summary.txt}"

{
  echo "PepeW Miner performance/stability summary"
  date -u +"UTC: %Y-%m-%dT%H:%M:%SZ"
  echo "Miner directory: ${miner_dir}"
  echo "Diagnostic log: ${diagnostic_log}"
  echo
  echo "== Build identity =="
  "${miner_dir}/pepepowminer" --version 2>&1 || true
  echo
  echo "== Exit status =="
  cat "${miner_dir}/miner-exit-status.txt" 2>&1 || true
  echo
  echo "== Runtime status =="
  cat "${miner_dir}/miner-status.env" 2>&1 || true
  echo "miner.pid=$(cat "${miner_dir}/miner.pid" 2>/dev/null || true)"
  echo "proxy.pid=$(cat "${miner_dir}/proxy.pid" 2>/dev/null || true)"
  echo
  echo "== HiveOS current stats =="
  MINER_DIR="${miner_dir}" source "${miner_dir}/h-stats.sh" 2>/dev/null || true
  printf '%s\n' "${stats:-unavailable}"
  echo
  echo "== Native hashrate samples =="
  grep ' HASHRATE hps=' "${diagnostic_log}" 2>/dev/null | tail -n 120 || true
  echo
  echo "== Share totals =="
  printf 'accepted=%s\n' "$(grep -c 'Share accepted' "${diagnostic_log}" 2>/dev/null || true)"
  printf 'rejected=%s\n' "$(grep -c 'Share rejected' "${diagnostic_log}" 2>/dev/null || true)"
  printf 'job_not_found=%s\n' "$(grep -c 'reason=job not found' "${diagnostic_log}" 2>/dev/null || true)"
  printf 'low_difficulty=%s\n' "$(grep -c 'reason=low difficulty' "${diagnostic_log}" 2>/dev/null || true)"
  printf 'candidates=%s\n' "$(grep -c 'CANDIDATE' "${diagnostic_log}" 2>/dev/null || true)"
  printf 'cpu_gpu_mismatch=%s\n' "$(grep -c 'match=0' "${diagnostic_log}" 2>/dev/null || true)"
  echo
  echo "== Target boundary records =="
  grep -E 'target_source=nbits_div_difficulty|target_be=' "${diagnostic_log}" 2>/dev/null | tail -n 200 || true
  echo
  echo "== GPU =="
  nvidia-smi --query-gpu=index,name,uuid,driver_version,compute_cap,pci.bus_id,utilization.gpu,clocks.sm,clocks.mem,power.draw,temperature.gpu --format=csv,noheader 2>&1 || true
  echo
  echo "== HiveOS package =="
  cat "${miner_dir}/h-manifest.conf" 2>&1 || true
  echo
  echo "== Runtime config =="
  cat "${miner_dir}/config.txt" 2>&1 || true
  echo
  echo "== Run command =="
  cat "${miner_dir}/run.txt" 2>&1 || true
  echo
  echo "== Runtime diagnostics =="
  cat "${miner_dir}/runtime-diagnostics.txt" 2>&1 || true
  echo
  echo "== Miner console tail =="
  tail -n 1000 "${miner_dir}/miner-console.log" 2>&1 || true
  echo
  echo "== Proxy tail =="
  tail -n 500 "${miner_dir}/stratum-proxy.log" 2>&1 || true
  echo
  echo "== Key runtime records =="
  grep -E 'BUILD_ID|POOL_REFERENCE|JOB |JOB_HEADER|HASHRATE|CANDIDATE|SHARE_TRACE|SUBMIT|STRATUM|Share accepted|Share rejected|WORKER_ERROR|Fatal|FINAL_STATS' "${diagnostic_log}" 2>/dev/null | tail -n 1500 || true
} > "${out_file}"

echo "${out_file}"
