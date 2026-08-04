#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

ROOT_NAME="PepeW-Miner-v1.0.3-HiveOS"
PACKAGE_VERSION="1.0.3"
ASSET_VERSION="1.0.3.1"
SOURCE_DIR="${1:-/hive/miners/custom/${ROOT_NAME}}"
OUT_DIR="${2:-/root/pepepow-tests}"
ARCHIVE_NAME="${ROOT_NAME}-${ASSET_VERSION}.tar.gz"
ARCHIVE="${OUT_DIR}/${ARCHIVE_NAME}"
SHA_FILE="${ARCHIVE}.sha256"

required=(
  BUILD_PROFILE LICENSE README.md RELEASE_MANIFEST.txt RELEASE_NOTES_v1.0.3.md
  VERSION h-config.sh h-manifest.conf h-run.sh h-stats.sh pepepowminer
  pepepowminer.sha256 stratum-replay-proxy.py
)

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ -d "${SOURCE_DIR}" ]] || fail "source directory missing: ${SOURCE_DIR}"
for file in "${required[@]}"; do
  [[ -f "${SOURCE_DIR}/${file}" ]] || fail "missing package file: ${file}"
done

# Match the exact parsing implemented by HiveOS custom-get.
basename="${ARCHIVE_NAME%.tar.gz}"
detected_version="$(awk -F- '{print $NF}' <<<"${basename}")"
detected_miner="${basename%-${detected_version}}"
[[ "${detected_version}" == "${ASSET_VERSION}" ]] || fail "custom-get version parse mismatch"
[[ "${detected_miner}" == "${ROOT_NAME}" ]] || fail "custom-get miner parse mismatch: ${detected_miner}"

grep -Fqx "CUSTOM_NAME=${ROOT_NAME}" "${SOURCE_DIR}/h-manifest.conf" || fail "manifest miner name mismatch"
grep -Fqx "CUSTOM_VERSION=${PACKAGE_VERSION}" "${SOURCE_DIR}/h-manifest.conf" || fail "manifest version mismatch"
grep -Fqx "CUSTOM_CONFIG_FILENAME=/hive/miners/custom/${ROOT_NAME}/config.txt" \
  "${SOURCE_DIR}/h-manifest.conf" || fail "manifest config path mismatch"
grep -Fqx "CUSTOM_LOG_BASENAME=/var/log/miner/custom/${ROOT_NAME}/pepew" \
  "${SOURCE_DIR}/h-manifest.conf" || fail "manifest log path mismatch"

bash -n "${SOURCE_DIR}/h-config.sh"
bash -n "${SOURCE_DIR}/h-run.sh"
bash -n "${SOURCE_DIR}/h-stats.sh"

# The package h-config.sh is sourced by HiveOS' generic custom dispatcher and
# must immediately create config.txt inside its own package directory.
config_output="$({
  CUSTOM_NAME="${ROOT_NAME}"
  CUSTOM_VERSION="${PACKAGE_VERSION}"
  CUSTOM_CONFIG_FILENAME="${SOURCE_DIR}/config.txt"
  CUSTOM_URL="stratum+tcp://example.invalid:1234"
  CUSTOM_TEMPLATE="wallet.worker"
  CUSTOM_PASS="x"
  source "${SOURCE_DIR}/h-config.sh"
  [[ -s "${SOURCE_DIR}/config.txt" ]]
  grep -Fq 'PEPEPOW_UPSTREAM=' "${SOURCE_DIR}/config.txt"
  grep -Fq 'PEPEPOW_ARGS=(' "${SOURCE_DIR}/config.txt"
  echo PACKAGE_CONFIG_GATE=PASS
} 2>&1)" || fail "package config generation failed: ${config_output}"
echo "${config_output}"
rm -f "${SOURCE_DIR}/config.txt" "${SOURCE_DIR}/setup.txt"

