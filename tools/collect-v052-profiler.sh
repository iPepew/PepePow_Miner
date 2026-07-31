#!/usr/bin/env bash
set -euo pipefail

DURATION="${DURATION:-600}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp}"
INCLUDE_SOURCE="${INCLUDE_SOURCE:-1}"
BASE_COLLECTOR_URL="${BASE_COLLECTOR_URL:-https://raw.githubusercontent.com/iPepew/PepePow_Miner/diagnostics/profiler-pack-v3/tools/collect-profiler-pack.sh}"

mkdir -p "${OUTPUT_DIR}"
temporary_collector="$(mktemp /tmp/pepepow-profiler-base.XXXXXX.sh)"
temporary_unpack="$(mktemp -d /tmp/pepepow-profiler-augment.XXXXXX)"
cleanup() { rm -f "${temporary_collector}"; rm -rf "${temporary_unpack}"; }
trap cleanup EXIT

curl -fsSL "${BASE_COLLECTOR_URL}" -o "${temporary_collector}"
chmod +x "${temporary_collector}"

before_list="$(mktemp /tmp/pepepow-before.XXXXXX)"
find "${OUTPUT_DIR}" -maxdepth 1 -type f -name 'pepepow-profiler-*.tar.gz' -printf '%p\n' 2>/dev/null | sort > "${before_list}" || true

env DURATION="${DURATION}" OUTPUT_DIR="${OUTPUT_DIR}" INCLUDE_SOURCE="${INCLUDE_SOURCE}" \
  bash "${temporary_collector}"

after_list="$(mktemp /tmp/pepepow-after.XXXXXX)"
find "${OUTPUT_DIR}" -maxdepth 1 -type f -name 'pepepow-profiler-*.tar.gz' -printf '%p\n' 2>/dev/null | sort > "${after_list}" || true
archive="$(comm -13 "${before_list}" "${after_list}" | tail -n1)"
rm -f "${before_list}" "${after_list}"
if [[ -z "${archive}" || ! -f "${archive}" ]]; then
  archive="$(find "${OUTPUT_DIR}" -maxdepth 1 -type f -name 'pepepow-profiler-*.tar.gz' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)"
fi
[[ -n "${archive}" && -f "${archive}" ]] || { echo "ERROR: profiler archive was not created" >&2; exit 1; }

tar -xzf "${archive}" -C "${temporary_unpack}"
pack_root="$(find "${temporary_unpack}" -mindepth 1 -maxdepth 1 -type d | head -n1)"
[[ -n "${pack_root}" && -d "${pack_root}" ]] || { echo "ERROR: invalid profiler archive" >&2; exit 1; }

mkdir -p "${pack_root}/package"
miner_exe="$(sed -n 's/^miner_exe=//p' "${pack_root}/MANIFEST.txt" | head -n1)"
miner_dir=""
if [[ -n "${miner_exe}" && "${miner_exe}" != "not_detected" ]]; then
  miner_dir="$(dirname "${miner_exe}")"
fi

if [[ -n "${miner_dir}" && -d "${miner_dir}" ]]; then
  for file_name in VERSION BUILD_PROFILE h-manifest.conf h-run.sh h-config.sh h-stats.sh; do
    if [[ -f "${miner_dir}/${file_name}" ]]; then
      cp -a "${miner_dir}/${file_name}" "${pack_root}/package/${file_name}"
    fi
  done
fi

for build_log in /root/v052-build.log /tmp/v052-build.log; do
  if [[ -f "${build_log}" ]]; then
    tail -c $((50 * 1024 * 1024)) "${build_log}" > "${pack_root}/package/$(basename "${build_log}")"
    break
  fi
done

{
  echo "v052_wrapper=1"
  echo "base_collector_url=${BASE_COLLECTOR_URL}"
  echo "miner_dir=${miner_dir:-not_detected}"
  if [[ -f "${pack_root}/package/BUILD_PROFILE" ]]; then
    echo "build_profile_present=1"
    grep -E '^(version|selected_profile|selected_hps|baseline_profile|baseline_hps|uplift_pct|target_hps|edition|driver|gpu|git_commit)=' \
      "${pack_root}/package/BUILD_PROFILE" || true
  else
    echo "build_profile_present=0"
  fi
} > "${pack_root}/package/V052_PROFILE_SUMMARY.txt"

rm -f "${archive}" "${archive}.sha256"
tar -C "${temporary_unpack}" -czf "${archive}" "$(basename "${pack_root}")"
sha256sum "${archive}" > "${archive}.sha256"

printf 'DONE_ARCHIVE=%s\n' "${archive}"
printf 'DONE_SHA256=%s\n' "${archive}.sha256"
ls -lh "${archive}" "${archive}.sha256"
