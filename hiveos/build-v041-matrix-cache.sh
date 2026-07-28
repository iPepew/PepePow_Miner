#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

chmod +x hiveos/prepare-v040-source.py hiveos/prepare-v041-source.py hiveos/build-and-validate-rtx3080.sh

# Apply the verified HiveOS/runtime profile and the consensus-preserving
# matrix-cache optimization.
python3 hiveos/prepare-v041-source.py

# Reuse the established validation/packaging pipeline, but require the actual
# v0.4.1 edition identity instead of rewriting the binary back to an older name.
sed -i 's/PepeW Performance \& Stability Edition/PepeW Matrix Cache Edition/g' \
  hiveos/build-and-validate-rtx3080.sh
sed -i 's/PepeW RTX 3080 Autotune Edition/PepeW Matrix Cache Autotune Edition/g' \
  hiveos/build-and-validate-rtx3080.sh

# This still runs all CPU/CUDA vectors, live target-boundary tests, RTX 3080
# profile benchmarks, HiveOS checks and archive validation.
./hiveos/build-and-validate-rtx3080.sh
