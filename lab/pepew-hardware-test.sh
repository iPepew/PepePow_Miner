#!/usr/bin/env bash
set -Eeuo pipefail

# PepeW Miner hardware validation harness for a dedicated HiveOS test rig.
# It intentionally uses the rig's existing PepeW Flight Sheet/configuration;
# wallet/pool credentials are never embedded in this script or report.

ASSET_URL="${PEPEW_ASSET_URL:-https://github.com/iPepew/PepePow_Miner/releases/download/hiveos-test/PepeW-Miner-HiveOS.tar.gz}"
MINER_DIR="${PEPEW_MINER_DIR:-/hive/miners/custom/PepeW-Miner}"
LOG_FILE="${PEPEW_LOG_FILE:-/var/log/miner/custom/PepeW-Miner/pepew.log}"
WARMUP_SECONDS="${PEPEW_WARMUP_SECONDS:-30}"
TEST_SECONDS="${PEPEW_TEST_SECONDS:-180}"
SAMPLE_SECONDS="${PEPEW_SAMPLE_SECONDS:-5}"
MIN_MHS="${PEPEW_MIN_MHS:-4.50}"
MAX_REJECTED="${PEPEW_MAX_REJECTED:-0}"
MAX_RECONNECTS="${PEPEW_MAX_RECONNECTS:-1}"
LEAVE_RUNNING="${PEPEW_LEAVE_RUNNING:-1}"
REPORT_ROOT="${PEPEW_REPORT_DIR:-${RUNNER_TEMP:-/tmp}/pepew-hwtest}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run this harness as root on the HiveOS worker" >&2
  exit 2
fi

for command in miner nvidia-smi awk grep sed date; do
  command -v "${command}" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: ${command}" >&2
    exit 2
  }
done

CUSTOM_GET=/hive/miners/custom/custom-get
if [[ ! -x "${CUSTOM_GET}" ]]; then
  echo "ERROR: HiveOS custom-get not found: ${CUSTOM_GET}" >&2
  exit 2
fi

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
out_dir="${REPORT_ROOT}/${run_id}"
mkdir -p "${out_dir}"
gpu_csv="${out_dir}/gpu.csv"
report_json="${out_dir}/report.json"
redacted_log="${out_dir}/miner.log.redacted"

status="FAIL"
reason="test_not_completed"
kat="FAIL"
avg_mhs="0"
min_seen_mhs="0"
max_seen_mhs="0"
telemetry_samples="0"
accepted="0"
rejected="0"
reconnects="0"
miner_state="unknown"
avg_power_w="0"
avg_temp_c="0"
avg_gpu_util="0"
max_temp_c="0"
gpu_name="unknown"
build_version="unknown"
build_commit="unknown"
build_ref="unknown"
cuda_toolkit="unknown"

write_report() {
  local finished_at
  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cat >"${report_json}" <<EOF
{
  "status": "${status}",
  "reason": "${reason}",
  "finished_at": "${finished_at}",
  "gpu": "${gpu_name}",
  "build": "${build_version}",
  "commit": "${build_commit}",
  "ref": "${build_ref}",
  "cuda_toolkit": "${cuda_toolkit}",
  "consensus_kat": "${kat}",
  "test_seconds": ${TEST_SECONDS},
  "warmup_seconds": ${WARMUP_SECONDS},
  "hashrate_avg_mhs": ${avg_mhs},
  "hashrate_min_mhs": ${min_seen_mhs},
  "hashrate_max_mhs": ${max_seen_mhs},
  "telemetry_samples": ${telemetry_samples},
  "accepted": ${accepted},
  "rejected": ${rejected},
  "reconnects": ${reconnects},
  "miner_state": "${miner_state}",
  "gpu_power_avg_w": ${avg_power_w},
  "gpu_temp_avg_c": ${avg_temp_c},
  "gpu_temp_max_c": ${max_temp_c},
  "gpu_util_avg_pct": ${avg_gpu_util},
  "thresholds": {
    "min_mhs": ${MIN_MHS},
    "max_rejected": ${MAX_REJECTED},
    "max_reconnects": ${MAX_RECONNECTS}
  }
}
EOF

  if [[ -f "${LOG_FILE}" ]]; then
    tail -n 1500 "${LOG_FILE}" \
      | sed -E 's/^(Stratum authorized: ).*/\1[redacted]/' \
      >"${redacted_log}" || true
  fi

  echo
  echo "=== HARDWARE TEST RESULT ==="
  cat "${report_json}"
  echo "Artifacts: ${out_dir}"
}

cleanup() {
  local rc=$?
  if [[ "${rc}" -ne 0 && "${LEAVE_RUNNING}" != "1" ]]; then
    miner stop >/dev/null 2>&1 || true
  fi
  if [[ ! -f "${report_json}" ]]; then
    write_report || true
  fi
  exit "${rc}"
}
trap cleanup EXIT

fail() {
  reason="$1"
  status="FAIL"
  write_report
  exit 1
}

echo "=== PEPEW HARDWARE TEST ${run_id} ==="
echo "Asset: ${ASSET_URL}"
echo "Warmup: ${WARMUP_SECONDS}s; test: ${TEST_SECONDS}s; sample: ${SAMPLE_SECONDS}s"
echo "Threshold: >= ${MIN_MHS} MH/s, rejected <= ${MAX_REJECTED}, reconnects <= ${MAX_RECONNECTS}"

echo
echo "=== STOP CURRENT MINER ==="
miner stop >/dev/null 2>&1 || true
sleep 2
rm -f "${LOG_FILE}"

