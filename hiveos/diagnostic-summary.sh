#!/usr/bin/env bash
set -euo pipefail

# The script is installed directly inside the miner package. Resolve that exact
# directory and ignore HiveOS' generic MINER_DIR environment variable.
miner_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
diagnostic_log="${1:-${miner_dir}/pepepow-debug.log}"
out_file="${2:-${miner_dir}/diagnostic-summary.txt}"

{
  echo "PepePow Miner diagnostic summary"
  date -u +"UTC: %Y-%m-%dT%H:%M:%SZ"
  echo "Miner directory: ${miner_dir}"
  echo "Diagnostic log: ${diagnostic_log}"
  echo
  echo "== Build identity =="
  "${miner_dir}/pepepowminer" --version 2>&1 || true
  echo
  echo "== GPU =="
  nvidia-smi --query-gpu=index,name,uuid,driver_version,compute_cap,pci.bus_id --format=csv,noheader 2>&1 || true
  echo
  echo "== HiveOS package =="
  cat "${miner_dir}/h-manifest.conf" 2>&1 || true
  echo
  echo "== Runtime config =="
  cat "${miner_dir}/config.txt" 2>&1 || true
  echo
  echo "== Setup =="
  cat "${miner_dir}/setup.txt" 2>&1 || true
  echo
  echo "== Run command =="
  cat "${miner_dir}/run.txt" 2>&1 || true
  echo
  echo "== Key runtime records =="
  grep -E 'BUILD_ID|JOB |JOB_HEADER|CANDIDATE|SHARE_TRACE|SUBMIT|STRATUM|Share accepted|Share rejected|CUDA candidate|Worker error|Fatal|FINAL_STATS' "${diagnostic_log}" 2>/dev/null | tail -n 1000 || true
} > "${out_file}"

echo "${out_file}"
