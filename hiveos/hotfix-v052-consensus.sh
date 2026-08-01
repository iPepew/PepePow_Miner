#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

python3 hiveos/prepare-v052-source.py

python3 - <<'PY'
from pathlib import Path

root = Path.cwd()
cuda_path = root / "native/src/cuda/header80_backend_v052.cu"
builder_path = root / "hiveos/build-v052-exact-conversions.sh"

cuda = cuda_path.read_text(encoding="utf-8")
unsafe = '''    if (value == 0.0) return;
    if (sw <= 0.02) {
        const double cell = matrix[cell_index];
        const double x = cell * hash_mod * value + nonce_mod;
        sum += safe_nonlinear(x) * value * 1234.0;
    } else {'''
restored = '''    if (sw <= 0.02) {
        if (value != 0.0) {
            const double cell = matrix[cell_index];
            const double x = cell * hash_mod * value + nonce_mod;
            sum += safe_nonlinear(x) * value * 1234.0;
        }
    } else {'''
if unsafe in cuda:
    cuda = cuda.replace(unsafe, restored, 1)
elif restored not in cuda:
    raise SystemExit("Cannot locate zero-nibble accumulator block")
cuda_path.write_text(cuda, encoding="utf-8")

builder = builder_path.read_text(encoding="utf-8")nbuilder = builder.replace(" positive_double_to_u64_rz 'if (value == 0.0) return;' 'hash_mod_fp64 = u32_to_double_exact(hash_mod)'", " positive_double_to_u64_rz 'hash_mod_fp64 = u32_to_double_exact(hash_mod)'")

old_validation = '''  ctest --test-dir "${dir}" --output-on-failure
  "${dir}/pepepow_cuda_header80_validation"

  local speeds=() output hps'''
new_validation = '''  if ! ctest --test-dir "${dir}" --output-on-failure; then
    printf 'name=%s\\nvalid=0\\nreason=ctest_failed\\nthreads=%s\\nmin_blocks=%s\\nsplit=%s\\nexact_bit_conversions=%s\\nunroll=%s\\nmax_regs=%s\\n' \\
      "${name}" "${threads}" "${min_blocks}" "${split}" "${exact_bits}" "${unroll}" "${max_regs:-auto}" > "${dir}/profile.meta"
    printf 'PROFILE_INVALID name=%s reason=ctest_failed\\n' "${name}"
    return 0
  fi
  if ! "${dir}/pepepow_cuda_header80_validation"; then
    printf 'name=%s\\nvalid=0\\nreason=validation_failed\\nthreads=%s\\nmin_blocks=%s\\nsplit=%s\\nexact_bit_conversions=%s\\nunroll=%s\\nmax_regs=%s\\n' \\
      "${name}" "${threads}" "${min_blocks}" "${split}" "${exact_bits}" "${unroll}" "${max_regs:-auto}" > "${dir}/profile.meta"
    printf 'PROFILE_INVALID name=%s reason=validation_failed\\n' "${name}"
    return 0
  fi

  local speeds=() output hps'''
if old_validation in builder:
    builder = builder.replace(old_validation, new_validation, 1)
elif "PROFILE_INVALID name=%s reason=ctest_failed" not in builder:
    raise SystemExit("Cannot locate builder validation block")

old_select = '''for profile in "${profiles[@]}"; do
  hps="$(cat "${PROFILE_ROOT}/${profile}/profile.hps")"
  if (( hps > best_hps )); then best_hps="${hps}"; best_profile="${profile}"; fi
done'''
new_select = '''for profile in "${profiles[@]}"; do
  [[ -s "${PROFILE_ROOT}/${profile}/profile.hps" ]] || continue
  hps="$(cat "${PROFILE_ROOT}/${profile}/profile.hps")"
  if (( hps > best_hps )); then best_hps="${hps}"; best_profile="${profile}"; fi
done'''
if old_select in builder:
    builder = builder.replace(old_select, new_select, 1)
elif '[[ -s "${PROFILE_ROOT}/${profile}/profile.hps" ]] || continue' not in builder:
    raise SystemExit("Cannot locate profile selection loop")

old_baseline = 'baseline_hps="$(cat "${PROFILE_ROOT}/baseline-mono64-u2/profile.hps")"'
new_baseline = '[[ -s "${PROFILE_ROOT}/baseline-mono64-u2/profile.hps" ]] || { echo "Consensus baseline failed; refusing to package" >&2; exit 1; }\nbaseline_hps="$(cat "${PROFILE_ROOT}/baseline-mono64-u2/profile.hps")"'
if old_baseline in builder and "Consensus baseline failed" not in builder:
    builder = builder.replace(old_baseline, new_baseline, 1)

old_meta = '  for profile in "${profiles[@]}"; do echo "--- ${profile} ---"; cat "${PROFILE_ROOT}/${profile}/profile.meta"; done'
new_meta = '  for profile in "${profiles[@]}"; do echo "--- ${profile} ---"; if [[ -s "${PROFILE_ROOT}/${profile}/profile.meta" ]]; then cat "${PROFILE_ROOT}/${profile}/profile.meta"; else echo "valid=0"; echo "reason=missing_profile_metadata"; fi; done'
if old_meta in builder:
    builder = builder.replace(old_meta, new_meta, 1)

builder_path.write_text(builder, encoding="utf-8")
print("PASS: v0.5.2 consensus hotfix applied")
PY

exec env \
  BENCH_RUNS="${BENCH_RUNS:-3}" \
  BENCH_NONCES="${BENCH_NONCES:-4194304}" \
  bash hiveos/build-v052-exact-conversions.sh
