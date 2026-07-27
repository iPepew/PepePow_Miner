#!/usr/bin/env bash
set -u

miner_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log_file="${miner_dir}/pepepow-debug.log"

accepted=0
rejected=0
uptime=0
hps=0
if [[ -r "${log_file}" ]]; then
  accepted="$(grep -c 'Share accepted' "${log_file}" 2>/dev/null || true)"
  rejected="$(grep -c 'Share rejected' "${log_file}" 2>/dev/null || true)"
  last_rate="$(grep ' HASHRATE hps=' "${log_file}" 2>/dev/null | tail -n1 || true)"
  parsed_rate="$(sed -n 's/.* hps=\([0-9][0-9]*\).*/\1/p' <<<"${last_rate}")"
  if [[ "${parsed_rate}" =~ ^[0-9]+$ ]]; then
    hps="${parsed_rate}"
  fi
fi

pid="$(pgrep -f "${miner_dir}/pepepowminer" | head -n1 || true)"
if [[ -n "${pid}" ]]; then
  uptime="$(ps -o etimes= -p "${pid}" 2>/dev/null | tr -d ' ' || true)"
else
  hps=0
fi
uptime="${uptime:-0}"

# Keep ver empty: HiveOS already displays the short custom package name before
# "(c)". Returning it here would duplicate the label and break mobile layout.
stats=$(printf '{"hs":[%s],"hs_units":"hs","ar":[%s,%s,0],"uptime":%s,"ver":"","algo":"hoohash"}' \
  "${hps:-0}" "${accepted:-0}" "${rejected:-0}" "${uptime}")
