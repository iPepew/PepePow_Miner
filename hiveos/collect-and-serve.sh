#!/usr/bin/env bash
set -euo pipefail

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# One command performs a consistent stop, collects every relevant file and
# exposes only /tmp over HTTP for download.
if command -v miner >/dev/null 2>&1; then
  miner stop >/dev/null 2>&1 || true
  sleep 3
fi

archive="$(${self_dir}/collect-forensics.sh)"
archive_name="$(basename "${archive}")"
rig_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

printf '\nREADY: %s\n' "${archive}"
printf 'DOWNLOAD: http://%s:8080/%s\n' "${rig_ip:-RIG_IP}" "${archive_name}"
printf 'After downloading, press Ctrl+C to stop the temporary server.\n\n'

cd /tmp
exec python3 -m http.server 8080 --bind 0.0.0.0
