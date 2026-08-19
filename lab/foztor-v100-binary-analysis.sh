#!/usr/bin/env bash
set -Eeuo pipefail

# Static inspection harness for Foztor hoo_gpu on a HiveOS/NVIDIA rig.
# Purpose: learn the actual sm_70 packaging, kernel/resource layout and exposed
# tuning knobs of the performance reference without changing or patching it.
#
# The script downloads the official Foztor archive, records metadata and uses
# NVIDIA binutils when available. It does NOT require wallet/pool credentials.

FOZTOR_VERSION="${FOZTOR_VERSION:-1.4.23}"
FOZTOR_URL="${FOZTOR_URL:-https://htn.foztor.net/hoo_gpu-${FOZTOR_VERSION}.tar.gz}"
OUT_ROOT="${FOZTOR_ANALYSIS_DIR:-/tmp/pepew-foztor-analysis}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${OUT_ROOT}/${STAMP}"
WORK_DIR="${OUT_DIR}/work"
REPORT="${OUT_DIR}/summary.txt"

mkdir -p "${WORK_DIR}"
exec > >(tee -a "${REPORT}") 2>&1

echo "=== PEPEW / FOZTOR V100 BINARY ANALYSIS ==="
echo "utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "version: ${FOZTOR_VERSION}"
echo "url: ${FOZTOR_URL}"
echo "output: ${OUT_DIR}"
echo

if command -v nvidia-smi >/dev/null 2>&1; then
  echo "=== GPU ==="
  nvidia-smi --query-gpu=index,name,pci.bus_id,compute_cap,driver_version,clocks.current.graphics,clocks.current.memory,power.limit --format=csv,noheader || true
  echo
fi

fetch() {
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 20 -o "$dest" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$dest" "$url"
  else
    echo "ERROR: curl or wget is required" >&2
    exit 2
  fi
}

ARCHIVE="${WORK_DIR}/hoo_gpu-${FOZTOR_VERSION}.tar.gz"
echo "=== DOWNLOAD ==="
fetch "${FOZTOR_URL}" "${ARCHIVE}"
sha256sum "${ARCHIVE}" | tee "${OUT_DIR}/archive.sha256"
ls -lh "${ARCHIVE}"
echo

echo "=== ARCHIVE CONTENTS ==="
tar -tzf "${ARCHIVE}" | tee "${OUT_DIR}/archive-contents.txt"
tar -xzf "${ARCHIVE}" -C "${WORK_DIR}"
echo

BIN="$(find "${WORK_DIR}" -type f -name hoo_gpu -perm -u+x -print -quit || true)"
if [[ -z "${BIN}" ]]; then
  BIN="$(find "${WORK_DIR}" -type f -name hoo_gpu -print -quit || true)"
fi
if [[ -z "${BIN}" ]]; then
  echo "ERROR: hoo_gpu binary not found in archive" >&2
  exit 3
fi

echo "=== MAIN BINARY ==="
echo "binary: ${BIN}"
file "${BIN}" || true
sha256sum "${BIN}" | tee "${OUT_DIR}/hoo_gpu.sha256"
ls -lh "${BIN}"
ldd "${BIN}" 2>&1 | tee "${OUT_DIR}/ldd.txt" || true
readelf -h "${BIN}" > "${OUT_DIR}/readelf-header.txt" 2>&1 || true
readelf -S "${BIN}" > "${OUT_DIR}/readelf-sections.txt" 2>&1 || true
readelf -Ws "${BIN}" > "${OUT_DIR}/readelf-symbols.txt" 2>&1 || true
objdump -T "${BIN}" > "${OUT_DIR}/dynamic-symbols.txt" 2>&1 || true
echo

echo "=== EXPOSED TUNING / CUDA STRINGS ==="
strings -a "${BIN}" | grep -Ei \
  'sm_[0-9]+|compute_[0-9]+|fatbin|cubin|ptx|autotun|tuner|exp-threshold|threshold|block|thread|launch|occup|register|fp64|double|cuda|volta|v100|invalid|validate|solver' \
  | sort -u | tee "${OUT_DIR}/interesting-strings.txt" | head -n 250 || true
echo

echo "=== HOO_GPU HELP ==="
(timeout 20s "${BIN}" --help || true) 2>&1 | tee "${OUT_DIR}/hoo_gpu-help.txt"
echo

