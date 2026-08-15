#!/usr/bin/env bash

miner_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${miner_dir}"
conf_file="${CUSTOM_CONFIG_FILENAME:-${miner_dir}/config.txt}"

if [[ ! -x ./pepepowminer ]]; then
  echo "pepepowminer binary is missing or not executable" >&2
  return 1 2>/dev/null || exit 1
fi
if [[ ! -s "${conf_file}" ]]; then
  echo "HiveOS miner config is missing: ${conf_file}" >&2
  return 1 2>/dev/null || exit 1
fi

# h-config.sh writes shell-escaped CLI arguments.
args=$(cat "${conf_file}")

# HiveOS versions differ: some source h-run.sh, older custom wrappers execute it.
# Avoid replacing the parent HiveOS shell when sourced, but keep exec semantics when run directly.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  eval "./pepepowminer ${args}"
else
  eval "exec ./pepepowminer ${args}"
fi
