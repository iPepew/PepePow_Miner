#!/usr/bin/env bash
set -euo pipefail

cd "${MINER_DIR:-$(dirname "$0")}" 

if [[ ! -x ./pepepowminer ]]; then
  echo "pepepowminer binary is missing or not executable" >&2
  exit 1
fi

pool="${CUSTOM_URL:-}"
user="${CUSTOM_TEMPLATE:-}"
pass="${CUSTOM_PASS:-x}"

if [[ -z "${pool}" ]]; then
  echo "HiveOS pool URL is missing (CUSTOM_URL)" >&2
  exit 1
fi
if [[ -z "${user}" ]]; then
  echo "HiveOS wallet/template is missing (CUSTOM_TEMPLATE)" >&2
  exit 1
fi

args=("-o" "${pool}" "-u" "${user}" "-p" "${pass}" "--pepepow")

if [[ -n "${CUSTOM_USER_CONFIG:-}" ]]; then
  # HiveOS custom arguments are appended last.
  # shellcheck disable=SC2206
  extra=( ${CUSTOM_USER_CONFIG} )
  args+=("${extra[@]}")
fi

exec ./pepepowminer "${args[@]}"
