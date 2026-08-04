#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

ROOT_NAME="PepeW-Miner-v1.0.2-HiveOS"
SOURCE_DIR="${1:-/hive/miners/custom/${ROOT_NAME}}"
OUT_DIR="${2:-/root/pepepow-tests}"
ARCHIVE="${OUT_DIR}/PepeW-Miner-v1.0.2-HiveOS-sm86.tar.gz"
SHA_FILE="${ARCHIVE}.sha256"

required=(
  BUILD_PROFILE LICENSE README.md RELEASE_MANIFEST.txt RELEASE_NOTES_v1.0.2.md
  VERSION h-config.sh h-manifest.conf h-run.sh h-stats.sh pepepowminer
  pepepowminer.sha256 stratum-replay-proxy.py
)

[[ -d "${SOURCE_DIR}" ]] || { echo "ERROR: source directory missing: ${SOURCE_DIR}" >&2; exit 1; }
for file in "${required[@]}"; do
  [[ -f "${SOURCE_DIR}/${file}" ]] || { echo "ERROR: missing package file: ${file}" >&2; exit 1; }
done

grep -Fqx 'CUSTOM_NAME=PepeW-Miner-v1.0.2-HiveOS' "${SOURCE_DIR}/h-manifest.conf" || {
  echo "ERROR: HiveOS manifest miner name mismatch" >&2
  exit 1
}
grep -Fqx 'CUSTOM_VERSION=1.0.2' "${SOURCE_DIR}/h-manifest.conf" || {
  echo "ERROR: HiveOS manifest version mismatch" >&2
  exit 1
}
grep -Fqx 'CUSTOM_CONFIG_FILENAME=/hive/miners/custom/PepeW-Miner-v1.0.2-HiveOS/config.txt' \
  "${SOURCE_DIR}/h-manifest.conf" || {
  echo "ERROR: HiveOS manifest config path mismatch" >&2
  exit 1
}

grep -Fq '"hs":%s' "${SOURCE_DIR}/h-stats.sh" || {
  echo "ERROR: per-GPU hs[] telemetry missing" >&2
  exit 1
}
grep -Fq '"ver":"1.0.2"' "${SOURCE_DIR}/h-stats.sh" || {
  echo "ERROR: telemetry version mismatch" >&2
  exit 1
}

bash -n "${SOURCE_DIR}/h-config.sh"
bash -n "${SOURCE_DIR}/h-run.sh"
bash -n "${SOURCE_DIR}/h-stats.sh"
(cd "${SOURCE_DIR}" && sha256sum -c pepepowminer.sha256)

mkdir -p "${OUT_DIR}"
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
mkdir -p "${STAGE}/${ROOT_NAME}"
for file in "${required[@]}"; do
  cp -a "${SOURCE_DIR}/${file}" "${STAGE}/${ROOT_NAME}/${file}"
done
chmod 0755 \
  "${STAGE}/${ROOT_NAME}/pepepowminer" \
  "${STAGE}/${ROOT_NAME}/h-config.sh" \
  "${STAGE}/${ROOT_NAME}/h-run.sh" \
  "${STAGE}/${ROOT_NAME}/h-stats.sh" \
  "${STAGE}/${ROOT_NAME}/stratum-replay-proxy.py"

rm -f "${ARCHIVE}" "${SHA_FILE}"
tar -C "${STAGE}" -czf "${ARCHIVE}" "${ROOT_NAME}"
sha256sum "${ARCHIVE}" >"${SHA_FILE}"

FIRST="$(tar -tzf "${ARCHIVE}" | sed -n '1p')"
[[ "${FIRST}" == "${ROOT_NAME}/" ]] || {
  echo "ERROR: invalid archive root: ${FIRST}" >&2
  exit 1
}
tar -tzf "${ARCHIVE}" | grep -Fqx "${ROOT_NAME}/h-manifest.conf" || {
  echo "ERROR: h-manifest.conf missing from expected archive directory" >&2
  exit 1
}

if tar -tzf "${ARCHIVE}" | grep -Eq '(^|/)(config\.txt|setup\.txt|run\.txt|.*\.log(\.previous)?|.*\.pid|miner-status\.env)$'; then
  echo "ERROR: runtime or generated configuration artifact detected" >&2
  exit 1
fi

echo "PACKAGE_ROOT_CHECK=PASS root=${ROOT_NAME}/"
echo "HIVEOS_MANIFEST=PASS"
echo "PER_GPU_HS_SCHEMA=PASS"
echo "ARCHIVE=${ARCHIVE}"
echo "SHA256_FILE=${SHA_FILE}"
