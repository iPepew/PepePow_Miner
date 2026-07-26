#!/usr/bin/env bash
set -u

miner_dir="${MINER_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
version_file="${miner_dir}/VERSION"

if [[ -r "${version_file}" ]]; then
  version="$(head -n 1 "${version_file}" | tr -d '\r\n')"
else
  version="unknown"
fi

# Until the native runtime API is available, return an explicit zero value.
# An empty hs array makes HiveOS retain stale statistics from a previous miner.
khs=0
stats=$(printf '{"hs":[0],"hs_units":"hs","ar":[0,0,0],"uptime":0,"ver":"%s","algo":"hoohash"}' "${version}")
