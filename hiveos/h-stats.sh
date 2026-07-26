#!/usr/bin/env bash
set -u

miner_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log_file="${miner_dir}/pepepow-debug.log"

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

# Hashrate remains zero until a native runtime rate counter is added. Returning
# an explicit zero prevents HiveOS from retaining stale data from another miner.
# Keep ver empty: HiveOS already displays the custom miner package name before
# "(c)". Returning the package version here duplicates the same label in UI.
khs=0
stats=$(printf '{"hs":[0],"hs_units":"hs","ar":[%s,%s,0],"uptime":%s,"ver":"","algo":"hoohash"}' \
  "${accepted:-0}" "${rejected:-0}" "${uptime}")
