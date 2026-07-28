#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

chmod +x hiveos/prepare-v041-source.py hiveos/build-and-validate-rtx3080.sh

# The standard validation builder now selects the correct source preparation
# and binary identity directly from VERSION. This avoids applying v0.4.0 twice
# after the v0.4.1 telemetry marker has already been added.
./hiveos/build-and-validate-rtx3080.sh
