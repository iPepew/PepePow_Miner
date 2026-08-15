#!/usr/bin/env bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
conf_file="${CUSTOM_CONFIG_FILENAME:-${script_dir}/config.txt}"
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

mkdir -p "$(dirname "${conf_file}")"
printf '%q ' "${args[@]}" > "${conf_file}"
printf '\n' >> "${conf_file}"
echo "PepeW config generated: ${conf_file}"
