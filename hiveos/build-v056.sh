#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/.." && pwd)"
if [[ ! -f "${ROOT}/native/src/cuda/header80_backend_v054.cu" ]]; then
  echo "BOOTSTRAP: generating v0.5.4 source backend"
  python3 "${DIR}/prepare-v054-source.py"
fi
exec "${DIR}/build-v056-cold-path.sh" "$@"
