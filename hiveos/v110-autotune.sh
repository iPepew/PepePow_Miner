#!/usr/bin/env bash
set -Eeuo pipefail

miner_dir="${1:?miner directory required}"
gpu_uuid="${2:?GPU UUID required}"
log_file="${3:-/var/log/miner/custom/$(basename "${miner_dir}")/v110-autotune.log}"
bench="${miner_dir}/pepepow-v110-autotune"
binary="${miner_dir}/pepepowminer"

mkdir -p "$(dirname "${log_file}")" "${miner_dir}/autotune"
[[ -x "${bench}" ]] || { echo "[AUTOTUNE] ERROR: v1.1.0 benchmark helper missing" >&2; exit 70; }
[[ -x "${binary}" ]] || { echo "[AUTOTUNE] ERROR: miner binary missing" >&2; exit 70; }

binary_sha="$(sha256sum "${binary}" | awk '{print $1}')"
safe_uuid="$(printf '%s' "${gpu_uuid}" | tr -c 'A-Za-z0-9._-' '_')"
cache_file="${miner_dir}/autotune/v110-${safe_uuid}.env"

if [[ "${PEPEW_V110_AUTOTUNE_FORCE:-0}" != "1" && -r "${cache_file}" ]]; then
  # shellcheck disable=SC1090
  source "${cache_file}" || true
  if [[ "${BINARY_SHA:-}" == "${binary_sha}" && "${ENGINE:-}" =~ ^(exact|cohort)$ &&
        "${THREADS:-}" =~ ^[0-9]+$ && "${THRESHOLD:-}" =~ ^[0-9]+$ &&
        "${BLOCKS_PER_SM:-}" =~ ^[0-9]+$ && "${HPS:-}" =~ ^[1-9][0-9]*$ ]]; then
    echo "[AUTOTUNE] cached v1.1.0 profile: engine=${ENGINE} threads=${THREADS} threshold=${THRESHOLD} blocks/SM=${BLOCKS_PER_SM} benchmark=$(awk -v h="${HPS}" 'BEGIN {printf "%.3f", h/1000000.0}') MH/s" >&2
    printf '%s %s %s %s %s\n' "${ENGINE}" "${THREADS}" "${THRESHOLD}" "${BLOCKS_PER_SM}" "${HPS}"
    exit 0
  fi
fi

count="${PEPEW_V110_AUTOTUNE_COUNT:-1228800}"
rounds="${PEPEW_V110_AUTOTUNE_ROUNDS:-3}"
thresholds="${PEPEW_V110_COHORT_THRESHOLDS:-4 8 12 16 20 24 28 32}"
blocks_per_sm_values="${PEPEW_V110_BLOCKS_PER_SM_VALUES:-1 2 4 8 10 12}"

: > "${log_file}"
printf 'UTC=%s\nGPU_UUID=%s\nBINARY_SHA=%s\nCOUNT=%s\nROUNDS=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${gpu_uuid}" "${binary_sha}" "${count}" "${rounds}" >> "${log_file}"

echo "[AUTOTUNE] v1.1.0 baseline: exact threads=768" >&2

best_engine=""
best_threads=0
best_threshold=0
best_blocks_per_sm=0
best_hps=0
exact_hps=0
valid_profiles=0

