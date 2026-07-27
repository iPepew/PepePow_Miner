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
         pepepow-debug.log pepepow-debug.log.previous stratum-proxy.log proxy.pid stratum-replay-proxy.py \
         miner-console.log runtime-diagnostics.txt miner-exit-status.txt; do
  [[ -e "${self_dir}/${f}" ]] && cp -a "${self_dir}/${f}" "${work}/${f}"
done

if [[ -r "${self_dir}/pepepow-debug.log" ]]; then
  grep ' HASHRATE hps=' "${self_dir}/pepepow-debug.log" \
    > "${work}/hashrate-samples.txt" 2>/dev/null || true
  grep -E 'Share accepted|Share rejected|FINAL_STATS|WORKER_ERROR|CANDIDATE|SUBMIT' \
    "${self_dir}/pepepow-debug.log" > "${work}/share-performance-evidence.txt" 2>/dev/null || true
fi

{
  MINER_DIR="${self_dir}" source "${self_dir}/h-stats.sh" 2>/dev/null || true
  printf '%s\n' "${stats:-unavailable}"
} > "${work}/hiveos-current-stats.json"

if [[ -r "${self_dir}/stratum-proxy.log" ]]; then
  grep -E 'PROXY_START|MINER_TX .*mining.submit|NONCE_REWRITE|POOL_RX .*result|POOL_RX .*error' \
    "${self_dir}/stratum-proxy.log" > "${work}/stratum-submit-evidence.txt" 2>/dev/null || true
fi

if [[ -r "${self_dir}/miner-console.log" ]]; then
  tail -n 3000 "${self_dir}/miner-console.log" > "${work}/miner-console-tail.txt" 2>/dev/null || true
  grep -Ein 'fatal|error|exception|terminate|abort|segmentation|cuda|proxy|exit|failed' \
    "${self_dir}/miner-console.log" > "${work}/crash-keywords.txt" 2>/dev/null || true
fi

ps auxww > "${work}/ps.txt" 2>&1 || true
screen -ls > "${work}/screen-ls.txt" 2>&1 || true
nvidia-smi -q > "${work}/nvidia-smi-q.txt" 2>&1 || true
nvidia-smi dmon -c 3 > "${work}/nvidia-dmon.txt" 2>&1 || true
nvidia-smi --query-gpu=timestamp,name,utilization.gpu,utilization.memory,clocks.sm,clocks.mem,power.draw,power.limit,temperature.gpu,memory.used,memory.total --format=csv \
  > "${work}/nvidia-performance.csv" 2>&1 || true
dmesg -T | tail -n 1000 > "${work}/dmesg-tail.txt" 2>&1 || true
journalctl -n 1000 --no-pager > "${work}/journal-tail.txt" 2>&1 || true
ip addr show > "${work}/ip-addr.txt" 2>&1 || true
ip route show > "${work}/ip-route.txt" 2>&1 || true
ss -lntup > "${work}/sockets.txt" 2>&1 || true

if command -v coredumpctl >/dev/null 2>&1; then
  coredumpctl list --no-pager > "${work}/coredump-list.txt" 2>&1 || true
  coredumpctl info --no-pager > "${work}/coredump-info.txt" 2>&1 || true
fi

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "${self_dir}/pepepowminer" "${self_dir}"/*.sh "${self_dir}"/*.py "${self_dir}/VERSION" \
    > "${work}/sha256.txt" 2>/dev/null || true
fi

tar -C "${self_dir}" -czf "${archive}" "$(basename "${work}")"
echo "${archive}"
