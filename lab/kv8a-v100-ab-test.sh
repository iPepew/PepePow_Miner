#!/usr/bin/env bash
set -Eeuo pipefail

# Safe field A/B for the isolated KV8-A Tesla V100 candidate.
# The current custom miner is backed up and restored automatically on any
# correctness/performance failure. A passing candidate is intentionally left
# running so it can continue real pool validation.

ASSET_URL="${PEPEW_KV8A_ASSET_URL:-https://github.com/iPepew/PepePow_Miner/releases/download/hiveos-v100-kv8a-test/PepeW-Miner-HiveOS.tar.gz}"
HARNESS_URL="${PEPEW_HARNESS_URL:-https://raw.githubusercontent.com/iPepew/PepePow_Miner/agent/v100-kv8a-exact-sw/lab/pepew-hardware-test.sh}"
MINER_DIR="${PEPEW_MINER_DIR:-/hive/miners/custom/PepeW-Miner}"
MIN_MHS="${PEPEW_KV8A_MIN_MHS:-10.20}"
WARMUP_SECONDS="${PEPEW_WARMUP_SECONDS:-30}"
TEST_SECONDS="${PEPEW_TEST_SECONDS:-300}"
REPORT_DIR="${PEPEW_REPORT_DIR:-/tmp/pepew-kv8a}"
EXPECTED_PREFIX="v100-kv8a-exactsw-"

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run as root on the HiveOS worker" >&2
  exit 2
fi

for cmd in curl tar miner cp rm mktemp grep awk date; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: ${cmd}" >&2
    exit 2
  }
done

if [[ ! -d "${MINER_DIR}" ]]; then
  echo "ERROR: current PepeW miner directory not found: ${MINER_DIR}" >&2
  exit 2
fi

stamp="$(date -u +%Y%m%d-%H%M%S)"
backup="${MINER_DIR}.backup.kv8a.${stamp}"
tmp_asset="$(mktemp /tmp/pepew-kv8a-asset.XXXXXX.tar.gz)"
tmp_harness="$(mktemp /tmp/pepew-kv8a-harness.XXXXXX.sh)"

cleanup_tmp() {
  rm -f "${tmp_asset}" "${tmp_harness}" >/dev/null 2>&1 || true
}
trap cleanup_tmp EXIT

rollback() {
  local why="$1"
  echo
  echo "=== KV8-A ROLLBACK ==="
  echo "Reason: ${why}"
  miner stop >/dev/null 2>&1 || true
  sleep 2
  rm -rf "${MINER_DIR}"
  cp -a "${backup}" "${MINER_DIR}"
  miner start
  echo "Restored: ${backup}"
}

echo "============================================================"
echo "PEPEW TESLA V100 KV8-A SAFE A/B TEST"
echo "============================================================"
echo "Asset:      ${ASSET_URL}"
echo "Keep gate:  >= ${MIN_MHS} MH/s"
echo "Warmup:     ${WARMUP_SECONDS}s"
echo "Measure:    ${TEST_SECONDS}s"
echo

echo "=== [1/6] PRE-FLIGHT RELEASE ASSET ==="
if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 \
    "${ASSET_URL}" -o "${tmp_asset}"; then
  echo "ERROR: KV8-A release asset is not available yet; current miner was NOT touched." >&2
  exit 3
fi

build_info="$(tar -xOf "${tmp_asset}" PepeW-Miner/BUILD_INFO.txt 2>/dev/null || true)"
version="$(awk -F= '$1=="version" {print $2; exit}' <<<"${build_info}")"
channel="$(awk -F= '$1=="channel" {print $2; exit}' <<<"${build_info}")"
threads="$(awk -F= '$1=="cuda_threads" {print $2; exit}' <<<"${build_info}")"
regs="$(awk -F= '$1=="cuda_max_registers" {print $2; exit}' <<<"${build_info}")"
sw_state="$(awk -F= '$1=="sw_state" {print $2; exit}' <<<"${build_info}")"

if [[ "${version}" != ${EXPECTED_PREFIX}* ]]; then
  echo "ERROR: unexpected package identity: version='${version}'" >&2
  exit 3
fi
if [[ "${channel}" != "hiveos-v100-kv8a-test" || "${threads}" != "256" || "${regs}" != "128" || "${sw_state}" != "exact-boolean" ]]; then
  echo "ERROR: package metadata mismatch" >&2
  printf '%s\n' "${build_info}" >&2
  exit 3
fi

echo "[ASSET] identity PASS"
echo "version=${version}"
echo "channel=${channel} threads=${threads} reg_cap=${regs} sw=${sw_state}"

echo
echo "=== [2/6] DOWNLOAD TEST HARNESS ==="
curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 \
  "${HARNESS_URL}" -o "${tmp_harness}"
bash -n "${tmp_harness}"
chmod +x "${tmp_harness}"
echo "[HARNESS] syntax PASS"

echo
echo "=== [3/6] BACKUP CURRENT MINER ==="
cp -a "${MINER_DIR}" "${backup}"
echo "Backup: ${backup}"

echo
echo "=== [4/6] INSTALL + KAT + ONLINE + WARMUP + MEASURE ==="
set +e
PEPEW_ASSET_URL="${ASSET_URL}" \
PEPEW_MINER_DIR="${MINER_DIR}" \
PEPEW_WARMUP_SECONDS="${WARMUP_SECONDS}" \
PEPEW_TEST_SECONDS="${TEST_SECONDS}" \
PEPEW_SAMPLE_SECONDS=5 \
PEPEW_PROGRESS_SECONDS=5 \
PEPEW_MIN_MHS="${MIN_MHS}" \
PEPEW_MAX_REJECTED=0 \
PEPEW_MAX_RECONNECTS=1 \
PEPEW_LEAVE_RUNNING=1 \
PEPEW_REPORT_DIR="${REPORT_DIR}" \
bash "${tmp_harness}"
rc=$?
set -e

if (( rc != 0 )); then
  rollback "hardware harness failed (rc=${rc})"
  exit "${rc}"
fi

echo
echo "=== [5/6] POST-INSTALL IDENTITY ==="
installed_info="${MINER_DIR}/BUILD_INFO.txt"
if [[ ! -s "${installed_info}" ]] || ! grep -q "^version=${EXPECTED_PREFIX}" "${installed_info}"; then
  rollback "installed package identity mismatch"
  exit 4
fi
cat "${installed_info}"

echo
echo "=== [6/6] KV8-A VERDICT ==="
echo "KV8-A: PASS — candidate remains running."
echo "Rollback copy retained at: ${backup}"
echo "Reports: ${REPORT_DIR}"
echo "Next gate: compare measured average with the known KV4-A ~10.212 MH/s result, then validate shares over a longer pool run."
