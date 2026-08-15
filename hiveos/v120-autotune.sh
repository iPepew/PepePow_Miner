#!/usr/bin/env bash
set -Eeuo pipefail

miner_dir="${1:?miner directory required}"
gpu_uuid="${2:?GPU UUID required}"
log_file="${3:-/var/log/miner/custom/$(basename "${miner_dir}")/v120-autotune.log}"

binary="${miner_dir}/pepepowminer"
bench="${miner_dir}/pepepow-v120-autotune"
mkdir -p "$(dirname "${log_file}")" "${miner_dir}/autotune"

[[ -x "${binary}" ]] || { echo "[AUTOTUNE] ERROR: miner binary is missing" >&2; exit 70; }
[[ -x "${bench}" ]] || { echo "[AUTOTUNE] ERROR: v1.2.0 benchmark helper is missing" >&2; exit 70; }

binary_sha="$(sha256sum "${binary}" | awk '{print $1}')"
tuner_sha="$(sha256sum "${bench}" | awk '{print $1}')"
build_key="$(printf '%s\n%s\n' "${binary_sha}" "${tuner_sha}" | sha256sum | awk '{print $1}')"
safe_uuid="$(printf '%s' "${gpu_uuid}" | tr -c 'A-Za-z0-9._-' '_')"
cache_file="${miner_dir}/autotune/v120-${safe_uuid}.env"

if [[ "${PEPEW_V120_AUTOTUNE_FORCE:-0}" != "1" && -r "${cache_file}" ]]; then
  # shellcheck disable=SC1090
  source "${cache_file}" || true
  if [[ "${BUILD_KEY:-}" == "${build_key}" && "${ENGINE:-}" =~ ^(exact|magic)$ &&
        "${THREADS:-}" =~ ^[0-9]+$ && "${BLOCKS_PER_SM:-}" =~ ^[0-9]+$ &&
        "${FAST_RSQRT:-}" =~ ^[01]$ && "${RAW_HPS:-}" =~ ^[1-9][0-9]*$ &&
        "${EFFECTIVE_HPS:-}" =~ ^[1-9][0-9]*$ ]]; then
    echo "[AUTOTUNE] cached V100 profile: engine=${ENGINE} threads=${THREADS} blocks/SM=${BLOCKS_PER_SM} fast_rsqrt=${FAST_RSQRT} raw=$(awk -v h="${RAW_HPS}" 'BEGIN {printf "%.3f", h/1000000.0}') MH/s effective=$(awk -v h="${EFFECTIVE_HPS}" 'BEGIN {printf "%.3f", h/1000000.0}') MH/s quality=${QUALITY:-1.000000}" >&2
    printf '%s %s %s %s %s %s %s\n' \
      "${ENGINE}" "${THREADS}" "${BLOCKS_PER_SM}" "${FAST_RSQRT}" \
      "${RAW_HPS}" "${EFFECTIVE_HPS}" "${QUALITY:-1.000000}"
    exit 0
  fi
fi

count="${PEPEW_V120_AUTOTUNE_COUNT:-1228800}"
rounds="${PEPEW_V120_AUTOTUNE_ROUNDS:-3}"
minimum_quality="${PEPEW_V120_MIN_QUALITY:-0.90}"
selection_margin="${PEPEW_V120_SELECTION_MARGIN:-1.05}"
threads_list="${PEPEW_V120_THREADS:-128 256}"
blocks_list="${PEPEW_V120_BLOCKS_PER_SM_LIST:-1 2 4 6 8}"
rsqrt_list="${PEPEW_V120_RSQRT_MODES:-0 1}"

: > "${log_file}"
printf 'UTC=%s\nGPU_UUID=%s\nBUILD_KEY=%s\nCOUNT=%s\nROUNDS=%s\nMIN_QUALITY=%s\nSELECTION_MARGIN=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${gpu_uuid}" "${build_key}" \
  "${count}" "${rounds}" "${minimum_quality}" "${selection_margin}" >> "${log_file}"

echo "[AUTOTUNE] v1.2.0 V100 Magic LUT: exact baseline + speculative profiles" >&2
echo "[AUTOTUNE] score=raw_hps*exact_hash_quality; min_quality=${minimum_quality}" >&2

run_profile() {
  local engine="$1" threads="$2" blocks="$3" fast_rsqrt="$4" min_quality="$5"
  local output rc=0
  output="$(CUDA_VISIBLE_DEVICES="${gpu_uuid}" "${bench}" \
      --engine "${engine}" --threads "${threads}" --blocks-per-sm "${blocks}" \
      --fast-rsqrt "${fast_rsqrt}" --count "${count}" --rounds "${rounds}" \
      --min-quality "${min_quality}" 2>&1)" || rc=$?
  printf 'engine=%s threads=%s blocks_per_sm=%s fast_rsqrt=%s rc=%s output=%s\n' \
    "${engine}" "${threads}" "${blocks}" "${fast_rsqrt}" "${rc}" "${output}" >> "${log_file}"
  if (( rc != 0 )); then
    return "${rc}"
  fi
  printf '%s\n' "${output}"
}

