#!/usr/bin/env bash
set -euo pipefail

miner_dir="${MINER_DIR:-$(cd "$(dirname "$0")" && pwd)}"
cd "${miner_dir}"

if [[ ! -x ./pepepowminer ]]; then
  echo "pepepowminer binary is missing or not executable" >&2
  exit 1
fi

conf_file="${CUSTOM_CONFIG_FILENAME:-${miner_dir}/config.txt}"
if [[ ! -s "${conf_file}" ]]; then
  # HiveOS normally calls h-config.sh before h-run.sh. Regenerate the file if
  # the agent skipped that callback or the package was reinstalled.
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
  printf './pepepowminer'
  printf ' %q' "${PEPEPOW_ARGS[@]}"
  echo
} > run.txt

exec ./pepepowminer "${PEPEPOW_ARGS[@]}"
