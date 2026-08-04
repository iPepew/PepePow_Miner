#!/usr/bin/env bash
set -Eeuo pipefail

CUSTOM_ROOT=/hive/miners/custom
OFFICIAL_BASE=https://raw.githubusercontent.com/minershive/hiveos-linux/master/hive/miners/custom
BACKUP=/root/hiveos-custom-dispatcher-backup-$(date +%Y%m%d-%H%M%S)

mkdir -p "${CUSTOM_ROOT}" "${CUSTOM_ROOT}/downloads" "${BACKUP}"

for file in h-manifest.conf h-config.sh h-run.sh h-stats.sh custom-get; do
  if [[ -e "${CUSTOM_ROOT}/${file}" ]]; then
    cp -a "${CUSTOM_ROOT}/${file}" "${BACKUP}/${file}"
  fi
  curl -fsSL "${OFFICIAL_BASE}/${file}" -o "${CUSTOM_ROOT}/${file}"
done

chmod 0755 \
  "${CUSTOM_ROOT}/h-config.sh" \
  "${CUSTOM_ROOT}/h-run.sh" \
  "${CUSTOM_ROOT}/h-stats.sh" \
  "${CUSTOM_ROOT}/custom-get"
chmod 0644 "${CUSTOM_ROOT}/h-manifest.conf"

grep -Fqx 'MINER_NAME=custom' "${CUSTOM_ROOT}/h-manifest.conf"
grep -Fq 'function miner_config_gen()' "${CUSTOM_ROOT}/h-config.sh"
grep -Fq '$MINER_DIR/$CUSTOM_MINER/h-run.sh' "${CUSTOM_ROOT}/h-run.sh"
grep -Fq '$MINER_DIR/$CUSTOM_MINER/h-stats.sh' "${CUSTOM_ROOT}/h-stats.sh"

echo "HIVEOS_CUSTOM_DISPATCHER_GATE=PASS"
echo "BACKUP=${BACKUP}"