exact_output="$(run_profile exact 768 1 0 1.0)" || {
  echo "[AUTOTUNE] FATAL: exact V100 baseline failed consensus validation" >&2
  exit 71
}
exact_hps="$(sed -n 's/.* hps=\([0-9][0-9]*\).*/\1/p' <<<"${exact_output}" | tail -n1)"
exact_effective="$(sed -n 's/.* effective_hps=\([0-9][0-9]*\).*/\1/p' <<<"${exact_output}" | tail -n1)"
[[ "${exact_hps}" =~ ^[1-9][0-9]*$ && "${exact_effective}" =~ ^[1-9][0-9]*$ ]] || {
  echo "[AUTOTUNE] FATAL: could not parse exact benchmark" >&2
  exit 72
}
echo "[AUTOTUNE] engine=exact threads=768 consensus=PASS benchmark=$(awk -v h="${exact_hps}" 'BEGIN {printf "%.3f", h/1000000.0}') MH/s" >&2

best_engine="exact"
best_threads=768
best_blocks=1
best_rsqrt=0
best_raw="${exact_hps}"
best_effective="${exact_effective}"
best_quality="1.000000"
valid_magic=0

for threads in ${threads_list}; do
  [[ "${threads}" =~ ^(128|256)$ ]] || continue
  for blocks in ${blocks_list}; do
    [[ "${blocks}" =~ ^[0-9]+$ ]] || continue
    (( blocks >= 1 && blocks <= 16 )) || continue
    for fast_rsqrt in ${rsqrt_list}; do
      [[ "${fast_rsqrt}" =~ ^[01]$ ]] || continue
      output=""
      if output="$(run_profile magic "${threads}" "${blocks}" "${fast_rsqrt}" "${minimum_quality}")"; then
        raw="$(sed -n 's/.* hps=\([0-9][0-9]*\).*/\1/p' <<<"${output}" | tail -n1)"
        effective="$(sed -n 's/.* effective_hps=\([0-9][0-9]*\).*/\1/p' <<<"${output}" | tail -n1)"
        quality="$(sed -n 's/.* quality=\([0-9.][0-9.]*\).*/\1/p' <<<"${output}" | tail -n1)"
        if [[ "${raw}" =~ ^[1-9][0-9]*$ && "${effective}" =~ ^[1-9][0-9]*$ && -n "${quality}" ]]; then
          ((valid_magic+=1))
          echo "[AUTOTUNE] engine=magic threads=${threads} blocks/SM=${blocks} fast_rsqrt=${fast_rsqrt} quality=${quality} raw=$(awk -v h="${raw}" 'BEGIN {printf "%.3f", h/1000000.0}') MH/s effective=$(awk -v h="${effective}" 'BEGIN {printf "%.3f", h/1000000.0}') MH/s" >&2
          if (( effective > best_effective )); then
            best_engine="magic"
            best_threads="${threads}"
            best_blocks="${blocks}"
            best_rsqrt="${fast_rsqrt}"
            best_raw="${raw}"
            best_effective="${effective}"
            best_quality="${quality}"
          fi
        fi
      else
        echo "[AUTOTUNE] engine=magic threads=${threads} blocks/SM=${blocks} fast_rsqrt=${fast_rsqrt} quality=FAIL" >&2
      fi
    done
  done
done

# Magic must beat exact by a meaningful margin; otherwise keep the fully exact
# baseline. Integer arithmetic avoids shell floating-point surprises.
required_magic="$(awk -v h="${exact_effective}" -v m="${selection_margin}" 'BEGIN {printf "%.0f", h*m}')"
if [[ "${best_engine}" == "magic" ]] && (( best_effective < required_magic )); then
  echo "[AUTOTUNE] best magic profile does not clear ${selection_margin}x exact margin; selecting exact" >&2
  best_engine="exact"
  best_threads=768
  best_blocks=1
  best_rsqrt=0
  best_raw="${exact_hps}"
  best_effective="${exact_effective}"
  best_quality="1.000000"
fi

if [[ "${best_engine}" == "magic" ]]; then
  echo "[AUTOTUNE] selected engine=magic threads=${best_threads} blocks/SM=${best_blocks} fast_rsqrt=${best_rsqrt} quality=${best_quality} raw=$(awk -v h="${best_raw}" 'BEGIN {printf "%.3f", h/1000000.0}') MH/s effective=$(awk -v h="${best_effective}" 'BEGIN {printf "%.3f", h/1000000.0}') MH/s valid_magic=${valid_magic}" >&2
else
  echo "[AUTOTUNE] selected engine=exact threads=768 benchmark=$(awk -v h="${exact_hps}" 'BEGIN {printf "%.3f", h/1000000.0}') MH/s valid_magic=${valid_magic}" >&2
fi

{
  printf 'BUILD_KEY=%q\n' "${build_key}"
  printf 'GPU_UUID=%q\n' "${gpu_uuid}"
  printf 'ENGINE=%q\n' "${best_engine}"
  printf 'THREADS=%q\n' "${best_threads}"
  printf 'BLOCKS_PER_SM=%q\n' "${best_blocks}"
  printf 'FAST_RSQRT=%q\n' "${best_rsqrt}"
  printf 'RAW_HPS=%q\n' "${best_raw}"
  printf 'EFFECTIVE_HPS=%q\n' "${best_effective}"
  printf 'QUALITY=%q\n' "${best_quality}"
  printf 'VALID_MAGIC_PROFILES=%q\n' "${valid_magic}"
  printf 'UTC=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${cache_file}.tmp"
mv -f "${cache_file}.tmp" "${cache_file}"
chmod 600 "${cache_file}"

printf '%s %s %s %s %s %s %s\n' \
  "${best_engine}" "${best_threads}" "${best_blocks}" "${best_rsqrt}" \
  "${best_raw}" "${best_effective}" "${best_quality}"
