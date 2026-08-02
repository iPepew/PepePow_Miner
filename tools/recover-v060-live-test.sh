#!/usr/bin/env bash
set -euo pipefail

TARGET="${TARGET:-/hive/miners/custom/pepepowminer-v0.6.0-PR}"
ARCHIVE="${ARCHIVE:-/root/pepepow-v060-src/dist/pepepowminer-v0.6.0-PR-hiveos.tar.gz}"
BUILD_LOG="${BUILD_LOG:-/root/v060-build.log}"
LIVE_MINUTES="${LIVE_MINUTES:-15}"
WARMUP_SECONDS="${WARMUP_SECONDS:-30}"
SESSION="${SESSION:-v060-live-recover}"
RUN_LOG="${RUN_LOG:-/root/v060-live-recovery.log}"
STAMP="$(date +%Y%m%d_%H%M%S)"
EVIDENCE="/root/pepepow-tests/v060-live-recovery-${STAMP}"
VALIDATION_ARCHIVE="/tmp/pepepow-v060-validation-${STAMP}.tar.gz"
RELEASE_COPY="/tmp/pepepowminer-v0.6.0-PR-hiveos.tar.gz"
CHECKSUMS="/tmp/pepepow-v060-downloads.sha256"

strip_ansi() {
  sed -r 's/\x1B\[[0-9;?]*[ -\/]*[@-~]//g'
}

if [[ "${RECOVERY_IN_SCREEN:-0}" != "1" ]]; then
  if pgrep -af '[i]nstall-and-live-test-v060.sh' >/dev/null 2>&1; then
    echo "WAIT: original v0.6.0 live-test process is still running."
    pgrep -af '[i]nstall-and-live-test-v060.sh'
    exit 0
  fi

  if screen -ls 2>/dev/null | grep -qE "[.]${SESSION}[[:space:]]"; then
    echo "WAIT: recovery session is already running: ${SESSION}"
    echo "View: tail -f ${RUN_LOG}"
    exit 0
  fi

  rm -f "${RUN_LOG}"
  screen -dmS "${SESSION}" bash -lc \
    "RECOVERY_IN_SCREEN=1 LIVE_MINUTES='${LIVE_MINUTES}' WARMUP_SECONDS='${WARMUP_SECONDS}' TARGET='${TARGET}' ARCHIVE='${ARCHIVE}' BUILD_LOG='${BUILD_LOG}' '$0' 2>&1 | tee '${RUN_LOG}'"
  sleep 3
  echo "PASS: disconnect-safe recovery started in screen '${SESSION}'."
  echo "View: tail -f ${RUN_LOG}"
  exit 0
fi

mkdir -p "${EVIDENCE}"

echo "========== VERIFY v0.6.0-PR MINER =========="
[[ -x "${TARGET}/pepepowminer" ]] || { echo "ERROR: miner not found: ${TARGET}/pepepowminer"; exit 1; }
[[ -x "${TARGET}/h-run.sh" ]] || { echo "ERROR: launcher not found: ${TARGET}/h-run.sh"; exit 1; }
[[ -s "${ARCHIVE}" ]] || { echo "ERROR: release archive not found: ${ARCHIVE}"; exit 1; }

MINER_PID="$(pgrep -x pepepowminer | head -n1 || true)"
if [[ -z "${MINER_PID}" ]] || ! kill -0 "${MINER_PID}" 2>/dev/null; then
  echo "Miner is not running; starting v0.6.0-PR."
  screen -S pepepow-v060 -X quit 2>/dev/null || true
  screen -dmS pepepow-v060 bash -lc "cd '${TARGET}' && exec ./h-run.sh"
  sleep 15
  MINER_PID="$(pgrep -x pepepowminer | head -n1 || true)"
fi

[[ -n "${MINER_PID}" ]] && kill -0 "${MINER_PID}" 2>/dev/null || {
  echo "ERROR: v0.6.0-PR miner is not running."
  tail -n100 "${TARGET}/miner-console.log" 2>/dev/null || true
  exit 1
}

echo "PASS: miner PID=${MINER_PID}"
echo "Warm-up: ${WARMUP_SECONDS}s"
sleep "${WARMUP_SECONDS}"

LOG="${TARGET}/miner-console.log"
[[ -s "${LOG}" ]] || { echo "ERROR: miner log not found: ${LOG}"; exit 1; }
START_LINE=$(( $(wc -l < "${LOG}") + 1 ))

