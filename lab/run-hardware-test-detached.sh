#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_URL="${PEPEW_TEST_SCRIPT_URL:-https://raw.githubusercontent.com/iPepew/PepePow_Miner/agent/multigpu-hive-stats/lab/pepew-hardware-test.sh}"
SCRIPT_PATH="${PEPEW_TEST_SCRIPT_PATH:-/tmp/pepew-hardware-test-current.sh}"
CURRENT_LOG="${PEPEW_CURRENT_LOG:-/tmp/pepew-test-current.log}"
PID_FILE="${PEPEW_PID_FILE:-/tmp/pepew-test-current.pid}"
REPORT_PATH_FILE="${PEPEW_REPORT_PATH_FILE:-/tmp/pepew-test-current-report.path}"
REPORT_ROOT="${PEPEW_REPORT_DIR:-/tmp/pepew-hwtest-detached}"

ASSET_URL="${PEPEW_ASSET_URL:-https://github.com/iPepew/PepePow_Miner/releases/download/hiveos-test/PepeW-Miner-HiveOS.tar.gz}"
TEST_SECONDS="${PEPEW_TEST_SECONDS:-300}"
WARMUP_SECONDS="${PEPEW_WARMUP_SECONDS:-30}"
SAMPLE_SECONDS="${PEPEW_SAMPLE_SECONDS:-5}"
PROGRESS_SECONDS="${PEPEW_PROGRESS_SECONDS:-5}"
MIN_MHS="${PEPEW_MIN_MHS:-6.00}"
MAX_REJECTED="${PEPEW_MAX_REJECTED:-0}"
MAX_RECONNECTS="${PEPEW_MAX_RECONNECTS:-1}"
LEAVE_RUNNING="${PEPEW_LEAVE_RUNNING:-1}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run this launcher as root on HiveOS" >&2
  exit 2
fi

if [[ -s "${PID_FILE}" ]]; then
  old_pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
  if [[ "${old_pid}" =~ ^[0-9]+$ ]] && kill -0 "${old_pid}" 2>/dev/null; then
    echo "ERROR: a hardware test is already running (PID ${old_pid})" >&2
    echo "Progress: tail -f ${CURRENT_LOG}" >&2
    exit 1
  fi
  rm -f "${PID_FILE}"
fi

if command -v wget >/dev/null 2>&1; then
  wget -qO "${SCRIPT_PATH}" "${SCRIPT_URL}"
elif command -v curl >/dev/null 2>&1; then
  curl -fsSL "${SCRIPT_URL}" -o "${SCRIPT_PATH}"
else
  echo "ERROR: wget or curl is required" >&2
  exit 2
fi
chmod +x "${SCRIPT_PATH}"
mkdir -p "${REPORT_ROOT}"
: > "${CURRENT_LOG}"
rm -f "${REPORT_PATH_FILE}"

export PEPEW_SCRIPT_PATH="${SCRIPT_PATH}"
export PEPEW_PID_FILE_INTERNAL="${PID_FILE}"
export PEPEW_REPORT_PATH_FILE_INTERNAL="${REPORT_PATH_FILE}"
export PEPEW_ASSET_URL="${ASSET_URL}"
export PEPEW_TEST_SECONDS="${TEST_SECONDS}"
export PEPEW_WARMUP_SECONDS="${WARMUP_SECONDS}"
export PEPEW_SAMPLE_SECONDS="${SAMPLE_SECONDS}"
export PEPEW_PROGRESS_SECONDS="${PROGRESS_SECONDS}"
export PEPEW_MIN_MHS="${MIN_MHS}"
export PEPEW_MAX_REJECTED="${MAX_REJECTED}"
export PEPEW_MAX_RECONNECTS="${MAX_RECONNECTS}"
export PEPEW_LEAVE_RUNNING="${LEAVE_RUNNING}"
export PEPEW_REPORT_DIR="${REPORT_ROOT}"

nohup bash -c '
  rc=0
  bash "$PEPEW_SCRIPT_PATH" || rc=$?
  latest=$(find "$PEPEW_REPORT_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n1)
  if [[ -n "$latest" && -f "$latest/report.json" ]]; then
    printf "%s\n" "$latest/report.json" > "$PEPEW_REPORT_PATH_FILE_INTERNAL"
  fi
  rm -f "$PEPEW_PID_FILE_INTERNAL"
  echo
  echo "[DETACHED] test process finished with exit code $rc"
  [[ -n "$latest" ]] && echo "[DETACHED] artifacts: $latest"
  exit "$rc"
' >"${CURRENT_LOG}" 2>&1 </dev/null &

pid=$!
printf '%s\n' "${pid}" > "${PID_FILE}"

cat <<EOF
PepeW detached hardware test started.
PID: ${pid}
Asset: ${ASSET_URL}
Warmup: ${WARMUP_SECONDS}s
Measurement: ${TEST_SECONDS}s
Progress interval: ${PROGRESS_SECONDS}s

The test survives Hive Shell disconnects.

Live progress:
  tail -f ${CURRENT_LOG}

One-shot status after reconnect:
  tail -n 30 ${CURRENT_LOG}

Process check:
  if [ -f ${PID_FILE} ]; then ps -fp \$(cat ${PID_FILE}); else echo "test finished"; fi

Final report:
  if [ -f ${REPORT_PATH_FILE} ]; then cat \$(cat ${REPORT_PATH_FILE}); else echo "report not ready"; fi
EOF
