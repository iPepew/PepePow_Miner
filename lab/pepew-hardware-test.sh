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
PROGRESS_SECONDS="${PEPEW_PROGRESS_SECONDS:-5}"
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

for value_name in WARMUP_SECONDS TEST_SECONDS SAMPLE_SECONDS PROGRESS_SECONDS; do
  value="${!value_name}"
  if [[ ! "${value}" =~ ^[0-9]+$ ]] || (( value <= 0 )); then
    echo "ERROR: ${value_name} must be a positive integer, got '${value}'" >&2
    exit 2
  fi
done

CUSTOM_GET=/hive/miners/custom/custom-get
if [[ ! -x "${CUSTOM_GET}" ]]; then
  echo "ERROR: HiveOS custom-get not found: ${CUSTOM_GET}" >&2
  exit 2
fi

format_duration() {
  local total="${1:-0}"
  (( total < 0 )) && total=0
  if (( total >= 3600 )); then
    printf '%02d:%02d:%02d' "$((total / 3600))" "$(((total % 3600) / 60))" "$((total % 60))"
  else
    printf '%02d:%02d' "$((total / 60))" "$((total % 60))"
  fi
}

latest_mining_line() {
  (grep -a '^\[MINING\]' "${LOG_FILE}" 2>/dev/null || true) | tail -n1
}

print_startup_progress() {
  local phase="$1" elapsed="$2" total="$3" detail="$4"
  local remaining=$((total - elapsed))
  (( remaining < 0 )) && remaining=0
  printf '[%s] elapsed %s / %s | remaining %s | %s\n' \
    "${phase}" "$(format_duration "${elapsed}")" "$(format_duration "${total}")" \
    "$(format_duration "${remaining}")" "${detail}"
}

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
out_dir="${REPORT_ROOT}/${run_id}"
mkdir -p "${out_dir}"
gpu_csv="${out_dir}/gpu.csv"
report_json="${out_dir}/report.json"
redacted_log="${out_dir}/miner.log.redacted"
hive_stats_file="${out_dir}/hive-stats.json"

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
gpu_count="0"
build_version="unknown"
build_commit="unknown"
build_ref="unknown"
cuda_toolkit="unknown"
hive_stats_complete="false"

