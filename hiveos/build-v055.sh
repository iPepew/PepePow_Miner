#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "${DIR}/patch-v055-resume.py"
exec "${DIR}/build-v055-ilp.sh" "$@"
