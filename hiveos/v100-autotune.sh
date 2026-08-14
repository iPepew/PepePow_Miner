#!/usr/bin/env bash
set -Eeuo pipefail

miner_dir="${1:?miner directory required}"
gpu_uuid="${2:?GPU UUID required}"
log_file="${3:-/var/log/miner/custom/$(basename "${miner_dir}")/v100-autotune.log}"

binary_exact="${miner_dir}/pepepowminer"
binary_fast="${miner_dir}/pepepowminer-fasttrig"
bench_exact="${miner_dir}/pepepow-v100-autotune"
bench_fast="${miner_dir}/pepepow-v100-autotune-fasttrig"

mkdir -p "$(dirname "${log_file}")" "${miner_dir}/autotune"
for required in "${binary_exact}" "${binary_fast}" "${bench_exact}" "${bench_fast}"; do
  [[ -x "${required}" ]] || { echo "[AUTOTUNE] ERROR: missing executable ${required}" >&2; exit 70; }
done

sha_exact="$(sha256sum "${binary_exact}" | awk '{print $1}')"
sha_fast="$(sha256sum "${binary_fast}" | awk '{print $1}')"
build_key="$(printf '%s\n%s\n' "${sha_exact}" "${sha_fast}" | sha256sum | awk '{print $1}')"
safe_uuid="$(printf '%s' "${gpu_uuid}" | tr -c 'A-Za-z0-9._-' '_')"
cache_file="${miner_dir}/autotune/v100-${safe_uuid}.env"

if [[ "${PEPEW_V100_AUTOTUNE_FORCE:-0}" != "1" && -r "${cache_file}" ]]; then
  # shellcheck disable=SC1090
  source "${cache_file}" || true
  if [[ "${BUILD_KEY:-}" == "${build_key}" && "${THREADS:-}" =~ ^[0-9]+$ &&
        "${HPS:-}" =~ ^[1-9][0-9]*$ && "${MODE:-}" =~ ^(exact|fasttrig)$ ]]; then
    echo "[AUTOTUNE] cached V100 profile: mode=${MODE} threads=${THREADS} benchmark=$(awk -v h="${HPS}" 'BEGIN {printf "%.3f", h/1000000.0}') MH/s" >&2
    printf '%s %s\n' "${THREADS}" "${MODE}"
    exit 0
  fi
fi

# Full physical sweep: exact is the proven service engine; fasttrig uses the
# restricted-domain argument reducer. Both modes must pass complete CPU/GPU
# HooHash validation in the benchmark helper before their speed is considered.
modes="${PEPEW_V100_AUTOTUNE_MODES:-exact fasttrig}"
candidates="${PEPEW_V100_AUTOTUNE_CANDIDATES:-96 128 160 192 224 256 288 320 352 384 416 448 480 512 544 576 608 640 672 704 736 768}"
count="${PEPEW_V100_AUTOTUNE_COUNT:-1048576}"
rounds="${PEPEW_V100_AUTOTUNE_ROUNDS:-3}"

printf '[AUTOTUNE] Tesla V100 modes:' >&2
for mode in ${modes}; do printf ' %s' "${mode}" >&2; done
printf '\n[AUTOTUNE] block geometries:' >&2
for threads in ${candidates}; do printf ' %s' "${threads}" >&2; done
printf '\n' >&2

best_mode=""
best_threads=0
best_hps=0
valid_count=0
: > "${log_file}"
printf 'UTC=%s\nGPU_UUID=%s\nBUILD_KEY=%s\nEXACT_SHA=%s\nFAST_SHA=%s\nCOUNT=%s\nROUNDS=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${gpu_uuid}" "${build_key}" \
  "${sha_exact}" "${sha_fast}" "${count}" "${rounds}" >> "${log_file}"

for mode in ${modes}; do
  case "${mode}" in
    exact) bench="${bench_exact}" ;;
    fasttrig) bench="${bench_fast}" ;;
    *) echo "[AUTOTUNE] skip unknown mode=${mode}" >&2; continue ;;
  esac

  for threads in ${candidates}; do
    [[ "${threads}" =~ ^[0-9]+$ ]] || continue
    if (( threads < 96 || threads > 768 || threads % 32 != 0 )); then
      echo "[AUTOTUNE] skip invalid threads=${threads}" >&2
      continue
    fi

    output=""
    if output="$(CUDA_VISIBLE_DEVICES="${gpu_uuid}" "${bench}" --threads "${threads}" --count "${count}" --rounds "${rounds}" 2>&1)"; then
      printf 'mode=%s %s\n' "${mode}" "${output}" >> "${log_file}"
      valid="$(sed -n 's/.*valid=\([01]\).*/\1/p' <<<"${output}" | tail -n1)"
      hps="$(sed -n 's/.*hps=\([0-9][0-9]*\).*/\1/p' <<<"${output}" | tail -n1)"
      if [[ "${valid}" == "1" && "${hps}" =~ ^[1-9][0-9]*$ ]]; then
        ((valid_count+=1))
        mhs="$(awk -v h="${hps}" 'BEGIN {printf "%.3f", h/1000000.0}')"
        echo "[AUTOTUNE] mode=${mode} threads=${threads} consensus=PASS benchmark=${mhs} MH/s" >&2
        if (( hps > best_hps )); then
          best_hps="${hps}"
          best_threads="${threads}"
          best_mode="${mode}"
        fi
      else
        echo "[AUTOTUNE] mode=${mode} threads=${threads} consensus=FAIL" >&2
      fi
    else
      rc=$?
      printf 'mode=%s threads=%s rc=%s output=%s\n' "${mode}" "${threads}" "${rc}" "${output}" >> "${log_file}"
      echo "[AUTOTUNE] mode=${mode} threads=${threads} benchmark failed rc=${rc}" >&2
    fi
  done
done

if (( valid_count == 0 || best_hps == 0 || best_threads == 0 )) || [[ -z "${best_mode}" ]]; then
  echo "[AUTOTUNE] FATAL: no consensus-valid V100 profile; refusing to start mining" >&2
  exit 71
fi

best_mhs="$(awk -v h="${best_hps}" 'BEGIN {printf "%.3f", h/1000000.0}')"
echo "[AUTOTUNE] selected mode=${best_mode} threads=${best_threads} benchmark=${best_mhs} MH/s valid_profiles=${valid_count}" >&2

{
  printf 'BUILD_KEY=%q\n' "${build_key}"
  printf 'GPU_UUID=%q\n' "${gpu_uuid}"
  printf 'MODE=%q\n' "${best_mode}"
  printf 'THREADS=%q\n' "${best_threads}"
  printf 'HPS=%q\n' "${best_hps}"
  printf 'VALID_PROFILES=%q\n' "${valid_count}"
  printf 'UTC=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${cache_file}.tmp"
mv -f "${cache_file}.tmp" "${cache_file}"
chmod 600 "${cache_file}"

printf '%s %s\n' "${best_threads}" "${best_mode}"
