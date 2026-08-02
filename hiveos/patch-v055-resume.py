#!/usr/bin/env python3
"""Patch the v0.5.5 autotuner for resumable RTX 3080 sweeps.

The first v0.5.5 rig run used an unsupported 32-thread candidate after the
expensive ILP1..4 stage. A subsequent resume also re-ran the historical source
preparation chain on an already prepared tree, which is intentionally not
idempotent. This patch:

* replaces the unsupported 32-thread candidate with 160 threads;
* reuses completed, consensus-gated profiles when RESUME=1;
* skips source preparation during RESUME=1 (or SKIP_SOURCE_PREPARE=1).
"""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / "hiveos/build-v055-ilp.sh"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"v0.5.5 hotfix failed: {label} marker not found")
    return text.replace(old, new, 1)


text = TARGET.read_text(encoding="utf-8")

text = replace_once(
    text,
    'chmod +x "${PREPARE_SCRIPT}"\n'
    'python3 "${PREPARE_SCRIPT}"\n',
    'if [[ "${RESUME:-0}" == "1" || "${SKIP_SOURCE_PREPARE:-0}" == "1" ]]; then\n'
    '  echo "SOURCE_PREPARE_SKIPPED: using existing v0.5.5 prepared source tree"\n'
    'else\n'
    '  chmod +x "${PREPARE_SCRIPT}"\n'
    '  python3 "${PREPARE_SCRIPT}"\n'
    'fi\n',
    "resume source preparation guard",
)

text = replace_once(
    text,
    'rm -rf "${PROFILE_ROOT}" "${LINK_BUILD_DIR}" "${PACKAGE_DIR}" "${ARCHIVE_PATH}" "${ARCHIVE_PATH}.sha256"\n'
    'mkdir -p "${PROFILE_ROOT}" "${ROOT_DIR}/dist"\n',
    'if [[ "${RESUME:-0}" == "1" ]]; then\n'
    '  echo "RESUME=1: preserving completed profile directories"\n'
    '  rm -rf "${LINK_BUILD_DIR}" "${PACKAGE_DIR}" "${ARCHIVE_PATH}" "${ARCHIVE_PATH}.sha256"\n'
    'else\n'
    '  rm -rf "${PROFILE_ROOT}" "${LINK_BUILD_DIR}" "${PACKAGE_DIR}" "${ARCHIVE_PATH}" "${ARCHIVE_PATH}.sha256"\n'
    'fi\n'
    'mkdir -p "${PROFILE_ROOT}" "${ROOT_DIR}/dist"\n',
    "resume cleanup",
)

text = replace_once(
    text,
    '  local dir="${PROFILE_ROOT}/${name}" build_log="${PROFILE_ROOT}/${name}.build.log"\n'
    '  rm -rf "${dir}" "${build_log}"\n'
    '  echo "== PROFILE ${name}: threads=${threads} min_blocks=${min_blocks} split=${split} ilp=${ilp} max_regs=${max_regs:-auto} =="\n',
    '  local dir="${PROFILE_ROOT}/${name}" build_log="${PROFILE_ROOT}/${name}.build.log"\n'
    '  if [[ "${RESUME:-0}" == "1" && -s "${dir}/profile.hps" && -s "${dir}/profile.meta" ]] \\\n'
    '     && grep -qx "valid=1" "${dir}/profile.meta"; then\n'
    '    printf "PROFILE_REUSE name=%s hps=%s\\n" "${name}" "$(cat "${dir}/profile.hps")"\n'
    '    return 0\n'
    '  fi\n'
    '  rm -rf "${dir}" "${build_log}"\n'
    '  echo "== PROFILE ${name}: threads=${threads} min_blocks=${min_blocks} split=${split} ilp=${ilp} max_regs=${max_regs:-auto} =="\n',
    "profile reuse",
)

text = replace_once(
    text,
    'for threads in 32 96 128 192; do\n',
    'for threads in 96 128 160 192; do\n',
    "supported thread sweep",
)

TARGET.write_text(text, encoding="utf-8")
print("PASS: v0.5.5 resume/source-preparation/thread-sweep hotfix applied")
