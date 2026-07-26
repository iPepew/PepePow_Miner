#!/usr/bin/env bash
set -u

miner_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
version_file="${miner_dir}/VERSION"
log_file="${miner_dir}/pepepow-debug.log"

if [[ -r "${version_file}" ]]; then
  version="$(head -n 1 "${version_file}" | tr -d '\r\n')"
else
  version="unknown"
fi

accepted=0
rejected=0
uptime=0
if [[ -r "${log_file}" ]]; then
  accepted="$(grep -c 'Share accepted' "${log_file}" 2>/dev/null || true)"
  rejected="$(grep -c 'Share rejected' "${log_file}" 2>/dev/null || true)"
fi
pid="$(pgrep -f "${miner_dir}/pepepowminer" | head -n1 || true)"
if [[ -n "${pid}" ]]; then
  uptime="$(ps -o etimes= -p "${pid}" 2>/dev/null | tr -d ' ' || true)"
fi
uptime="${uptime:-0}"

# Hashrate remains zero until a native rate counter is added. Returning an
# explicit zero prevents HiveOS from retaining stale data from another miner.
khs=0
stats=$(printf '{"hs":[0],"hs_units":"hs","ar":[%s,%s,0],"uptime":%s,"ver":"%s","algo":"hoohash"}' \
  "${accepted:-0}" "${rejected:-0}" "${uptime}" "${version}")
