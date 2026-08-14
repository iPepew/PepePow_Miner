#!/usr/bin/env bash
set -Eeuo pipefail

miner_dir="${1:?miner directory required}"
gpu_uuid="${2:?GPU UUID required}"
log_file="${3:-/var/log/miner/custom/$(basename "${miner_dir}")/v100-autotune.log}"
bench="${miner_dir}/pepepow-v100-autotune"
binary="${miner_dir}/pepepowminer"

mkdir -p "$(dirname "${log_file}")" "${miner_dir}/autotune"
[[ -x "${bench}" ]] || { echo "[AUTOTUNE] ERROR: benchmark helper is missing" >&2; exit 70; }
[[ -x "${binary}" ]] || { echo "[AUTOTUNE] ERROR: miner binary is missing" >&2; exit 70; }

binary_sha="$(sha256sum "${binary}" | awk '{print $1}')"
safe_uuid="$(printf '%s' "${gpu_uuid}" | tr -c 'A-Za-z0-9._-' '_')"
cache_file="${miner_dir}/autotune/v100-${safe_uuid}.env"

if [[ "${PEPEW_V100_AUTOTUNE_FORCE:-0}" != "1" && -r "${cache_file}" ]]; then
  # shellcheck disable=SC1090
  source "${cache_file}" || true
  if [[ "${BINARY_SHA:-}" == "${binary_sha}" && "${THREADS:-}" =~ ^[0-9]+$ && "${HPS:-}" =~ ^[1-9][0-9]*$ ]]; then
    echo "[AUTOTUNE] cached V100 geometry: threads=${THREADS} benchmark=$(awk -v h="${HPS}" 'BEGIN {printf "%.3f", h/1000000.0}') MH/s" >&2
    printf '%s\n' "${THREADS}"
    exit 0
  fi
fi

# Exhaust every legal service geometry. 96 threads is the minimum because the
# exact service kernel needs at least one warp for each of its three nonlinear
# regions. Three timed rounds provide a true median rather than selecting the
# faster of a two-sample pair.
candidates="${PEPEW_V100_AUTOTUNE_CANDIDATES:-96 128 160 192 224 256 288 320 352 384 416 448 480 512 544 576 608 640 672 704 736 768}"
count="${PEPEW_V100_AUTOTUNE_COUNT:-1048576}"
rounds="${PEPEW_V100_AUTOTUNE_ROUNDS:-3}"

printf '[AUTOTUNE] Tesla V100 geometry sweep:' >&2
for threads in ${candidates}; do printf ' %s' "${threads}" >&2; done
printf '\n' >&2

best_threads=0
best_hps=0
valid_count=0
: > "${log_file}"
printf 'UTC=%s\nGPU_UUID=%s\nBINARY_SHA=%s\nCOUNT=%s\nROUNDS=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${gpu_uuid}" "${binary_sha}" "${count}" "${rounds}" >> "${log_file}"

for threads in ${candidates}; do
  [[ "${threads}" =~ ^[0-9]+$ ]] || continue
  if (( threads < 96 || threads > 768 || threads % 32 != 0 )); then
    echo "[AUTOTUNE] skip invalid threads=${threads}" >&2
    continue
  fi

  output=""
  if output="$(CUDA_VISIBLE_DEVICES="${gpu_uuid}" "${bench}" --threads "${threads}" --count "${count}" --rounds "${rounds}" 2>&1)"; then
    printf '%s\n' "${output}" >> "${log_file}"
    valid="$(sed -n 's/.*valid=\([01]\).*/\1/p' <<<"${output}" | tail -n1)"
    hps="$(sed -n 's/.*hps=\([0-9][0-9]*\).*/\1/p' <<<"${output}" | tail -n1)"
    if [[ "${valid}" == "1" && "${hps}" =~ ^[1-9][0-9]*$ ]]; then
      ((valid_count+=1))
      mhs="$(awk -v h="${hps}" 'BEGIN {printf "%.3f", h/1000000.0}')"
      echo "[AUTOTUNE] threads=${threads} consensus=PASS benchmark=${mhs} MH/s" >&2
      if (( hps > best_hps )); then
        best_hps="${hps}"
        best_threads="${threads}"
      fi
    else
      echo "[AUTOTUNE] threads=${threads} consensus=FAIL" >&2
    fi
  else
    rc=$?
    printf 'threads=%s rc=%s output=%s\n' "${threads}" "${rc}" "${output}" >> "${log_file}"
    echo "[AUTOTUNE] threads=${threads} benchmark failed rc=${rc}" >&2
  fi
done

if (( valid_count == 0 || best_hps == 0 || best_threads == 0 )); then
  echo "[AUTOTUNE] FATAL: no consensus-valid V100 geometry; refusing to start mining" >&2
  exit 71
fi

best_mhs="$(awk -v h="${best_hps}" 'BEGIN {printf "%.3f", h/1000000.0}')"
echo "[AUTOTUNE] selected threads=${best_threads} benchmark=${best_mhs} MH/s valid_profiles=${valid_count}" >&2

{
  printf 'BINARY_SHA=%q\n' "${binary_sha}"
  printf 'GPU_UUID=%q\n' "${gpu_uuid}"
  printf 'THREADS=%q\n' "${best_threads}"
  printf 'HPS=%q\n' "${best_hps}"
  printf 'VALID_PROFILES=%q\n' "${valid_count}"
  printf 'UTC=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${cache_file}.tmp"
mv -f "${cache_file}.tmp" "${cache_file}"
chmod 600 "${cache_file}"

printf '%s\n' "${best_threads}"
