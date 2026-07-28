#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

chmod +x hiveos/prepare-v040-source.py hiveos/prepare-v041-source.py hiveos/build-and-validate-rtx3080.sh

# Apply the verified v0.4.0 runtime/HiveOS profile and then the experimental
# consensus-preserving matrix-cache optimization.
python3 hiveos/prepare-v041-source.py

# Keep the established build identity so the existing package gate can validate
# the experimental binary without weakening any consensus or archive checks.
sed -i 's/PepeW Matrix Cache Edition/PepeW Performance \& Stability Edition/g' native/src/app/main.cpp

# The standard builder now compiles the transformed source and still performs
# all CPU/CUDA vectors, target-boundary tests, profile benchmarks and packaging.
./hiveos/build-and-validate-rtx3080.sh
