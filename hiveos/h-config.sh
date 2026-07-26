#!/usr/bin/env bash
set -euo pipefail

conf_file="${CUSTOM_CONFIG_FILENAME:-${MINER_DIR:-.}/config.txt}"
args=()

if [[ -n "${CUSTOM_URL:-}" ]]; then
  args+=("-o" "${CUSTOM_URL}")
fi
if [[ -n "${CUSTOM_TEMPLATE:-}" ]]; then
  args+=("-u" "${CUSTOM_TEMPLATE}")
fi
args+=("-p" "${CUSTOM_PASS:-x}" "--pepepow")

if [[ -n "${CUSTOM_USER_CONFIG:-}" ]]; then
  # HiveOS custom arguments are intentionally appended last.
  # shellcheck disable=SC2206
  extra=( ${CUSTOM_USER_CONFIG} )
  args+=("${extra[@]}")
fi

printf '%q ' "${args[@]}" > "${conf_file}"
printf '\n' >> "${conf_file}"
