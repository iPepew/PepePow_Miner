#!/usr/bin/env bash
set -euo pipefail

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
work="${self_dir}/forensics-${stamp}"
archive="/tmp/pepepow-forensics-${stamp}.tar.gz"
mkdir -p "${work}"

"${self_dir}/forensic-audit.sh" "${work}/forensic-audit.txt" || true
"${self_dir}/diagnostic-summary.sh" "${self_dir}/pepepow-debug.log" "${work}/diagnostic-summary.txt" || true

for f in VERSION h-manifest.conf h-config.sh h-run.sh h-stats.sh config.txt setup.txt run.txt \
         pepepow-debug.log stratum-proxy.log proxy.pid stratum-replay-proxy.py; do
  [[ -e "${self_dir}/${f}" ]] && cp -a "${self_dir}/${f}" "${work}/${f}"
done

# Produce compact submit/reply evidence for quick comparison.
if [[ -r "${self_dir}/stratum-proxy.log" ]]; then
  grep -E 'PROXY_START|MINER_TX .*mining.submit|NONCE_REWRITE|POOL_RX .*result|POOL_RX .*error' \
    "${self_dir}/stratum-proxy.log" > "${work}/stratum-submit-evidence.txt" 2>/dev/null || true
fi

ps auxww > "${work}/ps.txt" 2>&1 || true
nvidia-smi -q > "${work}/nvidia-smi-q.txt" 2>&1 || true
nvidia-smi dmon -c 3 > "${work}/nvidia-dmon.txt" 2>&1 || true
dmesg -T | tail -n 500 > "${work}/dmesg-tail.txt" 2>&1 || true
journalctl -n 500 --no-pager > "${work}/journal-tail.txt" 2>&1 || true
ip addr show > "${work}/ip-addr.txt" 2>&1 || true
ip route show > "${work}/ip-route.txt" 2>&1 || true
ss -ntp > "${work}/sockets.txt" 2>&1 || true

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "${self_dir}/pepepowminer" "${self_dir}"/*.sh "${self_dir}"/*.py "${self_dir}/VERSION" \
    > "${work}/sha256.txt" 2>/dev/null || true
fi

tar -C "${self_dir}" -czf "${archive}" "$(basename "${work}")"
echo "${archive}"
