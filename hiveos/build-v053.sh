#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

python3 - <<'PY'
from pathlib import Path
root=Path.cwd()
builder=root/'hiveos/build-v053-bitfraction.sh'
h_run=root/'hiveos/h-run.sh'

text=builder.read_text(encoding='utf-8')
old='cmake --build "${dir}" --parallel "${JOBS}" --target pepepow_cuda_header80_validation pepepow_header80_benchmark pepepowminer 2>&1 | tee "${build_log}"'
new='cmake --build "${dir}" --parallel "${JOBS}" --target pepepow_core_tests pepepow_cuda_tests pepepow_cuda_header80_validation pepepow_header80_benchmark pepepowminer 2>&1 | tee "${build_log}"'
if old in text:
    text=text.replace(old,new,1)
elif new not in text:
    raise SystemExit('Cannot patch v0.5.3 build targets')
builder.write_text(text,encoding='utf-8')

run=h_run.read_text(encoding='utf-8')
run=run.replace(
    'AUTOTUNED_PIPELINE EXACT_BIT_CONVERSIONS FAST_FRACTION ZERO_NIBBLE_SKIP HASHMOD_HOIST PREFER_L1',
    'AUTOTUNED_PIPELINE EXACT_BIT_CONVERSIONS BIT_SW_FRACTION DERIVE_TWO NIBBLE_TABLE HASHMOD_HOIST PREFER_L1',
)
run=run.replace(
    'autotuned monolithic/split pipeline; exact bit conversions; exact fast fraction; zero-nibble skip; hash-mod conversion hoist; PreferL1; persistent buffers; 524288 runtime batch',
    'autotuned monolithic pipeline; exact bit conversions; direct bit fraction(sum/1024); derived nonlinear selector; optional nibble table; hash-mod conversion hoist; PreferL1; persistent buffers; 524288 runtime batch',
)
h_run.write_text(run,encoding='utf-8')
print('PASS: v0.5.3 build entrypoint patches applied')
PY

exec env \
  BENCH_RUNS="${BENCH_RUNS:-3}" \
  BENCH_NONCES="${BENCH_NONCES:-4194304}" \
  TARGET_HPS="${TARGET_HPS:-2000000}" \
  bash hiveos/build-v053-bitfraction.sh
