#!/usr/bin/env bash
set -euo pipefail

ARCHIVE="${ARCHIVE:-/root/pepepow-v054-src/dist/pepepowminer-v0.5.4-PR-hiveos.tar.gz}"
TARGET="${TARGET:-/hive/miners/custom/pepepowminer-v0.5.4-PR}"
SESSION="${SESSION:-pepepow-v054}"
START_DELAY="${START_DELAY:-12}"

[[ -s "${ARCHIVE}" ]] || { echo "ERROR: archive not found or empty: ${ARCHIVE}" >&2; exit 1; }

stage="$(mktemp -d /tmp/pepepow-v054-install.XXXXXX)"
config_copy="$(mktemp /tmp/pepepow-v054-config.XXXXXX)"
cleanup() { rm -rf "${stage}" "${config_copy}"; }
trap cleanup EXIT

find_config() {
  local candidate
  if [[ -n "${CONFIG_SOURCE:-}" && -s "${CONFIG_SOURCE}" ]]; then
    printf '%s\n' "${CONFIG_SOURCE}"
    return 0
  fi
  for candidate in \
    /hive/miners/custom/pepepowminer-v0.5.2-PR/config.txt \
    /hive/miners/custom/pepepowminer-v0.5.1-PR/config.txt; do
    [[ -s "${candidate}" ]] && { printf '%s\n' "${candidate}"; return 0; }
  done
  find /hive/miners/custom -maxdepth 3 -type f -name config.txt \
    ! -path "${TARGET}/*" -print 2>/dev/null | head -n1
}

config_source="$(find_config || true)"
[[ -n "${config_source}" && -s "${config_source}" ]] || {
  echo "ERROR: no previous PepePow config.txt was found" >&2
  exit 1
}
cp -f "${config_source}" "${config_copy}"

echo "========== ARCHIVE =========="
ls -lh "${ARCHIVE}"
if [[ -s "${ARCHIVE}.sha256" ]]; then
  sha256sum -c "${ARCHIVE}.sha256"
else
  sha256sum "${ARCHIVE}"
fi
tar -tzf "${ARCHIVE}" | sed -n '1,30p'

echo "========== STAGE EXTRACT =========="
tar -xzf "${ARCHIVE}" -C "${stage}"
mapfile -t binaries < <(find "${stage}" -type f -name pepepowminer -print)
if [[ ${#binaries[@]} -ne 1 ]]; then
  echo "ERROR: expected exactly one pepepowminer in archive, found ${#binaries[@]}" >&2
  find "${stage}" -maxdepth 4 -printf '%y %p\n' >&2
  exit 1
fi
package_dir="$(dirname "${binaries[0]}")"
for required in pepepowminer h-run.sh h-config.sh stratum-replay-proxy.py BUILD_PROFILE VERSION; do
  [[ -f "${package_dir}/${required}" ]] || {
    echo "ERROR: package is missing ${required}" >&2
    exit 1
  }
done
ls -lah "${package_dir}"

echo "========== STOP PREVIOUS INSTANCE =========="
miner stop 2>/dev/null || true
screen -S "${SESSION}" -X quit 2>/dev/null || true
screen -S miner -X quit 2>/dev/null || true
for pidfile in /hive/miners/custom/pepepowminer-v*/miner.pid /hive/miners/custom/pepepowminer-v*/proxy.pid; do
  [[ -s "${pidfile}" ]] || continue
  pid="$(cat "${pidfile}" 2>/dev/null || true)"
  [[ "${pid}" =~ ^[0-9]+$ ]] && kill -TERM "${pid}" 2>/dev/null || true
done
sleep 3

echo "========== INSTALL =========="
rm -rf "${TARGET}"
mkdir -p "${TARGET}"
cp -a "${package_dir}/." "${TARGET}/"
cp -f "${config_copy}" "${TARGET}/config.txt"
sed -Ei 's#pepepowminer-v0\.5\.[0-9]+-PR#pepepowminer-v0.5.4-PR#g' "${TARGET}/config.txt"
chmod 0755 "${TARGET}/pepepowminer" "${TARGET}/h-run.sh" "${TARGET}/h-config.sh" \
  "${TARGET}/stratum-replay-proxy.py"
find "${TARGET}" -maxdepth 1 -type f -printf '%f %s bytes\n' | sort

for required in pepepowminer h-run.sh h-config.sh stratum-replay-proxy.py config.txt BUILD_PROFILE VERSION; do
  [[ -s "${TARGET}/${required}" ]] || {
    echo "ERROR: installed file missing or empty: ${TARGET}/${required}" >&2
    exit 1
  }
done

echo "========== BINARY =========="
"${TARGET}/pepepowminer" --version
"${TARGET}/pepepowminer" --list-gpu
cat "${TARGET}/BUILD_PROFILE"

echo "========== START =========="
rm -f /root/v054-screen.log
screen -L -Logfile /root/v054-screen.log -dmS "${SESSION}" bash -lc \
  "cd '${TARGET}' && exec ./h-run.sh"
sleep "${START_DELAY}"

echo "========== STATUS =========="
screen -ls 2>&1 || true
if [[ -s "${TARGET}/miner.pid" ]]; then
  miner_pid="$(cat "${TARGET}/miner.pid")"
else
  miner_pid=""
fi
if [[ "${miner_pid}" =~ ^[0-9]+$ ]] && kill -0 "${miner_pid}" 2>/dev/null; then
  echo "PASS: v0.5.4 miner is running; PID=${miner_pid}"
  tail -n 100 "${TARGET}/miner-console.log" 2>/dev/null || true
  exit 0
fi

echo "ERROR: v0.5.4 did not remain running" >&2
echo "----- screen log -----" >&2
tail -n 160 /root/v054-screen.log 2>/dev/null >&2 || true
for file in miner-console.log proxy-console.log runtime-diagnostics.txt miner-exit-status.txt run.txt; do
  echo "----- ${file} -----" >&2
  tail -n 160 "${TARGET}/${file}" 2>/dev/null >&2 || echo "missing" >&2
done
exit 1