mapfile -t FATFILES < <(find "${WORK_DIR}" -type f \( -iname '*.fatbin' -o -iname '*.cubin' -o -iname '*.ptx' \) -print | sort)
echo "=== CUDA PAYLOAD FILES ==="
if (( ${#FATFILES[@]} == 0 )); then
  echo "No standalone .fatbin/.cubin/.ptx files found. Checking all extracted files for CUDA payloads."
else
  for f in "${FATFILES[@]}"; do
    printf '%10s  %s\n' "$(stat -c %s "$f" 2>/dev/null || echo '?')" "$f"
    file "$f" || true
  done
fi
echo

CUDA_OBJS=("${BIN}")
if (( ${#FATFILES[@]} > 0 )); then
  CUDA_OBJS+=("${FATFILES[@]}")
fi

if command -v cuobjdump >/dev/null 2>&1; then
  echo "=== CUOBJDUMP ==="
  cuobjdump --version 2>&1 | head -n 5 || true
  idx=0
  for obj in "${CUDA_OBJS[@]}"; do
    idx=$((idx + 1))
    base="${OUT_DIR}/cuobj-${idx}"
    echo "--- object ${idx}: ${obj} ---"
    cuobjdump --list-elf "${obj}" > "${base}-list-elf.txt" 2>&1 || true
    cuobjdump --list-ptx "${obj}" > "${base}-list-ptx.txt" 2>&1 || true
    cuobjdump --dump-resource-usage "${obj}" > "${base}-resources.txt" 2>&1 || true
    cuobjdump --dump-elf-symbols "${obj}" > "${base}-symbols.txt" 2>&1 || true
    cuobjdump --dump-sass "${obj}" > "${base}-sass.txt" 2>&1 || true

    echo "ELF images:"
    sed -n '1,120p' "${base}-list-elf.txt" || true
    echo "Resource highlights:"
    grep -Ei 'Function|REG|STACK|SHARED|LOCAL|CONSTANT|sm_70|code for' "${base}-resources.txt" | head -n 250 || true
    echo "Kernel/symbol highlights:"
    grep -Ei 'hoohash|hoo_|kernel|solve|hash|mat|exp|sin|cos|sm_70' "${base}-symbols.txt" | head -n 250 || true
  done
else
  echo "WARNING: cuobjdump not found. Install/locate CUDA toolkit binutils before the next pass."
fi

echo
if command -v nvdisasm >/dev/null 2>&1; then
  echo "nvdisasm: $(command -v nvdisasm)"
  nvdisasm --version 2>&1 | head -n 5 || true
else
  echo "nvdisasm not found"
fi

# Compact grep across generated SASS to reveal the instruction mix without
# flooding the terminal. Full SASS remains in the report directory.
echo
echo "=== SASS INSTRUCTION MIX (TOP) ==="
if compgen -G "${OUT_DIR}/cuobj-*-sass.txt" >/dev/null; then
  awk '/^[[:space:]]*\/\*[0-9a-fA-F]+\*\// {for(i=1;i<=NF;i++) if($i ~ /^[A-Z][A-Z0-9_.]+$/){gsub(/;.*/,"",$i); print $i; break}}' \
    "${OUT_DIR}"/cuobj-*-sass.txt 2>/dev/null \
    | sort | uniq -c | sort -nr | head -n 100 \
    | tee "${OUT_DIR}/sass-instruction-mix.txt" || true
fi

# Focus specifically on expensive FP64/transcendental-related call patterns.
echo
echo "=== FP64 / TRANSCENDENTAL SASS HINTS ==="
if compgen -G "${OUT_DIR}/cuobj-*-sass.txt" >/dev/null; then
  grep -Ehi 'DADD|DMUL|DFMA|DSETP|MUFU|CALL|JCAL|SIN|COS|EX2|LG2|RCP|SQRT' "${OUT_DIR}"/cuobj-*-sass.txt \
    | head -n 300 | tee "${OUT_DIR}/sass-fp64-hints.txt" || true
fi

echo
echo "=== PACKAGE REPORT ==="
rm -rf "${WORK_DIR}"
tar -C "${OUT_ROOT}" -czf "${OUT_ROOT}/foztor-v100-analysis-${STAMP}.tar.gz" "${STAMP}"
echo "Report directory: ${OUT_DIR}"
echo "Upload this file to ChatGPT: ${OUT_ROOT}/foztor-v100-analysis-${STAMP}.tar.gz"
echo "Done."
