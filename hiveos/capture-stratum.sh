#!/usr/bin/env bash
set -euo pipefail

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
duration="${1:-120}"
out="${2:-${self_dir}/stratum-capture.txt}"

if ! command -v tcpdump >/dev/null 2>&1; then
  echo "tcpdump is not installed" >&2
  exit 2
fi

port="$(grep -Eo 'stratum\+tcp://[^ ]+:[0-9]+' "${self_dir}/run.txt" 2>/dev/null | head -n1 | sed -E 's/.*:([0-9]+)$/\1/' || true)"
if [[ -z "${port}" ]]; then
  port="39333"
fi

echo "Capturing plaintext Stratum on TCP port ${port} for ${duration}s"
echo "Output: ${out}"
timeout "${duration}" tcpdump -i any -s 0 -A "tcp port ${port}" > "${out}" 2>&1 || rc=$?
rc="${rc:-0}"
if [[ "${rc}" -ne 0 && "${rc}" -ne 124 ]]; then
  exit "${rc}"
fi

grep -E 'mining\.(subscribe|authorize|set_difficulty|set_extranonce|notify|submit)|"result"|"error"' "${out}" > "${self_dir}/stratum-filtered.txt" 2>/dev/null || true
echo "${out}"