run_profile() {
  local engine="$1" threads="$2" threshold="$3" blocks_per_sm="$4"
  local output valid hps mhs rc
  output=""
  if output="$(CUDA_VISIBLE_DEVICES="${gpu_uuid}" "${bench}" \
      --engine "${engine}" --threads "${threads}" \
      --threshold "${threshold}" --blocks-per-sm "${blocks_per_sm}" \
      --count "${count}" --rounds "${rounds}" 2>&1)"; then
    printf '%s\n' "${output}" >> "${log_file}"
    valid="$(sed -n 's/.*valid=\([01]\).*/\1/p' <<<"${output}" | tail -n1)"
    hps="$(sed -n 's/.*hps=\([0-9][0-9]*\).*/\1/p' <<<"${output}" | tail -n1)"
    if [[ "${valid}" == "1" && "${hps}" =~ ^[1-9][0-9]*$ ]]; then
      ((valid_profiles+=1))
      mhs="$(awk -v h="${hps}" 'BEGIN {printf "%.3f", h/1000000.0}')"
      echo "[AUTOTUNE] engine=${engine} threads=${threads} threshold=${threshold} blocks/SM=${blocks_per_sm} consensus=PASS benchmark=${mhs} MH/s" >&2
      if [[ "${engine}" == "exact" ]]; then exact_hps="${hps}"; fi
      if (( hps > best_hps )); then
        best_hps="${hps}"
        best_engine="${engine}"
        best_threads="${threads}"
        best_threshold="${threshold}"
        best_blocks_per_sm="${blocks_per_sm}"
      fi
      return 0
    fi
    echo "[AUTOTUNE] engine=${engine} threads=${threads} threshold=${threshold} blocks/SM=${blocks_per_sm} consensus=FAIL" >&2
    return 1
  else
    rc=$?
    printf 'engine=%s threads=%s threshold=%s blocks_per_sm=%s rc=%s output=%s\n' \
      "${engine}" "${threads}" "${threshold}" "${blocks_per_sm}" "${rc}" "${output}" >> "${log_file}"
    echo "[AUTOTUNE] engine=${engine} threads=${threads} threshold=${threshold} blocks/SM=${blocks_per_sm} benchmark failed rc=${rc}" >&2
    return 1
  fi
}

# The exact v1.0.9-derived path is the safety anchor. If it cannot reproduce
# CPU consensus, v1.1.0 refuses to mine rather than silently selecting an
# experimental kernel.
if ! run_profile exact 768 16 10; then
  echo "[AUTOTUNE] FATAL: exact safety baseline failed consensus validation" >&2
  exit 71
fi

echo "[AUTOTUNE] v1.1.0 persistent warp-cohort sweep: threads=256" >&2
for blocks_per_sm in ${blocks_per_sm_values}; do
  [[ "${blocks_per_sm}" =~ ^[0-9]+$ ]] || continue
  for threshold in ${thresholds}; do
    [[ "${threshold}" =~ ^[0-9]+$ ]] || continue
    run_profile cohort 256 "${threshold}" "${blocks_per_sm}" || true
  done
done

if [[ -z "${best_engine}" ]] || (( best_hps == 0 || exact_hps == 0 )); then
  echo "[AUTOTUNE] FATAL: no consensus-valid v1.1.0 profile" >&2
  exit 72
fi

# A tiny synthetic-benchmark win is not enough to displace the field-proven
# exact engine. Cohort needs at least +2% over exact before automatic selection.
if [[ "${best_engine}" == "cohort" ]]; then
  required_hps=$(( exact_hps + exact_hps / 50 ))
  if (( best_hps < required_hps )); then
    echo "[AUTOTUNE] cohort win below 2% safety margin; selecting exact baseline" >&2
    best_engine="exact"
    best_threads=768
    best_threshold=16
    best_blocks_per_sm=10
    best_hps="${exact_hps}"
  fi
fi

best_mhs="$(awk -v h="${best_hps}" 'BEGIN {printf "%.3f", h/1000000.0}')"
echo "[AUTOTUNE] selected engine=${best_engine} threads=${best_threads} threshold=${best_threshold} blocks/SM=${best_blocks_per_sm} benchmark=${best_mhs} MH/s valid_profiles=${valid_profiles}" >&2

{
  printf 'BINARY_SHA=%q\n' "${binary_sha}"
  printf 'GPU_UUID=%q\n' "${gpu_uuid}"
  printf 'ENGINE=%q\n' "${best_engine}"
  printf 'THREADS=%q\n' "${best_threads}"
  printf 'THRESHOLD=%q\n' "${best_threshold}"
  printf 'BLOCKS_PER_SM=%q\n' "${best_blocks_per_sm}"
  printf 'HPS=%q\n' "${best_hps}"
  printf 'EXACT_HPS=%q\n' "${exact_hps}"
  printf 'VALID_PROFILES=%q\n' "${valid_profiles}"
  printf 'UTC=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${cache_file}.tmp"
mv -f "${cache_file}.tmp" "${cache_file}"
chmod 600 "${cache_file}"

printf '%s %s %s %s %s\n' \
  "${best_engine}" "${best_threads}" "${best_threshold}" "${best_blocks_per_sm}" "${best_hps}"
