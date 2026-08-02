#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-/root/pepepow-v060-src}"
BUILD_LOG="${BUILD_LOG:-/root/v060-build.log}"
ARCHIVE="${ARCHIVE:-${ROOT}/dist/pepepowminer-v0.6.0-PR-hiveos.tar.gz}"
TARGET="${TARGET:-/hive/miners/custom/pepepowminer-v0.6.0-PR}"
OLD="${OLD:-/hive/miners/custom/pepepowminer-v0.5.4-PR}"
LIVE_MINUTES="${LIVE_MINUTES:-15}"
WARMUP_SECONDS="${WARMUP_SECONDS:-60}"
STAMP="$(date +%Y%m%d_%H%M%S)"
EVIDENCE="/root/pepepow-tests/v060-live-${STAMP}"
VALIDATION_ARCHIVE="/tmp/pepepow-v060-validation-${STAMP}.tar.gz"
RELEASE_COPY="/tmp/pepepowminer-v0.6.0-PR-hiveos.tar.gz"

stop_pepepow_processes() {
  local pid cmd
  screen -S pepepow-v054 -X quit 2>/dev/null || true
  screen -S pepepow-v060 -X quit 2>/dev/null || true

  for pid in $(pgrep -x pepepowminer 2>/dev/null || true); do
    echo "Stopping pepepowminer PID=${pid}"
    kill -TERM "${pid}" 2>/dev/null || true
  done

  for pid in $(pgrep -x python3 2>/dev/null || true); do
    cmd="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
    case "${cmd}" in
      *stratum-replay-proxy.py*)
        echo "Stopping Stratum proxy PID=${pid}"
        kill -TERM "${pid}" 2>/dev/null || true
        ;;
    esac
  done

  sleep 5

  for pid in $(pgrep -x pepepowminer 2>/dev/null || true); do
    kill -KILL "${pid}" 2>/dev/null || true
  done
}

rollback_v054() {
  echo
  echo "========== ROLLBACK TO v0.5.4 =========="
  stop_pepepow_processes
  if [[ -x "${OLD}/h-run.sh" ]]; then
    screen -dmS pepepow-v054 bash -lc "cd '${OLD}' && exec ./h-run.sh"
    sleep 10
    echo "v0.5.4 restart requested."
  else
    echo "WARNING: v0.5.4 installation not found at ${OLD}" >&2
  fi
}

mkdir -p "${EVIDENCE}"

printf '\n========== CHECK AUTOTUNE =========='; echo
if screen -ls 2>/dev/null | grep -qE '[.]v060-build[[:space:]]'; then
  echo "WAIT: v0.6.0-PR autotune is still running."
  grep -E '^\[PROFILE [0-9]{2}/[0-9]{2}\]|^PROFILE_RESULT ' "${BUILD_LOG}" | tail -n20 || true
  exit 2
fi

[[ -s "${BUILD_LOG}" ]] || { echo "ERROR: build log is missing: ${BUILD_LOG}" >&2; exit 1; }

grep -E 'PROFILE_INVALID|PROFILE_RESULT|STATE_MODE_SELECTED|AUTOTUNE_SELECTED|AUTOTUNE_PROFILE|AUTOTUNE_STATE_MODE|AUTOTUNE_HPS|AUTOTUNE_BASELINE_HPS|AUTOTUNE_UPLIFT_PCT|TARGET_2MH|ARCHIVE=|SHA256=' \
  "${BUILD_LOG}" | tail -n250 | tee "${EVIDENCE}/autotune-summary.txt"

[[ -s "${ARCHIVE}" ]] || { echo "ERROR: release archive not found: ${ARCHIVE}" >&2; exit 1; }
[[ -s "${ARCHIVE}.sha256" ]] || { echo "ERROR: SHA256 file not found: ${ARCHIVE}.sha256" >&2; exit 1; }

printf '\n========== VERIFY PACKAGE =========='; echo
sha256sum -c "${ARCHIVE}.sha256"
tar -tzf "${ARCHIVE}" | head -n30
cp -f "${BUILD_LOG}" "${EVIDENCE}/v060-build.log"
cp -f "${ARCHIVE}.sha256" "${EVIDENCE}/"

printf '\n========== INSTALL v0.6.0-PR =========='; echo
stop_pepepow_processes
rm -rf "${TARGET}"
mkdir -p /hive/miners/custom
tar -xzf "${ARCHIVE}" -C /hive/miners/custom

for required in pepepowminer h-run.sh h-config.sh stratum-replay-proxy.py BUILD_PROFILE VERSION; do
  [[ -e "${TARGET}/${required}" ]] || {
    echo "ERROR: package file missing: ${TARGET}/${required}" >&2
    rollback_v054
    exit 1
  }
