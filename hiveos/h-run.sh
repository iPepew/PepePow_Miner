#!/usr/bin/env bash
set -euo pipefail

# Resolve the installed package directory from this script. HiveOS can export a
# generic MINER_DIR pointing at /hive/miners/custom, which must not be used here.
miner_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${miner_dir}"

if [[ ! -x ./pepepowminer ]]; then
  echo "pepepowminer binary is missing or not executable" >&2
  exit 1
fi

conf_file="${miner_dir}/config.txt"
if [[ ! -s "${conf_file}" ]]; then
  # HiveOS normally calls h-config.sh before h-run.sh. Regenerate if needed.
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

{
  echo "Miner directory: ${miner_dir}"
  printf './pepepowminer'
  printf ' %q' "${PEPEPOW_ARGS[@]}"
  echo
} > "${miner_dir}/run.txt"

exec ./pepepowminer "${PEPEPOW_ARGS[@]}"