write_report() {
  local finished_at
  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cat >"${report_json}" <<EOF
{
  "status": "${status}",
  "reason": "${reason}",
  "finished_at": "${finished_at}",
  "gpu": "${gpu_name}",
  "gpu_count": ${gpu_count},
  "build": "${build_version}",
  "commit": "${build_commit}",
  "ref": "${build_ref}",
  "cuda_toolkit": "${cuda_toolkit}",
  "consensus_kat": "${kat}",
  "test_seconds": ${TEST_SECONDS},
  "warmup_seconds": ${WARMUP_SECONDS},
  "sample_seconds": ${SAMPLE_SECONDS},
  "progress_seconds": ${PROGRESS_SECONDS},
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
  "hive_stats_complete": ${hive_stats_complete},
  "hive_stats_file": "hive-stats.json",
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
  if [[ -s "${hive_stats_file}" ]]; then
    echo "Hive stats:"
    cat "${hive_stats_file}"
  fi
  echo "Artifacts: ${out_dir}"
}

cleanup() {
  local rc=$?
  if [[ "${rc}" -ne 0 || "${LEAVE_RUNNING}" != "1" ]]; then
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
echo "Warmup: ${WARMUP_SECONDS}s; test: ${TEST_SECONDS}s; sample: ${SAMPLE_SECONDS}s; progress: ${PROGRESS_SECONDS}s"
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
gpu_count="$(nvidia-smi --query-gpu=index --format=csv,noheader,nounits | grep -c . || true)"
[[ "${gpu_count}" =~ ^[0-9]+$ ]] || gpu_count=0

echo "Build: ${build_version} (${build_commit}) CUDA ${cuda_toolkit}"
echo "GPU: ${gpu_name}; visible NVIDIA devices: ${gpu_count}"

echo
echo "=== START MINER ==="
miner start

# Wait up to 60s for the startup consensus KAT. Multi-GPU builds run one KAT
# per card; require the expected number of PASS lines before measuring speed.
kat_timeout=60
kat_started=$SECONDS
kat_deadline=$((kat_started + kat_timeout))
kat_next_progress=$kat_started
while (( SECONDS < kat_deadline )); do
  if [[ -f "${LOG_FILE}" ]] && grep -q 'CUDA consensus self-test FAILED' "${LOG_FILE}"; then
    miner stop >/dev/null 2>&1 || true
    fail "consensus_kat_failed"
  fi
  kat_passes="$(grep -c 'HooHashV110 CUDA consensus self-test: PASS' "${LOG_FILE}" 2>/dev/null || true)"
  if (( gpu_count > 0 && kat_passes >= gpu_count )); then
    kat="PASS"
    break
  fi
  if (( SECONDS >= kat_next_progress )); then
    print_startup_progress "KAT" "$((SECONDS - kat_started))" "${kat_timeout}" "passes ${kat_passes}/${gpu_count}; miner process active"
    kat_next_progress=$((SECONDS + PROGRESS_SECONDS))
  fi
  sleep 1
done
[[ "${kat}" == "PASS" ]] || fail "consensus_kat_timeout"

echo "Consensus KAT: PASS (${gpu_count}/${gpu_count} GPUs)"

# Wait up to 60s for an online aggregate telemetry line.
online_timeout=60
online_started=$SECONDS
online_deadline=$((online_started + online_timeout))
online_next_progress=$online_started
while (( SECONDS < online_deadline )); do
  mining_line="$(latest_mining_line)"
  if grep -q 'STATE online' <<<"${mining_line}"; then
    break
  fi
  if (( SECONDS >= online_next_progress )); then
    current_state="$(awk '{for(i=1;i<=NF;i++) if($i=="STATE") {print $(i+1); exit}}' <<<"${mining_line}")"
    [[ -n "${current_state}" ]] || current_state="waiting"
    print_startup_progress "STRATUM" "$((SECONDS - online_started))" "${online_timeout}" "state ${current_state}; waiting for online telemetry"
    online_next_progress=$((SECONDS + PROGRESS_SECONDS))
  fi
  sleep 1
done
if ! latest_mining_line | grep -q 'STATE online'; then
  fail "stratum_online_timeout"
fi

echo "Stratum telemetry: online"

# Warmup with a visible heartbeat instead of one opaque sleep.
echo "Warmup for ${WARMUP_SECONDS}s..."
warmup_started=$SECONDS
warmup_deadline=$((warmup_started + WARMUP_SECONDS))
warmup_next_progress=$warmup_started
while (( SECONDS < warmup_deadline )); do
  if (( SECONDS >= warmup_next_progress )); then
    mining_line="$(latest_mining_line)"
    current_mhs="$(awk '{print $2+0}' <<<"${mining_line}")"
    current_state="$(awk '{for(i=1;i<=NF;i++) if($i=="STATE") {print $(i+1); exit}}' <<<"${mining_line}")"
    [[ -n "${current_state}" ]] || current_state="waiting"
    print_startup_progress "WARMUP" "$((SECONDS - warmup_started))" "${WARMUP_SECONDS}" "miner ${current_mhs} MH/s; state ${current_state}"
    warmup_next_progress=$((SECONDS + PROGRESS_SECONDS))
  fi
  sleep 1
done
print_startup_progress "WARMUP" "${WARMUP_SECONDS}" "${WARMUP_SECONDS}" "complete"

# Discard warmup telemetry so averages describe only the measured interval.
telemetry_marker="$(grep -c '\[MINING\]' "${LOG_FILE}" 2>/dev/null || true)"
: >"${gpu_csv}"

echo "Measuring for ${TEST_SECONDS}s..."
measure_started=$SECONDS
end_at=$((measure_started + TEST_SECONDS))
measure_next_progress=$measure_started
while (( SECONDS < end_at )); do
  sample_output="$(nvidia-smi \
    --query-gpu=timestamp,name,temperature.gpu,power.draw,utilization.gpu,memory.used \
    --format=csv,noheader,nounits 2>/dev/null || true)"
  if [[ -n "${sample_output}" ]]; then
    printf '%s\n' "${sample_output}" >>"${gpu_csv}"
  fi

  now=$SECONDS
  if (( now >= measure_next_progress )); then
    elapsed=$((now - measure_started))
    (( elapsed > TEST_SECONDS )) && elapsed=$TEST_SECONDS
    remaining=$((TEST_SECONDS - elapsed))
    pct=$((elapsed * 100 / TEST_SECONDS))

    mining_line="$(latest_mining_line)"
    current_mhs="$(awk '{print $2+0}' <<<"${mining_line}")"
    current_accepted="$(awk '{for(i=1;i<=NF;i++) if($i=="A") {print $(i+1)+0; exit}}' <<<"${mining_line}")"
    current_rejected="$(awk '{for(i=1;i<=NF;i++) if($i=="R") {print $(i+1)+0; exit}}' <<<"${mining_line}")"
    current_reconnects="$(awk '{for(i=1;i<=NF;i++) if($i=="REC") {print $(i+1)+0; exit}}' <<<"${mining_line}")"
    current_state="$(awk '{for(i=1;i<=NF;i++) if($i=="STATE") {print $(i+1); exit}}' <<<"${mining_line}")"
    [[ -n "${current_state}" ]] || current_state="unknown"

    read -r rolling_avg rolling_samples < <(
      (grep -a '^\[MINING\]' "${LOG_FILE}" 2>/dev/null || true) \
        | tail -n "+$((telemetry_marker + 1))" \
        | awk '$18=="online" && ($2+0)>0 {sum+=$2; n++} END {if(n) printf "%.3f %d\n",sum/n,n; else print "0 0"}'
    )

    first_gpu_sample="$(printf '%s\n' "${sample_output}" | head -n1)"
    current_temp="$(awk -F',' '{gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3+0}' <<<"${first_gpu_sample}")"
    current_power="$(awk -F',' '{gsub(/^[ \t]+|[ \t]+$/, "", $4); printf "%.1f", $4+0}' <<<"${first_gpu_sample}")"
    current_util="$(awk -F',' '{gsub(/^[ \t]+|[ \t]+$/, "", $5); print $5+0}' <<<"${first_gpu_sample}")"

    printf '[MEASURE] %s / %s | %3d%% | remaining %s | last %.3f MH/s | avg %.3f MH/s (%d samples) | GPU %sC %sW %s%% | A/R %s/%s | REC %s | %s\n' \
      "$(format_duration "${elapsed}")" "$(format_duration "${TEST_SECONDS}")" "${pct}" \
      "$(format_duration "${remaining}")" "${current_mhs}" "${rolling_avg}" "${rolling_samples}" \
      "${current_temp}" "${current_power}" "${current_util}" \
      "${current_accepted}" "${current_rejected}" "${current_reconnects}" "${current_state}"

    measure_next_progress=$((now + PROGRESS_SECONDS))
  fi

  remaining_sleep=$((end_at - SECONDS))
  if (( remaining_sleep > 0 )); then
    sleep_for="${SAMPLE_SECONDS}"
    (( sleep_for > remaining_sleep )) && sleep_for="${remaining_sleep}"
    sleep "${sleep_for}"
  fi
done
printf '[MEASURE] %s / %s | 100%% | remaining 00:00 | measurement complete\n' \
  "$(format_duration "${TEST_SECONDS}")" "$(format_duration "${TEST_SECONDS}")"

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

last_line="$(latest_mining_line)"
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

# Exercise exactly the callback that HiveOS sources. The JSON must include the
# miner speed, pool A/R counters and hardware arrays needed for the summary UI.
hstats="${MINER_DIR}/h-stats.sh"
if [[ -s "${hstats}" ]]; then
  hive_stats="$(bash -c 'source "$1"; printf "%s\n" "$stats"' _ "${hstats}" 2>/dev/null || true)"
  printf '%s\n' "${hive_stats}" >"${hive_stats_file}"
  if grep -q '"hs":\[' "${hive_stats_file}" \
     && grep -q '"temp":\[' "${hive_stats_file}" \
     && grep -q '"fan":\[' "${hive_stats_file}" \
     && grep -q '"ar":\[' "${hive_stats_file}" \
     && grep -q '"bus_numbers":\[' "${hive_stats_file}"; then
    hive_stats_complete="true"
  fi
fi

# Correctness gates take precedence over speed.
[[ "${kat}" == "PASS" ]] || fail "consensus_kat_failed"
[[ "${miner_state}" == "online" ]] || fail "miner_not_online_at_end"
(( telemetry_samples >= 2 )) || fail "insufficient_telemetry"
awk -v avg="${avg_mhs}" -v min="${MIN_MHS}" 'BEGIN {exit !(avg >= min)}' \
  || fail "hashrate_regression"
(( rejected <= MAX_REJECTED )) || fail "rejected_share_regression"
(( reconnects <= MAX_RECONNECTS )) || fail "reconnect_regression"
[[ "${hive_stats_complete}" == "true" ]] || fail "hive_stats_incomplete"

status="PASS"
reason="ok"
write_report
trap - EXIT

if [[ "${LEAVE_RUNNING}" != "1" ]]; then
  miner stop >/dev/null 2>&1 || true
fi

exit 0