(cd "${SOURCE_DIR}" && sha256sum -c pepepowminer.sha256)
"${SOURCE_DIR}/pepepowminer" --version | grep -Fq "PepeW Miner v${PACKAGE_VERSION}" || \
  fail "binary identity is not v${PACKAGE_VERSION}"

grep -Fq '"hs":%s' "${SOURCE_DIR}/h-stats.sh" || fail "per-GPU hs[] telemetry missing"
grep -Fq '"hs_units":"khs"' "${SOURCE_DIR}/h-stats.sh" || fail "hs_units telemetry missing"
grep -Fq '"ver":"1.0.3"' "${SOURCE_DIR}/h-stats.sh" || fail "telemetry version mismatch"

mkdir -p "${OUT_DIR}"
stage="$(mktemp -d)"
trap 'rm -rf "${stage}"' EXIT
mkdir -p "${stage}/${ROOT_NAME}"
for file in "${required[@]}"; do
  cp -a "${SOURCE_DIR}/${file}" "${stage}/${ROOT_NAME}/${file}"
done
chmod 0755 \
  "${stage}/${ROOT_NAME}/pepepowminer" \
  "${stage}/${ROOT_NAME}/h-config.sh" \
  "${stage}/${ROOT_NAME}/h-run.sh" \
  "${stage}/${ROOT_NAME}/h-stats.sh" \
  "${stage}/${ROOT_NAME}/stratum-replay-proxy.py"
chmod 0644 \
  "${stage}/${ROOT_NAME}/BUILD_PROFILE" \
  "${stage}/${ROOT_NAME}/LICENSE" \
  "${stage}/${ROOT_NAME}/README.md" \
  "${stage}/${ROOT_NAME}/RELEASE_MANIFEST.txt" \
  "${stage}/${ROOT_NAME}/RELEASE_NOTES_v1.0.3.md" \
  "${stage}/${ROOT_NAME}/VERSION" \
  "${stage}/${ROOT_NAME}/h-manifest.conf" \
  "${stage}/${ROOT_NAME}/pepepowminer.sha256"

rm -f "${ARCHIVE}" "${SHA_FILE}"
tar --sort=name --owner=0 --group=0 --numeric-owner \
  -C "${stage}" -cf - "${ROOT_NAME}" | gzip -n > "${ARCHIVE}"
(
  cd "${OUT_DIR}"
  sha256sum "${ARCHIVE_NAME}" > "$(basename "${SHA_FILE}")"
)

first="$(tar -tzf "${ARCHIVE}" | sed -n '1p')"
[[ "${first}" == "${ROOT_NAME}/" ]] || fail "invalid archive root: ${first}"
tar -tzf "${ARCHIVE}" | grep -Fqx "${ROOT_NAME}/h-manifest.conf" || \
  fail "h-manifest.conf missing from archive root"

if tar -tzf "${ARCHIVE}" | grep -Eq '(^|/)(config\.txt|setup\.txt|run\.txt|.*\.log(\.previous)?|.*\.pid|miner-status\.env)$'; then
  fail "runtime or generated configuration artifact detected"
fi

extract_test="$(mktemp -d)"
tar -xzf "${ARCHIVE}" -C "${extract_test}"
[[ -f "${extract_test}/${ROOT_NAME}/h-manifest.conf" ]] || fail "manual extraction test failed"
rm -rf "${extract_test}"

echo "CUSTOM_GET_MINER=${detected_miner}"
echo "CUSTOM_GET_VERSION=${detected_version}"
echo "PACKAGE_NAME_GATE=PASS archive=${ARCHIVE_NAME}"
echo "PACKAGE_ROOT_CHECK=PASS root=${ROOT_NAME}/"
echo "PACKAGE_CONFIG_GATE=PASS"
echo "PER_GPU_HS_SCHEMA=PASS"
echo "MANUAL_EXTRACTION_GATE=PASS"
echo "ARCHIVE=${ARCHIVE}"
echo "SHA256_FILE=${SHA_FILE}"