echo "=== INSTALL ROLLING DEV BUILD ==="
"${CUSTOM_GET}" "${ASSET_URL}" -f

build_info="${MINER_DIR}/BUILD_INFO.txt"
if [[ ! -s "${build_info}" ]]; then
  fail "build_info_missing"
fi
cp "${build_info}" "${out_dir}/BUILD_INFO.txt"
build_version="$(awk -F= '$1=="version" {print $2; exit}' "${build_info}")"
build_commit="$(awk -F= '$1=="commit" {print $2; exit}' "${build_info}")"
build_ref="$(awk -F= '$1=="ref" {print $2; exit}' "${build_info}")"
cuda_toolkit="$(awk -F= '$1=="cuda_toolkit" {print $2; exit}' "${build_info}")"

gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

echo "Build: ${build_version} (${build_commit}) CUDA ${cuda_toolkit}"
echo "GPU: ${gpu_name}"

echo
echo "=== START MINER ==="
miner start

# Wait up to 60s for the startup consensus KAT.
kat_deadline=$((SECONDS + 60))
while (( SECONDS < kat_deadline )); do
  if [[ -f "${LOG_FILE}" ]] && grep -q 'HooHashV110 CUDA consensus self-test: PASS' "${LOG_FILE}"; then
    kat="PASS"
    break
  fi
  if [[ -f "${LOG_FILE}" ]] && grep -q 'CUDA consensus self-test FAILED' "${LOG_FILE}"; then
    miner stop >/dev/null 2>&1 || true
    fail "consensus_kat_failed"
  fi
  sleep 2
done
[[ "${kat}" == "PASS" ]] || fail "consensus_kat_timeout"

echo "Consensus KAT: PASS"

# Wait up to 60s for an online telemetry line.
online_deadline=$((SECONDS + 60))
while (( SECONDS < online_deadline )); do
  if grep '\[MINING\]' "${LOG_FILE}" 2>/dev/null | tail -n1 | grep -q 'STATE online'; then
    break
  fi
  sleep 2
done
if ! grep '\[MINING\]' "${LOG_FILE}" 2>/dev/null | tail -n1 | grep -q 'STATE online'; then
  fail "stratum_online_timeout"
fi

echo "Stratum telemetry: online"
echo "Warmup ${WARMUP_SECONDS}s..."
sleep "${WARMUP_SECONDS}"

# Discard warmup telemetry so averages describe only the measured interval.
telemetry_marker="$(grep -c '\[MINING\]' "${LOG_FILE}" 2>/dev/null || true)"
: >"${gpu_csv}"

echo "Measuring for ${TEST_SECONDS}s..."
end_at=$((SECONDS + TEST_SECONDS))
while (( SECONDS < end_at )); do
  nvidia-smi \
    --query-gpu=timestamp,name,temperature.gpu,power.draw,utilization.gpu,memory.used \
    --format=csv,noheader,nounits >>"${gpu_csv}" || true
  sleep "${SAMPLE_SECONDS}"
done

telemetry_file="${out_dir}/telemetry.txt"
grep '\[MINING\]' "${LOG_FILE}" 2>/dev/null | tail -n "+$((telemetry_marker + 1))" >"${telemetry_file}" || true

read -r avg_mhs min_seen_mhs max_seen_mhs telemetry_samples < <(
  awk '$1=="[MINING]" && $18=="online" && ($2+0)>0 {
         v=$2+0; sum+=v; n++; if(n==1||v<min)min=v; if(n==1||v>max)max=v
       }
       END {
         if(n==0) printf "0 0 0 0\n";
         else printf "%.3f %.3f %.3f %d\n", sum/n, min, max, n
       }' "${telemetry_file}"
)

last_line="$(grep '\[MINING\]' "${LOG_FILE}" 2>/dev/null | tail -n1 || true)"
if [[ -n "${last_line}" ]]; then
  accepted="$(awk '{print $6+0}' <<<"${last_line}")"
  rejected="$(awk '{print $9+0}' <<<"${last_line}")"
  reconnects="$(awk '{print $15+0}' <<<"${last_line}")"
  miner_state="$(awk '{print $18}' <<<"${last_line}")"
fi

read -r avg_temp_c max_temp_c avg_power_w avg_gpu_util < <(
  awk -F',' '{
       gsub(/^[ \t]+|[ \t]+$/, "", $3); gsub(/^[ \t]+|[ \t]+$/, "", $4); gsub(/^[ \t]+|[ \t]+$/, "", $5);
       t=$3+0; p=$4+0; u=$5+0; st+=t; sp+=p; su+=u; n++; if(n==1||t>mt)mt=t
     }
     END {if(n==0) print "0 0 0 0"; else printf "%.1f %.1f %.1f %.1f\n",st/n,mt,sp/n,su/n}' "${gpu_csv}"
)

# Correctness gates take precedence over speed.
[[ "${kat}" == "PASS" ]] || fail "consensus_kat_failed"
[[ "${miner_state}" == "online" ]] || fail "miner_not_online_at_end"
(( telemetry_samples >= 2 )) || fail "insufficient_telemetry"
awk -v avg="${avg_mhs}" -v min="${MIN_MHS}" 'BEGIN {exit !(avg >= min)}' \
  || fail "hashrate_regression"
(( rejected <= MAX_REJECTED )) || fail "rejected_share_regression"
(( reconnects <= MAX_RECONNECTS )) || fail "reconnect_regression"

status="PASS"
reason="ok"
write_report
trap - EXIT

if [[ "${LEAVE_RUNNING}" != "1" ]]; then
  miner stop >/dev/null 2>&1 || true
fi

exit 0
