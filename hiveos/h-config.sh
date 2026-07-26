#!/usr/bin/env bash
set -euo pipefail

# v0.1.3 passes HiveOS settings directly to h-run.sh.
# Keep this hook for HiveOS compatibility, but do not generate config.txt.
if [[ -z "${CUSTOM_URL:-}" ]]; then
  echo "HiveOS pool URL is missing (CUSTOM_URL)" >&2
  exit 1
fi
if [[ -z "${CUSTOM_TEMPLATE:-}" ]]; then
  echo "HiveOS wallet/template is missing (CUSTOM_TEMPLATE)" >&2
  exit 1
fi

exit 0