done
chmod +x "${TARGET}/pepepowminer" "${TARGET}"/*.sh "${TARGET}"/*.py 2>/dev/null || true

printf '\n========== CONFIGURE =========='; echo
rm -f "${TARGET}/config.txt"
if ! (cd "${TARGET}" && bash ./h-config.sh); then
  echo "WARNING: HiveOS config generation failed; trying the v0.5.4 config."
  if [[ -s "${OLD}/config.txt" ]]; then
    cp -f "${OLD}/config.txt" "${TARGET}/config.txt"
    sed -i "s#${OLD}#${TARGET}#g" "${TARGET}/config.txt"
  fi
fi
[[ -s "${TARGET}/config.txt" ]] || {
  echo "ERROR: config.txt was not generated." >&2
  rollback_v054
  exit 1
}

bash -n "${TARGET}/h-run.sh"
bash -n "${TARGET}/h-config.sh"
"${TARGET}/pepepowminer" --version | tee "${EVIDENCE}/version.txt"
"${TARGET}/pepepowminer" --list-gpu | tee "${EVIDENCE}/gpu-list.txt"
cat "${TARGET}/BUILD_PROFILE" > "${EVIDENCE}/BUILD_PROFILE"

printf '\n========== START LIVE TEST =========='; echo
screen -dmS pepepow-v060 bash -lc "cd '${TARGET}' && exec ./h-run.sh"
sleep 15

[[ -s "${TARGET}/miner.pid" ]] || {
  echo "ERROR: miner PID file was not created." >&2
  tail -n100 "${TARGET}/miner-console.log" 2>/dev/null || true
  rollback_v054
  exit 1
}
MINER_PID="$(cat "${TARGET}/miner.pid")"
if ! kill -0 "${MINER_PID}" 2>/dev/null; then
  echo "ERROR: v0.6.0-PR miner exited during startup." >&2
  tail -n100 "${TARGET}/miner-console.log" 2>/dev/null || true
  rollback_v054
  exit 1
fi

echo "PASS: v0.6.0-PR miner is running; PID=${MINER_PID}"
echo "Warm-up: ${WARMUP_SECONDS}s"
sleep "${WARMUP_SECONDS}"
START_LINE=$(( $(wc -l < "${TARGET}/miner-console.log") + 1 ))

for ((minute=1; minute<=LIVE_MINUTES; minute++)); do
  sleep 60
  printf '[LIVE TEST %02d/%02d] ' "${minute}" "${LIVE_MINUTES}"
  grep '^\[MINING\]' "${TARGET}/miner-console.log" | tail -n1 || echo "No mining line yet"
  nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,clocks.current.sm,clocks.current.memory,power.draw \
    --format=csv,noheader 2>/dev/null || true
done

printf '\n========== LIVE TEST RESULT =========='; echo
if ! kill -0 "${MINER_PID}" 2>/dev/null; then
  echo "LIVE_STATUS=FAIL process_exited"
  rollback_v054
  exit 1
fi

tail -n +"${START_LINE}" "${TARGET}/miner-console.log" > "${EVIDENCE}/miner-live-sample.log"
cp -f "${TARGET}/miner-console.log" "${EVIDENCE}/miner-console.log"
cp -f "${TARGET}/proxy-console.log" "${EVIDENCE}/proxy-console.log" 2>/dev/null || true
cp -f "${TARGET}/stratum-proxy.log" "${EVIDENCE}/stratum-proxy.log" 2>/dev/null || true
cp -f "${TARGET}/pepepow-debug.log" "${EVIDENCE}/pepepow-debug.log" 2>/dev/null || true
cp -f "${TARGET}/runtime-diagnostics.txt" "${EVIDENCE}/runtime-diagnostics.txt" 2>/dev/null || true
cp -f "${TARGET}/run.txt" "${EVIDENCE}/run.txt" 2>/dev/null || true

awk -F'|' '
/^\[MINING\]/ {
  value=$2;
  gsub(/[^0-9.]/,"",value);
  if (value=="") next;
  value+=0;
  if (count==0 || value<min) min=value;
  if (count==0 || value>max) max=value;
  sum+=value;
  count++;
}
END {
  if (count>0) printf "samples=%d\nmin_mhs=%.3f\navg_mhs=%.3f\nmax_mhs=%.3f\n", count,min,sum/count,max;
  else print "samples=0";
}' "${EVIDENCE}/miner-live-sample.log" | tee "${EVIDENCE}/hashrate-stats.txt"

LAST_MINING="$(grep '^\[MINING\]' "${EVIDENCE}/miner-live-sample.log" | tail -n1 || true)"
ACCEPTED_EVENTS="$(grep -c '^\[ACCEPTED\]' "${EVIDENCE}/miner-live-sample.log" 2>/dev/null || true)"
REJECTED_EVENTS="$(grep -c '^\[REJECTED\]' "${EVIDENCE}/miner-live-sample.log" 2>/dev/null || true)"
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
sha256sum "${RELEASE_COPY}" "${VALIDATION_ARCHIVE}" | tee "/tmp/pepepow-v060-downloads.sha256"

printf '\n========== DOWNLOAD FILES =========='; echo
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo "Release package : http://${IP}:8080/$(basename "${RELEASE_COPY}")"
echo "Validation logs : http://${IP}:8080/$(basename "${VALIDATION_ARCHIVE}")"
echo "Checksums       : http://${IP}:8080/pepepow-v060-downloads.sha256"
echo "Download all three files, then press Ctrl+C."

echo
for pid in $(pgrep -x python3 2>/dev/null || true); do
  cmd="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
  case "${cmd}" in
    *http.server*8080*) kill "${pid}" 2>/dev/null || true ;;
  esac
done

exec python3 -m http.server 8080 --bind 0.0.0.0 --directory /tmp