for ((minute=1; minute<=LIVE_MINUTES; minute++)); do
  sleep 60
  CLEAN_LAST="$(strip_ansi < "${LOG}" | grep -a '^\[MINING\]' | tail -n1 || true)"
  printf '[LIVE TEST %02d/%02d] %s\n' "${minute}" "${LIVE_MINUTES}" "${CLEAN_LAST:-No mining line yet}"
  nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,clocks.current.sm,clocks.current.memory,power.draw \
    --format=csv,noheader 2>/dev/null || true
done

if ! kill -0 "${MINER_PID}" 2>/dev/null; then
  echo "LIVE_STATUS=FAIL process_exited"
  exit 1
fi

tail -n +"${START_LINE}" "${LOG}" | strip_ansi > "${EVIDENCE}/miner-live-sample.log"
strip_ansi < "${LOG}" > "${EVIDENCE}/miner-console-clean.log"
cp -f "${LOG}" "${EVIDENCE}/miner-console-raw.log"
cp -f "${BUILD_LOG}" "${EVIDENCE}/v060-build.log" 2>/dev/null || true
cp -f "${TARGET}/BUILD_PROFILE" "${EVIDENCE}/BUILD_PROFILE" 2>/dev/null || true
cp -f "${TARGET}/VERSION" "${EVIDENCE}/VERSION" 2>/dev/null || true
cp -f "${TARGET}/proxy-console.log" "${EVIDENCE}/proxy-console.log" 2>/dev/null || true
cp -f "${TARGET}/stratum-proxy.log" "${EVIDENCE}/stratum-proxy.log" 2>/dev/null || true
cp -f "${TARGET}/pepepow-debug.log" "${EVIDENCE}/pepepow-debug.log" 2>/dev/null || true
cp -f "${TARGET}/runtime-diagnostics.txt" "${EVIDENCE}/runtime-diagnostics.txt" 2>/dev/null || true

awk -F'|' '
/^\[MINING\]/ {
  value=$2; gsub(/[^0-9.]/,"",value); if (value=="") next;
  value+=0; if (count==0 || value<min) min=value; if (count==0 || value>max) max=value;
  sum+=value; count++;
}
END {
  if (count>0) printf "samples=%d\nmin_mhs=%.3f\navg_mhs=%.3f\nmax_mhs=%.3f\n", count,min,sum/count,max;
  else print "samples=0";
}' "${EVIDENCE}/miner-live-sample.log" | tee "${EVIDENCE}/hashrate-stats.txt"

ACCEPTED_EVENTS="$(grep -ac '^\[ACCEPTED\]' "${EVIDENCE}/miner-live-sample.log" || true)"
REJECTED_EVENTS="$(grep -ac '^\[REJECTED\]' "${EVIDENCE}/miner-live-sample.log" || true)"
LAST_MINING="$(grep -a '^\[MINING\]' "${EVIDENCE}/miner-live-sample.log" | tail -n1 || true)"

{
  echo "LIVE_STATUS=PASS"
  echo "MINER_PID=${MINER_PID}"
  echo "LIVE_MINUTES=${LIVE_MINUTES}"
  echo "ACCEPTED_EVENTS=${ACCEPTED_EVENTS}"
  echo "REJECTED_EVENTS=${REJECTED_EVENTS}"
  echo "LAST_MINING=${LAST_MINING}"
} | tee "${EVIDENCE}/live-result.txt"

nvidia-smi -q > "${EVIDENCE}/nvidia-smi-q.txt" 2>&1 || true
dmesg -T 2>/dev/null | grep -Ei 'NVRM|Xid|CUDA|nvidia' | tail -n100 > "${EVIDENCE}/nvidia-kernel-events.txt" || true

cp -f "${ARCHIVE}" "${RELEASE_COPY}"
tar -czf "${VALIDATION_ARCHIVE}" -C "${EVIDENCE}" .
sha256sum "${RELEASE_COPY}" "${VALIDATION_ARCHIVE}" | tee "${CHECKSUMS}"

for pid in $(pgrep -x python3 2>/dev/null || true); do
  cmd="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
  case "${cmd}" in *http.server*8080*) kill "${pid}" 2>/dev/null || true ;; esac
done
screen -S v060-http -X quit 2>/dev/null || true
screen -dmS v060-http bash -lc "exec python3 -m http.server 8080 --bind 0.0.0.0 --directory /tmp"

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo
echo "========== DOWNLOAD FILES =========="
echo "Release package : http://${IP}:8080/$(basename "${RELEASE_COPY}")"
echo "Validation logs : http://${IP}:8080/$(basename "${VALIDATION_ARCHIVE}")"
echo "Checksums       : http://${IP}:8080/$(basename "${CHECKSUMS}")"
echo "HTTP server runs in screen 'v060-http'."
